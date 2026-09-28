# frozen_string_literal: true

# Task 27d-b: decides where a release's icon comes from, the same two tiers as ReleaseDownload:
#
#   1. the icon still on this host's disk (CarrierWave, `Release#icon`), else
#   2. the copy mirrored by ReleaseFileMirrorJob (`icon_storage_key`, Task 27d-a), as a short-lived
#      signed URL the caller redirects to; else
#   3. nothing.
#
# Tier 2 is what keeps the icon URL working after a redeploy wipes the disk. Only the two lookups
# differ from ReleaseDownload, so `available?` and `resolve` (including its handling of a
# misconfigured or unreachable storage) are inherited unchanged.
class ReleaseIconDownload < ReleaseDownload
  private

  def local_path
    path = @release.icon&.path
    path if path.present? && File.file?(path)
  end

  def remote_key
    @release.icon_storage_key.presence
  end
end
