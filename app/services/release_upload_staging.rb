# frozen_string_literal: true

require 'aws-sdk-s3'

# Task 40h-a: the R2 staging bucket, as far as the decided Task 40 flow needs it. Zealot hands the client a
# presigned URL for a key Zealot chose, so the bytes go straight to R2 and never touch Render (no Rack temp
# file, no CarrierWave copy). Afterwards Zealot asks R2 how big the object is and, when the upload is over,
# deletes it. The durable store stays the GitHub storage repo (Task 19); this bucket only holds files in
# transit and is emptied by CI and by a lifecycle rule.
#
# Separate from `ReleaseStorage::R2Adapter` on purpose: different bucket, different (narrower) token, and the
# adapter's `R2_*` names belong to the storage adapter. Needs its own env:
#
#   R2_STAGING_BUCKET             bucket name
#   R2_STAGING_ENDPOINT           https://<account_id>.r2.cloudflarestorage.com
#   R2_STAGING_ACCESS_KEY_ID      the token Render uses: presign, HEAD and delete on this bucket
#   R2_STAGING_SECRET_ACCESS_KEY
#   R2_STAGING_REGION             optional, "auto" (R2's convention)
#
# Presigned URLs are bearer tokens: anyone holding one can do that one operation on that one key until it
# expires. They work only on the S3 endpoint above (not a custom domain), and when a browser uses them the
# bucket needs a CORS rule (see the Task 40 entry in handover.md). A presigned PUT cannot be limited to the
# declared size, so the size is checked afterwards: `#head` reports what R2 holds and finalize (40h-b)
# compares it with `ReleaseUpload#declared_size`.
#
# Nothing here writes to the database: the callers (40h-b) record what these methods return.
#
#   staging = ReleaseUploadStaging.new
#   staging.presign_put(upload)        # => Presigned (url, method, headers, expires_at)
#   staging.head(upload)               # => Head (size, etag) or nil when nothing was uploaded
#   staging.delete(upload)
#
# Multipart (for large files and resumable browsers): `start_multipart` returns the upload id (the caller
# stores it in `ReleaseUpload#multipart_upload_id`), `presign_part` signs one part, `complete_multipart`
# joins them, `abort_multipart` throws them away.
#
# Not verified: nothing was run against R2 and no Ruby ran beyond `ruby -c`. Cloudflare's presigned-URL page
# lists GET, HEAD, PUT and DELETE; presigning an individual UploadPart (a PUT with `partNumber` and
# `uploadId`) is not named there, and R2's minimum part size is not documented on the pages read, so
# `MIN_PART_SIZE` is S3's value. The single presigned PUT (up to 5 GiB per Cloudflare's limits page) already
# covers every file under the 2 GiB cap, so the multipart methods are an option, not a requirement.
class ReleaseUploadStaging
  REQUIRED_ENV = %w[
    R2_STAGING_BUCKET R2_STAGING_ENDPOINT R2_STAGING_ACCESS_KEY_ID R2_STAGING_SECRET_ACCESS_KEY
  ].freeze

  # Same as the upload window on the record (R2 allows 1 second to 7 days).
  DEFAULT_EXPIRES_IN = ReleaseUpload::UPLOAD_WINDOW.to_i

  # S3's multipart limits. R2's page for them was not read: treat as the S3 values, to be confirmed.
  MAX_PART_NUMBER = 10_000
  MIN_PART_SIZE = 5 * 1024 * 1024

  Presigned = Struct.new(:url, :method, :headers, :expires_at, keyword_init: true)
  Head = Struct.new(:size, :etag, keyword_init: true)

  # True when all four required variables are set (the console can hide direct upload until they are).
  def self.configured?
    REQUIRED_ENV.all? { |name| ENV[name].present? }
  end

  # @raise [ReleaseStorage::ConfigurationError] a variable is missing (only when no client is passed)
  def initialize(client: nil, bucket: ENV['R2_STAGING_BUCKET'])
    ensure_configured! unless client
    raise ReleaseStorage::ConfigurationError, 'R2_STAGING_BUCKET is not set' if bucket.blank?

    @bucket = bucket
    @client = client || build_client
  end

  # A presigned PUT for the upload's staging key. If the record has a content type it is part of the
  # signature, so the client must send the same `Content-Type` header (the returned `headers` say so).
  #
  # @return [Presigned]
  def presign_put(upload, expires_in: DEFAULT_EXPIRES_IN)
    params = { bucket: @bucket, key: key_for(upload), expires_in: expires_in }
    params[:content_type] = upload.content_type if upload.content_type.present?

    Presigned.new(url: presigner.presigned_url(:put_object, **params), method: 'PUT',
                  headers: upload.content_type.present? ? { 'Content-Type' => upload.content_type } : {},
                  expires_at: expires_in.seconds.from_now)
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 presign failed for #{upload.staging_key}: #{e.message}"
  end

  # What R2 holds at the upload's staging key.
  #
  # @return [Head, nil] nil when nothing is there (the client never sent, or the object expired)
  def head(upload)
    response = @client.head_object(bucket: @bucket, key: key_for(upload))
    Head.new(size: response.content_length, etag: response.etag.to_s.delete('"'))
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    nil
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 head failed for #{upload.staging_key}: #{e.message}"
  end

  # Removes the staged object. Deleting what is not there is not an error (R2 answers 204 either way).
  def delete(upload)
    @client.delete_object(bucket: @bucket, key: key_for(upload))
    true
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 delete failed for #{upload.staging_key}: #{e.message}"
  end

  # Task 40i-c: removes another object stage 1 put beside the file (the icon). Only a key under this upload's
  # own prefix is accepted, so a report can never make Zealot delete someone else's staged file.
  def delete_sibling(upload, key)
    prefix = "#{File.dirname(key_for(upload))}/"
    unless key.to_s.start_with?(prefix) && !key.to_s.include?('..')
      raise ArgumentError, 'the key is not under this upload'
    end

    @client.delete_object(bucket: @bucket, key: key)
    true
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 delete failed for #{key}: #{e.message}"
  end

  # @return [String] the multipart upload id; the caller stores it on the record
  def start_multipart(upload)
    params = { bucket: @bucket, key: key_for(upload) }
    params[:content_type] = upload.content_type if upload.content_type.present?
    @client.create_multipart_upload(**params).upload_id
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 multipart start failed for #{upload.staging_key}: #{e.message}"
  end

  # A presigned PUT for one part of the record's multipart upload.
  #
  # @return [Presigned]
  def presign_part(upload, part_number:, upload_id: upload.multipart_upload_id, expires_in: DEFAULT_EXPIRES_IN)
    number = Integer(part_number)
    raise ArgumentError, "part_number must be 1 to #{MAX_PART_NUMBER}" unless (1..MAX_PART_NUMBER).cover?(number)
    raise ArgumentError, 'no multipart upload has been started for this upload' if upload_id.blank?

    url = presigner.presigned_url(:upload_part, bucket: @bucket, key: key_for(upload), upload_id: upload_id,
                                                part_number: number, expires_in: expires_in)
    Presigned.new(url: url, method: 'PUT', headers: {}, expires_at: expires_in.seconds.from_now)
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 part presign failed for #{upload.staging_key}: #{e.message}"
  end

  # @param parts [Array<Hash>] `{ part_number:, etag: }` for every part, in any order (the ETag as the part's
  #   PUT response gave it, quotes included)
  def complete_multipart(upload, parts:, upload_id: upload.multipart_upload_id)
    raise ArgumentError, 'no multipart upload has been started for this upload' if upload_id.blank?

    listed = parts.map { |part| { part_number: Integer(part[:part_number]), etag: part[:etag].to_s } }
                  .sort_by { |part| part[:part_number] }
    @client.complete_multipart_upload(bucket: @bucket, key: key_for(upload), upload_id: upload_id,
                                      multipart_upload: { parts: listed })
    true
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 multipart complete failed for #{upload.staging_key}: #{e.message}"
  end

  # @return [Boolean] false when R2 no longer knows that upload id
  def abort_multipart(upload, upload_id: upload.multipart_upload_id)
    return false if upload_id.blank?

    @client.abort_multipart_upload(bucket: @bucket, key: key_for(upload), upload_id: upload_id)
    true
  rescue Aws::S3::Errors::NoSuchUpload
    false
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 multipart abort failed for #{upload.staging_key}: #{e.message}"
  end

  private

  def key_for(upload)
    key = upload.staging_key
    raise ReleaseStorage::StorageError, "upload #{upload.id} has no staging key" if key.blank?

    key
  end

  def presigner
    @presigner ||= Aws::S3::Presigner.new(client: @client)
  end

  def ensure_configured!
    missing = REQUIRED_ENV.select { |name| ENV[name].blank? }
    return if missing.empty?

    raise ReleaseStorage::ConfigurationError, "R2 staging selected but missing env vars: #{missing.join(', ')}"
  end

  def build_client
    Aws::S3::Client.new(
      access_key_id: ENV.fetch('R2_STAGING_ACCESS_KEY_ID'),
      secret_access_key: ENV.fetch('R2_STAGING_SECRET_ACCESS_KEY'),
      endpoint: ENV.fetch('R2_STAGING_ENDPOINT'),
      region: ENV.fetch('R2_STAGING_REGION', 'auto'),
      force_path_style: true
    )
  end
end
