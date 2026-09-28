# frozen_string_literal: true

# Task 38d (decision 3): a tenant's catalog index lists its descendants' apps (38c), so when a
# tenant publishes, every tenant above it is out of date. Publishing each ancestor synchronously
# on every write would be a cascade up the chain; instead the writer only MARKS the ancestors
# dirty (`Tenant#mark_ancestors_dirty!`) and enqueues this job a short time later. The job claims
# every dirty tenant in one statement and enqueues one ordinary `CatalogIndexPublishJob` for each,
# so any number of rapid changes underneath collapse into one republish per ancestor.
#
# Only a change that turns a CLEAN ancestor dirty enqueues this job (`schedule_for` returns
# without doing so while the marker is already set), so a burst of writes enqueues one of these,
# not one per write. A write that lands after the job has claimed the markers sees them clean and
# enqueues the next one: no change is left without a republish behind it.
#
# The actual publish (Pages repo, key, retries, "skip a tenant with no key") is
# `CatalogIndexPublishJob`'s, unchanged. It is enqueued directly with `perform_later`, NOT through
# `enqueue_for`, which would mark this tenant's own ancestors dirty again and loop up the chain.
#
#   rails runner 'TenantIndexRepublishJob.perform_now'   # republish every dirty tenant now
class TenantIndexRepublishJob < ApplicationJob
  queue_as :default

  # Starting point from decision 3 (60 seconds); tunable without a deploy of code.
  def self.debounce
    Integer(ENV.fetch('ZEALOT_TENANT_REPUBLISH_DELAY_SECONDS', 60)).seconds
  rescue ArgumentError, TypeError
    60.seconds
  end

  # Called after a non-default tenant's own publish is enqueued. `tenant` is a `Tenant`, a tenant id
  # String, or anything answering `tenant_id`. The default tenant is not a row and has no ancestors,
  # so it does nothing here; an unknown tenant does nothing either.
  def self.schedule_for(tenant)
    return if CatalogIndex::KeyResolver.default?(tenant)

    row = tenant.is_a?(::Tenant) ? tenant : ::Tenant.find_by(tenant_id: CatalogIndex::KeyResolver.tenant_id_of(tenant))
    return unless row&.persisted?

    set(wait: debounce).perform_later if row.mark_ancestors_dirty!.positive?
  end

  def perform
    tenant_ids = ::Tenant.claim_dirty_tenant_ids
    tenant_ids.each { |tenant_id| CatalogIndexPublishJob.perform_later(tenant_id) }
    Rails.logger.info("[TenantIndexRepublishJob] republishing #{tenant_ids.size} tenant(s): #{tenant_ids.join(', ')}")
  end
end
