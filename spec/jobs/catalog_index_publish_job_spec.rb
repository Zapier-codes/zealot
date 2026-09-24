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
end
