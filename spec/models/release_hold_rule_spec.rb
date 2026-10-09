# frozen_string_literal: true

require 'rails_helper'

# Task 49: an update to an app that already has a version is never held; only the first release may be.
# Needs Postgres. Built like release_status_spec.rb (no Release factory; `save!(validate: false)` skips the
# create-only `file` validation). NOT run in the sandbox that wrote it (no Ruby, Rails or database there).
RSpec.describe Release, 'hold rule (Task 49)' do
  let(:app) { App.create!(name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }

  def make_release(version:)
    Release.new(channel: channel, version: version, changelog: [], release_version: "1.0.#{version}",
                build_version: version.to_s).tap { |release| release.save!(validate: false) }
  end

  describe '#first_release_of_app? / #hold_allowed?' do
    it 'is true for the only release of an app' do
      release = make_release(version: 1)

      expect(release.first_release_of_app?).to be(true)
      expect(release.hold_allowed?).to be(true)
    end

    it 'is true for a release that has not been saved yet when the app has none' do
      expect(Release.new(channel: channel, version: 1).hold_allowed?).to be(true)
    end

    it 'is false for a release when the app already has another one' do
      make_release(version: 1)
      update = make_release(version: 2)

      expect(update.first_release_of_app?).to be(false)
      expect(Release.new(channel: channel, version: 3).hold_allowed?).to be(false)
    end
  end

  describe 'holding an update' do
    it 'offers no hold move for an update, but still offers halt and pull' do
      make_release(version: 1)
      update = make_release(version: 2)

      expect(update.status_actions).to eq('halted' => 'halt', 'pulled' => 'pull')
      expect(update.status_change_allowed?('held')).to be(false)
    end

    it 'refuses to hold an update at the model level, with a reason' do
      make_release(version: 1)
      update = make_release(version: 2)

      expect(update.update(status: :held)).to be(false)
      expect(update.errors[:status].join).to match(/cannot be held/)
      expect(update.reload.status).to eq('available')
    end

    it 'still lets the first release be held and released' do
      first = make_release(version: 1)

      expect(first.status_actions).to include('held' => 'hold')
      expect(first.update(status: :held)).to be(true)
      expect(first.update(status: :available)).to be(true)
    end

    it 'still releases an update that an earlier version left held' do
      make_release(version: 1)
      legacy = make_release(version: 2)
      legacy.update_columns(status: 'held')

      expect(legacy.status_actions['available']).to eq('release')
      expect(legacy.update(status: :available)).to be(true)
    end
  end
end
