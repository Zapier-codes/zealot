# frozen_string_literal: true

require 'rails_helper'

# Task 38d: the debounced ancestor republish. Needs Postgres (the claim is `UPDATE ... RETURNING`).
RSpec.describe TenantIndexRepublishJob do
  include ActiveJob::TestHelper

  let!(:root) { create(:tenant, tenant_id: 'root-co') }
  let!(:child) { create(:tenant, tenant_id: 'child-co', parent: root) }
  let!(:grandchild) { create(:tenant, tenant_id: 'grandchild-co', parent: child) }

  def republish_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j['job_class'] == 'TenantIndexRepublishJob' }
  end

  describe '.schedule_for' do
    it 'marks every ancestor dirty and enqueues one delayed republish' do
      expect { described_class.schedule_for(grandchild) }.to have_enqueued_job(described_class).exactly(:once)

      expect(root.reload.dirty_at).not_to be_nil
      expect(child.reload.dirty_at).not_to be_nil
      expect(grandchild.reload.dirty_at).to be_nil
    end

    it 'delays the job by the debounce window' do
      described_class.schedule_for(grandchild)

      at = republish_jobs.last['scheduled_at']
      time = at.is_a?(Numeric) ? Time.at(at) : Time.zone.parse(at.to_s)

      expect(time).to be_within(5.seconds).of(60.seconds.from_now)
    end

    it 'reads the window from ZEALOT_TENANT_REPUBLISH_DELAY_SECONDS and falls back to 60 seconds' do
      original = ENV['ZEALOT_TENANT_REPUBLISH_DELAY_SECONDS']
      ENV['ZEALOT_TENANT_REPUBLISH_DELAY_SECONDS'] = '15'
      expect(described_class.debounce).to eq(15.seconds)
      ENV['ZEALOT_TENANT_REPUBLISH_DELAY_SECONDS'] = 'soon'
      expect(described_class.debounce).to eq(60.seconds)
    ensure
      ENV['ZEALOT_TENANT_REPUBLISH_DELAY_SECONDS'] = original
    end

    it 'collapses a burst of changes into one republish' do
      3.times { described_class.schedule_for(grandchild) }
      described_class.schedule_for('grandchild-co')

      expect(republish_jobs.size).to eq(1)
    end

    it 'schedules the next republish once the markers have been claimed' do
      described_class.schedule_for(grandchild)
      Tenant.claim_dirty_tenant_ids

      described_class.schedule_for(grandchild)

      expect(republish_jobs.size).to eq(2)
    end

    it 'does nothing for a root tenant, the default tenant, an unknown tenant or an unsaved one' do
      [ root, nil, '', 'default', 'no-such-tenant', build(:tenant, tenant_id: 'unsaved') ].each do |tenant|
        described_class.schedule_for(tenant)
      end

      expect(republish_jobs).to be_empty
      expect(Tenant.where.not(dirty_at: nil)).to be_empty
    end
  end

  describe '#perform' do
    it 'enqueues one ordinary publish per dirty tenant, with its tenant id, and clears the markers' do
      described_class.schedule_for(grandchild)

      expect { described_class.perform_now }.to have_enqueued_job(CatalogIndexPublishJob).with('child-co')
        .and have_enqueued_job(CatalogIndexPublishJob).with('root-co')

      expect(Tenant.where.not(dirty_at: nil)).to be_empty
    end

    it 'does nothing when nothing is dirty' do
      expect { described_class.perform_now }.not_to have_enqueued_job(CatalogIndexPublishJob)
    end

    it 'republishes each dirty tenant once however many changes marked it' do
      3.times { described_class.schedule_for(grandchild) }

      expect { described_class.perform_now }.to have_enqueued_job(CatalogIndexPublishJob).exactly(2).times
    end

    it 'does not mark anything dirty itself (no loop up the chain)' do
      described_class.schedule_for(grandchild)
      described_class.perform_now

      expect(Tenant.where.not(dirty_at: nil)).to be_empty
      expect(republish_jobs.size).to eq(1)
    end
  end
end
