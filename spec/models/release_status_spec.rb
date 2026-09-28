# frozen_string_literal: true

require 'rails_helper'

# Task 27f-a: `releases.status` (available / held / halted / pulled). A held release stays out of
# the signed index; halted and pulled stay in it with that status; changing the status republishes
# the owning tenant's catalog. Needs Postgres. Built the way release_catalog_index_publish_spec.rb
# builds releases (no Release factory exists; `save!(validate: false)` skips the create-only `file`
# validation). NOT run in the sandbox that wrote it (no Rails boot or database there).
RSpec.describe Release, 'status (Task 27f-a)' do
  let(:app) { App.create!(name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }

  def make_release(on: channel, version: Release.count + 1)
    Release.new(channel: on, version: version, changelog: [], release_version: "1.0.#{version}",
                build_version: version.to_s).tap { |release| release.save!(validate: false) }
  end

  def serialized_versions(for_app)
    CatalogIndex::Serializer.call(for_app, generated_at: Time.utc(2026, 9, 24, 12), sequence: 1)[:apps]
                            .first[:versions]
  end

  describe 'the column' do
    it 'defaults to available, so every existing release stays published' do
      expect(make_release.status).to eq('available')
    end

    it 'accepts the four states and refuses anything else' do
      release = make_release
      %w[held halted pulled available].each do |state|
        release.update!(status: state)
        expect(release.reload.status).to eq(state)
      end

      expect { release.status = 'deleted' }.to raise_error(ArgumentError)
    end

    it 'is also refused by the database (check constraint)' do
      release = make_release

      expect { release.update_column(:status, 'deleted') }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe 'the index' do
    it 'lists an available release as available' do
      make_release

      expect(serialized_versions(app).map { |v| v[:status] }).to eq(['available'])
    end

    it 'leaves a held release out of versions[] altogether' do
      kept = make_release(version: 1)
      make_release(version: 2).update!(status: :held)

      expect(serialized_versions(app).map { |v| v[:release_id] }).to eq([kept.id])
    end

    it 'keeps halted and pulled releases in versions[] with that status' do
      make_release(version: 1).update!(status: :halted)
      make_release(version: 2).update!(status: :pulled)

      expect(serialized_versions(app).map { |v| v[:status] }).to contain_exactly('halted', 'pulled')
    end

    it 'publishes a release again once it is released (held to available)' do
      release = make_release
      release.update!(status: :held)
      expect(serialized_versions(app)).to eq([])

      release.update!(status: :available)
      expect(serialized_versions(app).map { |v| v[:release_id] }).to eq([release.id])
    end

    it 'reads a record that does not answer status as available (duck-typed like the rest)' do
      release_like = Struct.new(:release_version).new('1.0.0')

      serializer = CatalogIndex::Serializer.new(app, generated_at: Time.utc(2026, 9, 24, 12), sequence: 1,
                                                     expires_at: Time.utc(2026, 9, 25, 12))

      expect(serializer.send(:version_status_for, release_like)).to eq('available')
    end
  end

  describe 'republishing' do
    it 'enqueues the default tenant\'s publish (no argument) when a live app\'s release changes status' do
      release = make_release

      expect { release.update!(status: :held) }
        .to have_enqueued_job(CatalogIndexPublishJob).with(no_args).exactly(:once)
    end

    it 'enqueues only the owning tenant for a tenant app\'s release' do
      tenant = create(:tenant, tenant_id: 'acme')
      tenant_app = App.create!(name: 'Tenant app', listing_status: :live, listed_at: Time.current, tenant: tenant)
      tenant_scheme = tenant_app.schemes.create!(name: 'Main')
      tenant_channel = tenant_scheme.channels.create!(name: 'Android', device_type: :android)
      release = make_release(on: tenant_channel)

      expect { release.update!(status: :halted) }
        .to have_enqueued_job(CatalogIndexPublishJob).with('acme').exactly(:once)
    end

    it 'does nothing for a change to another column' do
      release = make_release

      expect { release.update!(build_version: '99') }.not_to have_enqueued_job(CatalogIndexPublishJob)
    end

    it 'does nothing when the app is not live' do
      draft = App.create!(name: 'Draft app', listing_status: :draft)
      draft_channel = draft.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android)
      release = make_release(on: draft_channel)

      expect { release.update!(status: :held) }.not_to have_enqueued_job(CatalogIndexPublishJob)
    end
  end

  # Task 27f-b: the transition table that drives the release-page buttons and the controller check.
  describe 'STATUS_TRANSITIONS (Task 27f-b)' do
    it 'knows every status, and only moves to statuses the enum has' do
      expect(Release::STATUS_TRANSITIONS.keys).to match_array(Release.statuses.keys)
      Release::STATUS_TRANSITIONS.each_value do |moves|
        expect(moves.keys - Release.statuses.keys).to be_empty
      end
    end

    it 'names every action with a translation in both locales' do
      names = Release::STATUS_TRANSITIONS.values.flat_map(&:values).uniq
      %i[en zh-CN].each do |locale|
        names.each do |name|
          expect(I18n.exists?("releases.show.status_actions.#{name}", locale)).to be(true), "#{locale} #{name}"
        end
        Release.statuses.each_key do |state|
          expect(I18n.exists?("releases.show.status_badges.#{state}", locale)).to be(true), "#{locale} #{state}"
          expect(I18n.exists?("releases.show.status_hint.#{state}", locale)).to be(true), "#{locale} #{state}"
        end
      end
    end

    it 'offers hold, halt and pull from available, and nothing to itself' do
      release = make_release

      expect(release.status_actions).to eq('held' => 'hold', 'halted' => 'halt', 'pulled' => 'pull')
      expect(release.status_change_allowed?('available')).to be(false)
      expect(release.status_change_allowed?('deleted')).to be(false)
      expect(release.status_change_allowed?(nil)).to be(false)
    end

    it 'only enters held from available, and only leaves pulled for available' do
      release = make_release

      release.update!(status: 'halted')
      expect(release.status_change_allowed?('held')).to be(false)

      release.update!(status: 'pulled')
      expect(release.status_actions).to eq('available' => 'restore')
    end
  end
end
