# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TenantSigningKey do
  let(:tenant) { create(:tenant) }
  let(:other_tenant) { create(:tenant) }

  describe 'a new key' do
    it 'derives the public key and id from the private key' do
      key = create(:tenant_signing_key, tenant: tenant)

      expect(key.public_key).to eq(CatalogIndex::Ed25519.public_key_b64(key.private_key_pem))
      expect(key.key_id).to eq(CatalogIndex::Ed25519.key_id(key.public_key))
    end

    it 'keeps the private key encrypted at rest' do
      key = create(:tenant_signing_key, tenant: tenant)
      raw = described_class.connection.select_value(
        "SELECT private_key_pem FROM tenant_signing_keys WHERE id = #{key.id}"
      )

      expect(raw).not_to include('PRIVATE KEY')
      expect(described_class.find(key.id).private_key_pem).to include('PRIVATE KEY')
    end

    it 'refuses an unknown purpose or status, a missing tenant, and a missing private key' do
      expect(build(:tenant_signing_key, tenant: tenant, purpose: 'tenant_config')).not_to be_valid
      expect(build(:tenant_signing_key, tenant: tenant, status: 'revoked')).not_to be_valid
      expect(build(:tenant_signing_key, tenant: nil)).not_to be_valid
      expect(build(:tenant_signing_key, tenant: tenant, private_key_pem: nil)).not_to be_valid
    end

    it 'refuses a public key another tenant already has (no two tenants share a key)' do
      pem = CatalogIndex::Ed25519.generate_pem
      existing = create(:tenant_signing_key, tenant: tenant, private_key_pem: pem)

      expect(build(:tenant_signing_key, tenant: other_tenant, private_key_pem: pem)).not_to be_valid
      # Bypass validations to reach the unique index itself (the derived fields are set by hand).
      dup = build(:tenant_signing_key, tenant: other_tenant, private_key_pem: pem,
                                       public_key: existing.public_key, key_id: existing.key_id)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'the database refuses what the model refuses, even with validations skipped' do
    def insert_bypassing_validations(**attrs)
      key = build(:tenant_signing_key, tenant: tenant, **attrs)
      key.valid? # derives public_key/key_id like a normal save would
      key.save!(validate: false)
    end

    it 'an unknown status or purpose' do
      expect { insert_bypassing_validations(status: 'revoked') }.to raise_error(ActiveRecord::StatementInvalid)
      expect { insert_bypassing_validations(purpose: 'tenant_config') }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it 'a key that can still sign but has no private key; a retired one may lack it' do
      key = build(:tenant_signing_key, tenant: tenant, status: 'active', private_key_pem: nil)
      key.public_key = CatalogIndex::Ed25519.public_key_b64(CatalogIndex::Ed25519.generate_pem)
      key.key_id = 'abc'
      expect { key.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid, /private_key_unless_retired/)

      retired = build(:tenant_signing_key, tenant: tenant, status: 'retired', private_key_pem: nil,
                                           public_key: CatalogIndex::Ed25519.public_key_b64(CatalogIndex::Ed25519.generate_pem),
                                           key_id: 'def')
      expect { retired.save!(validate: false) }.not_to raise_error
    end

    it 'a key for a tenant that does not exist' do
      key = build(:tenant_signing_key, tenant: tenant)
      key.valid?
      key.tenant_id = 0
      expect { key.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe 'one pending, one active and one retiring key per tenant' do
    %w[active pending retiring].each do |status|
      it "refuses a second #{status} key for the same tenant, in the model and in the index" do
        create(:tenant_signing_key, tenant: tenant, status: status)
        second = build(:tenant_signing_key, tenant: tenant, status: status)

        expect(second).not_to be_valid
        expect(second.errors[:status]).to be_present
        expect { second.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
      end

      it "allows an #{status} key for each of two tenants" do
        create(:tenant_signing_key, tenant: tenant, status: status)

        expect(build(:tenant_signing_key, tenant: other_tenant, status: status)).to be_valid
      end
    end

    it 'allows several retired keys' do
      2.times do
        key = create(:tenant_signing_key, tenant: tenant, status: 'retiring')
        key.update!(status: 'retired', private_key_pem: nil)
      end

      expect(described_class.where(tenant: tenant, status: 'retired').count).to eq(2)
    end
  end

  describe 'status only moves forward, one step at a time' do
    it 'accepts pending -> active -> retiring -> retired' do
      key = create(:tenant_signing_key, tenant: tenant, status: 'pending')
      key.update!(status: 'active')
      key.update!(status: 'retiring')
      key.update!(status: 'retired', private_key_pem: nil)

      expect(key.reload).to be_retired
    end

    it 'refuses going back, skipping a step, and reviving a retired key' do
      key = create(:tenant_signing_key, tenant: tenant, status: 'active')
      expect(key.update(status: 'pending')).to be false
      key.reload
      expect(key.update(status: 'retired', private_key_pem: nil)).to be false
      key.reload

      key.update!(status: 'retiring')
      key.update!(status: 'retired', private_key_pem: nil)
      expect(key.update(status: 'active', private_key_pem: CatalogIndex::Ed25519.generate_pem)).to be false
    end

    it 'requires a private key on every key that can still sign, but not on a retired one' do
      key = create(:tenant_signing_key, tenant: tenant, status: 'retiring')

      expect(key.update(private_key_pem: nil)).to be false
      expect(key.update(status: 'retired', private_key_pem: nil)).to be true
    end

    it 'never changes tenant, purpose, public key or key id' do
      key = create(:tenant_signing_key, tenant: tenant)
      original = key.slice(:tenant_id, :purpose, :public_key, :key_id)

      { tenant: other_tenant, public_key: 'x', key_id: 'x' }.each do |attr, value|
        begin
          key.update!(attr => value)
        rescue ActiveRecord::ReadonlyAttributeError
          nil # raised when raise_on_assign_to_attr_readonly is on; otherwise the write is dropped
        end
        expect(key.reload.slice(:tenant_id, :purpose, :public_key, :key_id)).to eq(original)
      end
    end
  end

  describe '#sign' do
    it 'signs bytes that verify against its own public key when active or retiring' do
      %w[active retiring].each do |status|
        key = create(:tenant_signing_key, status: status)

        expect(CatalogIndex::Ed25519.verify(key.public_key, 'hello', key.sign('hello'))).to be true
      end
    end

    it 'refuses to sign when pending or retired' do
      pending_key = create(:tenant_signing_key, :pending)
      expect { pending_key.sign('x') }.to raise_error(described_class::NotSigningError)

      retired = create(:tenant_signing_key, :retiring)
      retired.update!(status: 'retired', private_key_pem: nil)
      expect { retired.sign('x') }.to raise_error(described_class::NotSigningError)
    end
  end

  describe '.active_for' do
    it 'returns only that tenant\'s active key, never another tenant\'s' do
      mine = create(:tenant_signing_key, tenant: tenant)
      theirs = create(:tenant_signing_key, tenant: other_tenant)
      create(:tenant_signing_key, :pending, tenant: tenant)

      expect(described_class.active_for(tenant)).to eq(mine)
      expect(described_class.active_for(other_tenant)).to eq(theirs)
      expect(described_class.active_for(create(:tenant))).to be_nil
    end
  end

  describe 'the tenant' do
    it 'cannot be destroyed while it has keys' do
      create(:tenant_signing_key, tenant: tenant)

      expect(tenant.destroy).to be false
      expect(Tenant.exists?(tenant.id)).to be true
    end
  end
end
