# frozen_string_literal: true

# Z-P17 (Play Console parity): the "Android vitals / crashes" page. Play shows an owner the distinct crashes
# their app produced, worst first, with a count and the last time each was seen. This is that page for the
# opt-in crash reporter (`CrashReport`, fed by `Api::CrashReportsController`).
#
# Read-only: a report is append-only, so there is nothing to edit here. The page is reachable whether or not
# crash reporting is on -- when it is off it says how to turn it on (the App content page) rather than 404ing.
class Apps::CrashReportsController < ApplicationController
  include AppArchived

  before_action :authenticate_user!
  before_action :set_app
  before_action -> { set_app_breadcrumbs(app: @app) }

  # GET /apps/:app_id/crash_reports
  def index
    authorize CrashReport.new(app: @app), :index?
    load_page
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  def load_page
    @enabled = @app.crash_reporting_enabled?
    @groups = CrashReport.grouped_for(@app).limit(100)
    @total = CrashReport.where(app_id: @app.id).count
    # The most recent report per fingerprint, so each group can show its stack trace and device context without
    # a query per row.
    @latest = CrashReport.where(app_id: @app.id, fingerprint: @groups.map(&:fingerprint))
                         .order(occurred_at: :desc).group_by(&:fingerprint).transform_values(&:first)
    @title = t('apps.crash_reports.index.title')
  end
end
