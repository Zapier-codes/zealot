# frozen_string_literal: true

require 'rails_helper'

# Task 40h-b: opening a direct upload. Needs Postgres. The staging service is a fake: no network, no bucket.
# NOT run (the operator said no testing); look here first if CI is red for this slice.
RSpec.describe ReleaseUploadSession do
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:presigned) do
    ReleaseUploadStaging::Presigned.new(url: 'https://r2.example/put?sig=1', method: 'PUT',
                                        headers: { 'Content-Type' => 'application/octet-stream' },
                                        expires_at: 2.hours.from_now)
  end
  let(:staging) { instance_double(ReleaseUploadStaging, presign_put: presigned) }
  let(:params) do
    ActionController::Parameters.new(filename: 'my app.aab', size: '5000', content_type: 'application/octet-stream',
                                     hold: 'true', changelog: 'fixes', source: 'client', evil: 'x').permit!
  end

  def open_session(overrides = {})
    described_class.new(channel: channel, user: nil, params: params.merge(overrides), staging: staging).call
  end

  describe '.enabled?' do
    it 'needs the flag and a configured staging bucket' do
      env = { 'R2_STAGING_BUCKET' => 'b', 'R2_STAGING_ENDPOINT' => 'https://x', 'R2_STAGING_ACCESS_KEY_ID' => 'k',
              'R2_STAGING_SECRET_ACCESS_KEY' => 's' }
      stub_const('ENV', ENV.to_hash.merge(env).merge('RELEASE_UPLOAD_SESSIONS_ENABLED' => 'true'))
      expect(described_class.enabled?).to be(true)

      stub_const('ENV', ENV.to_hash.merge(env).merge('RELEASE_UPLOAD_SESSIONS_ENABLED' => 'yes'))
      expect(described_class.enabled?).to be(false)

      stub_const('ENV', ENV.to_hash.merge(env).merge('RELEASE_UPLOAD_SESSIONS_ENABLED' => 'true',
                                                     'R2_STAGING_BUCKET' => ''))
      expect(described_class.enabled?).to be(false)
    end
  end

  describe '#call' do
    it 'creates an awaiting_bytes row and returns the presigned PUT' do
      result = open_session

      upload = result.upload.reload
      expect(upload.state).to eq('awaiting_bytes')
      expect(upload.filename).to eq('my_app.aab')
      expect(upload.declared_size).to eq(5000)
      expect(result.payload).to include(id: upload.id, upload_url: presigned.url, method: 'PUT', size: 5000)
      expect(result.payload[:headers]).to eq('Content-Type' => 'application/octet-stream')
    end

    it 'never exposes the staging key' do
      payload = open_session.payload

      expect(payload.to_json).not_to include('staging/')
    end

    it 'keeps only the known form options' do
      options = open_session.upload.reload.form_options

      expect(options).to include('hold' => 'true', 'changelog' => 'fixes', 'source' => 'client')
      expect(options.keys).not_to include('evil')
    end

    it 'refuses a size that is not a whole number' do
      expect { open_session(size: 'abc') }.to raise_error(ActiveRecord::RecordInvalid)
      expect(ReleaseUpload.count).to eq(0)
    end

    it 'refuses a zero size and a size at or over 2 GiB' do
      expect { open_session(size: '0') }.to raise_error(ActiveRecord::RecordInvalid)
      expect { open_session(size: (2 * 1024**3).to_s) }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'refuses a missing file name' do
      expect { open_session(filename: '') }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'marks the row failed and re-raises when the presign fails' do
      allow(staging).to receive(:presign_put).and_raise(ReleaseStorage::StorageError, 'R2 presign failed')

      expect { open_session }.to raise_error(ReleaseStorage::StorageError)

      upload = ReleaseUpload.last
      expect(upload.state).to eq('failed')
      expect(upload.error).to include('R2 presign failed')
    end
  end
end
