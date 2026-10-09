# frozen_string_literal: true

require 'rails_helper'

# Task 46d: the supersede rule runs by itself. ReleaseSuperseder's own behaviour is covered by its spec; this one
# covers when the job is enqueued and what it does with a refusal or a switch. NOT run (no Rails or database in
# the sandbox that wrote it).
RSpec.describe ReleaseSupersedeJob do
  include ActiveJob::TestHelper

  let!(:app) { create(:app, name: 'Auto Supersede App') }
  let!(:channel) { app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android) }

  def make_release(version, **attrs)
    Release.new({ channel: channel, version: version, changelog: [], release_version: "1.0.#{version}",
                  build_version: version.to_s }.merge(attrs)).tap { |r| r.save!(validate: false) }
  end

  def make_installable(version, **attrs)
    make_release(version, ci_compile_state: 'done', universal_apk_storage_key: "a1/r#{version}/app.apk",
                          universal_apk_sha256: 'a' * 64, universal_apk_size: 1234, **attrs)
  end

  def supersede_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j['job_class'] == 'ReleaseSupersedeJob' }
  end

  before do
    allow(ReleaseStorageCleanupJob).to receive(:perform_later)
    allow(CatalogIndexPublishJob).to receive(:enqueue_for)
    clear_enqueued_jobs
  end

  describe 'when it is enqueued' do
    it 'is enqueued when an available release is created' do
      release = make_release(1)

      expect(supersede_jobs.map { |j| j['arguments'] }).to include([release.id])
    end

    it 'is enqueued when a release becomes available' do
      release = make_release(1, status: 'held')
      clear_enqueued_jobs

      release.update_columns(updated_at: Time.current) # a column change that is not a trigger
      expect(supersede_jobs).to be_empty

      release.update!(status: 'available')

      expect(supersede_jobs.map { |j| j['arguments'] }).to eq([[release.id]])
    end

    it 'is enqueued when the CI result is recorded' do
      release = make_release(1, ci_compile_state: 'dispatched')
      clear_enqueued_jobs

      release.update!(ci_compile_state: 'done', universal_apk_storage_key: 'a1/r1/app.apk',
                      universal_apk_sha256: 'a' * 64, universal_apk_size: 1234)

      expect(supersede_jobs.map { |j| j['arguments'] }).to eq([[release.id]])
    end

    it 'is not enqueued for a release that is not available' do
      make_release(1, status: 'held')
      make_release(2, status: 'halted')
      make_release(3, status: 'pulled')

      expect(supersede_jobs).to be_empty
    end

    it 'is not enqueued by a save that changes none of the trigger fields' do
      release = make_release(1)
      clear_enqueued_jobs

      release.update!(changelog: [{ 'message' => 'x' }])

      expect(supersede_jobs).to be_empty
    end

    it 'does not turn a queue failure into a failed save' do
      allow(ReleaseSupersedeJob).to receive(:perform_later).and_raise(StandardError, 'queue down')

      expect { make_release(1) }.not_to raise_error
    end
  end

  describe '#perform' do
    it 'removes the older releases once the named one is installable' do
      old_one = make_release(1)
      keeper = make_installable(2)

      described_class.perform_now(keeper.id)

      expect(Release.exists?(old_one.id)).to be(false)
      expect(Release.exists?(keeper.id)).to be(true)
    end

    it 'removes nothing while the named release is still compiling, without raising' do
      old_one = make_release(1)
      compiling = make_release(2, ci_compile_state: 'dispatched')

      expect { described_class.perform_now(compiling.id) }.not_to raise_error

      expect(Release.exists?(old_one.id)).to be(true)
    end

    it 'removes nothing while the named release is held' do
      old_one = make_release(1)
      held = make_installable(2, status: 'held')

      described_class.perform_now(held.id)

      expect(Release.exists?(old_one.id)).to be(true)
    end

    it 'does nothing for a release that no longer exists' do
      expect { described_class.perform_now(0) }.not_to raise_error
    end

    it 'does nothing when AUTO_SUPERSEDE is off' do
      old_one = make_release(1)
      keeper = make_installable(2)

      allow(described_class).to receive(:enabled?).and_return(false)

      described_class.perform_now(keeper.id)

      expect(Release.exists?(old_one.id)).to be(true)
    end
  end

  describe '.enabled?' do
    it 'is on by default and off for false, 0, off and no' do
      original = ENV.fetch('AUTO_SUPERSEDE', nil)
      ENV.delete('AUTO_SUPERSEDE')
      expect(described_class.enabled?).to be(true)
      %w[false 0 off no FALSE].each do |value|
        ENV['AUTO_SUPERSEDE'] = value
        expect(described_class.enabled?).to be(false)
      end
      ENV['AUTO_SUPERSEDE'] = 'true'
      expect(described_class.enabled?).to be(true)
    ensure
      original.nil? ? ENV.delete('AUTO_SUPERSEDE') : ENV['AUTO_SUPERSEDE'] = original
    end
  end
end
