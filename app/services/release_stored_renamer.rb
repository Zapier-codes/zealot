# frozen_string_literal: true

# Task 44f: gives a release's stored files today's names, in place, without deleting the release.
#
# A release stored before Task 44 (the live Storeapp release 6 is `pipeline__universal.apk` in the storage
# repo) keeps the generic or build-numbered names it was stored under, and a browser saves the storage asset's
# name. Deleting and re-sending the release would fix that but takes it out of the catalog index meanwhile.
# This renames each stored file to `ReleaseArtifactName.for(release)` plus its extension (`appstore-1.1.4.apk`)
# with the storage adapter's own rename (GitHub's asset-rename call: no download, no re-upload), then records
# the new keys on the release. The key's folder stays (`binary/`, `pipeline/`, `icons/`), so a file never
# changes storage release. The catalog index only tests that a key is present, so nothing is republished.
#
# Safe to repeat: a file already under its new name is recorded and counted as `already`, so a run that stopped
# half way (a network error after the third rename) is finished by running it again. Nothing is overwritten:
# when both the old and the new name exist the adapter refuses and that column keeps its old key.
#
# Not touched: `patched_file_storage_key` (the patched internal APK, which no download serves under its name).
#
# Written, NOT run (no Ruby in the sandbox that wrote it); the specs use the in-memory GitHub fake.
class ReleaseStoredRenamer
  class Refused < StandardError; end

  # The columns holding a stored file's key.
  COLUMNS = %i[file_storage_key universal_apk_storage_key compressed_apks_storage_key icon_storage_key].freeze
  # The one extension that is two parts; `File.extname` would give `.br`.
  DOUBLE_EXTENSION = '.apks.br'

  Change = Struct.new(:column, :from, :to, :status, keyword_init: true) do
    def to_h
      { column: column.to_s, from: from, to: to, status: status.to_s }
    end
  end

  # @param release [Release]
  # @param storage [ReleaseStorage, nil] built from the release when omitted (specs inject one)
  def initialize(release, storage: nil)
    @release = release
    @storage = storage
  end

  # @return [Array<Change>] one per stored file, in COLUMNS order
  # @raise [Refused] CI is still working on the release, or nothing is stored for it
  def call
    refuse_while_ci_works!
    wanted = targets
    raise Refused, :nothing_stored if wanted.empty?

    wanted.map { |column, (from, to)| move(column, from, to) }
  end

  private

  attr_reader :release

  def storage
    @storage ||= ReleaseStorage.new(release)
  end

  # CI writes and records these keys itself while it works; renaming under it would race with it.
  def refuse_while_ci_works!
    return unless release.ci_compile_queued? || release.ci_compile_dispatched?

    raise Refused, :ci_busy
  end

  # { column => [current key, new key] } for each column that has a key.
  def targets
    base = ReleaseArtifactName.for(release)
    COLUMNS.each_with_object({}) do |column, found|
      from = release.public_send(column).to_s
      next if from.empty?

      found[column] = [from, File.join(File.dirname(from), "#{base}#{extension_of(from)}")]
    end
  end

  def extension_of(key)
    key.end_with?(DOUBLE_EXTENSION) ? DOUBLE_EXTENSION : File.extname(key)
  end

  # Renames one file, then records its key. The key is recorded as soon as its file has moved, so a later
  # failure never leaves a recorded key pointing at a file that is gone.
  def move(column, from, to)
    status = from == to ? :same : storage.rename(from, to)
    release.update_columns(column => to, updated_at: Time.current) if %i[renamed already].include?(status)
    Change.new(column: column, from: from, to: to, status: status)
  end
end
