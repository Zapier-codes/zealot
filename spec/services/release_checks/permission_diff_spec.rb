# frozen_string_literal: true

require 'rails_helper'

# Task 30c-a: `ReleaseChecks::PermissionDiff` reports the permissions a release added or dropped
# against the release before it in the same channel. Needs Postgres for the lookup examples. Built
# the way app_catalog_releases_track_spec.rb builds releases (`save!(validate: false)` skips the
# create-only `file` validation). NOT run in the sandbox that wrote it (no Rails boot or database).
RSpec.describe ReleaseChecks::PermissionDiff do
  describe '.between' do
    it 'reports what was added and what was dropped, sorted' do
      added, removed = described_class.between(%w[A B], %w[B D C])
      expect(added).to eq(%w[C D])
      expect(removed).to eq(%w[A])
    end

    it 'ignores order, duplicates, blanks and non-string entries' do
      added, removed = described_class.between(['A', 'A', ' ', nil], [' A ', :A, ''])
      expect(added).to eq([])
      expect(removed).to eq([])
    end

    it 'treats nil on either side as an empty list' do
      expect(described_class.between(nil, %w[A])).to eq([%w[A], []])
      expect(described_class.between(%w[A], nil)).to eq([[], %w[A]])
      expect(described_class.between(nil, nil)).to eq([[], []])
    end
  end

  describe '.call' do
    let(:app) { create(:app) }
    let(:scheme) { app.schemes.create!(name: 'Main') }
    let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
    let(:other_channel) { scheme.channels.create!(name: 'Beta', device_type: :android) }

    def make_release(version, permissions, on: channel)
      Release.new(channel: on, version: version, changelog: [], release_version: "1.0.#{version}",
                  build_version: version.to_s, permissions: permissions)
             .tap { |release| release.save!(validate: false) }
    end

    it 'compares with the next-lower version of the same channel, not just the latest one' do
      make_release(1, %w[INTERNET])
      second = make_release(2, %w[INTERNET CAMERA])
      third = make_release(3, %w[INTERNET CAMERA])

      result = described_class.call(third)
      expect(result.previous).to eq(second)
      expect(result.changed?).to be false

      result = described_class.call(second)
      expect(result.added).to eq(%w[CAMERA])
      expect(result.removed).to eq([])
      expect(result.changed?).to be true
    end

    it 'reports a dropped permission' do
      make_release(1, %w[INTERNET CAMERA])
      second = make_release(2, %w[INTERNET])

      expect(described_class.call(second).removed).to eq(%w[CAMERA])
    end

    it 'is a baseline (no comparison, no change) for the first release of a channel' do
      first = make_release(1, %w[INTERNET CAMERA])

      result = described_class.call(first)
      expect(result.compared?).to be false
      expect(result.added).to eq([])
      expect(result.changed?).to be false
    end

    it 'never compares across channels' do
      make_release(1, %w[INTERNET], on: other_channel)
      first_here = make_release(2, %w[INTERNET CAMERA])

      expect(described_class.call(first_here).compared?).to be false
    end

    it 'does not compare a release that has no channel or version yet' do
      expect(described_class.call(Release.new).compared?).to be false
    end
  end
end
