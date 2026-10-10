# frozen_string_literal: true

# Z-P18 (SCIM half, Play Console parity): what a SCIM create/update/delete actually does to Zealot. The
# controller (Scim::UsersController) owns the HTTP and the token; this object owns the data change, so it can
# be unit tested and so the same rules apply whether the caller is SCIM or a future console button.
#
# The rules, and why:
#   * Provisioning into a tenant is a `TenantMembership`, never a change to `User#role`. The platform's own
#     role is global; org membership is per tenant, like every other tenant rule (Task 37b-iii-s7c).
#   * A created account is an SSO account: it gets a random password nobody knows (the IdP is the way in) and
#     skips confirmation (the IdP already asserts the email is real). It is never made an admin by SCIM.
#   * De-provision (`active: false`) is DELETE of the membership plus a lock of the account, in one
#     transaction and never a destroy: the audit trail, the apps and the reviews must survive a person leaving
#     the org. Re-provisioning (`active: true` again) restores the membership and unlocks.
#   * A blank/absent attribute is left alone; SCIM PATCHes that only flip `active` must not wipe a name.
class Scim::Provisioner
  # @!attribute created true when a new `User` row was made (a SCIM 201, not a 200)
  Result = Struct.new(:user, :membership, :created, :errors, keyword_init: true) do
    def ok? = errors.blank?
    def active? = membership.present? && !user.access_locked?
  end

  attr_reader :tenant

  # @param tenant [Tenant, nil] the tenant this token is scoped to, or nil for a platform-scoped token
  def initialize(tenant:)
    @tenant = tenant
  end

  # Create a user (or adopt an existing account by email) and, in a tenant, make them a member.
  # @return [Result]
  def create(attributes)
    attrs = normalize(attributes)
    return invalid(:email, 'userName is required') if attrs[:email].blank?

    user = nil
    membership = nil
    created = false
    errors = []

    User.transaction do
      user = User.find_or_initialize_by(email: attrs[:email].downcase)
      created = user.new_record?
      apply_attributes(user, attrs, creating: created)
      unless user.save
        errors = user.errors.full_messages
        raise ActiveRecord::Rollback
      end

      membership = sync_membership(user, active: attrs.fetch(:active, true))
      errors = user.errors.full_messages if errors.empty? && user.errors.any?
    end

    Result.new(user: user, membership: membership, created: created, errors: errors)
  end

  # Update an existing user. `active` controls the membership exactly as create does.
  # @return [Result]
  def update(user, attributes)
    attrs = normalize(attributes)
    errors = []
    membership = nil

    User.transaction do
      apply_attributes(user, attrs, creating: false)
      unless user.save
        errors = user.errors.full_messages
        raise ActiveRecord::Rollback
      end

      membership = sync_membership(user, active: attrs[:active]) if attrs.key?(:active)
      errors = user.errors.full_messages if errors.empty? && user.errors.any?
    end

    Result.new(user: user, membership: membership, created: false, errors: errors)
  end

  # De-provision: drop the membership and lock the account. Kept separate from #update so a DELETE is a
  # DELETE (and idempotent: deleting twice does nothing the second time and still answers success).
  def deactivate(user)
    User.transaction do
      user.tenant_memberships.where(tenant_id: tenant.id).destroy_all if tenant
      user.lock_access!(send_instructions: false) unless user.access_locked?
    end
    Result.new(user: user, membership: nil, created: false, errors: [])
  end

  private

  def normalize(attributes)
    attributes.to_h.symbolize_keys.slice(:email, :username, :active)
  end

  # Writes only the attributes present. `creating` fills the SSO defaults (random password, confirmed).
  def apply_attributes(user, attrs, creating:)
    user.email = attrs[:email].downcase if attrs[:email].present?
    user.username = attrs[:username] if attrs[:username].present?
    if creating
      user.password = Devise.friendly_token[0, 20]
      # Same fallback UserOmniauth#from_omniauth uses: an IdP that sends only `userName` and an email still
      # yields a stored account, because `username` is otherwise required and would refuse the create.
      user.username = attrs[:email].downcase.split('@').first if user.username.blank?
      user.skip_confirmation!
    end
  end

  # Adds or removes the tenant membership for `active`, and keeps the account's lock in step:
  #   * active true  -> membership exists, account unlocked (this is "provisioned here")
  #   * active false -> membership gone, account locked (this is "de-provisioned"; the row stays)
  #   * active nil   -> nothing (a create/update that did not speak to membership leaves it alone)
  # Returns the membership when active, else nil. Never raises: an unexpected save failure leaves the
  # membership as it was and is reported on the user's errors so the caller answers 400 rather than a silent
  # half-provision.
  def sync_membership(user, active:)
    return nil if tenant.nil?
    return nil if active.nil?

    if active == false
      user.tenant_memberships.where(tenant_id: tenant.id).destroy_all
      user.lock_access!(send_instructions: false) unless user.access_locked?
      return nil
    end

    membership = user.tenant_memberships.find_or_initialize_by(tenant_id: tenant.id)
    membership.role ||= 'member'
    membership.save! unless membership.persisted?
    user.unlock_access! if user.access_locked?
    membership
  rescue ActiveRecord::RecordInvalid => e
    user.errors.add(:base, e.record.errors.full_messages.to_sentence)
    nil
  end

  def invalid(field, message)
    user = User.new
    user.errors.add(field, message)
    Result.new(user: user, membership: nil, created: false, errors: user.errors.full_messages)
  end
end
