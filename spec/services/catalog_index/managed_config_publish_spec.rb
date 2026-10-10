# frozen_string_literal: true

require 'rails_helper'

# Z-P24 (enterprise device management): when the organisation sets managed-configuration policy,
# CatalogIndex::Publish adds `managed-config.json` to the same Pages commit; when it does not, the commit is
# byte-for-byte what it has always been.
RSpec.describe CatalogIndex::Publish, 'managed configuration' do
  let(:key) { CatalogIndexSigningKey.generate! }
  let(:client) { instance_double(CatalogIndex::GithubPagesCommit) }
  let(:landed) { CatalogIndex::GithubPagesCommit::Result.new(status: :published, commit_sha: 'abc') }

  before do
    Setting.managed_config = {}
  end

  it 'adds managed-config.json when the organisation set policy' do
    Setting.managed_config = { 'enabled_sources' => 'fdroid', 'hidden_packages' => 'com.secret' }
    files = nil
    allow(client).to receive(:publish) { |f, **| files = f; landed }

    described_class.call(apps: [], client: client, key: key, hook_url: '')

    doc = JSON.parse(files.fetch('managed-config.json'))
    expect(doc['managed_keys']).to contain_exactly('enabled_sources', 'hidden_packages')
    expect(doc['config']['enabled_sources']).to eq(['FDroid'])
    expect(doc['config']['hidden_packages']).to eq(['com.secret'])
  end

  it 'publishes no managed-config.json when nothing is set' do
    files = nil
    allow(client).to receive(:publish) { |f, **| files = f; landed }

    described_class.call(apps: [], client: client, key: key, hook_url: '')

    expect(files).not_to have_key('managed-config.json')
    expect(files.keys).to contain_exactly('index.json', 'index.json.sig', 'signing_key.pub', 'taxonomy.json',
                                          'taxonomy.json.sig', '.nojekyll')
  end
end
