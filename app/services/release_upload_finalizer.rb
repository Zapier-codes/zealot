# frozen_string_literal: true

# Task 40h-b: the client says it has finished sending the file to the staging bucket. Finalize asks R2 what it
# actually holds (`ReleaseUploadStaging#head`), compares it with what was declared, and moves the row
# `awaiting_bytes -> uploaded`. A presigned PUT cannot be capped at the declared size (see
# `ReleaseUploadStaging`), so this is where an oversized or wrong file is caught.
#
# Task 40i-a: a successful finalize enqueues `ReleaseUploadDispatchJob`, which sends the upload to the stage-1
# workflow (`read-upload.yml`) that reads the manifest and icon. A repeated finalize enqueues nothing.
#
#   result = ReleaseUploadFinalizer.new(upload).call
#   result.code   # :uploaded, :already_uploaded, :no_bytes, :size_mismatch, :expired, :not_open, :storage_unavailable
#   result.http   # the status the doors answer with
#   result.error  # a short reason for the client, nil on success
#
# Idempotent: finalizing an `uploaded` row again answers 200 and writes nothing. Every write is conditional on
# the state still being `awaiting_bytes`, so two concurrent finalize calls cannot both win and a sweeper that
# expired the row in between is not overwritten.
#
# The window: the presigned URL is good for `ReleaseUpload::UPLOAD_WINDOW`, but a request that started inside it
# can finish after it, so finalize is accepted for GRACE longer. Past that the row becomes `expired`.
#
# Not verified: no Ruby in the sandbox this was written in; nothing was run against R2.
class ReleaseUploadFinalizer
  GRACE = 30.minutes

  HTTP = {
    uploaded: 200, already_uploaded: 200, no_bytes: 422, size_mismatch: 422,
    expired: 409, not_open: 409, storage_unavailable: 503
  }.freeze

  Result = Struct.new(:code, :error, keyword_init: true) do
    def http
      HTTP.fetch(code)
    end

    def ok?
      %i[uploaded already_uploaded].include?(code)
    end
  end

  def initialize(upload, staging: nil, now: Time.current)
    @upload = upload
    @staging = staging
    @now = now
  end

  # @return [Result]
  def call
    return Result.new(code: :already_uploaded) if @upload.state_uploaded?
    return Result.new(code: :not_open, error: "This upload is #{@upload.state}.") unless @upload.state_awaiting_bytes?
    return expire if @upload.expires_at.nil? || @upload.expires_at + GRACE < @now

    held = staging.head(@upload)
    return Result.new(code: :no_bytes, error: 'No file has reached the staging bucket for this upload.') if held.nil?
    return reject_size(held) unless held.size == @upload.declared_size

    record_uploaded(held)
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    Rails.logger.error("[ReleaseUploadFinalizer] upload #{@upload.id}: #{e.message}")
    Result.new(code: :storage_unavailable, error: 'Staging storage is unavailable. Try again shortly.')
  end

  private

  def staging
    @staging ||= ReleaseUploadStaging.new
  end

  def expire
    conditional_update(state: 'expired', error: 'The upload window closed before the file was finalized.')
    Result.new(code: :expired, error: 'The upload window has closed. Start a new upload.')
  end

  # The wrong file is useless and may be huge: fail the row and drop the object (best effort; the lifecycle
  # rule is the backstop, so a delete error never changes the answer).
  def reject_size(held)
    reason = "The staged file is #{held.size} bytes but #{@upload.declared_size} were declared."
    conditional_update(state: 'failed', error: reason, uploaded_size: held.size)
    begin
      staging.delete(@upload)
    rescue ReleaseStorage::StorageError => e
      Rails.logger.warn("[ReleaseUploadFinalizer] upload #{@upload.id}: staged object not deleted: #{e.message}")
    end
    Result.new(code: :size_mismatch, error: reason)
  end

  def record_uploaded(held)
    changed = conditional_update(state: 'uploaded', uploaded_size: held.size, etag: held.etag, uploaded_at: @now)
    if changed.positive?
      ReleaseUploadDispatchJob.perform_later(@upload.id)
      return Result.new(code: :uploaded)
    end

    # Lost a race: report whatever the row became.
    @upload.reload
    return Result.new(code: :already_uploaded) if @upload.state_uploaded?

    Result.new(code: :not_open, error: "This upload is #{@upload.state}.")
  end

  def conditional_update(attributes)
    ReleaseUpload.where(id: @upload.id, state: 'awaiting_bytes').update_all(attributes.merge(updated_at: @now))
  end
end
