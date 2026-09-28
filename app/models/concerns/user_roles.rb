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

  # Task 37b-iii-s7c-2 (❓4b-a): does this user belong to `tenant` (a `Tenant` row)? The default
  # host has no tenant row and no memberships (nil is never a member), so on the default host this
  # rule is not consulted; the platform's own `role` rules apply there, unchanged.
  def tenant_member?(tenant)
    return false if tenant.nil? || new_record?

    tenant_memberships.exists?(tenant_id: tenant.id)
  end

  # Task 37b-iii-s7c-2 (❓4b-b): "platform admin" is `role = admin` ON THE DEFAULT HOST ONLY. Pass the
  # request's tenant (`Current.tenant`, `nil` on the default host). On a tenant's host an admin is
  # an ordinary user, scoped to that tenant like everyone else; platform-wide power never rides in
  # on a tenant request. (The card wrote `platform_admin?(request)`; the tenant is what is needed,
  # and it keeps this method free of Rack.)
  def platform_admin?(tenant = nil)
    admin? && tenant.nil?
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
