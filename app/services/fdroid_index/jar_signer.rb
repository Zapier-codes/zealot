# frozen_string_literal: true

require 'digest'
require 'json'
require 'zlib'

module FdroidIndex
  # Z-P15b (Play Console parity; docs/PARITY-KANBAN.md): turn Z-P15a's unsigned `entry.json` into the
  # signed `entry.jar` an F-Droid-style client fetches first. The client verifies the JAR's signature
  # against the fingerprint the user added for the repo, then reads `entry.json` out of it and follows
  # it to `index-v2.json`. Without a signed entry.jar the repo is not installable by a real client, so
  # this is the half that makes Z-P15a's two JSON documents reachable.
  #
  # ## The format, read from fdroidserver, not guessed
  # `fdroidserver/signindex.py#sign_index` (read this session) does exactly three things, and this
  # mirrors them: it re-checks the unsigned JSON (for `entry.json`, that `index.sha256` matches the
  # `index-v2.json` bytes it points at), writes a ZIP whose single entry is that JSON named as the
  # JSON file (`entry.json` at the JAR root — not under a directory), and signs it. This class does the
  # same ZIP step here and the signing via `Anthropic::ApkSigningService#sign_jar!` (a JDK `jarsigner`
  # call, `SHA256withRSA`, which Android 7+ / API 23+ verifies — fdroidserver uses `apksigner
  # --v1-signing-enabled` for the same reason: `jarsigner`/apksigner v1 both produce JAR signatures
  # Android reads). The ZIP is `STORED` (no compression) so `jarsigner` never has to decompress to add
  # its `META-INF/` signature entries, and `jarsigner -verify` accepts the result (checked against the
  # real `jarsigner` in this session).
  #
  # This file deliberately shells out to nothing itself: the ZIP half is pure Ruby (no gem — `rubyzip`
  # is only a transitive dependency here, so it is not `require`d), and the signing half is
  # `ApkSigningService`, so there is one place that knows how to open a keystore with a JDK.
  class JarSigner
    class UnsignedIndexError < StandardError; end

    # entry.json carries `index.name` (the file it points at) and `index.sha256`; fdroidserver
    # re-derives the digest from that named file before signing and refuses on a mismatch. Same check
    # here, so a broken pair is never signed (a signed-but-wrong index would fail every client).
    #
    # @param entry_json [String] the exact bytes Z-P15a produced
    # @param index_json [String] the exact index-v2.json bytes entry.json points at
    # @param extra_entries [Hash{String=>String}] Z-P15c: additional JSON documents to carry inside the signed
    #   JAR under their own file names (the signer index). F-Droid's own entry.jar holds only entry.json; we
    #   add signer-index.json so it is covered by the same signature without a second signed JAR. A client
    #   ignores entries it does not ask for, so this is additive and never changes how entry.json is read.
    def initialize(entry_json:, index_json:, extra_entries: {})
      @entry_json = entry_json
      @index_json = index_json
      @extra_entries = extra_entries
    end

    def call
      verify_against_index!
      build_jar({ 'entry.json' => @entry_json }.merge(@extra_entries))
    end

    # Signs an already-built JAR in place. Kept separate so the unsigned bytes are testable without a
    # JDK: `build_jar`/`verify_against_index!` need no keystore, `sign_jar!` does.
    def self.sign_jar!(jar_bytes, keystore_bytes:, keystore_password:, key_alias:, key_password:)
      Anthropic::ApkSigningService.sign_jar!(
        jar_bytes: jar_bytes,
        keystore_bytes: keystore_bytes,
        keystore_password: keystore_password,
        key_alias: key_alias,
        key_password: key_password
      )
    end

    private

    def verify_against_index!
      entry = JSON.parse(@entry_json)
      index = entry['index'] || {}
      name = index['name'].to_s
      claimed = index['sha256'].to_s
      actual = Digest::SHA256.hexdigest(@index_json)

      raise UnsignedIndexError, 'entry.json has no index.sha256 to verify' if claimed.empty?
      raise UnsignedIndexError, "entry.json index.sha256 #{claimed[0, 16]}… does not match the index bytes" if claimed != actual
      raise UnsignedIndexError, "entry.json points at #{name.inspect}, not index-v2.json" unless name.end_with?('index-v2.json')
    rescue JSON::ParserError => e
      raise UnsignedIndexError, "entry.json is not valid JSON: #{e.message}"
    end

    # A minimal, valid ZIP. Written by hand (local file header + central directory + end record) so no
    # compression gem is needed and the bytes are exactly what `jarsigner` expects; `jarsigner` then
    # appends/updates only the `META-INF/` entries. Entries are STORED (method 0) and written in the order
    # given, so `entry.json` stays the first root entry (a client finds it regardless, but the order matches
    # F-Droid's own single-entry layout as closely as possible).
    def build_jar(entries)
      local_parts = []
      central_parts = []
      offset = 0
      dos_time = dos_date = 0 # jarsigner does not read the timestamp; F-Droid clients do not either

      entries.each do |name, content|
        data = content.b
        crc = Zlib.crc32(data)
        size = data.bytesize
        name_bytes = name.b

        local = [
          0x04034b50, 20, 0, 0, # signature, version-needed, flags, method (0 = stored)
          dos_time, dos_date,
          crc, size, size,
          name_bytes.bytesize, 0
        ].pack('VvvvvvVVVvv') + name_bytes
        central = [
          0x02014b50, 20, 20, 0, 0, # signature, version-made-by, version-needed, flags, method
          dos_time, dos_date,
          crc, size, size,
          name_bytes.bytesize, 0, 0, 0, 0, # name len, extra len, comment len, disk start, internal attrs
          0, offset # external attrs, local header offset
        ].pack('VvvvvvvVVVvvvvvVV') + name_bytes

        local_parts << local << data
        central_parts << central
        offset += local.bytesize + size
      end

      local = local_parts.join
      central = central_parts.join
      eocd = [0x06054b50, 0, 0, entries.size, entries.size, central.bytesize, local.bytesize, 0].pack('VvvvvVVv')
      local + central + eocd
    end
  end
end
