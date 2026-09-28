# frozen_string_literal: true

# Task 37b-iii-s7c-0 (❓4b-a): a user's membership of one tenant, with a role. NO callers yet: the
# request-tenant reader (s7c-1) and the access rule (s7c-2) are what will read this. Access on a
# tenant's host follows a membership, never the accident of which apps a user touched.
#
# Roles are the smallest set that lets a tenant have a manager (least privilege): `owner` and
# `member`. More roles are a later decision. `users.role` and per-app `Collaborator` roles are
# untouched and stay layered under the tenant check.
#
# The DEFAULT tenant is not a `Tenant` row, so it has no memberships: on the default host the
# platform's own `users.role` rules apply, unchanged.
class TenantMembership < ApplicationRecord
  ROLES = %w[member owner].freeze

  belongs_to :user
  belongs_to :tenant

  enum :role, { member: 'member', owner: 'owner' }, default: 'member', validate: true

  # A user has at most one membership per tenant; the unique index backs this up.
  validates :user_id, uniqueness: { scope: :tenant_id }

  scope :for_tenant, ->(tenant) { where(tenant: tenant) }
  scope :for_user, ->(user) { where(user: user) }
end
