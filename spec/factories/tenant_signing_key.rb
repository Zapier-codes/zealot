# frozen_string_literal: true

FactoryBot.define do
  factory :tenant_signing_key do
    tenant
    purpose { 'catalog_index' }
    status { 'active' }
    private_key_pem { CatalogIndex::Ed25519.generate_pem }
    add_attribute(:sequence) { 1 } # `sequence` alone would call FactoryBot's own DSL method

    trait(:pending) { status { 'pending' } }
    trait(:retiring) { status { 'retiring' } }
  end
end
