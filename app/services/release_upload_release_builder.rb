# frozen_string_literal: true

# Task 40i-b: turns a staged upload whose stage-1 report has been recorded into the real `Release`. This is the
# ONLY code that creates a release without a user session (the decided Task 40 flow's third creator), and the
# only caller is `ReleaseUploadIntake`, which only the OIDC-verified stage-1 callback reaches. The tripwire spec
# `spec/requests/manual_upload_only_spec.rb` pins all three facts.
#
#   result = ReleaseUploadReleaseBuilder.new(upload, staging: nil).call
#   result.code      # :created, :existing, :refused, :not_ready
#   result.release   # the release, for :created and :existing
#   result.reason    # the refusal text, for :refused
#
# What it does, in one transaction on a locked `release_uploads` row:
# - `:existing`  the row already has a release (a replayed callback); nothing is created, nothing changes;
# - `:not_ready` the row is not `uploaded` with a recorded report (never finalized, failed, expired); nothing is
#                created. A callback can therefore never make a release for an upload nobody finalized;
# - otherwise builds the release from the report and the options the owner chose at session time, runs the SAME
#   model validations the upload form runs (`bundle_id_matched`, and for a Play target `play_target_bundle_valid`
#   and `play_version_code_newer`), and saves it **held**, so it is not in the signed catalog index until stage 2
#   (40i-c) has made it installable. On success the row becomes `processing` and points at the release (the
#   unique index on `release_uploads.release_id` backs the one-release-per-upload rule);
# - a refused release creates nothing: the row becomes `failed` with the reason and the staged object is dropped
#   (best effort, after the transaction).
#
# The manifest itself was read by CI (`manifest_readable` has nothing left to check: the intake already refused a
# report without a package name and a version code). The file, the icon and the keys are NOT recorded here:
# `file_storage_key` and `icon_storage_key` stay empty until stage 2 uploads to the storage repo and Zealot has
# checked the object is there, so no release ever carries a key that points at nothing.
#
# Concurrent uploads to one channel can race on the channel's version counter (`releases` has a unique index on
# `channel_id, version`); the transaction is retried a few times, then the error is raised to the caller.
#
# Not verified: no Ruby in the sandbox this was written in; nothing was run.
class ReleaseUploadReleaseBuilder
  Result = Struct.new(:code, :release, :reason, keyword_init: true)

  MAX_ATTEMPTS = 3

  # Options copied from the session's `form_options` when the owner gave them. `hold` and `source` are handled
  # on their own; `devices` is an iOS ad-hoc option and means nothing for an APK or an AAB.
  OPTION_ATTRIBUTES = %w[release_type branch git_commit ci_url changelog custom_fields play_store_target].freeze

  def initialize(upload, staging: nil)
    @upload = upload
    @staging = staging
  end

  # @return [Result]
  def call
    attempts = 0
    begin
      attempts += 1
      result = ReleaseUpload.transaction { build_locked }
    rescue ActiveRecord::RecordNotUnique
      retry if attempts < MAX_ATTEMPTS
      raise
    end

    drop_staged_object if result.code == :refused
    result
  end

  private

  attr_reader :upload

  def staging
    @staging ||= ReleaseUploadStaging.new
  end

  # Runs inside the transaction. No `return` out of the block: the result is the method's value.
  def build_locked
    row = ReleaseUpload.lock.find(upload.id)
    if row.release_id.present?
      Result.new(code: :existing, release: row.release)
    elsif !(row.state_uploaded? && row.stage1_at.present?)
      Result.new(code: :not_ready)
    else
      create_release(row)
    end
  end

  def create_release(row)
    release = build_release(row)
    return refuse(row, release) unless release.save

    row.update_columns(state: 'processing', release_id: release.id, updated_at: Time.current)
    Result.new(code: :created, release: release)
  end

  def refuse(row, release)
    reason = release.errors.full_messages.to_sentence.presence || 'The release was refused.'
    row.update_columns(state: 'failed', error: reason.truncate(1000), updated_at: Time.current)
    Result.new(code: :refused, reason: reason)
  end

  def build_release(row)
    meta = row.metadata
    release = Release.new(core_attributes(row, meta))
    release.assign_attributes(option_attributes(row.form_options))
    release.storage_intake_kind = meta['kind']
    release
  end

  # What the manifest says is the source of truth, so the typed `release_version` / `build_version` of the form
  # are not read (40h-c-1, choice 1). `status` is always `held` here: whether the owner asked for `hold` is read
  # from the row's `form_options` by stage 2, which makes the release available unless they did.
  def core_attributes(row, meta)
    {
      channel: row.channel, status: 'held', device_type: Channel.device_types['android'],
      name: meta['app_label'].presence || meta['package_name'], bundle_id: meta['package_name'],
      release_version: meta['version_name'], build_version: meta['version_code'].to_s,
      min_sdk_version: meta['min_sdk'], target_sdk_version: meta['target_sdk'], abis: Array(meta['abis']),
      file_sha256: meta['file_sha256'], source: row.form_options['source'].presence
    }
  end

  def option_attributes(options)
    options.slice(*OPTION_ATTRIBUTES).compact_blank
  end

  # The staged object is of no use once the upload is refused. Best effort: the bucket's lifecycle rule is the
  # backstop, so a failure here only logs.
  def drop_staged_object
    staging.delete(upload)
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    Rails.logger.warn("[ReleaseUploadReleaseBuilder] upload #{upload.id}: staged object not deleted: #{e.message}")
  end
end
