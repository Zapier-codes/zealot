# frozen_string_literal: true

# Task 45g: the exact signed bytes of a tenant's latest catalog index (see CatalogIndex::Publish and
# CatalogController). `index_json` and `signature` are stored and served untouched: a reader checks the signature
# over the raw bytes, so one changed character would make the index fail verification.
class CatalogIndexSnapshot < ApplicationRecord
  DEFAULT_KEY = 'default'

  validates :tenant_key, presence: true, uniqueness: true
  validates :index_json, :signature, :generated_at, presence: true

  # The row key for a tenant (nil, blank and the default tenant all share one).
  def self.key_for(tenant)
    CatalogIndex::KeyResolver.default?(tenant) ? DEFAULT_KEY : CatalogIndex::KeyResolver.tenant_id_of(tenant)
  end

  # Stores (or replaces) a tenant's snapshot.
  def self.store!(tenant:, index_json:, signature:, signing_key_id:, generated_at:)
    record = find_or_initialize_by(tenant_key: key_for(tenant))
    record.update!(index_json: index_json, signature: signature, signing_key_id: signing_key_id, generated_at: generated_at)
    record
  end

  def self.for_tenant(tenant = nil)
    find_by(tenant_key: key_for(tenant))
  end
end
