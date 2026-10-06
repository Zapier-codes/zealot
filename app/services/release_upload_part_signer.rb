# frozen_string_literal: true

# Task 40s-c: what a client of a multipart direct upload asks for while it sends the file in parts. Both doors
# (the console and the API) call this after their own authentication and ownership checks; nothing here decides
# who may upload. Rails never handles a byte of the file: it signs part URLs and reads R2's own list of parts.
#
#   signer = ReleaseUploadPartSigner.new(upload)
#   signer.sign([1, 2, 3, 4])   # up to MAX_BATCH part numbers -> one presigned PUT per part
#   signer.list                 # which parts R2 holds (right size) and which are still to send (resume)
#
# Both answer a `Result`: `code`, `http` and `payload` (what the doors render). The client never reports ETags
# or sizes; the numbers it asks for are checked against the plan stored on the row (`ReleaseUpload#plan`), and
# `list` is R2's word, so a resumed upload (dropped connection, page refresh) learns what to send from R2.
#
# Part URLs live for the smaller of the single-PUT window (2 hours) and the time left in the row's window, so
# no URL outlives the row. A part URL signs no content type: the client sends the bytes with no special header.
#
# Not verified: no Rails and no R2 where this was written; see the Task 40s-c entry in handover.md.
class ReleaseUploadPartSigner
  HTTP = {
    ok: 200, invalid_parts: 422, not_multipart: 422, not_open: 409, expired: 409, upload_gone: 409,
    storage_unavailable: 503
  }.freeze

  Result = Struct.new(:code, :error, :payload, keyword_init: true) do
    def http
      HTTP.fetch(code)
    end

    def ok?
      code == :ok
    end

    # What the doors render: the answer on success, `{ error: }` otherwise.
    def body
      ok? ? payload : { error: error }
    end
  end

  # Part numbers as a client may send them: a JSON array (`[1, 2]`, `["1", "2"]`) or a comma list (`"1,2"`).
  #
  # @return [Array<Integer>, nil] nil when the value is missing or any entry is not a plain whole number
  def self.parse_numbers(raw)
    list = raw.is_a?(String) ? raw.split(',') : raw
    return nil unless list.is_a?(Array) && list.any?

    list.map { |entry| Integer(entry.to_s.strip, 10) }
  rescue ArgumentError
    nil
  end

  def initialize(upload, staging: nil, now: Time.current)
    @upload = upload
    @staging = staging
    @now = now
  end

  # @param numbers [Array<Integer>, nil] the parts to sign, 1 to MAX_BATCH distinct numbers inside the plan
  # @return [Result]
  def sign(numbers)
    refusal = refusal_for_state
    return refusal if refusal

    problem = problem_with_numbers(numbers)
    return fail_with(:invalid_parts, problem) if problem

    ttl = [[ReleaseUploadStaging::DEFAULT_EXPIRES_IN, (@upload.expires_at - @now).to_i].min, 1].max
    parts = numbers.map { |number| signed_part(number, ttl) }
    Result.new(code: :ok, payload: { id: @upload.id, state: @upload.state, part_size: plan.part_size,
                                     part_count: plan.count, parts: parts })
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    storage_unavailable(e)
  end

  # @return [Result] `uploaded` (numbers R2 holds at the right size) and `missing` (the rest, in order)
  def list
    refusal = refusal_for_state
    return refusal if refusal

    held = staging.list_parts(@upload)
    if held.nil?
      return fail_with(:upload_gone, 'R2 no longer holds this upload (it was completed or discarded). ' \
                                     'Finalize it, or start a new upload.')
    end

    missing = plan.missing(held)
    Result.new(code: :ok, payload: { id: @upload.id, state: @upload.state, part_size: plan.part_size,
                                     part_count: plan.count, uploaded: (1..plan.count).to_a - missing,
                                     missing: missing })
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    storage_unavailable(e)
  end

  private

  def plan
    @plan ||= @upload.plan
  end

  def staging
    @staging ||= ReleaseUploadStaging.new
  end

  # nil when the row may be worked on, else the refusing Result.
  def refusal_for_state
    return fail_with(:not_multipart, 'This upload was not opened in parts.') unless @upload.multipart?
    return fail_with(:not_open, "This upload is #{@upload.state}.") unless @upload.state_awaiting_bytes?
    return fail_with(:expired, 'The upload window has closed. Start a new upload.') unless @upload.window_open?(@now)
    return nil if @upload.multipart_upload_id.present?

    fail_with(:upload_gone, 'This upload was never opened in storage. Start a new upload.')
  end

  def problem_with_numbers(numbers)
    return 'Send the part numbers to sign as "parts", for example [1, 2, 3].' if numbers.blank?

    max = ReleaseUploadParts::MAX_BATCH
    return "Ask for at most #{max} parts at a time." if numbers.size > max
    return 'Each part number may be given once.' unless numbers.uniq.size == numbers.size

    outside = numbers.reject { |number| plan.number_ok?(number) }
    return nil if outside.empty?

    "This upload has parts 1 to #{plan.count}; #{outside.first(5).join(', ')} is outside that."
  end

  def signed_part(number, ttl)
    presigned = staging.presign_part(@upload, part_number: number, expires_in: ttl)
    { part_number: number, url: presigned.url, method: presigned.method, headers: presigned.headers,
      size: plan.size_of(number), expires_at: presigned.expires_at.iso8601 }
  end

  def fail_with(code, error)
    Result.new(code: code, error: error)
  end

  def storage_unavailable(error)
    Rails.logger.error("[ReleaseUploadPartSigner] upload #{@upload.id}: #{error.message}")
    fail_with(:storage_unavailable, 'Staging storage is unavailable. Try again shortly.')
  end
end
