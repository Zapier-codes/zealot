# frozen_string_literal: true

# Task 40i-a: records what the stage-1 workflow found in a staged upload (or that it failed). Stage 1 reads the
# file in CI: package name, version, the SDK levels, the ABIs, the SHA-256, and an icon it puts back into the
# staging bucket next to the file. This service checks the report against what Zealot already knows, stores it
# on the `release_uploads` row, and (Task 40i-b) hands the recorded report to `ReleaseUploadReleaseBuilder`,
# which builds the held `Release` with the form's own validations. This file never creates a release itself.
#
#   result = ReleaseUploadIntake.new(upload, body).call
#   result.code     # :recorded, :already_recorded, :failure_recorded, :refused, :malformed, :not_open, :conflict
#   result.http     # the status the callback answers with
#   result.payload  # the JSON body to answer with
#
# Rules, all enforced here and not by trusting CI:
# - only an `uploaded` row takes a report; any other state is refused (409) and nothing changes;
# - idempotent: the same report again (same `file_sha256`) answers 200 and writes nothing; a different one for an
#   already-reported upload is refused (409), so a replay or a second run can never overwrite the first answer;
# - a malformed report (bad package name, hash, size, kind) is refused (422) and changes nothing, so CI can
#   resend a corrected one;
# - `file_size` must equal the size finalize recorded from the bucket, and `kind` must match the file extension,
#   so the report is about the object that was actually staged;
# - an icon key must live under this upload's own staging prefix, so a report cannot point at another object;
# - a `failed` report marks the upload failed with the reason and drops the staged object (best effort);
# - a recorded report whose release the checks refuse (wrong package name, stale Play version code) answers 422
#   `{ state: "failed", error: ... }`, creates nothing and leaves the upload `failed`. A replay of a recorded
#   report whose release was never created (the first call died in between) finishes the job; a replay after the
#   release exists answers the same release again and never makes a second one.
#
# Not verified: no Ruby in the sandbox this was written in; nothing was run.
class ReleaseUploadIntake
  Result = Struct.new(:code, :http, :payload, keyword_init: true)

  PACKAGE_FORMAT = /\A[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+\z/
  SHA256_FORMAT = /\A[0-9a-f]{64}\z/
  ABI_FORMAT = /\A[A-Za-z0-9_-]{1,32}\z/
  # Task 46a: an Android permission name (`android.permission.INTERNET`, `com.example.app.SOME_PERMISSION`).
  PERMISSION_FORMAT = /\A[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+\z/
  MAX_PERMISSIONS = 200
  KINDS = { 'apk' => '.apk', 'aab' => '.aab' }.freeze
  MAX_VERSION_CODE = 2_100_000_000

  def initialize(upload, body, staging: nil, now: Time.current)
    @upload = upload
    @body = body
    @staging = staging
    @now = now
  end

  def call
    return refuse(:malformed, 422, 'state must be "ok" or "failed"') unless %w[ok failed].include?(body['state'])
    return record_failure if body['state'] == 'failed'

    record_report
  end

  private

  attr_reader :upload, :body

  def staging
    @staging ||= ReleaseUploadStaging.new
  end

  def record_report
    sha = body['file_sha256'].to_s.downcase
    return already_recorded(sha) if upload.stage1_at.present?
    return not_open unless upload.state_uploaded?

    problem = malformed(sha)
    return refuse(:malformed, 422, problem) if problem

    metadata = normalized(sha)
    changed = ReleaseUpload.where(id: upload.id, state: 'uploaded', stage1_at: nil)
                           .update_all(metadata: metadata, stage1_at: @now, updated_at: @now)
    return build_release(:recorded) if changed.positive?

    upload.reload
    upload.stage1_at.present? ? already_recorded(sha) : not_open
  end

  def already_recorded(sha)
    return refuse(:conflict, 409, 'This upload was already reported with a different file.') unless
      upload.metadata['file_sha256'] == sha

    build_release(:already_recorded)
  end

  # Task 40i-b: the builder locks the row, so a replay and a first call can never both create a release.
  def build_release(code)
    # `@staging` on purpose, not `staging`: the builder only needs the bucket client to drop a refused upload's
    # object, so it builds one then, and a good report never depends on the staging bucket's configuration.
    result = ReleaseUploadReleaseBuilder.new(upload, staging: @staging).call
    upload.reload

    case result.code
    when :created, :existing then Result.new(code: code, http: 200, payload: answer(result.release))
    when :refused then Result.new(code: :refused, http: 422, payload: refused_answer(result.reason))
    else not_open
    end
  end

  def refused_answer(reason)
    { upload_id: upload.id, state: upload.state, error: reason }
  end

  # What stage 2 needs: the release id, the storage tag its files go under, (Task 41b) the base name its
  # files are stored as and (Task 47c) whether the publisher allows the injected updater.
  def answer(release)
    payload = { upload_id: upload.id, state: upload.state, stage: 1, release_id: release&.id,
                package_name: upload.metadata['package_name'] }
    if release
      payload[:storage_tag] = ReleaseStorage.new(release, adapter: nil).tag
      payload[:artifact_base] = ReleaseArtifactName.for(release)
      # Task 47c: the publisher's switch (47e). Stage 2 injects the updater only when it is true; a missing key
      # (an older Zealot answering a newer workflow) is read by the workflow as false, so nothing is injected.
      payload[:updater_enabled] = release.app.updater_enabled == true
    end
    payload
  end

  def not_open
    refuse(:not_open, 409, "This upload is #{upload.state}.")
  end

  def refuse(code, http, message)
    Result.new(code: code, http: http, payload: { error: message })
  end

  def record_failure
    return not_open unless upload.state_uploaded? && upload.stage1_at.nil?

    reason = body['error'].to_s.strip.presence || 'CI reported a failure without a reason'
    changed = ReleaseUpload.where(id: upload.id, state: 'uploaded', stage1_at: nil)
                           .update_all(state: 'failed', error: reason.truncate(1000), updated_at: @now)
    drop_staged_object if changed.positive?
    Result.new(code: :failure_recorded, http: 200, payload: { upload_id: upload.id, state: 'failed' })
  end

  def drop_staged_object
    staging.delete(upload)
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    Rails.logger.warn("[ReleaseUploadIntake] upload #{upload.id}: staged object not deleted: #{e.message}")
  end

  # @return [String, nil] the first problem found, or nil
  def malformed(sha)
    kind = body['kind'].to_s
    return 'kind must be apk or aab' unless KINDS.key?(kind)
    unless upload.filename.downcase.end_with?(KINDS[kind])
      return "kind #{kind} does not match the file name #{upload.filename}"
    end
    return 'package_name is not a valid Android package name' unless valid_package?(body['package_name'])
    return 'version_code must be a positive integer' unless valid_version_code?(body['version_code'])
    return 'version_name is required (255 characters at most)' unless version_name_ok?
    return 'app_label is too long' unless valid_text?(body['app_label'], 255, required: false)
    return 'file_sha256 must be 64 hex characters' unless SHA256_FORMAT.match?(sha)
    return 'file_size does not match the staged file' unless body['file_size'].to_s == upload.uploaded_size.to_s

    sdk_problem || abi_problem || icon_problem
  end

  def valid_package?(value)
    value.is_a?(String) && value.length <= 255 && PACKAGE_FORMAT.match?(value)
  end

  def valid_version_code?(value)
    number = Integer(value.to_s, 10, exception: false)
    !number.nil? && number.between?(1, MAX_VERSION_CODE)
  end

  def version_name_ok?
    valid_text?(body['version_name'], 255, required: true)
  end

  def valid_text?(value, max, required:)
    return !required if value.nil? || value.to_s.empty?

    value.is_a?(String) && value.length <= max && !value.match?(/[[:cntrl:]]/)
  end

  def sdk_problem
    %w[min_sdk target_sdk].each do |field|
      next if body[field].nil? || body[field].to_s.empty?

      number = Integer(body[field].to_s, 10, exception: false)
      return "#{field} must be a number from 1 to 99" unless number&.between?(1, 99)
    end
    nil
  end

  def abi_problem
    abis = body['abis']
    return nil if abis.nil?
    return 'abis must be a list of at most 16 names' unless abis.is_a?(Array) && abis.length <= 16
    return 'an ABI name is not valid' unless abis.all? { |abi| abi.is_a?(String) && ABI_FORMAT.match?(abi) }

    nil
  end

  # An icon is optional, but its key and hash come together and the key must be under this upload's prefix.
  def icon_problem
    key = body['icon_key'].to_s
    sha = body['icon_sha256'].to_s.downcase
    return nil if key.empty? && sha.empty?
    return 'icon_key and icon_sha256 must be sent together' if key.empty? || sha.empty?
    return 'icon_sha256 must be 64 hex characters' unless SHA256_FORMAT.match?(sha)

    prefix = "#{File.dirname(upload.staging_key)}/"
    return 'icon_key is not under this upload' unless icon_key_ok?(key, prefix)

    nil
  end

  def icon_key_ok?(key, prefix)
    key.start_with?(prefix) && !key.include?('..') && key.length <= 512
  end

  def normalized(sha)
    {
      'kind' => body['kind'], 'package_name' => body['package_name'],
      'version_code' => Integer(body['version_code'].to_s, 10), 'version_name' => body['version_name'].to_s,
      'app_label' => body['app_label'].presence, 'file_sha256' => sha, 'file_size' => upload.uploaded_size,
      'min_sdk' => integer_or_nil(body['min_sdk']), 'target_sdk' => integer_or_nil(body['target_sdk']),
      'abis' => Array(body['abis']), 'permissions' => self.class.clean_permissions(body['permissions']),
      'icon_key' => body['icon_key'].presence,
      'icon_sha256' => body['icon_sha256'].to_s.downcase.presence
    }.compact
  end

  # Task 46a: the permissions CI read from the manifest. Cleaned, never refused ("nothing is rejected"): anything that
  # is not a well-formed permission name is dropped, duplicates collapse, the list is capped and sorted. Used by the
  # stage-2 finisher too, so both stages judge a name the same way. Always an Array.
  def self.clean_permissions(value)
    return [] unless value.is_a?(Array)

    value.filter_map { |name| name.to_s.strip if name.is_a?(String) && name.length <= 255 }
         .select { |name| PERMISSION_FORMAT.match?(name) }
         .uniq.sort.first(MAX_PERMISSIONS)
  end

  def integer_or_nil(value)
    value.to_s.empty? ? nil : Integer(value.to_s, 10)
  end
end
