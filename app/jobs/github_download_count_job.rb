# frozen_string_literal: true

# Task 45e: every 6 hours, reads GitHub's download count for each live app's installable files
# (GithubDownloadCounter) and republishes the catalog index of an app only when its total went up, so a quiet
# store makes no commits. One failing release is logged and skipped; the next run tries again.
class GithubDownloadCountJob < ApplicationJob
  queue_as :schedule

  def perform
    return unless ReleaseStorage.adapter_name == 'github'

    App.listing_live.find_each do |app|
      raised = app.play_releases_scope.to_a.count { |release| refresh(release) }
      next if raised.zero?

      app.catalog_index_tenants_to_republish_for_stats.each { |tenant| CatalogIndexPublishJob.enqueue_for(tenant) }
    end
  end

  private

  def refresh(release)
    GithubDownloadCounter.refresh(release)
  rescue ReleaseStorage::ConfigurationError, ReleaseStorage::StorageError => e
    logger.error("[GithubDownloadCountJob] release #{release.id}: #{e.message}")
    false
  end
end
