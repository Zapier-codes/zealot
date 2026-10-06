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

  # Task 40s-c: a file at or over the threshold is opened in parts when the flag is on.
  describe '#call for a multipart upload' do
    let(:staging) { instance_double(ReleaseUploadStaging, presign_put: presigned, start_multipart: 'mp-1') }
    let(:multipart_env) do
      { 'RELEASE_UPLOAD_MULTIPART_ENABLED' => 'true', 'RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB' => '100',
        'RELEASE_UPLOAD_PART_SIZE_MIB' => '16' }
    end
    let(:big) { (250 * 1024 * 1024).to_s }

    before { stub_const('ENV', ENV.to_hash.merge(multipart_env)) }

    it 'stores the part size and the upload id, and answers the part plan instead of a URL' do
      result = open_session(size: big)

      upload = result.upload.reload
      expect(upload).to have_attributes(part_size: 16 * 1024 * 1024, multipart_upload_id: 'mp-1',
                                        state: 'awaiting_bytes', declared_size: 250 * 1024 * 1024)
      expect(result.payload).to include(id: upload.id, multipart: true, part_size: 16 * 1024 * 1024,
                                        part_count: 16, size: 250 * 1024 * 1024)
      expect(result.payload).not_to have_key(:upload_url)
      expect(staging).not_to have_received(:presign_put)
    end

    it 'keeps the row open for the longer multipart window' do
      upload = open_session(size: big).upload.reload

      expect(upload.expires_at).to be_within(1.minute).of(ReleaseUploadParts::WINDOW.seconds.from_now)
      expect(result_expires(upload).to_i).to be > ReleaseUpload::UPLOAD_WINDOW.to_i
    end

    it 'never exposes the staging key or the multipart upload id' do
      payload = open_session(size: big).payload.to_json

      expect(payload).not_to include('staging/')
      expect(payload).not_to include('mp-1')
    end

    it 'keeps a file under the threshold a single PUT, with its URL' do
      result = open_session(size: (99 * 1024 * 1024).to_s)

      expect(result.upload.reload.part_size).to be_nil
      expect(result.payload).to include(upload_url: presigned.url)
      expect(staging).not_to have_received(:start_multipart)
    end

    it 'opens a file exactly at the threshold in parts' do
      expect(open_session(size: (100 * 1024 * 1024).to_s).payload).to include(multipart: true)
    end

    context 'when the flag is off' do
      let(:multipart_env) { { 'RELEASE_UPLOAD_MULTIPART_ENABLED' => 'false' } }

      it 'sends every file as a single PUT' do
        result = open_session(size: big)

        expect(result.payload).to include(upload_url: presigned.url)
        expect(result.upload.reload.part_size).to be_nil
      end
    end

    it 'marks the row failed and re-raises when R2 cannot start the upload' do
      allow(staging).to receive(:start_multipart).and_raise(ReleaseStorage::StorageError, 'R2 multipart start failed')

      expect { open_session(size: big) }.to raise_error(ReleaseStorage::StorageError)

      upload = ReleaseUpload.last
      expect(upload.state).to eq('failed')
      expect(upload.error).to include('R2 multipart start failed')
    end

    it 'still refuses a size over the cap before anything is started in R2' do
      expect { open_session(size: (2 * 1024**3).to_s) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(staging).not_to have_received(:start_multipart)
    end
  end

  def result_expires(upload)
    upload.expires_at - upload.created_at
  end
end
