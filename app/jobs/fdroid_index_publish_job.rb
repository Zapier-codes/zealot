# frozen_string_literal: true

# Z-P15b (Play Console parity; docs/PARITY-KANBAN.md): publish the F-Droid repo (index-v2.json,
# entry.json and the signed entry.jar) beside the signed Zealot index. Off unless ENABLE_FDROID_INDEX
# is "true" and a Pages repo and the org signing key exist; otherwise it logs and does nothing, so an
# unconfigured deploy is never broken by it (the same posture as CatalogIndexPublishJob).
#
# Run from the console after a key exists:
#   rails runner 'FdroidIndexPublishJob.perform_now'
#
# A failure (GitHub down, branch missing, jarsigner missing) raises so the queue retries; the repo is
# regenerated from current state each time, so a retry can never publish something stale.
class FdroidIndexPublishJob < ApplicationJob
  queue_as :default

  retry_on CatalogIndex::GithubPagesCommit::Error, wait: :polynomially_longer, attempts: 5

  def perform
    unless FdroidIndex::Publisher.configured?
      Rails.logger.warn('[FdroidIndexPublishJob] skipped: set ENABLE_FDROID_INDEX=true, CATALOG_PAGES_REPO, ' \
                        'CATALOG_PAGES_TOKEN and FDROID_REPO_ADDRESS, and configure an AndroidSigningKey')
      return
    end

    result = FdroidIndex::Publisher.call
    Rails.logger.info("[FdroidIndexPublishJob] #{result.status} packages=#{result.package_count} " \
                      "generated_at=#{result.generated_at.iso8601} commit=#{result.commit_sha}")
  end
end
