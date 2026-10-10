# frozen_string_literal: true

require 'json'
require 'digest'

module FdroidIndex
  # Z-P15d (Play Console parity; docs/PARITY-KANBAN.md): the **binary transparency log** for our F-Droid
  # repo, the last of the F-Droid card's three halves (P15a = index-v2/entry.json, P15b = signed entry.jar,
  # P15d = this). Binary transparency is the idea that every released file is logged as it is published, so
  # anyone can later check that a file they received was one we publicly released and not something else.
  #
  # ## The format, read from fdroidserver, not guessed
  # `fdroidserver/btlog.py#make_binary_transparency_log` defines it, and f-droid.org's own
  # `f-droid.org-transparency-log` repo is the reference instance. Two files per repo subdirectory:
  #   * `filesystemlog.json` -- one map, `{ "<relative path>": [size, ctime_ns, mtime_ns, mode, uid, gid] }`,
  #     sorted by path, over every file in the repo directory. It is the "these bytes existed" record.
  #   * `.HTTP-headers.json` per logged file -- the response headers the file was served with, so a
  #     mirror's copy can be compared. btlog.py writes those from a live HTTP fetch, which is the mirroring
  #     deployment's step, not ours; we do not fabricate one, because a made-up header file is worse than
  #     an absent one (it would assert something we never observed).
  #
  # ## What this class does and does not do
  # It renders `filesystemlog.json` from the bytes we are about to publish, purely (no Rails, no OpenSSL,
  # no filesystem write), exactly like `Serializer`. The append-only git repo (init, README, committing the
  # logged copies) is `FdroidIndex::TransparencyLog`, the deploy step. Sizes are the real byte lengths of the
  # published documents; ctime/mtime/uid/gid are not meaningful for content we render in memory, so they are
  # zero — the fields exist because the format has them, not because we have real values to put there.
  class TransparencyLog
    Result = Struct.new(:filesystem_log_json, :path_count, keyword_init: true)

    # @param files [Hash{String=>String}] relative path => exact bytes that will be published
    # @param generated_at [Time] recorded as the mtime is not available; kept for the caller's message
    def initialize(files, generated_at: Time.now.utc)
      @files = files
      @generated_at = generated_at
    end

    def self.call(files, **opts)
      new(files, **opts).call
    end

    def call
      log = @files.keys.sort.each_with_object({}) do |path, out|
        bytes = @files[path]
        out[path] = [bytes.to_s.bytesize, 0, 0, 0o100644, 0, 0]
      end
      Result.new(filesystem_log_json: "#{JSON.pretty_generate(log)}\n", path_count: log.size)
    end
  end
end
