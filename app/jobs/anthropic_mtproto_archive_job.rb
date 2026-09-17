# frozen_string_literal: true

# Pre-population cron for task #6 (Telegram MTProto cold storage). Scans our
# own releases for ones that are old and large enough to be worth moving off
# R2's paid tier and onto the free MTProto archive tier, archives them via
# Anthropic::MtprotoArchiveService, and records the archive location.
#
# Best-effort by design, same posture as AnthropicAssetDeliveryJob: if the
# feature isn't enabled, or a given release can't be archived, it logs and
# moves on rather than raising and blocking the queue.
#
# Config:
#   MTPROTO_ARCHIVE_ENABLED           - "true" to turn this job on at all
#   MTPROTO_ARCHIVE_AFTER_DAYS        - min release age before archiving (default 90)
#   MTPROTO_ARCHIVE_MIN_BYTES         - min compressed_size before archiving (default 50MB)
#   MTPROTO_ARCHIVE_BATCH_SIZE        - releases archived per run (default 25)
class AnthropicMtprotoArchiveJob < ApplicationJob
  queue_as :schedule

  DEFAULT_AFTER_DAYS = 90
  DEFAULT_MIN_BYTES = 50 * 1024 * 1024
  DEFAULT_BATCH_SIZE = 25

  def perform
    return unless Anthropic::MtprotoArchiveService.enabled?

    candidates.find_each(batch_size: batch_size) do |release|
      archive_release(release)
    rescue Anthropic::MtprotoArchiveService::ArchiveError, Anthropic::MtprotoArchiveService::ConfigurationError => e
      logger.error("[AnthropicMtprotoArchiveJob] failed for release #{release.id}: #{e.message}")
    end
  end

  private

  # Our own release artifacts only (see handover.md scope note): releases
  # already compressed by the PAD pipeline, stored in ReleaseStorage, old
  # enough and big enough to be worth archiving, not already archived.
  def candidates
    Release
      .where(mtproto_archived_at: nil)
      .where.not(compressed_apks_storage_key: nil)
      .where('created_at < ?', after_days.days.ago)
      .where('compressed_size >= ?', min_bytes)
      .limit(batch_size)
  end

  def archive_release(release)
    storage = ReleaseStorage.new(release)
    key = release.compressed_apks_storage_key

    Dir.mktmpdir('anthropic-mtproto-archive-') do |dir|
      local_path = File.join(dir, 'release.apks.br')
      fetched = storage.fetch(key, to: local_path)
      unless fetched
        logger.warn("[AnthropicMtprotoArchiveJob] release #{release.id}: #{key} not found in ReleaseStorage, skipping")
        return
      end

      location = Anthropic::MtprotoArchiveService.new.archive(local_path, key: key)
      release.update!(mtproto_archived_location: location, mtproto_archived_at: Time.current)
    end
  end

  def after_days
    (ENV['MTPROTO_ARCHIVE_AFTER_DAYS'] || DEFAULT_AFTER_DAYS).to_i
  end

  def min_bytes
    (ENV['MTPROTO_ARCHIVE_MIN_BYTES'] || DEFAULT_MIN_BYTES).to_i
  end

  def batch_size
    (ENV['MTPROTO_ARCHIVE_BATCH_SIZE'] || DEFAULT_BATCH_SIZE).to_i
  end
end
