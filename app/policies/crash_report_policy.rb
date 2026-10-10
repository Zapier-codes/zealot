# frozen_string_literal: true

# Z-P17. Reading an app's crash reports is exactly as sensitive as editing the app (it can carry a stack trace
# from a real device), so it takes the same per-app rule the other read policies use.
class CrashReportPolicy < ApplicationPolicy
  def index?
    any_manage?
  end

  class Scope < Scope
    def resolve
      scope.all
    end
  end

  private

  def any_manage?
    tenant_access? && in_request_tenant?(app) && manage?(app: app)
  end

  def app
    @app ||= record.is_a?(CrashReport) ? record.app : record.respond_to?(:app) ? record.app : record
  end
end
