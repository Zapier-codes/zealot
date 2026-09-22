# frozen_string_literal: true

class TeardownJob < ApplicationJob
  queue_as :app_parse

  def perform(release_id, user_id)
    @release_id = release_id
    @user_id = user_id

    # Task 19d: was `release&.file.file; File.exist?(file.path)` — only ever
    # looked at local disk, so teardown (queued behind a sleeping Free-tier
    # Render worker, or re-run later) silently did nothing once a redeploy
    # had wiped it. Falls back to the mirrored copy in storage when the
    # local file is gone.
    ReleaseStorage.new(release).with_local_file do |path|
      metadata = TeardownService.new(path).call
      unless metadata
        logger.error "Unable to parse metadata with release: #{@release_id}"
        next
      end

      metadata.update_attribute(:user_id, @user_id) if @user_id.present?
      update_release_resouces(metadata)
      # broadcast_release_metadata
    end
  rescue ReleaseStorage::MissingFileError => e
    logger.error(e.message)
  rescue AppInfo::UnknownFormatError
    # ignore
  end

  private

  # # turbo_stream_from dom_id(release, :metadata) in view/releases/body/_metadata.html.slim
  # # TODO: not working yet, view include many devise helper methods need current_user from env of request. 
  # def broadcast_release_metadata
  #   return if @user_id.blank? || @release.blank?

  #   turbo_stream(
  #     method: :broadcast_replace_to,
  #     target: dom_id(release, :metadata), # "metadata_release_#{release_id}"
  #     partial: 'releases/body/metadata',
  #     locals: { release: release, signed_in?: true }
  #   )
  # end

  def update_release_resouces(metadata)
    return if release.blank?

    metadata.update_attribute(:release_id, release.id)
    release.update(release_type: metadata.release_type) if release.release_type.blank?
  end

  def release
    @release ||= Release.find(@release_id)
  end
end
