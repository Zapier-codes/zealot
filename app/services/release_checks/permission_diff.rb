# frozen_string_literal: true

module ReleaseChecks
  # Task 30c-a: which permissions did this release add or drop compared with the release before it?
  # The first of the automated checks the Play-parity plan wants on commit (Task 30c). It only
  # REPORTS: nothing calls it yet, it blocks nothing and writes nothing, so a caller (30c-d, and
  # the review queue in 30d) decides what an added permission means.
  #
  # "The release before it" is the release of the same channel with the next-lower `version`
  # (`releases` is unique on `[channel_id, version]`). A channel is one package on one device
  # type, so this compares like with like; a release with no earlier release is a baseline: it
  # has nothing to diff against, so it reports no change rather than treating every permission it
  # declares as new.
  #
  #   ReleaseChecks::PermissionDiff.call(release)
  #   # => #<struct previous=..., added=["android.permission.CAMERA"], removed=[]>
  class PermissionDiff
    Result = Struct.new(:previous, :added, :removed, keyword_init: true) do
      # True when there was an earlier release to compare with.
      def compared?
        !previous.nil?
      end

      def changed?
        added.any? || removed.any?
      end
    end

    # Pure comparison of two permission lists (`Release#permissions` is a jsonb array of strings).
    # Order, duplicates, blanks and non-string entries do not matter; the result is sorted.
    # @return [Array<Array<String>>] `[added, removed]`
    def self.between(previous_permissions, current_permissions)
      before = normalize(previous_permissions)
      after = normalize(current_permissions)
      [(after - before).sort, (before - after).sort]
    end

    def self.normalize(list)
      Array(list).map { |entry| entry.to_s.strip }.reject(&:empty?).uniq
    end

    def self.call(release)
      new(release).call
    end

    def initialize(release)
      @release = release
    end

    # @return [Result]
    def call
      previous = previous_release
      return Result.new(previous: nil, added: [], removed: []) if previous.nil?

      added, removed = self.class.between(previous.permissions, @release.permissions)
      Result.new(previous: previous, added: added, removed: removed)
    end

    private

    def previous_release
      return nil if @release.channel_id.nil? || @release.version.nil?

      Release.where(channel_id: @release.channel_id)
             .where('releases.version < ?', @release.version)
             .order(version: :desc)
             .first
    end
  end
end
