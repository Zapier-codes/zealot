# frozen_string_literal: true

class ReleasePolicy < ApplicationPolicy

  def show?
    true
  end

  def new?
    any_manage?
  end

  def create?
    any_manage?
  end

  def edit?
    any_manage?
  end

  def update?
    any_manage?
  end

  def destroy?
    any_manage?
  end

  def auth?
    true
  end

  # Deliberately admin? and not any_manage?, unlike every other action on
  # this policy: approving/rejecting a Play Store publish is an org-level
  # publishing decision (it's about this org's single verified Play
  # Console identity, not about who can manage the app the release
  # belongs to), so an app-scoped developer/collaborator shouldn't be able
  # to approve their own release for Play Store distribution. See
  # handover.md task #11.
  def approve_play_publish?
    admin?
  end

  def reject_play_publish?
    admin?
  end

  class Scope < Scope
    def resolve
      scope.all
    end
  end

  private

  def enabled_auth?
    record.channel.password.present?
  end

  def any_manage?
    manage? || manage?(app: app)
  end

  def app
    @app ||= record.app
  end
end
