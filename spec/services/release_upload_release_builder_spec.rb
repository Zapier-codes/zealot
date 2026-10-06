# frozen_string_literal: true

require 'rails_helper'

# Task 40i-b: the one code path that creates a release from a staged upload's stage-1 report. Needs Postgres.
# Written by reading the code, NOT run (no Ruby in the sandbox that wrote it).
RSpec.describe ReleaseUploadReleaseBuilder do
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:filename) { 'app.apk' }
  let(:kind) { 'apk' }
  let(:options) { { 'source' => 'web', 'changelog' => "- first\n- second", 'branch' => 'origin/main' } }
  let(:metadata) do
    { 'kind' => kind, 'package_name' => 'com.example.app', 'version_code' => 12, 'version_name' => '1.2',
      'app_label' => 'Example', 'file_sha256' => 'a' * 64, 'file_size' => 2048, 'min_sdk' => 21, 'target_sdk' => 34,
      'abis' => %w[arm64-v8a], 'icon_key' => 'staging/a1/u1/x/icon.png', 'icon_sha256' => 'b' * 64 }
  end
  let(:state) { 'uploaded' }
  let(:stage1_at) { Time.current }
  let!(:upload) do
    ReleaseUpload.create!(channel: channel, filename: filename, declared_size: 2048, form_options: options)
                 .tap do |row|
      row.update_columns(state: state, uploaded_size: 2048, stage1_at: stage1_at, metadata: metadata)
    end
  end
  let(:staging) { instance_double(ReleaseUploadStaging, delete: true) }

  def build
    described_class.new(upload.reload, staging: staging).call
  end

  describe 'a report the checks accept' do
    it 'creates one held release from the manifest data and the options the owner chose' do
      expect { @result = build }.to change(Release, :count).by(1)

      expect(@result.code).to eq(:created)
      release = @result.release.reload
      expect(release).to have_attributes(
        status: 'held', bundle_id: 'com.example.app', release_version: '1.2', build_version: '12',
        name: 'Example', min_sdk_version: 21, target_sdk_version: 34, abis: %w[arm64-v8a],
        file_sha256: 'a' * 64, source: 'web', branch: 'main', channel_id: channel.id, version: 1
      )
      expect(release.changelog).to eq([{ 'message' => 'first' }, { 'message' => 'second' }])
    end

    it 'moves the row to processing and points it at the release' do
      release = build.release

      expect(upload.reload).to have_attributes(state: 'processing', release_id: release.id)
    end

    it 'records no storage key and no icon: stage 2 does that once the objects exist' do
      release = build.release.reload

      expect(release.file_storage_key).to be_nil
      expect(release.icon_storage_key).to be_nil
      expect(release.icon_sha256).to be_nil
    end

    [ProxySdkInjectionJob, AnthropicAssetDeliveryJob, CiCompileDispatchJob, ReleaseFileMirrorJob,
     ReleaseDeployNotificationJob].each do |job_class|
      it "enqueues no #{job_class}: stage 2 owns the file work and the email" do
        expect { build }.not_to have_enqueued_job(job_class)
      end
    end

    it 'ignores the typed release and build versions: the manifest is the source of truth' do
      upload.update_columns(form_options: options.merge('release_version' => '9.9', 'build_version' => '99'))

      expect(build.release).to have_attributes(release_version: '1.2', build_version: '12')
    end

    it 'numbers a second release in the same channel after the first' do
      build
      second = described_class.new(create_second_upload, staging: staging).call

      expect(second.release.version).to eq(2)
    end

    def create_second_upload
      ReleaseUpload.create!(channel: channel, filename: 'b.apk', declared_size: 10).tap do |row|
        row.update_columns(state: 'uploaded', uploaded_size: 10, stage1_at: Time.current,
                           metadata: metadata.merge('version_code' => 13, 'file_size' => 10))
      end
    end
  end

  describe 'a replay' do
    it 'returns the same release and creates nothing new' do
      first = build.release

      expect { @again = build }.not_to change(Release, :count)
      expect(@again.code).to eq(:existing)
      expect(@again.release).to eq(first)
    end
  end

  describe 'an upload that is not ready' do
    %w[awaiting_bytes failed expired].each do |bad_state|
      context "in state #{bad_state}" do
        let(:state) { bad_state }

        it 'creates nothing' do
          expect { @result = build }.not_to change(Release, :count)
          expect(@result.code).to eq(:not_ready)
          expect(upload.reload.state).to eq(bad_state)
        end
      end
    end

    context 'with no recorded report' do
      let(:stage1_at) { nil }

      it 'creates nothing' do
        expect { @result = build }.not_to change(Release, :count)
        expect(@result.code).to eq(:not_ready)
      end
    end
  end

  describe 'a report the release checks refuse' do
    before { channel.update!(bundle_id: 'com.other.app') }

    it 'creates no release, fails the upload with the reason and drops the staged object' do
      expect { @result = build }.not_to change(Release, :count)

      expect(@result.code).to eq(:refused)
      expect(@result.reason).to be_present
      expect(upload.reload).to have_attributes(state: 'failed', release_id: nil)
      expect(upload.error).to be_present
      expect(staging).to have_received(:delete)
    end

    it 'does not fail if the staged object cannot be deleted' do
      allow(staging).to receive(:delete).and_raise(ReleaseStorage::StorageError, 'boom')

      expect(build.code).to eq(:refused)
    end
  end

  describe 'a Play target' do
    let(:filename) { 'app.aab' }
    let(:kind) { 'aab' }
    let(:options) { { 'source' => 'web', 'play_store_target' => '1' } }

    it 'is refused when the bundle is not the package the app expects on Play' do
      app.update_columns(play_package_name: 'com.other.app')

      expect { @result = build }.not_to change(Release, :count)
      expect(@result.code).to eq(:refused)
    end

    it 'is accepted for the expected package, as a held release' do
      app.update_columns(play_package_name: 'com.example.app')

      expect(build.release).to have_attributes(status: 'held', play_store_target: true)
    end
  end

  describe 'a Play target on an APK' do
    let(:options) { { 'source' => 'web', 'play_store_target' => '1' } }

    it 'drops the Play target, as the upload form does, and still creates the release' do
      release = build.release

      expect(release.play_store_target).to be(false)
    end
  end

  # Task 40r: a first upload (no channel) gets its app, scheme and channel at stage 1, in the same transaction.
  describe 'a first upload of an app' do
    let(:developer) do
      User.create!(email: 'first@example.com', username: 'first', password: 'correct-horse-9',
                   password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: :developer)
    end
    let!(:first_upload) do
      ReleaseUpload.create!(channel: nil, user: developer, filename: 'app.apk', declared_size: 2048,
                            form_options: { 'new_app' => true, 'source' => 'api' })
                   .tap do |row|
        row.update_columns(state: 'uploaded', uploaded_size: 2048, stage1_at: Time.current, metadata: metadata)
      end
    end

    it 'creates the app and one held release for it, and points the row at both' do
      result = nil
      expect { result = described_class.new(first_upload.reload, staging: staging).call }
        .to change(App, :count).by(1).and change(Release, :count).by(1)

      expect(result.code).to eq(:created)
      expect(result.release.channel.scheme.app.name).to eq('Example')
      expect(first_upload.reload).to have_attributes(state: 'processing', release_id: result.release.id)
      expect(first_upload.channel).to eq(result.release.channel)
    end

    it 'refuses the upload when the uploader may not create the app, creating nothing' do
      developer.update_columns(role: User.roles[:member])
      result = nil

      expect { result = described_class.new(first_upload.reload, staging: staging).call }
        .not_to change { [App.count, Release.count] }

      expect(result.code).to eq(:refused)
      expect(result.reason).to include('may not create')
      expect(first_upload.reload.state).to eq('failed')
      expect(staging).to have_received(:delete)
    end
  end
end
