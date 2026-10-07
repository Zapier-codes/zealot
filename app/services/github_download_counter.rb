# frozen_string_literal: true

# Task 45e: reads the storage host's own download count for the ONE file a release serves (ReleaseDownload's
# served key) and keeps the highest value seen on the release. Icons, listing graphics, the bundle and the
# compressed split APKs are never asked about: their counts are fetches by the index and mirror, not installs.
#
#   GithubDownloadCounter.refresh(release)  # => true when the stored count went up, false otherwise
#
# Does nothing (false) where storage is not GitHub, where the release has no served file, or where the file is
# not on the host. A host error raises ReleaseStorage::StorageError so the caller decides (the job logs and moves on).
module GithubDownloadCounter
  module_function

  def refresh(release, storage: nil)
    return false unless ReleaseStorage.adapter_name == 'github'

    key = ReleaseDownload.new(release).served_storage_key
    return false if key.blank?

    count = (storage || ReleaseStorage.new(release)).download_count(key)
    return false if count.nil?

    raised = count > release.github_download_count
    release.update_columns(github_download_count: [ count, release.github_download_count ].max,
                           github_download_count_synced_at: Time.current)
    raised
  end
end
