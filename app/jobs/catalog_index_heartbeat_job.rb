# frozen_string_literal: true

# Task 49: a heartbeat for the signed catalog index.
#
# Every index carries `expires_at` (`Serializer::DEFAULT_TTL`) and a reader (D-Store, Storeapp) refuses an
# expired one, falling back to whatever it last stored. Until now the index was published only when
# something changed (a go-live, a release, a listing edit, a download-count change), so after a quiet
# day it expired and the website went back to an old copy. This job republishes every configured index on
# a timer, well inside the TTL, whether or not anything changed. It is the standard "signed feed"
# arrangement: re-sign on a schedule shorter than the validity window.
#
# It adds no behaviour of its own: each publish is an ordinary `CatalogIndexPublishJob` (Pages repo, key,
# retries, "skip what is not configured"). A tenant is enqueued directly with `perform_later`, NOT through
# `CatalogIndexPublishJob.enqueue_for`, because that marks the tenant's ancestors dirty; every tenant is
# republished here anyway, so no ancestor cascade is needed.
#
# Render's Free plan sleeps the service and GoodJob does not backfill a missed cron tick, so
# `config/initializers/good_job.rb` schedules this twice a day inside the windows
# `.github/workflows/wake_render_service.yml` keeps the service awake (16:05 and 22:05 UTC). With a
# 48 hour TTL one missed tick still leaves the index valid.
#
#   rails runner 'CatalogIndexHeartbeatJob.perform_now'   # republish every configured index now
class CatalogIndexHeartbeatJob < ApplicationJob
  queue_as :default

  def perform
    enqueued = []

    if CatalogIndex::Publish.configured?
      CatalogIndexPublishJob.perform_later
      enqueued << 'default'
    end

    ::Tenant.pluck(:tenant_id).each do |tenant_id|
      next unless CatalogIndex::Publish.configured?(tenant_id)

      CatalogIndexPublishJob.perform_later(tenant_id)
      enqueued << tenant_id
    end

    Rails.logger.info("[CatalogIndexHeartbeatJob] republishing #{enqueued.size} index(es): #{enqueued.join(', ')}")
  end
end
