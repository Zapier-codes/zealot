# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index?
    tenant_access? && user_signed_in_or_guest_mode?
  end

  def show?
    tenant_access? && (scope.where(id: record.id).exists? || user_signed_in_or_guest_mode?)
  end

  def create?
    manage?
  end

  def new?
    manage?
  end

  def update?
    manage?
  end

  def edit?
    manage?
  end

  def destroy?
    manage?
  end

  def scope
    Pundit.policy_scope!(user, record.class)
  end

  delegate :admin?, :developer?, :manage?, :member?, to: :user, allow_nil: true

  class Scope
    attr_reader :user, :scope

    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    # Task 37b-iii-s7c-2 (deny by default): on the default host this is exactly what it always was.
    # On a tenant's host a non-member sees nothing, and a member sees only that tenant's rows; a
    # model that cannot say which tenant a row belongs to (no `for_tenant`) is not listed there.
    def resolve
      tenant = Current.tenant
      return scope.all if tenant.nil?
      return scope.none unless user&.tenant_member?(tenant)

      scope.respond_to?(:for_tenant) ? scope.for_tenant(tenant) : scope.none
    end
  end

  protected

  # Task 37b-iii-s7c-2: the request's tenant (`nil` on the default host), from `Current`.
  def request_tenant
    Current.tenant
  end

  # The access rule, in one place. On the default host it is always true (nothing changes for
  # anyone there). On a tenant's host only a member of that tenant passes: no membership means no
  # console, admins included (control plane and tenant plane are separate, ❓4b-b).
  def tenant_access?
    tenant = request_tenant
    return true if tenant.nil?

    user.present? && user.tenant_member?(tenant)
  end

  # Whether a record that carries `tenant_id` (an `App`) belongs to the request's tenant. Always
  # true on the default host: a platform admin (and today's collaborators) still reach every app
  # from there, unchanged.
  def in_request_tenant?(record)
    tenant = request_tenant
    return true if tenant.nil?

    record.respond_to?(:tenant_id) && record.tenant_id == tenant.id
  end

  def app_collaborator?(user, app, role: nil, exclude: false)
    model = Collaborator.where(user: user, app: app)
    return model.exists? unless role
    
    exclude ? model.where.not(role: role).exists? : model.where(role: role).exists?
  end

  # Task 23: the app's owner (Collaborator#owner), i.e. the person who
  # created / first uploaded it. AppPolicy#app_owner? used to filter on
  # `role: 'owner', exclude: true`, and 'owner' is not a Collaborator role, so
  # it matched *any* collaborator (even a plain member).
  def app_owner_of?(app)
    return false if user.blank? || app.blank?

    Collaborator.where(user: user, app: app, owner: true).exists?
  end

  def user_signed_in_or_guest_mode?
    guest_mode? || user_signed_in?
  end

  def guest_mode?
    Setting.guest_mode
  end

  def user_signed_in?
    user.present?
  end
end
