# frozen_string_literal: true

require 'rails_helper'

# Task 27b-iii: sign -> one commit -> D-store deploy hook. See the harness note in
# github_pages_commit_spec.rb (same scenarios run in plain Ruby, not under rspec).
RSpec.describe CatalogIndex::Publish do
  let(:key) { CatalogIndexSigningKey.generate! }
  let(:client) { instance_double(CatalogIndex::GithubPagesCommit) }
  let(:landed) { CatalogIndex::GithubPagesCommit::Result.new(status: :published, commit_sha: 'abc') }

  it 'publishes index, signature, public key and .nojekyll in one commit, signed over the exact bytes' do
    files = nil
    allow(client).to receive(:publish) { |f, **| files = f; landed }

    result = described_class.call(apps: [], client: client, key: key, hook_url: '')

    expect(result.status).to eq(:published)
    expect(files.keys).to contain_exactly('index.json', 'index.json.sig', 'signing_key.pub', '.nojekyll')
    expect(files['signing_key.pub'].strip).to eq(key.public_key)
    expect(CatalogIndex::Ed25519.verify(key.public_key, files['index.json'], files['index.json.sig'].strip)).to be true
  end

  it 'fires the deploy hook only after a commit landed, and never fails the publish because of it' do
    allow(client).to receive(:publish).and_return(landed)
    transport = instance_double(ReleaseStorage::GithubAdapter::HttpTransport)
    allow(transport).to receive(:call).and_return(ReleaseStorage::GithubAdapter::Response.new(status: 500, headers: {}, body: ''))

    result = described_class.call(apps: [], client: client, key: key, hook_url: 'https://hooks.example/secret', hook_transport: transport)

    expect(result.status).to eq(:published)
    expect(result.hook).to eq(:failed)

    allow(client).to receive(:publish).and_return(CatalogIndex::GithubPagesCommit::Result.new(status: :unchanged, commit_sha: 'abc'))
    expect(transport).not_to receive(:call)
    described_class.call(apps: [], client: client, key: key, hook_url: 'https://hooks.example/secret', hook_transport: transport)
  end

  it 'raises NoKeyError before touching GitHub when there is no signing key' do
    expect(client).not_to receive(:publish)

    expect { described_class.call(apps: [], client: client, key: nil) }.to raise_error(CatalogIndex::Signer::NoKeyError)
  end
end
