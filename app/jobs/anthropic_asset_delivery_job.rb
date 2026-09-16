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
    return unless Rails.application.config.x.anthropic.asset_pack_delivery_enabled

    release = Release.find_by(id: release_id)
    return unless release&.file&.path
    return unless release.file.path.to_s.end_with?('.aab')

    work_dir = Dir.mktmpdir('anthropic-pad-')
    begin
      process_release(release, work_dir, pack_config)
    ensure
      FileUtils.remove_entry(work_dir, true)
    end
  rescue Anthropic::BundletoolService::BundletoolNotFoundError,
         Anthropic::BrotliService::BrotliNotFoundError => e
    logger.warn("[AnthropicAssetDeliveryJob] tooling unavailable, skipping: #{e.message}")
  rescue StandardError => e
    logger.error("[AnthropicAssetDeliveryJob] failed for release #{release_id}: #{e.full_message}")
  end

  private

  def process_release(release, work_dir, pack_config)
    # Org-wide key (task #5, made a singleton this session) — every release
    # through this pipeline is signed with the same key regardless of
    # which App it belongs to. See AndroidSigningKey#current.
    signing_key = AndroidSigningKey.current

    result = Anthropic::AssetPackService.new(release.file.path).process(
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
  end

  # Best-effort single label for the release's dominant pack type, since
  # `Release` stores one value but an AAB can contain packs of several
  # types. Prefers on_demand > fast_follow > install_time.
  def dominant_pack_type(packs)
    return nil if packs.blank?

    %w[on_demand fast_follow install_time].find { |type| packs[type].present? }
  end
end
