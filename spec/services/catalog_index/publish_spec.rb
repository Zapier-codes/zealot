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

  # Task 37b-ii-k4
  it 'takes the default tenant\'s key from the resolver, publishing exactly the same four files' do
    key
    files = nil
    allow(client).to receive(:publish) { |f, **| files = f; landed }

    described_class.call(apps: [], client: client, hook_url: '')

    expect(files.keys).to contain_exactly('index.json', 'index.json.sig', 'signing_key.pub', '.nojekyll')
    expect(files['signing_key.pub'].strip).to eq(key.public_key)
  end

  # Task 37b-iii-s4 (replaces the k4 example that refused a non-default tenant).
  describe 'for a non-default tenant' do
    let(:acme) { create(:tenant, tenant_id: 'acme') }
    let!(:acme_key) { create(:tenant_signing_key, tenant: acme) }

    def live_app(**attrs)
      create(:app, listing_status: :live, listed_at: Time.current, **attrs)
    end

    it 'writes the same four files under tenants/<id>, signed with the tenant\'s own key' do
      files = root = message = nil
      allow(client).to receive(:publish) { |f, **opts| files = f; root = opts[:root]; message = opts[:message]; landed }

      result = described_class.call(client: client, tenant: 'acme', hook_url: '')

      expect(result.status).to eq(:published)
      expect(root).to eq('tenants/acme')
      expect(message).to include('[acme]')
      expect(files.keys).to contain_exactly('index.json', 'index.json.sig', 'signing_key.pub', '.nojekyll')
      expect(files['signing_key.pub'].strip).to eq(acme_key.public_key)
      expect(CatalogIndex::Ed25519.verify(acme_key.public_key, files['index.json'], files['index.json.sig'].strip)).to be true
    end

    it 'never signs with the default tenant\'s key' do
      default_key = CatalogIndexSigningKey.generate!
      files = nil
      allow(client).to receive(:publish) { |f, **| files = f; landed }

      described_class.call(client: client, tenant: acme, hook_url: '')

      expect(CatalogIndex::Ed25519.verify(default_key.public_key, files['index.json'], files['index.json.sig'].strip)).to be false
    end

    it 'publishes only that tenant\'s own live apps, and none of the default tenant\'s or another tenant\'s' do
      default_app = live_app
      acme_app = live_app(tenant: acme)
      live_app(tenant: create(:tenant, tenant_id: 'globex'))
      files = nil
      allow(client).to receive(:publish) { |f, **| files = f; landed }

      described_class.call(client: client, tenant: 'acme', hook_url: '')

      ids = JSON.parse(files['index.json'])['apps'].map { |a| a['id'] }
      expect(ids).to eq([ acme_app.id ])
      expect(ids).not_to include(default_app.id)
    end

    it 'publishes the tenant\'s own collections, never the default tenant\'s, and no sponsored slots until s6b' do
      Collection.create!(slug: 'staff-picks', name: 'Staff picks')
      acme_picks = Collection.create!(slug: 'acme-picks', name: 'Acme picks', tenant: acme)
      acme_app = live_app(tenant: acme)
      CollectionApp.create!(app: acme_app, collection: acme_picks)
      SponsoredSlot.create!(app: acme_app, starts_at: 1.day.from_now, ends_at: 2.days.from_now)
      files = nil
      allow(client).to receive(:publish) { |f, **| files = f; landed }

      described_class.call(client: client, tenant: 'acme', hook_url: '')

      index = JSON.parse(files['index.json'])
      expect(index['collections'].map { |c| c['slug'] }).to eq(%w[acme-picks])
      expect(index['apps'].first).to include('id' => acme_app.id, 'sponsored_slots' => [],
                                             'collections' => %w[acme-picks])
    end

    it 'publishes an empty collection registry for a tenant that has none, even when the default has some' do
      Collection.create!(slug: 'staff-picks', name: 'Staff picks')
      acme_app = live_app(tenant: acme)
      files = nil
      allow(client).to receive(:publish) { |f, **| files = f; landed }

      described_class.call(client: client, tenant: 'acme', hook_url: '')

      index = JSON.parse(files['index.json'])
      expect(index['collections']).to eq([])
      expect(index['apps'].first).to include('id' => acme_app.id, 'sponsored_slots' => [], 'collections' => [])
    end

    it 'still fails with a NoKeyError naming the tenant when it has no active key' do
      create(:tenant, tenant_id: 'nokey')
      expect(client).not_to receive(:publish)

      expect { described_class.call(client: client, tenant: 'nokey', hook_url: '') }
        .to raise_error(CatalogIndex::KeyResolver::NoKeyError, /nokey/)
    end

    it 'leaves the default tenant at the repo root with an unchanged commit message' do
      key
      root = :unset
      message = nil
      allow(client).to receive(:publish) { |_f, **opts| root = opts[:root]; message = opts[:message]; landed }

      described_class.call(apps: [], client: client, hook_url: '')

      expect(root).to be_nil
      expect(message).to match(/\Acatalog index \d{4}-/)
    end
  end

  it 'raises NoKeyError before touching GitHub when there is no signing key' do
    expect(client).not_to receive(:publish)

    expect { described_class.call(apps: [], client: client, key: nil) }.to raise_error(CatalogIndex::Signer::NoKeyError)
  end

  # Task 37b-iii-s1: the advisory lock is keyed by tenant.
  describe '.lock_sql' do
    let(:connection) { ActiveRecord::Base.connection }

    it 'is exactly the historical statement for the default tenant, however it is spelled' do
      [nil, '', 'default', 'DEFAULT', ' default '].each do |t|
        expect(described_class.lock_sql(connection, t, 'lock')).to eq('SELECT pg_advisory_lock(2027003)'), t.inspect
        expect(described_class.lock_sql(connection, t, 'unlock')).to eq('SELECT pg_advisory_unlock(2027003)'), t.inspect
      end
    end

    it 'uses the two-key form, in its own key space, for any other tenant' do
      expect(described_class.lock_sql(connection, 'acme', 'lock'))
        .to eq("SELECT pg_advisory_lock(2027003, hashtext('acme'))")
      expect(described_class.lock_sql(connection, 'acme', 'unlock'))
        .to eq("SELECT pg_advisory_unlock(2027003, hashtext('acme'))")
    end

    it 'takes a Tenant or anything answering tenant_id, and quotes the id instead of interpolating it' do
      expect(described_class.lock_sql(connection, Struct.new(:tenant_id).new('globex'), 'lock')).to include("'globex'")
      expect(described_class.lock_sql(connection, "x'); DROP TABLE apps; --", 'lock')).to include("''")
    end

    it 'refuses a verb other than lock or unlock' do
      expect { described_class.lock_sql(connection, 'acme', 'lock(1); --') }.to raise_error(ArgumentError)
    end

    it 'runs against Postgres: a tenant lock can be taken and released' do
      connection.execute(described_class.lock_sql(connection, 'acme', 'lock'))
      released = connection.select_value(described_class.lock_sql(connection, 'acme', 'unlock'))
      expect([true, 't']).to include(released)
    end
  end
end
