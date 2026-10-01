# frozen_string_literal: true

# Task 31b (slice 31b-b): read-only view of D-store-owned figures (traffic,
# top searches, report counts, review aggregates). The data comes from
# DstoreStats.fetch, one GET to D-store with a read-only bearer token; this
# controller has no write action and Zealot has no write path to D-store
# (Task 31c). The admin namespace already gates access to admins at the
# routing level, same as Admin::DatabaseAnalyticsController.
class Admin::DstoreStatsController < ApplicationController
  # GET /admin/dstore_stats
  def index
    @result = DstoreStats.fetch
    @stats = @result.stats
  end
end
