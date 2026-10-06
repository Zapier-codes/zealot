# frozen_string_literal: true

require 'rails_helper'

# Task 40h-a: the staging record. Needs Postgres. Channels and releases are built like
# release_status_control_spec.rb builds them. Written, NOT run (the operator said no testing): look here
# first if CI is red for this slice.
RSpec.describe ReleaseUpload do
  let(:app) { create(:app, name: 'Upload app') }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }

  def build_upload(**overrides)
    described_class.new({ channel: channel, filename: 'app.aab', declared_size: 1234 }.merge(overrides))
  end

  describe 'creation' do
    it 'starts awaiting bytes, with a window to upload in' do
      upload = build_upload.tap(&:save!)

      expect(upload).to be_state_awaiting_bytes
      expect(upload.expires_at).to be_within(1.minute).of(described_class::UPLOAD_WINDOW.from_now)
      expect(upload.window_open?).to be(true)
      expect(upload.form_options).to eq({})
    end

    it 'picks the staging key itself: app, upload id, an unguessable segment, then the file name' do
      upload = build_upload.tap(&:save!)

      expect(upload.reload.staging_key)
        .to match(%r{\Astaging/a#{app.id}/u#{upload.id}/[0-9a-f]{32}/app\.aab\z})
    end

    it 'gives two uploads of the same file different keys' do
      first = build_upload.tap(&:save!)
      second = build_upload.tap(&:save!)

      expect(first.reload.staging_key).not_to eq(second.reload.staging_key)
    end

    it 'keeps what the form carries, untouched' do
      upload = build_upload(form_options: { 'hold' => true, 'changelog' => 'fixes' }).tap(&:save!)

      expect(upload.reload.form_options).to eq('hold' => true, 'changelog' => 'fixes')
    end
  end

  describe 'file name' do
    it 'drops directories and replaces anything outside letters, digits, dot, dash and underscore' do
      upload = build_upload(filename: '../../my app (1).aab').tap(&:save!)

      expect(upload.filename).to eq('my_app__1_.aab')
      expect(upload.reload.staging_key).not_to include('..')
    end

    it 'treats a Windows path the same way' do
      expect(build_upload(filename: 'C:\\builds\\app.apk').tap(&:save!).filename).to eq('app.apk')
    end

    it 'is refused when blank' do
      upload = build_upload(filename: '')

      expect(upload).not_to be_valid
      expect(upload.errors[:filename]).to be_present
    end
  end

  describe 'declared size' do
    it 'must be a positive whole number' do
      [0, -1, 1.5, nil].each do |size|
        expect(build_upload(declared_size: size)).not_to be_valid
      end
    end

    it 'must be under 2 GiB, the size of a GitHub release asset' do
      expect(build_upload(declared_size: described_class::MAX_BYTES)).to be_valid
      expect(build_upload(declared_size: described_class::MAX_BYTES + 1)).not_to be_valid
    end
  end

  it 'refuses form options that are not a hash' do
    expect(build_upload(form_options: 'hold')).not_to be_valid
  end

  it 'reaches the app through its channel' do
    expect(build_upload.app).to eq(app)
  end

  describe '.stale_awaiting' do
    it 'finds only rows still awaiting bytes whose window has closed' do
      stale = build_upload.tap(&:save!)
      stale.update_columns(expires_at: 1.minute.ago)
      fresh = build_upload.tap(&:save!)
      uploaded = build_upload.tap(&:save!)
      uploaded.update_columns(expires_at: 1.minute.ago, state: 'uploaded')

      expect(described_class.stale_awaiting).to contain_exactly(stale)
      expect(fresh.window_open?).to be(true)
      expect(stale.reload.window_open?).to be(false)
    end
  end

  describe 'release reference' do
    def build_release
      Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1', build_version: '1')
             .tap { |release| release.save!(validate: false) }
    end

    it 'lets one upload point at one release, and no release at two uploads' do
      release = build_release
      build_upload(release: release).save!

      expect { build_upload(release: release).save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'keeps the record when its release is deleted' do
      release = build_release
      upload = build_upload(release: release).tap(&:save!)

      release.delete

      expect(upload.reload.release_id).to be_nil
    end
  end

  # Task 40r: the first upload of an app has no channel until stage 1.
  describe 'a first upload with no channel' do
    def build_channel_less(options)
      described_class.new(channel: nil, filename: 'app.apk', declared_size: 10, form_options: options)
    end

    it 'is valid only when it was opened as a new app' do
      expect(build_channel_less('new_app' => true)).to be_valid
      expect(build_channel_less({})).not_to be_valid
      expect(build_channel_less('new_app' => 'yes')).not_to be_valid
    end

    it 'has no app yet and stages its file under the a0 segment, which the CI key pattern accepts' do
      upload = build_channel_less('new_app' => true).tap(&:save!)

      expect(upload.app).to be_nil
      expect(upload).to be_new_app
      expect(upload.reload.staging_key).to match(%r{\Astaging/a0/u#{upload.id}/[0-9a-f]{32}/app\.apk\z})
    end

    it 'keeps the app id in the staging key of an upload that has a channel' do
      upload = build_upload.tap(&:save!)

      expect(upload).not_to be_new_app
      expect(upload.reload.staging_key).to start_with("staging/a#{upload.app.id}/")
    end
  end
end
