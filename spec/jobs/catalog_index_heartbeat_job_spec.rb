# frozen_string_literal: true

require 'rails_helper'

# Task 49: the heartbeat re-signs every configured index on a timer so none reaches its `expires_at`.
# NOT run in the sandbox that wrote it (no Ruby, Rails or database there).
RSpec.describe CatalogIndexHeartbeatJob do
  include ActiveJob::TestHelper

  def publish_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j['job_class'] == 'CatalogIndexPublishJob' }
  end

  let!(:configured_tenant) { create(:tenant, tenant_id: 'acme-co') }
  let!(:unconfigured_tenant) { create(:tenant, tenant_id: 'no-key-co') }

  before do
    allow(CatalogIndex::Publish).to receive(:configured?).and_return(false)
    allow(CatalogIndex::Publish).to receive(:configured?).with(no_args).and_return(true)
    allow(CatalogIndex::Publish).to receive(:configured?).with('acme-co').and_return(true)
  end

  it 'enqueues one publish for the default index and one per configured tenant' do
    described_class.perform_now

    expect(publish_jobs.map { |j| j['arguments'] }).to contain_exactly([], ['acme-co'])
  end

  it 'skips a tenant that has no Pages repo or key, without raising' do
    expect { described_class.perform_now }.not_to raise_error

    expect(publish_jobs.flat_map { |j| j['arguments'] }).not_to include('no-key-co')
  end

  it 'enqueues nothing when no index is configured at all' do
    allow(CatalogIndex::Publish).to receive(:configured?).and_return(false)

    described_class.perform_now

    expect(publish_jobs).to be_empty
  end

  it 'is scheduled twice a day inside the wake-workflow windows' do
    jobs = CRON_JOBS_SETUP.call.values.select { |entry| entry[:class] == 'CatalogIndexHeartbeatJob' }

    expect(jobs.map { |entry| entry[:cron] }).to contain_exactly('5 16 * * *', '5 22 * * *')
  end
end
