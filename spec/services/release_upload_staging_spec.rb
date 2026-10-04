# frozen_string_literal: true

require 'rails_helper'
require 'aws-sdk-s3'

# Task 40h-a: the R2 staging service, against a stubbed S3 client (`stub_responses: true`): no network call is
# made and R2 is never reached. Presigning is offline (it only signs a URL). Needs Postgres for the upload
# record. Written, NOT run (the operator said no testing): look here first if CI is red for this slice.
RSpec.describe ReleaseUploadStaging do
  let(:app) { create(:app, name: 'Staging app') }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:content_type) { nil }
  let(:upload) do
    ReleaseUpload.create!(channel: channel, filename: 'app.aab', declared_size: 1234, content_type: content_type)
  end
  let(:client) do
    Aws::S3::Client.new(stub_responses: true, access_key_id: 'AKIAEXAMPLE', secret_access_key: 'secret',
                        region: 'auto', endpoint: 'https://acct.r2.cloudflarestorage.com', force_path_style: true)
  end
  let(:staging) { described_class.new(client: client, bucket: 'zealot-staging') }

  describe '.configured?' do
    let(:all_set) do
      described_class::REQUIRED_ENV.index_with { |name| "#{name}-value" }
    end

    it 'is true only when all four variables are set' do
      stub_const('ENV', ENV.to_hash.merge(all_set))
      expect(described_class.configured?).to be(true)

      stub_const('ENV', ENV.to_hash.merge(all_set).merge('R2_STAGING_ENDPOINT' => ''))
      expect(described_class.configured?).to be(false)
    end
  end

  describe '.new' do
    it 'names every missing variable when no client is passed' do
      stub_const('ENV', ENV.to_hash.except(*described_class::REQUIRED_ENV))

      expect { described_class.new }.to raise_error(ReleaseStorage::ConfigurationError, /R2_STAGING_BUCKET/)
    end

    it 'needs a bucket even with a client' do
      expect { described_class.new(client: client, bucket: nil) }
        .to raise_error(ReleaseStorage::ConfigurationError, /R2_STAGING_BUCKET/)
    end
  end

  describe '#presign_put' do
    it 'returns a signed PUT URL for the upload\'s own staging key' do
      presigned = staging.presign_put(upload)

      expect(presigned.method).to eq('PUT')
      expect(presigned.url).to start_with('https://acct.r2.cloudflarestorage.com/zealot-staging/staging/')
      expect(presigned.url).to include(upload.staging_key)
      expect(presigned.url).to include('X-Amz-Signature=')
      expect(presigned.url).to include("X-Amz-Expires=#{ReleaseUpload::UPLOAD_WINDOW.to_i}")
      expect(presigned.headers).to eq({})
      expect(presigned.expires_at).to be_within(1.minute).of(ReleaseUpload::UPLOAD_WINDOW.from_now)
    end

    it 'honours a shorter expiry' do
      expect(staging.presign_put(upload, expires_in: 600).url).to include('X-Amz-Expires=600')
    end

    context 'when the upload names a content type' do
      let(:content_type) { 'application/octet-stream' }

      it 'signs it and tells the client to send the same header' do
        presigned = staging.presign_put(upload)

        expect(presigned.headers).to eq('Content-Type' => 'application/octet-stream')
        expect(presigned.url).to match(/X-Amz-SignedHeaders=[^&]*content-type/i)
      end
    end

    it 'refuses an upload that has no staging key' do
      upload.update_columns(staging_key: nil)

      expect { staging.presign_put(upload) }.to raise_error(ReleaseStorage::StorageError, /no staging key/)
    end
  end

  describe '#head' do
    it 'reports the size and ETag R2 holds, without the quotes' do
      client.stub_responses(:head_object, content_length: 1234, etag: '"abc123"')

      head = staging.head(upload)

      expect(head.size).to eq(1234)
      expect(head.etag).to eq('abc123')
    end

    it 'asks for the upload\'s staging key in the staging bucket' do
      client.stub_responses(:head_object, content_length: 1, etag: '"x"')

      staging.head(upload)

      expect(client.api_requests.last[:params]).to include(bucket: 'zealot-staging', key: upload.staging_key)
    end

    it 'answers nil when nothing was uploaded' do
      client.stub_responses(:head_object, 'NotFound')

      expect(staging.head(upload)).to be_nil
    end

    it 'raises a storage error for any other R2 failure' do
      client.stub_responses(:head_object, 'AccessDenied')

      expect { staging.head(upload) }.to raise_error(ReleaseStorage::StorageError, /R2 head failed/)
    end
  end

  describe '#delete' do
    it 'deletes the staged object' do
      expect(staging.delete(upload)).to be(true)
      expect(client.api_requests.last).to include(operation_name: :delete_object)
      expect(client.api_requests.last[:params]).to include(bucket: 'zealot-staging', key: upload.staging_key)
    end

    it 'raises a storage error when R2 refuses' do
      client.stub_responses(:delete_object, 'AccessDenied')

      expect { staging.delete(upload) }.to raise_error(ReleaseStorage::StorageError, /R2 delete failed/)
    end
  end

  describe 'multipart' do
    it 'starts an upload and returns its id' do
      client.stub_responses(:create_multipart_upload, upload_id: 'mp-1')

      expect(staging.start_multipart(upload)).to eq('mp-1')
    end

    it 'presigns one part, with the part number and upload id in the URL' do
      presigned = staging.presign_part(upload, part_number: 3, upload_id: 'mp-1')

      expect(presigned.method).to eq('PUT')
      expect(presigned.url).to include('partNumber=3').and include('uploadId=mp-1')
    end

    it 'refuses a part number outside 1 to 10,000, or a missing upload id' do
      expect { staging.presign_part(upload, part_number: 0, upload_id: 'mp-1') }.to raise_error(ArgumentError)
      expect { staging.presign_part(upload, part_number: 10_001, upload_id: 'mp-1') }.to raise_error(ArgumentError)
      expect { staging.presign_part(upload, part_number: 1) }.to raise_error(ArgumentError, /no multipart/)
    end

    it 'completes with the parts sorted by number' do
      staging.complete_multipart(upload, upload_id: 'mp-1',
                                         parts: [{ part_number: 2, etag: '"b"' }, { part_number: 1, etag: '"a"' }])

      sent = client.api_requests.last[:params]
      expect(sent[:upload_id]).to eq('mp-1')
      expect(sent[:multipart_upload][:parts]).to eq([{ part_number: 1, etag: '"a"' },
                                                      { part_number: 2, etag: '"b"' }])
    end

    it 'aborts an upload, and says false when R2 no longer knows it' do
      expect(staging.abort_multipart(upload, upload_id: 'mp-1')).to be(true)

      client.stub_responses(:abort_multipart_upload, 'NoSuchUpload')
      expect(staging.abort_multipart(upload, upload_id: 'mp-1')).to be(false)
    end

    it 'does nothing when no multipart upload was started' do
      expect(staging.abort_multipart(upload)).to be(false)
    end
  end
end
