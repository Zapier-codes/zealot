# frozen_string_literal: true

# Task 46c: a newer release replaces the older ones of its channel. Zealot keeps ONE version per app: the
# operator's rule is that an uploaded new version supersedes the old one, nothing is kept for roll back.
#
# The release the caller names is the one that stays. Every OTHER release of the same channel that was
# uploaded before it (a lower id) is destroyed, and the destroy's own cleanup removes its stored files
# (`Release#enqueue_storage_cleanup`, which since this task includes the universal APK). A release with a
# HIGHER id is never touched: it is newer, not old.
#
# Nothing is removed until the kept release can really be installed, so the app is never left with nothing to
# download: it must be `available` (a held, halted or pulled release is not served) and either be a CI-built
# release whose universal APK is recorded (`Release#serves_universal_apk?`) or a release with no CI step that has
# its file. A CI release still `queued`, `dispatched` or `failed` is refused for the same reason.
#
# `dry_run` lists what would be removed and changes nothing. After a real removal the owning tenant's catalog
# index is republished, because a destroy on its own does not (the entries of the removed releases would
# otherwise stay in the signed index until some unrelated publish).
#
# Written, NOT run (no Ruby in the sandbox that wrote it); see spec/services/release_superseder_spec.rb.
class ReleaseSuperseder
  class Refused < StandardError; end

  Entry = Struct.new(:id, :release_version, :build_version, keyword_init: true) do
    def to_h
      { id: id, release_version: release_version, build_version: build_version }
    end
  end

  Result = Struct.new(:kept_id, :dry_run, :removed, :failed, keyword_init: true) do
    def to_h
      { kept: kept_id, dry_run: dry_run, removed: removed.map(&:to_h), failed: failed.map(&:to_h) }
    end
  end

  # @param release [Release] the newer release that stays
  def initialize(release)
    @release = release
  end

  # @param dry_run [Boolean] true: report only, remove nothing and publish nothing
  # @return [Result]
  # @raise [Refused] with a reason key: app_archived, not_available or not_installable
  def call(dry_run: false)
    refuse_unless_safe!
    older = older_releases.to_a
    return Result.new(kept_id: release.id, dry_run: dry_run, removed: entries(older), failed: []) if dry_run

    removed, failed = remove(older)
    republish_index if removed.any?
    Result.new(kept_id: release.id, dry_run: false, removed: removed, failed: failed)
  end

  private

  attr_reader :release

  def older_releases
    release.channel.releases.where('releases.id < ?', release.id).order(:id)
  end

  def refuse_unless_safe!
    raise Refused, :app_archived if release.app.archived
    raise Refused, :not_available unless release.status == 'available'
    raise Refused, :not_installable unless installable?
  end

  # Installable now: a compiled universal APK, or a release that never goes through CI and has its file.
  def installable?
    return true if release.serves_universal_apk?

    release.ci_compile_state.blank? && release.file?
  end

  # Each release is destroyed on its own so one failure never stops the others; the failures are reported.
  def remove(older)
    removed = []
    failed = []
    older.each do |old|
      entry = Entry.new(id: old.id, release_version: old.release_version, build_version: old.build_version)
      old.destroy
      (old.destroyed? ? removed : failed) << entry
    rescue StandardError => e
      Rails.logger&.error("[ReleaseSuperseder] release #{old.id}: #{e.class}: #{e.message}")
      failed << entry
    end
    [removed, failed]
  end

  def entries(releases)
    releases.map do |old|
      Entry.new(id: old.id, release_version: old.release_version, build_version: old.build_version)
    end
  end

  def republish_index
    app = release.app
    CatalogIndexPublishJob.enqueue_for(app.tenant) if app.listing_live?
  end
end
