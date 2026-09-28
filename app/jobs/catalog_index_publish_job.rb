# frozen_string_literal: true

# Task 27b-iii: publishes the signed catalog index (CatalogIndex::Publish).
#
# 27c enqueues this on go-live, suspension, listing edits and new releases. Until the Pages repo
# and the signing key are set up it logs and does nothing, so an unconfigured deploy is never
# broken by it. A failed publish (GitHub down, branch missing) raises so the job is retried by
# the queue; the index is regenerated from current state each time, so a retry can never publish
# something stale.
#
# Task 37b-iii-s5: the job takes an optional tenant id (the `tenants.tenant_id` string, never the
# numeric row id). No argument, nil, blank or "default" is the DEFAULT tenant and behaves exactly
# as before. Any other value publishes that tenant's own index under its own root, lock and key.
# Callers use `CatalogIndexPublishJob.enqueue_for(tenant)`, which enqueues the default tenant with
# no argument at all so its queued job is byte-for-byte what it was before this slice.
#
# A tenant that has no Pages repo configured, does not exist (deleted after the job was
# enqueued) or has no active signing key is logged and skipped, never raised: retrying cannot fix
# any of them, and a raise would only fill the queue with doomed retries.
#
#   rails runner 'CatalogIndexPublishJob.perform_now'          # publish the default tenant now
#   rails runner 'CatalogIndexPublishJob.perform_now("acme")'  # publish tenant "acme" now
class CatalogIndexPublishJob < ApplicationJob
  queue_as :default

  retry_on CatalogIndex::GithubPagesCommit::Error, wait: :polynomially_longer, attempts: 5

  # Enqueue a publish for whichever tenant owns the change. `tenant` may be nil (default), a tenant
  # id String, a `Tenant`, or anything answering `tenant_id`.
  def self.enqueue_for(tenant = nil)
    return perform_later if CatalogIndex::KeyResolver.default?(tenant)

    perform_later(CatalogIndex::KeyResolver.tenant_id_of(tenant))
  end

  def perform(tenant_id = nil)
    if CatalogIndex::KeyResolver.default?(tenant_id)
      perform_default
    else
      perform_tenant(CatalogIndex::KeyResolver.tenant_id_of(tenant_id))
    end
  end

  private

  def perform_default
    unless CatalogIndex::Publish.configured?
      Rails.logger.warn('[CatalogIndexPublishJob] skipped: set CATALOG_PAGES_REPO and CATALOG_PAGES_TOKEN and ' \
                        'run `rake catalog_index:generate_key` first')
      return
    end

    log_result(CatalogIndex::Publish.call)
  end

  def perform_tenant(tenant_id)
    unless CatalogIndex::Publish.configured?(tenant_id)
      Rails.logger.warn("[CatalogIndexPublishJob] skipped tenant=#{tenant_id}: no Pages repo configured, " \
                        'no such tenant, or no active catalog_index signing key')
      return
    end

    log_result(CatalogIndex::Publish.call(tenant: tenant_id), tenant_id)
  rescue CatalogIndex::Signer::NoKeyError => e
    # The tenant lost its key between the check above and the signing step.
    Rails.logger.warn("[CatalogIndexPublishJob] skipped tenant=#{tenant_id}: #{e.message}")
  end

  def log_result(result, tenant_id = nil)
    scope = tenant_id ? " tenant=#{tenant_id}" : ''
    Rails.logger.info("[CatalogIndexPublishJob]#{scope} #{result.status} generated_at=#{result.generated_at.iso8601} " \
                      "commit=#{result.commit_sha} hook=#{result.hook}")
  end
end
