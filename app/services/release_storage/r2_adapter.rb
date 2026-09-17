# frozen_string_literal: true

# Stores release-pipeline artifacts in Cloudflare R2 via the S3-compatible
# API (aws-sdk-s3 pointed at the R2 endpoint). Selected when
# RELEASE_STORAGE_ADAPTER=r2.
#
# Required env vars:
#   R2_BUCKET             - target bucket name
#   R2_ENDPOINT           - e.g. https://<account_id>.r2.cloudflarestorage.com
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_REGION             - optional, defaults to "auto" (R2's convention)
class ReleaseStorage::R2Adapter
  REQUIRED_ENV = %w[R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY].freeze

  def initialize(client: nil, bucket: ENV['R2_BUCKET'])
    ensure_configured!
    @bucket = bucket
    @client = client || build_client
  end

  def put(key, local_path, content_encoding: nil, content_type: nil)
    File.open(local_path, 'rb') do |file|
      params = { bucket: @bucket, key: key, body: file }
      params[:content_encoding] = content_encoding if content_encoding.present?
      params[:content_type] = content_type if content_type.present?
      @client.put_object(**params)
    end
    key
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 put failed for #{key}: #{e.message}"
  end

  def get(key, to)
    FileUtils.mkdir_p(File.dirname(to))
    @client.get_object(bucket: @bucket, key: key, response_target: to)
    to
  rescue Aws::S3::Errors::NoSuchKey
    nil
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 get failed for #{key}: #{e.message}"
  end

  def url_for(key, expires_in: 3600)
    signer = Aws::S3::Presigner.new(client: @client)
    signer.presigned_url(:get_object, bucket: @bucket, key: key, expires_in: expires_in)
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 presign failed for #{key}: #{e.message}"
  end

  def delete(key)
    @client.delete_object(bucket: @bucket, key: key)
    true
  rescue Aws::Errors::ServiceError => e
    raise ReleaseStorage::StorageError, "R2 delete failed for #{key}: #{e.message}"
  end

  def exist?(key)
    @client.head_object(bucket: @bucket, key: key)
    true
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    false
  end

  private

  def ensure_configured!
    missing = REQUIRED_ENV.select { |var| ENV[var].blank? }
    return if missing.empty?

    raise ReleaseStorage::ConfigurationError,
          "R2 adapter selected but missing env vars: #{missing.join(', ')}"
  end

  def build_client
    require 'aws-sdk-s3'

    Aws::S3::Client.new(
      access_key_id: ENV.fetch('R2_ACCESS_KEY_ID'),
      secret_access_key: ENV.fetch('R2_SECRET_ACCESS_KEY'),
      endpoint: ENV.fetch('R2_ENDPOINT'),
      region: ENV.fetch('R2_REGION', 'auto'),
      force_path_style: true
    )
  end
end
