# frozen_string_literal: true

# Task 37b-ii-k2: a tenant's Ed25519 signing key, one row per key, lifecycle per
# docs/tenant_signing_keys.md (`pending` -> `active` -> `retiring` -> `retired`). NO callers yet:
# the lifecycle service is k3 (`TenantKeys::Lifecycle`), the resolver that picks a tenant's key
# is k4. Rows are meant to be changed only through that service; the model still refuses every
# state that breaks the design's invariants, and the partial unique indexes back it up.
#
# The DEFAULT tenant is never a row here (it stays on `CatalogIndexSigningKey`, which D-store
# already pins), because the default tenant is not a `Tenant` row either.
#
# The private key is encrypted at rest with Active Record Encryption, like
# `CatalogIndexSigningKey`. `public_key`/`key_id` are derived from it on create and never change.
# A RETIRED key has its private key destroyed, so it can no longer sign even by mistake.
class TenantSigningKey < ApplicationRecord
  PURPOSES = %w[catalog_index].freeze
  STATUSES = %w[pending active retiring retired].freeze
  # A key only ever moves forward, one step (doc section 2, invariant 3).
  NEXT_STATUS = { 'pending' => 'active', 'active' => 'retiring', 'retiring' => 'retired' }.freeze
  SIGNING_STATUSES = %w[active retiring].freeze
  # At most one row in each of these per (tenant, purpose); `retired` may be many.
  SINGLE_STATUSES = %w[pending active retiring].freeze

  # Raised by #sign on a key that must not sign (`pending`, `retired`).
  class NotSigningError < StandardError; end

  encrypts :private_key_pem

  belongs_to :tenant

  attr_readonly :tenant_id, :purpose, :public_key, :key_id

  before_validation :derive_public_fields, on: :create

  validates :purpose, inclusion: { in: PURPOSES }
  validates :status, inclusion: { in: STATUSES }
  validates :public_key, :key_id, presence: true
  validates :public_key, uniqueness: true, on: :create
  validates :private_key_pem, presence: true, unless: :retired?
  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :one_key_per_single_status
  validate :status_moves_forward_only, on: :update

  scope :for_tenant, ->(tenant, purpose = 'catalog_index') { where(tenant: tenant, purpose: purpose) }

  # The key of record for one tenant and purpose, or nil. Scoped by the tenant record itself, so
  # tenant A's lookup can never return tenant B's key.
  def self.active_for(tenant, purpose = 'catalog_index')
    for_tenant(tenant, purpose).find_by(status: 'active')
  end

  STATUSES.each do |name|
    define_method(:"#{name}?") { status == name }
  end

  def signing?
    SIGNING_STATUSES.include?(status)
  end

  # @return [String] base64 signature over exactly these bytes
  # @raise [NotSigningError] unless this key is `active` or `retiring`
  def sign(data)
    raise NotSigningError, "a #{status} tenant key must not sign" unless signing?

    CatalogIndex::Ed25519.sign(private_key_pem, data)
  end

  private

  def derive_public_fields
    return if private_key_pem.blank?

    self.public_key = CatalogIndex::Ed25519.public_key_b64(private_key_pem)
    self.key_id = CatalogIndex::Ed25519.key_id(public_key)
  end

  def one_key_per_single_status
    return unless SINGLE_STATUSES.include?(status)

    clash = self.class.for_tenant(tenant_id, purpose).where(status: status).where.not(id: id).exists?
    errors.add(:status, :taken) if clash
  end

  def status_moves_forward_only
    return unless status_changed?

    errors.add(:status, :backwards) unless NEXT_STATUS[status_was] == status
  end
end
