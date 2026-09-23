# frozen_string_literal: true

module UserRoles
  extend ActiveSupport::Concern

  included do
    scope :admins, -> { where(role: :admin) }
    scope :developers, -> { where(role: :developer) }
    scope :members, -> { where(role: :member) }
  end

  # Task 23: with an app given, this is *per app* — an admin, or a collaborator
  # with a manage role (owner = the person who created/first uploaded the app,
  # see App#create_owner). The global developer role used to satisfy this for
  # every app on the instance, so any developer could upload a new build to,
  # edit or delete somebody else's app. Without an app the meaning is
  # unchanged: the global admin/developer check, used for things that aren't
  # about one app (creating an app, admin screens).
  def manage?(app: nil)
    return admin? || developer? if app.nil?

    admin? || app_roles?(app, :manage)
  end

  def grant_admin!
    update!(role: :admin)
  end

  def revoke_admin!
    update!(role: :member)
  end

  def grant_developer!
    update!(role: :developer)
  end

  def revoke_developer!
    update!(role: :member)
  end

  def roles?(value)
    roles.where(role: value.to_sym).exists?
  end

  def app_roles?(app, value)
    value = %w[admin developer] if value.to_sym == :manage
    collaborators.where(app: app, role: value).exists?
  end

  def role_name
    key = if admin?
            :admin
          elsif developer?
            :developer
          else
            :member
          end

    Setting.builtin_roles[key]
  end
end
