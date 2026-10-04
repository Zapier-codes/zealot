# frozen_string_literal: true

# Runs the Play Asset Delivery + Brotli pipeline for a newly uploaded
# Android App Bundle (.aab) release. Splits into device-specific APKs via
# bundletool, groups any asset packs by delivery type, Brotli-compresses
# the resulting artifacts, and records size/pack metadata on the release.
#
# This job is intentionally best-effort: if bundletool/brotli are not
# installed, or the release isn't an .aab, it logs and returns without
# raising, so it never blocks the normal upload flow.
class AnthropicAssetDeliveryJob < ApplicationJob
  queue_as :default

  def perform(release_id, pack_config: nil)
    # Task 40d: with CI compile on, Zealot never compiles, splits, signs or compresses; there is no local
    # fallback (see Release#anthropic_asset_delivery_job). Checked first, before any lookup or file work.
    if CiCompileDispatcher.enabled?
      logger.info("[AnthropicAssetDeliveryJob] release #{release_id}: skipped, CI compile is on (CI_COMPILE_ENABLED)")
      return
    end

    return unless Rails.application.config.x.anthropic.asset_pack_delivery_enabled

    release = Release.find_by(id: release_id)
    return unless release&.file&.path
    return unless release.file.path.to_s.end_with?('.aab')

    # Copy the upload to durable storage BEFORE compiling. The compile is the heaviest step on this
    # instance, and a restart during it (2026-10-03 21:00 and 2026-10-04 02:59, both OOM kills at 512Mi)
    # wipes the local disk; with no stored copy the retry could only answer "AAB not found".
    ensure_mirrored(release)
    release.reload

    work_dir = Dir.mktmpdir('anthropic-pad-')
    begin
      # with_local_file uses the local copy when it is there and downloads the stored copy when it is not,
      # so a retry after a restart can still compile.
      ReleaseStorage.new(release).with_local_file do |path|
        process_release(release, work_dir, pack_config, path)
      end
    ensure
      FileUtils.remove_entry(work_dir, true)
    end
  rescue Anthropic::BundletoolService::BundletoolNotFoundError,
         Anthropic::BrotliService::BrotliNotFoundError => e
    logger.warn("[AnthropicAssetDeliveryJob] tooling unavailable, skipping: #{e.message}")
  rescue ReleaseStorage::MissingFileError => e
    logger.error("[AnthropicAssetDeliveryJob] release #{release_id}: #{e.message}")
  rescue StandardError => e
    logger.error("[AnthropicAssetDeliveryJob] failed for release #{release_id}: #{e.full_message}")
  end

  private

  # Runs the mirror inline (it skips anything already stored) and never lets a mirror failure stop the
  # compile: the mirror logs its own errors, and the compile then runs from the local copy as before.
  def ensure_mirrored(release)
    ReleaseFileMirrorJob.perform_now(release.id)
  rescue StandardError => e
    logger.error("[AnthropicAssetDeliveryJob] release #{release.id}: mirror before compile failed: #{e.message}")
  end

  def process_release(release, work_dir, pack_config, aab_path)
    # Org-wide key (task #5, made a singleton this session) — every release
    # through this pipeline is signed with the same key regardless of
    # which App it belongs to. See AndroidSigningKey#current.
    signing_key = AndroidSigningKey.current

    result = Anthropic::AssetPackService.new(aab_path).process(
      output_dir: work_dir,
      pack_config: pack_config,
      signing_key: signing_key
    )

    brotli = Anthropic::BrotliService.new
    compressed = brotli.compress(result[:apks_path])

    pack_type = dominant_pack_type(result[:packs])
    storage_key = ReleaseStorage.new(release).store_compressed_apks(compressed[:path])

    release.update!(
      asset_pack_type: pack_type,
      brotli_compressed: true,
      original_size: compressed[:original_size],
      compressed_size: compressed[:compressed_size],
      compressed_apks_storage_key: storage_key,
      signed: signing_key.present?,
      signing_key_checksum: signing_key&.checksum
    )

    # Task 36b-6: register the package name with Google. Off unless ADC_AUTO_REGISTER=true, and the
    # job itself re-checks everything; a failure to enqueue must never undo the signing above.
    GoogleAdcRegisterJob.perform_later(release.id) if signing_key.present? && GoogleAdc.auto_register?
  end

  # Best-effort single label for the release's dominant pack type, since
  # `Release` stores one value but an AAB can contain packs of several
  # types. Prefers on_demand > fast_follow > install_time.
  def dominant_pack_type(packs)
    return nil if packs.blank?

    %w[on_demand fast_follow install_time].find { |type| packs[type].present? }
  end
end
