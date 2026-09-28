# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CatalogIndexPublishJob do
  it 'does nothing (and does not raise) until the Pages repo and signing key are set up' do
    allow(CatalogIndex::Publish).to receive(:configured?).and_return(false)
    expect(CatalogIndex::Publish).not_to receive(:call)

    expect { described_class.perform_now }.not_to raise_error
  end

  it 'publishes when configured' do
    allow(CatalogIndex::Publish).to receive(:configured?).and_return(true)
    result = CatalogIndex::Publish::Result.new(status: :published, commit_sha: 'abc', generated_at: Time.utc(2026, 9, 28), key_id: 'k', hook: :skipped)
    expect(CatalogIndex::Publish).to receive(:call).and_return(result)

    described_class.perform_now
  end

  # Task 37b-iii-s5: the job takes a tenant id; no argument is the default tenant, unchanged.
  describe 'tenant scoping' do
    let(:result) do
      CatalogIndex::Publish::Result.new(status: :published, commit_sha: 'abc', generated_at: Time.utc(2026, 9, 28),
                                        key_id: 'k', hook: :skipped)
    end

    it 'publishes the default tenant with no arguments when given nothing, nil, blank or "default"' do
      allow(CatalogIndex::Publish).to receive(:configured?).and_return(true)
      expect(CatalogIndex::Publish).to receive(:call).with(no_args).exactly(4).times.and_return(result)

      [[], [nil], [''], ['default']].each { |args| described_class.perform_now(*args) }
    end

    it 'publishes only the named tenant when given a tenant id' do
      allow(CatalogIndex::Publish).to receive(:configured?).with('acme').and_return(true)
      expect(CatalogIndex::Publish).to receive(:call).with(tenant: 'acme').once.and_return(result)

      described_class.perform_now('acme')
    end

    it 'normalizes the tenant id the way the key resolver does' do
      allow(CatalogIndex::Publish).to receive(:configured?).with('acme').and_return(true)
      expect(CatalogIndex::Publish).to receive(:call).with(tenant: 'acme').once.and_return(result)

      described_class.perform_now(' ACME ')
    end

    it 'skips (and does not raise) a tenant that is not configured, and never falls back to the default tenant' do
      allow(CatalogIndex::Publish).to receive(:configured?).with('acme').and_return(false)
      expect(CatalogIndex::Publish).not_to receive(:call)

      expect { described_class.perform_now('acme') }.not_to raise_error
    end

    it 'skips a tenant whose key disappeared between the check and the signing' do
      allow(CatalogIndex::Publish).to receive(:configured?).with('acme').and_return(true)
      allow(CatalogIndex::Publish).to receive(:call).and_raise(CatalogIndex::KeyResolver::NoKeyError, 'no key')

      expect { described_class.perform_now('acme') }.not_to raise_error
    end

    it 'still raises a GitHub failure for a tenant so the queue retries it' do
      allow(CatalogIndex::Publish).to receive(:configured?).with('acme').and_return(true)
      allow(CatalogIndex::Publish).to receive(:call).and_raise(CatalogIndex::GithubPagesCommit::Error, 'down')

      expect { described_class.new.perform('acme') }.to raise_error(CatalogIndex::GithubPagesCommit::Error)
    end
  end

  describe '.enqueue_for' do
    it 'enqueues the default tenant with no argument at all (the queued job is unchanged)' do
      [nil, '', 'default'].each do |tenant|
        expect { described_class.enqueue_for(tenant) }.to have_enqueued_job(described_class).with(no_args)
      end
    end

    it 'enqueues another tenant with its tenant id, from a String or a Tenant' do
      tenant = create(:tenant, tenant_id: 'acme')

      expect { described_class.enqueue_for('acme') }.to have_enqueued_job(described_class).with('acme')
      expect { described_class.enqueue_for(tenant) }.to have_enqueued_job(described_class).with('acme')
    end

    # Task 38d
    it 'schedules no ancestor republish for the default tenant, or for a tenant with no parent' do
      create(:tenant, tenant_id: 'acme')

      expect { described_class.enqueue_for(nil) }.not_to have_enqueued_job(TenantIndexRepublishJob)
      expect { described_class.enqueue_for('acme') }.not_to have_enqueued_job(TenantIndexRepublishJob)
    end

    it 'marks the tenants above dirty and schedules one republish for a tenant with a parent (38d)' do
      root = create(:tenant, tenant_id: 'root-co')
      create(:tenant, tenant_id: 'child-co', parent: root)

      expect { described_class.enqueue_for('child-co') }
        .to have_enqueued_job(described_class).with('child-co').and have_enqueued_job(TenantIndexRepublishJob).once

      expect(root.reload.dirty_at).not_to be_nil
    end
  end

  describe 'Publish.configured? for a tenant' do
    before { allow(CatalogIndex::GithubPagesCommit).to receive(:configured?).and_return(true) }

    it 'is true for a tenant with an active key' do
      key = create(:tenant_signing_key)

      expect(CatalogIndex::Publish.configured?(key.tenant)).to eq(true)
    end

    it 'is false for a tenant with no key, and for an unknown tenant' do
      tenant = create(:tenant)

      expect(CatalogIndex::Publish.configured?(tenant)).to eq(false)
      expect(CatalogIndex::Publish.configured?('no-such-tenant')).to eq(false)
    end

    it 'is false for every tenant when the Pages repo is not configured' do
      allow(CatalogIndex::GithubPagesCommit).to receive(:configured?).and_return(false)
      key = create(:tenant_signing_key)

      expect(CatalogIndex::Publish.configured?(key.tenant)).to eq(false)
    end

    it 'does not let the default tenant\'s key stand in for a tenant that has none' do
      allow(CatalogIndexSigningKey).to receive(:current).and_return(instance_double(CatalogIndexSigningKey))
      tenant = create(:tenant)

      expect(CatalogIndex::Publish.configured?).to eq(true)
      expect(CatalogIndex::Publish.configured?(tenant)).to eq(false)
    end
  end
end
