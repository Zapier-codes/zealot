# frozen_string_literal: true

# Z-P25 (docs/PARITY-KANBAN.md; docs/UNOFFICIAL-ROUTES.md §1.1 rule 5): a hard, timestamped cache for every
# Play read. The point of the rule is that the load on Play stays small and a break shows *stale data, not
# an error*, so this cache is consulted before the adapter ever runs a backend and it is what the adapter
# falls back to when a backend fails. One file per key, JSON, with the fetched-at time beside the payload.
#
# It is deliberately dumb: no eviction policy beyond "older than max_age is not served", no locking beyond
# an atomic write. A cache miss (no file, unreadable, past max_age) is `nil`, which the caller reads as
# "go fetch", never as an error.
class PlayCatalogCache
  class << self
    # @return [Hash, nil] `{ 'data' => <payload>, 'fetched_at' => <iso8601> }`, or nil on miss/expiry
    def read(key, max_age: default_max_age, now: Time.current)
      path = path_for(key)
      return nil unless File.file?(path)

      entry = JSON.parse(File.read(path))
      fetched_at = Time.iso8601(entry['fetched_at'].to_s)
      return nil if fetched_at < now - max_age

      entry
    rescue JSON::ParserError, ArgumentError
      nil
    end

    # Atomic write: the temp file is renamed into place, so a reader never sees a half-written entry.
    def write(key, data, now: Time.current)
      path = path_for(key)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.generate('data' => data, 'fetched_at' => now.utc.iso8601))
      File.rename(tmp, path)
      data
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def path_for(key)
      safe = key.to_s.gsub(/[^A-Za-z0-9._-]/, '_')
      Rails.root.join('tmp', 'play_catalog_cache', "#{safe}.json").to_s
    end

    private

    def default_max_age
      # A day: the canary refreshes daily and rule 5 says refresh slowly; a week-old listing is still a
      # usable labelled panel, and the timestamp is shown so a person can judge staleness themselves.
      (ENV['PLAY_CACHE_MAX_AGE_HOURS'] || 24).to_i.hours
    end
  end
end
