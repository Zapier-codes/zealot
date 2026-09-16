# frozen_string_literal: true

class Download::ReleasesController < ApplicationController
  before_action :set_release

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_entity_response

  def show
    # password protected check
    unless helpers.logged_in_or_without_auth?(@release) 
      return redirect_to channel_release_path(@release.channel, @release, back_url: @release.download_url)
    end

    return render_not_found_entity_response unless File.exist?(@release.file.path.to_s)

    redirect_to filename_download_release_url(@release, @release.download_filename)
  end

  def download
    # 触发 web_hook
    @release.channel.perform_web_hook('download_events', current_user&.id)

    return serve_brotli if serve_brotli?

    headers['Content-Length'] = @release.file.size
    send_file @release.file.path,
              filename: @release.download_filename,
              disposition: 'attachment'
  end

  # GET /releases/:id/delta?from_version=1.2.3
  #
  # Returns a bsdiff patch that can turn the client's currently-installed
  # `from_version` into this release's APK, instead of downloading the
  # full file again. Falls back to 404 if delta patching is disabled, no
  # prior release matches `from_version`, or patching tools are missing.
  def delta
    return render_not_found_entity_response unless Rails.application.config.x.anthropic.delta_patching_enabled

    from_version = params[:from_version]
    old_release = @release.channel.releases.find_by(release_version: from_version)
    return render_not_found_entity_response unless old_release&.file&.path && @release.file&.path

    patch_path = cached_or_generated_patch(old_release, @release)
    return render_not_found_entity_response unless patch_path && File.exist?(patch_path)

    headers['X-Delta-From-Version'] = from_version
    headers['X-Delta-To-Version'] = @release.release_version.to_s
    send_file patch_path,
              filename: "#{@release.download_filename}.bspatch",
              disposition: 'attachment'
  rescue Anthropic::DeltaService::BsdiffNotFoundError
    render_not_found_entity_response
  end

  private

  def storage
    @storage ||= ReleaseStorage.new(@release)
  end

  def serve_brotli?
    return false unless @release.brotli_compressed?
    return false unless request.headers['Accept-Encoding'].to_s.include?('br')
    return false if @release.compressed_apks_storage_key.blank?

    storage.exist?(@release.compressed_apks_storage_key)
  end

  # Adapters that can hand back a direct URL (e.g. a presigned R2 URL, with
  # Content-Encoding: br already set as object metadata at upload time) get
  # a redirect so the app doesn't proxy the bytes itself. Adapters that
  # can't (local disk) get fetched and streamed through send_file instead.
  def serve_brotli
    key = @release.compressed_apks_storage_key
    direct_url = storage.url_for(key)
    return redirect_to(direct_url, allow_other_host: true) if direct_url

    tmp_path = Rails.root.join('tmp', "brotli-#{@release.id}-#{SecureRandom.hex(4)}.apks.br")
    storage.fetch(key, to: tmp_path)
    return render_not_found_entity_response unless File.exist?(tmp_path)

    headers['Content-Encoding'] = 'br'
    headers['Content-Length'] = @release.compressed_size || File.size(tmp_path)
    send_file tmp_path,
              filename: @release.download_filename,
              disposition: 'attachment'
  end

  # Patches are cached on disk under tmp/anthropic_deltas, keyed by the
  # pair of release ids, so repeated requests for the same from/to
  # version don't recompute the diff every time.
  def cached_or_generated_patch(old_release, new_release)
    cache_dir = Rails.root.join('tmp', 'anthropic_deltas')
    FileUtils.mkdir_p(cache_dir)
    patch_path = cache_dir.join("#{old_release.id}-#{new_release.id}.bspatch").to_s

    return patch_path if File.exist?(patch_path)

    Anthropic::DeltaService.new.diff(old_release.file.path, new_release.file.path, patch_path)
  end

  def render_not_found_entity_response
    render json: {
      error: t('.not_found')
    }, status: :not_found
  end


  def set_release
    @release = Release.find(params[:id])
  end
end


