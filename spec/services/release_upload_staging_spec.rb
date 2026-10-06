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

  # Task 40i-c: the icon stage 1 put beside the file is deleted with it, but only from this upload's own prefix.
  describe '#delete_sibling' do
    let(:icon_key) { "#{File.dirname(upload.staging_key)}/icon.png" }

    it 'deletes an object beside the staged file' do
      expect(staging.delete_sibling(upload, icon_key)).to be(true)
      expect(client.api_requests.last).to include(operation_name: :delete_object)
      expect(client.api_requests.last[:params]).to include(bucket: 'zealot-staging', key: icon_key)
    end

    it 'refuses a key outside the upload\'s own prefix, and one that climbs out of it' do
      expect { staging.delete_sibling(upload, 'staging/a1/u999/other/icon.png') }.to raise_error(ArgumentError)
      expect { staging.delete_sibling(upload, "#{File.dirname(upload.staging_key)}/../x.png") }
        .to raise_error(ArgumentError)
      expect { staging.delete_sibling(upload, nil) }.to raise_error(ArgumentError)
    end

    it 'raises a storage error when R2 refuses' do
      client.stub_responses(:delete_object, 'AccessDenied')

      expect { staging.delete_sibling(upload, icon_key) }
        .to raise_error(ReleaseStorage::StorageError, /R2 delete failed/)
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

    it 'adds the quotes to an ETag that has none, and leaves quoted ones alone' do
      staging.complete_multipart(upload, upload_id: 'mp-1',
                                         parts: [{ part_number: 1, etag: 'a' }, { part_number: 2, etag: '"b"' }])

      expect(client.api_requests.last[:params][:multipart_upload][:parts])
        .to eq([{ part_number: 1, etag: '"a"' }, { part_number: 2, etag: '"b"' }])
    end

    it 'answers true when R2 completes the upload' do
      expect(staging.complete_multipart(upload, upload_id: 'mp-1', parts: [{ part_number: 1, etag: '"a"' }]))
        .to be(true)
    end

    it 'answers false, not an error, when R2 no longer knows the upload (completed or aborted already)' do
      client.stub_responses(:complete_multipart_upload, 'NoSuchUpload')

      expect(staging.complete_multipart(upload, upload_id: 'mp-1', parts: [{ part_number: 1, etag: '"a"' }]))
        .to be(false)
    end

    it 'raises a storage error when R2 refuses to complete for another reason' do
      client.stub_responses(:complete_multipart_upload, 'InvalidPart')

      expect { staging.complete_multipart(upload, upload_id: 'mp-1', parts: [{ part_number: 1, etag: '"a"' }]) }
        .to raise_error(ReleaseStorage::StorageError, /R2 multipart complete failed/)
    end

    it 'refuses to complete without an upload id' do
      expect { staging.complete_multipart(upload, parts: []) }.to raise_error(ArgumentError, /no multipart/)
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

  # Task 40s-b: what R2 holds for a multipart upload, so finalize and resume never depend on the client's word.
  describe '#list_parts' do
    let(:held_class) { ReleaseUploadParts::Held }

    it 'returns number, size and ETag (without the quotes) for every part, sorted by number' do
      client.stub_responses(:list_parts, parts: [{ part_number: 2, size: 7, etag: '"b"' },
                                                 { part_number: 1, size: 16, etag: '"a"' }],
                                         is_truncated: false)

      held = staging.list_parts(upload, upload_id: 'mp-1')

      expect(held).to eq([held_class.new(part_number: 1, size: 16, etag: 'a'),
                          held_class.new(part_number: 2, size: 7, etag: 'b')])
    end

    it 'asks for the upload\'s staging key and upload id in the staging bucket' do
      client.stub_responses(:list_parts, parts: [], is_truncated: false)

      staging.list_parts(upload, upload_id: 'mp-1')

      expect(client.api_requests.last[:params])
        .to include(bucket: 'zealot-staging', key: upload.staging_key, upload_id: 'mp-1')
    end

    it 'reads the upload id from the record by default' do
      client.stub_responses(:list_parts, parts: [], is_truncated: false)
      upload.update_columns(multipart_upload_id: 'mp-record')

      staging.list_parts(upload)

      expect(client.api_requests.last[:params]).to include(upload_id: 'mp-record')
    end

    it 'follows the part number marker until R2 says the listing is complete' do
      client.stub_responses(:list_parts, [
                              { parts: [{ part_number: 1, size: 16, etag: '"a"' }],
                                is_truncated: true, next_part_number_marker: 1 },
                              { parts: [{ part_number: 2, size: 7, etag: '"b"' }], is_truncated: false }
                            ])

      held = staging.list_parts(upload, upload_id: 'mp-1')

      expect(held.map(&:part_number)).to eq([1, 2])
      list_calls = client.api_requests.select { |request| request[:operation_name] == :list_parts }
      expect(list_calls.size).to eq(2)
      expect(list_calls.first[:params]).not_to have_key(:part_number_marker)
      expect(list_calls.last[:params]).to include(part_number_marker: 1)
    end

    it 'answers an empty list when R2 holds no parts yet' do
      client.stub_responses(:list_parts, parts: [], is_truncated: false)

      expect(staging.list_parts(upload, upload_id: 'mp-1')).to eq([])
    end

    it 'answers nil, not an error, when R2 no longer knows the upload' do
      client.stub_responses(:list_parts, 'NoSuchUpload')

      expect(staging.list_parts(upload, upload_id: 'mp-1')).to be_nil
    end

    it 'answers nil without calling R2 when no multipart upload was started' do
      expect(staging.list_parts(upload)).to be_nil
      expect(client.api_requests).to be_empty
    end

    it 'raises a storage error for any other R2 failure' do
      client.stub_responses(:list_parts, 'AccessDenied')

      expect { staging.list_parts(upload, upload_id: 'mp-1') }
        .to raise_error(ReleaseStorage::StorageError, /R2 list parts failed/)
    end
  end

  # Task 40s-b: the operator's boto3 run only passed with the SDK's default checksums off.
  describe 'the client it builds' do
    let(:env) do
      ENV.to_hash.merge('R2_STAGING_BUCKET' => 'zealot-staging',
                        'R2_STAGING_ENDPOINT' => 'https://acct.r2.cloudflarestorage.com',
                        'R2_STAGING_ACCESS_KEY_ID' => 'AKIAEXAMPLE', 'R2_STAGING_SECRET_ACCESS_KEY' => 'secret')
    end

    it 'only adds and validates checksums when an operation requires them' do
      stub_const('ENV', env)

      config = described_class.new.instance_variable_get(:@client).config

      expect(config.request_checksum_calculation).to eq('when_required')
      expect(config.response_checksum_validation).to eq('when_required')
    end

    it 'presigns a single PUT without a checksum parameter' do
      stub_const('ENV', env)

      url = described_class.new.presign_put(upload).url

      expect(url).not_to match(/x-amz-checksum|x-amz-sdk-checksum/i)
    end
  end
end
