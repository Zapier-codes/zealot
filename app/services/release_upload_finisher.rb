# frozen_string_literal: true

# Task 40i-c: takes the stage-2 report of a staged upload (CI has uploaded the files to the storage repo and, for
# a bundle, built the signed universal APK and the split set) and makes the held release installable. Stage 1
# (`ReleaseUploadIntake`, 40i-a) read the file and `ReleaseUploadReleaseBuilder` (40i-b) created the release
# `held`, with no storage key; this is the step that records the keys, once Zealot has checked the objects are
# really there.
#
#   result = ReleaseUploadFinisher.new(upload, body).call
#   result.code     # :finished, :already_finished, :failure_recorded, :rejected, :malformed, :not_open, :unavailable
#   result.http     # the status the callback answers with
#   result.payload  # the JSON body to answer with
#
# Rules, all enforced here and not by trusting CI:
# - only a `processing` row (stage 1 recorded, the release exists) takes a report; any other state is refused
#   (409) and nothing changes. A callback can never finish an upload nobody finalized or whose release was
#   refused, and it never creates a release: it only updates the one stage 1 made;
# - idempotent: the same report again for a `done` upload answers 200 and writes nothing (a different file hash
#   is 409), so a replay can never run the release steps twice;
# - the storage keys are derived HERE (`ReleaseStorage#staged_keys`) and CI's reported keys must equal them. The
#   file's SHA-256 CI reports must equal the one stage 1 read from the same staged object, and so must the icon's:
#   a file swapped between the two stages is refused;
# - nothing is recorded before every object the release will point at exists in storage. Where the signing
#   certificate is expected (`CI_COMPILE_EXPECT_CERT_SHA256`), a bundle's report must carry it and it must match;
# - a malformed report (bad hash, size, key) is 422 and changes nothing, so CI can resend a corrected one. A
#   report that is well formed but does not check out (a missing object, a wrong certificate), and a `failed`
#   report from CI, mark the upload `failed` with the reason and leave the release HELD with the reason on its
#   `ci_compile_error`: it has no file, so it must never become available. The owner deletes it and uploads again;
# - storage that cannot be reached is 503 and changes nothing, so a transient GitHub problem does not fail a
#   good upload.
#
# On success, in one transaction on locked rows: the release gets `file_storage_key`, `icon_storage_key` and
# `icon_sha256` (when stage 1 found an icon) and, for a bundle, `ci_compile_state: done` with the universal APK
# and the compressed set (so `Release#serves_universal_apk?` becomes true); its status becomes `available`
# unless the owner asked for `hold` at session time (the row's `form_options`); the upload becomes `done`.
# Changing `status` and the universal APK's hash and size is what republishes the catalog index (the release
# callbacks of Task 27f-d and 40e). After the commit, and only for a release that became available, the
# "new build" email stage 1 deferred is queued, and the staged file and icon are deleted (best effort: the
# bucket's lifecycle rule is the backstop).
#
# Task 40j: SDK injection ran in CI before the report, so the file Zealot serves is the patched one.
# - a bundle: the universal APK (hash, size) CI reports is already the patched, org-signed one; nothing else
#   changes, and the bundle itself stays as uploaded for Play;
# - an APK: CI replaced the stored file with the patched APK and reports `sdk_injected: true` with
#   `injected_file_sha256`; that becomes the release's `file_sha256`, which the catalog publishes (the old local
#   flow did the same: the mirror job hashed the file after the injector had swapped it). `file_sha256` stays the
#   hash of the UPLOADED file in the report and is still checked against what stage 1 read.
# `injected_file_sha256` without `sdk_injected` is refused; for a bundle it is ignored (the bundle is not replaced).
#
# Task 40l: Zealot signs every app it publishes, so CI re-signs an uploaded APK with the organisation key (the
# stage-2 step `Sign the uploaded APK`, behind the repository variable SIGN_UPLOADED_APKS) and replaces the stored
# file with it. The report then carries `org_signed: true`, `signed_file_sha256` (the hash of the signed file, which
# becomes the release's `file_sha256`, exactly like an injected APK's) and `cert_sha256`; where the certificate is
# expected (`CI_COMPILE_EXPECT_CERT_SHA256`) the certificate is required and must match, as for a bundle.
# `signed_file_sha256` without `org_signed` is refused; a bundle ignores both (its universal APK is already signed
# by the same key); `org_signed` together with `sdk_injected` is refused (the injector already signs, CI sends one).
#
# Task 40l-b: a release made through this flow is marked `signed: true` with `signing_key_checksum` set to the
# current organisation key's checksum (the pair `GoogleAdcRegisterJob` and the catalog fingerprint read, and the
# only other writer of which is the old local `AnthropicAssetDeliveryJob`) when CI reports a certificate for the
# served file (a bundle's universal APK, an org-signed APK, an SDK-injected APK) and that certificate equals
# `CI_COMPILE_EXPECT_CERT_SHA256`. Without that variable nothing is marked: confirming the certificate against
# the key itself would need `keytool` and a keystore tempfile on Render, which Task 40 removes. A matching
# certificate with no organisation key row, or no reported certificate, leaves the release unmarked and is not
# an error. After the commit, for a release marked signed that became available, the Google registration job is
# queued (it re-checks everything, and only runs when ADC_AUTO_REGISTER is on).
#
# Task 40n-c: an uploaded APK is never injected and never re-signed (the 40l re-sign step is switched off). Stage 2
# only READS the signature inside it (`apksigner verify --print-certs`) and reports `apk_verified` (the signature
# verified and has exactly one signer) with that signer's `cert_sha256`; the file stays as uploaded, so its hash is
# not replaced. The decision is Zealot's, not CI's: with `REQUIRE_ORG_SIGNED_APKS=true` on this server an APK is
# accepted only when CI reported a verified signature whose certificate equals `CI_COMPILE_EXPECT_CERT_SHA256`
# (distr's CI signs with the organisation key, so a file signed by anyone else, or by no one, cannot have been
# through it). Anything else is rejected like any other stage-2 refusal: the upload fails with a stated reason
# ("not built by distr") and the release stays held. A report that omits `apk_verified` is rejected too, so an old
# copy of the workflow cannot slip a file past the rule, and so is a report that says CI re-signed or injected the
# APK (`org_signed`, `sdk_injected`): under the rule an APK is published exactly as it came. With the variable unset
# an APK is accepted as before; a verified signature that equals the expected certificate still marks the release
# signed (40l-b below).
# `apk_verified` for a bundle is ignored; together with `org_signed` or `sdk_injected` it is refused.
#
# Not verified: no Ruby beyond `ruby -c` in the sandbox this was written in; nothing was run.
class ReleaseUploadFinisher
  Result = Struct.new(:code, :http, :payload, keyword_init: true)

  SHA256_FORMAT = /\A[0-9a-f]{64}\z/

  # Task 40n-c. What the uploader is told when `REQUIRE_ORG_SIGNED_APKS` turns an APK away. Plain sentences: they
  # are stored on the upload and the held release and shown as written, like every other stage-2 reason.
  NOT_BUILT_BY_DISTR = 'This APK is not signed with the organisation key, so it was not built by distr and ' \
                       'cannot be published here. Upload the APK distr gave you unchanged, or upload an .aab.'
  UNVERIFIED_APK = 'The signature of this APK could not be verified (it is unsigned, has more than one signer, ' \
                   'or is damaged), so it was not built by distr and cannot be published here. Upload the APK ' \
                   'distr gave you unchanged, or upload an .aab.'
  NO_ORGANISATION_CERTIFICATE = 'APK uploads are limited to files signed with the organisation key, but this ' \
                                'server has no organisation certificate configured ' \
                                '(CI_COMPILE_EXPECT_CERT_SHA256). Ask the administrator.'
  CHANGED_IN_CI = 'This APK was re-signed or modified while it was being processed, which is not allowed for ' \
                  'APK uploads: an APK is published exactly as distr built it. Upload it again unchanged, or ' \
                  'upload an .aab.'

  def initialize(upload, body, storage: nil, staging: nil, env: ENV, now: Time.current)
    @upload = upload
    @body = body
    @storage = storage
    @staging = staging
    @env = env
    @now = now
  end

  def call
    return refuse(:malformed, 422, 'state must be "ok" or "failed"') unless %w[ok failed].include?(body['state'])
    return record_failure if body['state'] == 'failed'

    finish
  end

  private

  attr_reader :upload, :body, :env

  def finish
    return already_finished if upload.state_done?
    return not_open unless open_for_stage2?

    release = upload.release
    keys = expected_keys(release)
    problem = malformed(keys)
    return refuse(:malformed, 422, problem) if problem

    reason = certificate_problem
    return reject(reason) if reason

    reason = missing_object(release, keys)
    return reject(reason) if reason

    record(release, keys)
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    Rails.logger.error("[ReleaseUploadFinisher] upload #{upload.id}: storage could not be checked: #{e.message}")
    Result.new(code: :unavailable, http: 503, payload: { error: 'The storage could not be checked. Try again.' })
  end

  def open_for_stage2?
    upload.state_processing? && upload.release_id.present? && upload.stage1_at.present?
  end

  def metadata
    upload.metadata
  end

  def bundle?
    metadata['kind'] == 'aab'
  end

  # Built without an adapter on purpose (like `#tag`): the keys are names, and answering needs no storage.
  def expected_keys(release)
    icon_extension = metadata['icon_key'].present? ? File.extname(metadata['icon_key']) : nil
    ReleaseStorage.new(release, adapter: nil).staged_keys(filename: upload.filename, icon_extension: icon_extension)
  end

  def storage(release)
    @storage ||= ReleaseStorage.new(release)
  end

  def staging
    @staging ||= ReleaseUploadStaging.new
  end

  # --- the report's shape -------------------------------------------------

  # @return [String, nil] the first problem found, or nil
  def malformed(keys)
    return 'file_key is not where Zealot expects the file' unless body['file_key'].to_s == keys[:file]
    return 'file_sha256 does not match the file that was read' unless same_hash?(body['file_sha256'],
                                                                                  metadata['file_sha256'])

    icon_problem(keys) || injection_problem || signing_problem || verification_problem || bundle_problem(keys)
  end

  # Task 40j
  def injection_problem
    injected = ActiveModel::Type::Boolean.new.cast(body['sdk_injected']) == true
    sha = body['injected_file_sha256']
    return 'injected_file_sha256 was sent without sdk_injected' if sha.present? && !injected
    return nil unless injected && !bundle?
    return 'injected_file_sha256 must be 64 hex characters' unless SHA256_FORMAT.match?(sha.to_s.downcase)
    return 'cert_sha256 is required' if expected_certificate.present? && body['cert_sha256'].blank?

    nil
  end

  def injected_apk?
    !bundle? && ActiveModel::Type::Boolean.new.cast(body['sdk_injected']) == true
  end

  # Task 40l
  def signing_problem
    signed = ActiveModel::Type::Boolean.new.cast(body['org_signed']) == true
    sha = body['signed_file_sha256']
    return 'signed_file_sha256 was sent without org_signed' if sha.present? && !signed
    return nil unless signed && !bundle?
    return 'org_signed and sdk_injected cannot both be reported for an APK' if injected_apk?
    return 'signed_file_sha256 must be 64 hex characters' unless SHA256_FORMAT.match?(sha.to_s.downcase)
    return 'cert_sha256 is required' if expected_certificate.present? && body['cert_sha256'].blank?

    nil
  end

  def signed_apk?
    !bundle? && ActiveModel::Type::Boolean.new.cast(body['org_signed']) == true
  end

  # Task 40n-c. A malformed claim is 422 and changes nothing (CI can resend); whether the claim is acceptable is
  # `certificate_problem`'s question.
  def verification_problem
    return nil unless verified_apk?
    return 'apk_verified cannot be reported together with org_signed or sdk_injected' if signed_apk? || injected_apk?
    return nil if SHA256_FORMAT.match?(normalize_fingerprint(body['cert_sha256']))

    'cert_sha256 must be 64 hex characters when apk_verified is true'
  end

  # CI read the uploaded APK's own signature: it verifies and has exactly one signer (whose certificate is
  # `cert_sha256`). Never true for a bundle.
  def verified_apk?
    !bundle? && ActiveModel::Type::Boolean.new.cast(body['apk_verified']) == true
  end


  def same_hash?(reported, known)
    reported = reported.to_s.downcase
    SHA256_FORMAT.match?(reported) && reported == known.to_s
  end

  def icon_problem(keys)
    if metadata['icon_key'].blank?
      return 'an icon was reported that stage 1 did not find' if body['icon_key'].present?

      return nil
    end

    return 'icon_key is not where Zealot expects the icon' unless body['icon_key'].to_s == keys[:icon]
    return 'icon_sha256 does not match the icon that was read' unless same_hash?(body['icon_sha256'],
                                                                                  metadata['icon_sha256'])

    nil
  end

  def bundle_problem(keys)
    return nil unless bundle?

    return 'universal_apk_key is not where Zealot expects it' unless body['universal_apk_key'].to_s == keys[:universal]
    return 'compressed_apks_key is not where Zealot expects it' unless
      body['compressed_apks_key'].to_s == keys[:compressed]
    return 'universal_apk_sha256 must be 64 hex characters' unless SHA256_FORMAT.match?(universal_sha)
    return 'universal_apk_size must be a positive integer' unless positive_integer?(body['universal_apk_size'])
    return 'compressed_size must be a positive integer' if body['compressed_size'].present? &&
                                                           !positive_integer?(body['compressed_size'])
    return 'cert_sha256 is required' if expected_certificate.present? && body['cert_sha256'].blank?

    nil
  end

  def universal_sha
    body['universal_apk_sha256'].to_s.downcase
  end

  def positive_integer?(value)
    Integer(value.to_s, 10).positive?
  rescue ArgumentError
    false
  end

  # --- what must be true before anything is recorded ----------------------

  def certificate_problem
    return apk_rule_problem if !bundle? && require_org_signed_apks?
    return nil unless (bundle? || signed_apk? || injected_apk?) && expected_certificate.present?
    return nil if normalize_fingerprint(body['cert_sha256']) == expected_certificate

    'the signing certificate CI reported does not match the expected certificate'
  end

  # Task 40n-c: the rule for every APK upload. Off unless this server says `REQUIRE_ORG_SIGNED_APKS=true`. It fails
  # closed: no configured certificate, a file CI changed (re-signed or injected), no verified signature or another
  # certificate all turn the APK away. A bundle is not subject to it (its universal APK is built and signed in CI).
  def apk_rule_problem
    return NO_ORGANISATION_CERTIFICATE if expected_certificate.blank?
    return CHANGED_IN_CI if signed_apk? || injected_apk?
    return UNVERIFIED_APK unless verified_apk?
    return NOT_BUILT_BY_DISTR unless normalize_fingerprint(body['cert_sha256']) == expected_certificate

    nil
  end

  def require_org_signed_apks?
    env['REQUIRE_ORG_SIGNED_APKS'].to_s.strip == 'true'
  end

  def expected_certificate
    normalize_fingerprint(env['CI_COMPILE_EXPECT_CERT_SHA256'])
  end

  # Accepts `AA:BB:..` (keytool's form) or bare hex, in either case.
  def normalize_fingerprint(value)
    value.to_s.delete(':').strip.downcase
  end

  # @return [String, nil] which expected object is not in storage, or nil
  def missing_object(release, keys)
    wanted = [keys[:file]]
    wanted << keys[:icon] if metadata['icon_key'].present?
    wanted.push(keys[:universal], keys[:compressed]) if bundle?
    store = storage(release)
    absent = wanted.reject { |key| store.exist?(key) }
    absent.empty? ? nil : "#{absent.join(', ')} #{absent.one? ? 'is' : 'are'} not in storage"
  end

  # --- recording ----------------------------------------------------------

  def record(release, keys)
    outcome = ReleaseUpload.transaction { record_locked(keys) }
    return not_open unless outcome == :finished

    housekeeping(release)
    Result.new(code: :finished, http: 200, payload: answer)
  end

  # Runs inside the transaction. No `return` out of the block: the outcome is the method's value.
  def record_locked(keys)
    row = ReleaseUpload.lock.find(upload.id)
    return :not_open unless row.state_processing? && row.release_id.present?

    release = Release.lock.find(row.release_id)
    release.update!(release_attributes(row, keys))
    row.update_columns(state: 'done', error: nil, updated_at: @now)
    :finished
  end

  def release_attributes(row, keys)
    attributes = { file_storage_key: keys[:file] }
    attributes[:file_sha256] = body['injected_file_sha256'].to_s.downcase if injected_apk?
    attributes[:file_sha256] = body['signed_file_sha256'].to_s.downcase if signed_apk?
    attributes.merge!(icon_storage_key: keys[:icon], icon_sha256: metadata['icon_sha256']) if keys[:icon]
    attributes.merge!(bundle_attributes(keys)) if bundle?
    attributes.merge!(signing_attributes)
    attributes[:status] = 'available' unless hold_requested?(row)
    attributes
  end

  # Task 40l-b. The certificate must be reported and equal the expected one (checked without any local work);
  # the key row only supplies the checksum the registration job compares against.
  def signing_attributes
    return {} unless certificate_confirmed?

    key = AndroidSigningKey.current
    key ? { signed: true, signing_key_checksum: key.checksum } : {}
  end

  def certificate_confirmed?
    return false unless bundle? || signed_apk? || injected_apk? || verified_apk?

    reported = normalize_fingerprint(body['cert_sha256'])
    reported.present? && expected_certificate.present? && reported == expected_certificate
  end

  def bundle_attributes(keys)
    attributes = {
      ci_compile_state: 'done', ci_compile_error: nil, ci_compile_finished_at: @now,
      universal_apk_storage_key: keys[:universal], universal_apk_sha256: universal_sha,
      universal_apk_size: Integer(body['universal_apk_size'].to_s, 10),
      compressed_apks_storage_key: keys[:compressed], brotli_compressed: true
    }
    attributes[:compressed_size] = Integer(body['compressed_size'].to_s, 10) if body['compressed_size'].present?
    attributes
  end

  # The same cast the API upload door uses for `hold`.
  def hold_requested?(row)
    ActiveModel::Type::Boolean.new.cast(row.form_options['hold']) == true
  end

  # Housekeeping that must not turn an accepted result into an error: the release is already saved.
  def housekeeping(release)
    release.reload
    send_deploy_email(release) if release.status_available?
    enqueue_google_registration(release)
    delete_staged_objects
  end

  # Task 40l-b: what `AnthropicAssetDeliveryJob` does for the old path. Never lets a queueing failure undo the release.
  def enqueue_google_registration(release)
    return unless release.signed? && release.status_available? && GoogleAdc.auto_register?

    GoogleAdcRegisterJob.perform_later(release.id)
  rescue StandardError => e
    Rails.logger.error("[ReleaseUploadFinisher] upload #{upload.id}: could not queue Google registration: #{e.message}")
  end

  # The email stage 1 deferred (a held release with no file must not tell members about a build). Reuses the
  # release's own hook; a reloaded release is not flagged as a staged intake, so the hook runs normally.
  def send_deploy_email(release)
    release.schedule_deploy_notification
  rescue StandardError => e
    Rails.logger.error("[ReleaseUploadFinisher] release #{release.id}: could not queue the deploy email: #{e.message}")
  end

  def delete_staged_objects
    staging.delete(upload)
    staging.delete_sibling(upload, metadata['icon_key']) if metadata['icon_key'].present?
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError, ArgumentError => e
    Rails.logger.warn("[ReleaseUploadFinisher] upload #{upload.id}: staged objects not deleted: #{e.message}")
  end

  # --- failures -----------------------------------------------------------

  def record_failure
    return not_open unless open_for_stage2?

    reason = body['error'].to_s.strip.presence || 'CI reported a failure without a reason'
    return not_open unless mark_failed(reason)

    Result.new(code: :failure_recorded, http: 200, payload: { upload_id: upload.id, state: 'failed' })
  end

  def reject(reason)
    return not_open unless mark_failed(reason)

    Result.new(code: :rejected, http: 422, payload: { upload_id: upload.id, state: 'failed', error: reason })
  end

  # Fails the upload and writes the reason on the held release, in one transaction on locked rows. The release
  # is left held: it has no file, so it must never become available.
  #
  # @return [Boolean] false when the row was no longer `processing`
  def mark_failed(reason)
    ReleaseUpload.transaction do
      row = ReleaseUpload.lock.find(upload.id)
      next false unless row.state_processing? && row.release_id.present?

      text = reason.to_s.truncate(1000)
      row.update_columns(state: 'failed', error: text, updated_at: @now)
      Release.where(id: row.release_id)
             .update_all(ci_compile_state: 'failed', ci_compile_error: text, ci_compile_finished_at: @now)
      true
    end
  end

  # --- answers ------------------------------------------------------------

  def already_finished
    return refuse(:conflict, 409, 'This upload was already finished with a different file.') unless
      same_hash?(body['file_sha256'], metadata['file_sha256'])

    Result.new(code: :already_finished, http: 200, payload: answer)
  end

  def answer
    release = upload.release
    { upload_id: upload.id, state: 'done', stage: 2, release_id: upload.release_id, status: release&.status }
  end

  def not_open
    upload.reload
    refuse(:not_open, 409, "This upload is #{upload.state}.")
  end

  def refuse(code, http, message)
    Result.new(code: code, http: http, payload: { error: message })
  end
end
