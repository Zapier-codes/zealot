# frozen_string_literal: true

require 'rails_helper'

RSpec.describe App, 'Play setup (task 18)' do
  include ActiveJob::TestHelper

  describe 'play_package_name' do
    it 'is optional and stored as nil when blank' do
      app = described_class.create!(name: 'No Play yet', play_package_name: '  ')

      expect(app.play_package_name).to be_nil
    end

    it 'accepts a valid applicationId and schedules the Play setup check' do
      expect do
        described_class.create!(name: 'With Play', play_package_name: 'com.example.app')
      end.to have_enqueued_job(AnthropicPlayPreflightJob)
    end

    it 'rejects an invalid applicationId' do
      app = described_class.new(name: 'Bad', play_package_name: 'not a package')

      expect(app).not_to be_valid
      expect(app.errors[:play_package_name]).to be_present
    end

    it 'rejects a package name already used by another app' do
      described_class.create!(name: 'First', play_package_name: 'com.example.app')
      other = described_class.new(name: 'Second', play_package_name: 'com.example.app')

      expect(other).not_to be_valid
    end
  end

  describe '#adopt_play_package_name!' do
    it 'takes the bundle applicationId when none was entered' do
      app = described_class.create!(name: 'Adopter')

      expect(app.adopt_play_package_name!('com.example.adopted')).to be_truthy
      expect(app.reload.play_package_name).to eq('com.example.adopted')
    end

    it 'never overwrites an entered applicationId' do
      app = described_class.create!(name: 'Keeper', play_package_name: 'com.example.keep')

      expect(app.adopt_play_package_name!('com.example.other')).to be(false)
      expect(app.reload.play_package_name).to eq('com.example.keep')
    end
  end

  describe '#record_play_setup!' do
    it 'stores the check result without scheduling another check' do
      app = described_class.create!(name: 'Recorder', play_package_name: 'com.example.rec')
      result = Anthropic::PlayPreflightService::Result.new(code: :package_not_found, message: 'first upload needed')

      expect { app.record_play_setup!(result) }.not_to have_enqueued_job(AnthropicPlayPreflightJob)

      app.reload
      expect(app.play_setup_status).to eq('needs_first_upload')
      expect(app.play_setup_message).to eq('first upload needed')
      expect(app.play_setup_checked_at).to be_present
    end
  end

  describe '#resume_waiting_play_publishes!' do
    it 'enqueues a publish for each waiting release' do
      app = described_class.create!(name: 'Resumer')
      allow(app).to receive(:waiting_play_releases).and_return([double(id: 11), double(id: 12)])

      expect { app.resume_waiting_play_publishes! }
        .to have_enqueued_job(AnthropicPlayPublishJob).with(11).and have_enqueued_job(AnthropicPlayPublishJob).with(12)
    end
  end
end

RSpec.describe Release, 'Play target bundle check (task 18)' do
  def release_with(bundle_id:, path: '/tmp/app.aab', expected: 'com.example.app')
    release = described_class.new(play_store_target: true, bundle_id: bundle_id)
    allow(release).to receive(:file).and_return(double(blank?: false, path: path))
    allow(release).to receive(:app).and_return(App.new(name: 'X', play_package_name: expected))
    release.play_target_bundle_valid
    release
  end

  it 'accepts an .aab whose applicationId matches the app' do
    expect(release_with(bundle_id: 'com.example.app').errors[:play_store_target]).to be_empty
  end

  it 'rejects an .aab with a different applicationId' do
    expect(release_with(bundle_id: 'com.other.app').errors[:play_store_target]).to be_present
  end

  describe 'unsupported file types' do
    def release_with_file(path)
      release = described_class.new(play_store_target: true)
      allow(release).to receive(:file).and_return(double(blank?: false, path: path))
      release.send(:drop_unsupported_play_target)
      release
    end

    it 'switches the Play target off for an .apk, and flags it, instead of failing the upload' do
      release = release_with_file('/tmp/app.apk')

      expect(release.play_store_target).to be(false)
      expect(release.play_target_dropped).to be(true)
    end

    it 'does the same for any other file type' do
      expect(release_with_file('/tmp/app.zip').play_store_target).to be(false)
    end

    it 'keeps the Play target for an .aab' do
      release = release_with_file('/tmp/app.aab')

      expect(release.play_store_target).to be(true)
      expect(release.play_target_dropped).to be_nil
    end
  end

  it 'does not block when the app has no Play applicationId yet' do
    expect(release_with(bundle_id: 'com.any.thing', expected: nil).errors[:play_store_target]).to be_empty
  end

  it 'rejects an applicationId that already belongs to another app' do
    App.create!(name: 'Owner', play_package_name: 'com.example.taken')

    release = release_with(bundle_id: 'com.example.taken', expected: nil)

    expect(release.errors[:play_store_target]).to be_present
  end

  it 'does not block when the bundle applicationId could not be read' do
    expect(release_with(bundle_id: nil).errors[:play_store_target]).to be_empty
  end
end
