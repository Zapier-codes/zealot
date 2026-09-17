class Download::ReleasesController < ApplicationController
  before_action :set_release

  def download
    # If a patched internal file exists, serve that. Otherwise serve the original.
    if @release.patched_file_path.present? && File.exist?(@release.patched_file_path)
      send_file @release.patched_file_path, filename: File.basename(@release.patched_file_path), disposition: 'attachment'
    else
      send_file @release.file.path, filename: File.basename(@release.file.path), disposition: 'attachment'
    end
  end

  private

  def set_release
    @release = Release.version_by_channel(params[:channel_id], params[:release_id])
  end
end
