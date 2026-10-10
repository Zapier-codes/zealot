# frozen_string_literal: true

# Release downloads. Restored and extended in Task 19c: commit f8a8da89
# (Proxies SDK injection) had replaced this controller with a stub that had no
# `show` action (so `Release#download_url` 404'd) and looked the release up with
# params that this route never provides. The Brotli `.apks.br` serving stayed
# removed (see handover.md Task 19); Z-P13 re-adds `delta`, but for a different
# thing: the File-by-File *update* patch (a `GFbFv1_0` container, one per
# `from_version_code`), not the old whole-file Brotli split.
class Download::ReleasesController < ApplicationController
  before_action :set_release
  before_action -> { redirect_to_canonical_host(@release.channel) }, only: %i[show icon] # Task 37b-iii-s7b, 27d-b

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_entity_response

  def show
    # password protected check
    unless helpers.logged_in_or_without_auth?(@release)
      return redirect_to channel_release_path(@release.channel, @release, back_url: @release.download_url)
    end

    return render_not_found_entity_response unless release_download.available?

    redirect_to filename_download_release_url(@release, @release.download_filename)
  end

  def download
    # 触发 web_hook
    @release.channel.perform_web_hook('download_events', current_user&.id)

    source = release_download.resolve
    case source.kind
    when :file
      # The patched internal APK, else the original.
      send_file source.path, filename: File.basename(source.path), disposition: 'attachment'
    when :redirect
      # Signed, short-lived storage URL (GitHub Releases / R2); never cache it.
      response.headers['Cache-Control'] = 'no-store'
      redirect_to source.url, allow_other_host: true
    else
      render_not_found_entity_response
    end
  end

  # Task 27d-b: the stable, public icon URL the catalog index will carry (27d-c). Serves the local icon,
  # else a signed redirect to the mirrored copy (ReleaseIconDownload), so the URL survives a redeploy.
  # No login or channel-password check: the icon is already a public static file under public/uploads
  # and is shown on the public install page.
  def icon
    source = ReleaseIconDownload.new(@release).resolve
    case source.kind
    when :file
      send_file source.path, type: Rack::Mime.mime_type(File.extname(source.path), 'application/octet-stream'),
                             disposition: 'inline'
    when :redirect
      response.headers['Cache-Control'] = 'no-store'
      redirect_to source.url, allow_other_host: true
    else
      render_not_found_entity_response
    end
  end

  # Z-P13: serve the File-by-File update delta published for this release, made from the version named by
  # `params[:from]` (the value the index carried as `from_version_code`). Same "no login" rule as the
  # download itself: a client that may fetch the APK may fetch its patch. The patch is a stored artifact, so
  # it is served from storage directly, as a signed redirect when the adapter can produce one.
  def delta
    manifest = delta_manifest_for(params[:from])
    return render_not_found_entity_response if manifest.nil?

    key = manifest['storage_key']
    source = delta_source(key)
    case source.kind
    when :file
      send_file source.path, filename: File.basename(source.path), type: 'application/octet-stream',
                             disposition: 'attachment'
    when :redirect
      response.headers['Cache-Control'] = 'no-store'
      redirect_to source.url, allow_other_host: true
    else
      render_not_found_entity_response
    end
  end

  private

  # The manifest whose base version matches the request. Exact string first (the client echoes what the
  # index published); a semver fallback tolerates a client that normalised "1.2.0" to "1.2".
  def delta_manifest_for(from)
    wanted = from.to_s.strip
    patches = @release.respond_to?(:delta_patches) && @release.delta_patches.is_a?(Array) ? @release.delta_patches : []
    exact = patches.find { |p| p.is_a?(Hash) && p['from_version_code'].to_s.strip == wanted }
    return exact if exact

    patches.find { |p| p.is_a?(Hash) && version_equal?(p['from_version_code'], wanted) }
  end

  def version_equal?(a, b)
    return false if a.to_s.strip.empty? || b.to_s.strip.empty?

    Gem::Version.new(a.to_s.strip) == Gem::Version.new(b.to_s.strip)
  rescue ArgumentError
    false
  end

  # @return [ReleaseDownload::Source] a :file/:redirect/:missing triple for the patch's storage key.
  def delta_source(key)
    return ReleaseDownload::MISSING if key.blank?

    storage = ReleaseStorage.new(@release)
    url = storage.url_for(key)
    return ReleaseDownload::Source.new(kind: :redirect, url: url) if url

    Dir.mktmpdir("delta-serve-#{@release.id}-") do |dir|
      fetched = storage.fetch(key, to: File.join(dir, 'patch.gfb'))
      return ReleaseDownload::MISSING unless fetched

      return ReleaseDownload::Source.new(kind: :file, path: fetched)
    end
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    Rails.logger&.warn("[Download::ReleasesController] delta for #{@release.id}: #{e.class}: #{e.message}")
    ReleaseDownload::MISSING
  end

  def release_download
    @release_download ||= ReleaseDownload.new(@release)
  end

  def set_release
    @release = Release.find(params[:id])
  end

  def render_not_found_entity_response
    render json: {
      error: t('download.releases.show.not_found')
    }, status: :not_found
  end
end
