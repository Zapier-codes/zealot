# frozen_string_literal: true

# Z-P17 (Play Console parity): the opt-in crash/vitals intake. An app's crash reporter (the Storeapp half uses
# ACRA) POSTs an event here; Zealot records it against the app, grouped by fingerprint.
#
# Two gates, both required, both fail closed:
#   1. a per-app token in `Authorization: Bearer zpa_...` (Api::AppTokenAuth, scope `vitals`), which also fixes
#      the app the event belongs to -- the body can never choose a different app;
#   2. the app's own `crash_reporting_enabled` must be true. A report for an app that has not opted in is
#      refused with 403 and records nothing, so a build that still has the reporter compiled in cannot send
#      after the owner turns it off.
#
# The accepted fields are the minimum that makes a crash actionable (see CrashReport). Unknown fields are
# ignored, so a newer reporter cannot widen what is stored. No user id, no advertising id, no free-form blob.
#
# A malformed body (no message and no trace) is refused 422 and changes nothing. A repeat of the same event
# (same report_id) is answered 200 and writes nothing, so a reporter's retry is harmless.
class Api::CrashReportsController < Api::BaseController
  include Api::AppTokenAuth

  before_action :validate_app_token
  before_action :require_crash_reporting_enabled

  PERMITTED = %i[kind message stack_trace app_version_name app_version_code android_version device_model
                 report_id occurred_at].freeze

  # POST /api/crash_reports
  #
  #   { "kind": "crash", "message": "FATAL EXCEPTION: main ...", "stack_trace": "...",
  #     "app_version_name": "1.1.4", "app_version_code": "218", "android_version": "14",
  #     "device_model": "Pixel 7", "report_id": "uuid", "occurred_at": "2026-10-10T12:00:00Z" }
  def create
    body = params.permit(*PERMITTED)
    return render json: { error: 'a report needs a message or a stack trace' }, status: :unprocessable_entity if blank_event?(body)
    return render json: { message: 'OK' }, status: :ok if already_recorded?(body[:report_id])

    report = CrashReport.new(
      app: @app_token.app,
      release: @app_token.app.releases.find_by(build_version: body[:app_version_code].to_s),
      tenant_id: @app_token.app.tenant_id,
      kind: normalized_kind(body[:kind]),
      fingerprint: CrashReport.fingerprint_for(kind: normalized_kind(body[:kind]), message: body[:message], stack_trace: body[:stack_trace]),
      message: body[:message].to_s,
      stack_trace: body[:stack_trace].to_s,
      app_version_name: body[:app_version_name].to_s.presence,
      app_version_code: body[:app_version_code].to_s.presence,
      android_version: body[:android_version].to_s.presence,
      device_model: body[:device_model].to_s.presence,
      report_id: body[:report_id].to_s.presence,
      occurred_at: parse_time(body[:occurred_at]) || Time.current
    )

    if report.save
      render json: { message: 'OK', fingerprint: report.fingerprint }, status: :created
    else
      render json: { error: report.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  private

  # Only a vitals-scoped token reaches this endpoint (Z-P17: "only the vitals intake accepts it, and it can
  # never publish"). The concern fails closed on any other scope.
  def required_app_token_scope
    AppApiToken::VITALS_SCOPE
  end

  def require_crash_reporting_enabled
    return if @app_token&.app&.crash_reporting_enabled?

    render json: { error: 'Crash reporting is not enabled for this app' }, status: :forbidden
  end

  def blank_event?(body)
    body[:message].to_s.strip.empty? && body[:stack_trace].to_s.strip.empty?
  end

  def already_recorded?(report_id)
    value = report_id.to_s.strip
    return false if value.empty?

    CrashReport.exists?(app_id: @app_token.app_id, report_id: value)
  end

  def normalized_kind(kind)
    value = kind.to_s.strip.downcase
    CrashReport::KINDS.include?(value) ? value : 'crash'
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
