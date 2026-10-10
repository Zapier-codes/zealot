# frozen_string_literal: true

# Z-P13 (Play Console parity): when a new release supersedes the previous one, build the File-by-File delta
# a client can use to update in place instead of downloading the whole APK. The patch is made here, while
# both files are still on disk, and *before* `ReleaseSuperseder` destroys the older release (which deletes
# its stored bytes). See ArchivePatcher::Generator for what the patch is and when it is refused.
#
# Runs from ReleaseSupersedeJob, which already fires the moment a release becomes available and installable,
# so the two share one trigger and one ordering. Silent and best-effort: a release with no local copy, no
# previous version, an identical pair, or an unreadable archive leaves `delta_patches` empty and the client
# downloads the full APK, which is always a correct answer.
#
# Off unless ENABLE_DELTA_PATCHING is set (see config/initializers/anthropic_asset_delivery.rb), so an
# un-set deployment produces nothing.
#
# Written, NOT run (no Ruby/Postgres in the sandbox that wrote it); the File-by-File algorithm itself is
# runtime-verified by spec/services/archive_patcher/*, and see spec/jobs/delta_patch_generation_job_spec.rb.
class DeltaPatchGenerationJob < ApplicationJob
  queue_as :default

  def perform(release_id, from_release_id = nil)
    return unless ArchivePatcher::Generator.enabled?

    release = Release.find_by(id: release_id)
    return if release.nil?

    previous = from_release_id ? Release.find_by(id: from_release_id) : previous_release_of(release)
    return if previous.nil?

    manifest = ArchivePatcher::Generator.new(release).generate_from(previous)
    logger.info("[DeltaPatchGenerationJob] release #{release.id}: patch from #{previous.id} " \
                "#{manifest ? "stored (#{manifest['size']} bytes)" : 'not produced'}")
  end

  private

  # The release a client is most likely updating from: the newest earlier release on the same channel.
  def previous_release_of(release)
    release.channel.releases.where('releases.id < ?', release.id).order(id: :desc).first
  end
end
