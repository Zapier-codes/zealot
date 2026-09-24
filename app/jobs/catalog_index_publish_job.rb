# frozen_string_literal: true

# Task 27b-iii: publishes the signed catalog index (CatalogIndex::Publish).
#
# Nothing enqueues this yet — 27c wires it to go_live!, suspension, listing
# edits and new releases. Until the Pages repo and the signing key are set up
# it logs and does nothing, so an unconfigured deploy is never broken by it.
# A failed publish (GitHub down, branch missing) raises so the job is retried
# by the queue; the index is regenerated from current state each time, so a
# retry can never publish something stale.
#
#   rails runner 'CatalogIndexPublishJob.perform_now'   # publish now, by hand
class CatalogIndexPublishJob < ApplicationJob
  queue_as :default

  retry_on CatalogIndex::GithubPagesCommit::Error, wait: :polynomially_longer, attempts: 5

  def perform
    unless CatalogIndex::Publish.configured?
      Rails.logger.warn('[CatalogIndexPublishJob] skipped: set CATALOG_PAGES_REPO and CATALOG_PAGES_TOKEN and ' \
                        'run `rake catalog_index:generate_key` first')
      return
    end

    result = CatalogIndex::Publish.call
    Rails.logger.info("[CatalogIndexPublishJob] #{result.status} generated_at=#{result.generated_at.iso8601} " \
                      "commit=#{result.commit_sha} hook=#{result.hook}")
  end
end
