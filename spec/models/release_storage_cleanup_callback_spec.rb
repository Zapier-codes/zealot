# frozen_string_literal: true

require 'rails_helper'

# Exercises the *pattern* Release#enqueue_storage_cleanup relies on — an
# after_destroy_commit callback, firing exactly once per destroyed row, keys
# captured from the frozen instance, and still firing on a has_many
# dependent: :destroy cascade — against a real ActiveRecord model backed by
# in-memory SQLite. This is a parallel harness, not app/models/release.rb
# itself (that class pulls in CarrierWave, several concerns and enums that
# don't load outside the full Rails app); the method under test there is the
# 8-line callback shown in the comment above it. See handover.md Task 19 for
# what this does and doesn't cover.
RSpec.describe 'Release storage-cleanup callback (harness)' do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    ActiveRecord::Schema.define do
      create_table :cleanup_spec_channels
      create_table :cleanup_spec_releases do |t|
        t.integer :cleanup_spec_channel_id
        t.string :file_storage_key
        t.string :patched_file_storage_key
        t.string :compressed_apks_storage_key
      end
    end

    cleanup_job = Class.new(ApplicationJob) do
      cattr_accessor :calls
      self.calls = []
      def perform(release_id, keys)
        self.class.calls << [release_id, keys]
      end
    end
    Object.const_set(:CleanupSpecStorageCleanupJob, cleanup_job)

    release_class = Class.new(ActiveRecord::Base) do
      self.table_name = 'cleanup_spec_releases'
      after_destroy_commit :enqueue_storage_cleanup

      private

      def enqueue_storage_cleanup
        keys = [file_storage_key, patched_file_storage_key, compressed_apks_storage_key].compact
        return if keys.empty?

        CleanupSpecStorageCleanupJob.perform_later(id, keys)
      end
    end
    Object.const_set(:CleanupSpecRelease, release_class)

    channel_class = Class.new(ActiveRecord::Base) do
      self.table_name = 'cleanup_spec_channels'
      has_many :cleanup_spec_releases, dependent: :destroy
    end
    Object.const_set(:CleanupSpecChannel, channel_class)
  end

  after(:all) do
    %i[CleanupSpecRelease CleanupSpecChannel CleanupSpecStorageCleanupJob].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
  end

  before { CleanupSpecStorageCleanupJob.calls = [] }

  it 'enqueues the job with every present key, once, after a direct destroy' do
    release = CleanupSpecRelease.create!(file_storage_key: 'binary/app.apk',
                                          compressed_apks_storage_key: 'pipeline/x.apks.br')

    release.destroy

    expect(CleanupSpecStorageCleanupJob.calls).to eq([[release.id, %w[binary/app.apk pipeline/x.apks.br]]])
  end

  it 'does not enqueue when the release was never mirrored' do
    release = CleanupSpecRelease.create!

    release.destroy

    expect(CleanupSpecStorageCleanupJob.calls).to be_empty
  end

  it 'still fires through a has_many dependent: :destroy cascade' do
    channel = CleanupSpecChannel.create!
    release = channel.cleanup_spec_releases.create!(file_storage_key: 'binary/app.apk')

    channel.destroy

    expect(CleanupSpecStorageCleanupJob.calls).to eq([[release.id, ['binary/app.apk']]])
  end

  it 'fires once per release, not once per row touched by the cascade' do
    channel = CleanupSpecChannel.create!
    3.times { |n| channel.cleanup_spec_releases.create!(file_storage_key: "binary/app#{n}.apk") }

    channel.destroy

    expect(CleanupSpecStorageCleanupJob.calls.size).to eq(3)
  end
end
