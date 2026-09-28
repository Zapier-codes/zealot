# frozen_string_literal: true

class DashboardsController < ApplicationController
  before_action :authenticate_user! unless Setting.guest_mode
  before_action :authorize_console

  def index
    @title = t('dashboard.title')

    system_analytics
    recently_upload

    # flash.now[:warn] = {
    #   title: 'warn title',
    #   message: 'warn warn warn warn warn warn warn warn warn warn',
    #     delay: 2000
    # }
    # flash.now[:notice] = 'Test successful notification message.'
    # flash.now[:warn] = 'Test warning notification message.'
    # flash.now[:alert] = 'Test failure notification message.'
  end

  private

  # Task 37b-iii-s7c-4a: on a tenant's host only a member gets the dashboard (a non-member is
  # refused, not shown zeros). Always allowed on the default host.
  def authorize_console
    authorize App, :console?
  end

  # The apps this request may see: every app on the default host, the tenant's own on a tenant's
  # host (the policy scope, the one choke point). Everything below reads through it.
  def visible_apps
    @visible_apps ||= policy_scope(App)
  end

  # The signed-in user's own apps, limited to the ones this request may see.
  def visible_user_apps
    current_user.apps.merge(visible_apps)
  end

  # Whether the user counts every visible app (guest mode, or an admin), as the totals always did.
  def sees_all_apps?
    Setting.guest_mode || !!current_user&.admin?
  end

  # The default host keeps its old, unscoped relations byte for byte; a tenant's host counts only
  # its own releases, debug files and teardowns (reached through the tenant's apps).
  def tenant_releases
    default_host? ? Release.all : Release.for_tenant(current_tenant)
  end

  def tenant_debug_files
    default_host? ? DebugFile.all : DebugFile.where(app_id: visible_apps.select(:id))
  end

  def tenant_metadata
    default_host? ? Metadatum.all : Metadatum.where(release_id: tenant_releases.select(:id))
  end

  def recently_upload
    @releases = tenant_releases.page(params.fetch(:page, 1))
                               .per(params.fetch(:per_page, Setting.per_page))
                               .order(id: :desc)
    return if manage_user_or_guest_mode?

    channel_ids = visible_user_apps.map { |app| app.channel_ids }
    @releases = @releases.where(channel_id: channel_ids)
  end

  def system_analytics
    general_widgets
    admin_panels
  end

  def general_widgets
    @analytics = {
      apps: user_apps,
      debug_files: user_debug_files,
      teardowns: user_teardowns,
      releases: app_uploads,
    }
  end

  def admin_panels
    # Users, webhooks, jobs and disk are platform-wide figures: platform admin (role admin on the
    # DEFAULT host) only. On a tenant's host an admin is scoped to the tenant like everyone else.
    return unless current_user&.platform_admin?(current_tenant)

    @analytics.merge!({
      users: User.count,
      webhooks: WebHook.count,
      jobs: job_stats,
      disk: disk_usage,
    })
  end

  def job_stats
    filters = GoodJob::JobsFilter.new(params)
    states = filters.states
    states['running']
  end

  def disk_usage
    disk = Sys::Filesystem.stat(Rails.root)
    percent = (disk.bytes_used.to_f / disk.bytes_total.to_f * 100.0)
    ActiveSupport::NumberHelper.number_to_percentage(percent, precision: 0)
  end

  def user_apps
    return visible_apps.count if sees_all_apps?
    return 0 unless current_user&.apps

    visible_user_apps.count
  end

  def user_teardowns
    return tenant_metadata.count if sees_all_apps?
    return 0 unless current_user&.metadatum

    current_user.metadatum.merge(tenant_metadata).count
  end

  def user_debug_files
    return tenant_debug_files.count if sees_all_apps?
    return 0 unless current_user&.apps

    visible_user_apps.sum { |app| app.total_debug_files }
  end

  def app_uploads
    return tenant_releases.count if sees_all_apps?
    return 0 unless current_user&.apps

    visible_user_apps.sum { |app| app.total_releases }
  end
end
