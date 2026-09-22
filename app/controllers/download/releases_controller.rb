# frozen_string_literal: true

# Release downloads. Restored and extended in Task 19c: commit f8a8da89
# (Proxies SDK injection) had replaced this controller with a stub that had no
# `show` action (so `Release#download_url` 404'd) and looked the release up with
# params that this route never provides. Not restored here on purpose: the
# Brotli `.apks.br` serving and the `delta` action that commit also removed; see
# handover.md Task 19 for why that is a decision, not an oversight.
class Download::ReleasesController < ApplicationController
  before_action :set_release

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

  private

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
