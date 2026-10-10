# frozen_string_literal: true

require 'zlib'
require_relative 'errors'

module ArchivePatcher
  # A minimal, faithful zip reader and writer, for the archive-patcher generator. It is deliberately small:
  # it reads the entries of an archive (name, deflate method/level/strategy/wrap, flags, times, extra) and
  # writes an archive back with the same entries and the same deflate settings, so that recompressing a
  # changed entry reproduces the original bytes exactly.
  #
  # Only what archive-patcher needs is supported: stored (method 0) and raw-deflate (method 8) entries. A
  # zip64 archive (EOCD64 / > 65535 files or > 4 GiB) is refused, as the reference implementation does
  # (see its README's own note). Data descriptors (general-purpose bit 3) are tolerated on read through the
  # central directory's sizes; a changed entry is rewritten without one.
  module ZipArchive
    class Error < ArchivePatcher::Error; end

    LOCAL_SIG = 0x04034b50
    CENTRAL_SIG = 0x02014b50
    EOCD_SIG = 0x06054b50

    STORED = 0
    DEFLATED = 8

    # One entry as read. `compressed` holds the exact bytes that were in the archive (compressed for
    # DEFLATED, raw for STORED); `content` is the decompressed bytes.
    Entry = Struct.new(
      :name, :flags, :method, :time, :date, :extra, :crc, :comp_size, :uncomp_size,
      :compressed, :content,
      :deflate_level, :deflate_strategy,
      :version_made_by, :version_needed, :internal_attrs, :external_attrs, :data_offset, keyword_init: true
    ) do
      def stored?
        method == STORED
      end

      def deflated?
        method == DEFLATED
      end
    end

    module_function

    # @return [Array<Entry>] in central-directory order
    def read(bytes)
      bytes = bytes.b
      eocd = find_eocd(bytes)
      raise Error, 'not a zip archive (no end-of-central-directory)' unless eocd

      count = le16(bytes, eocd + 10)
      cd_offset = le32(bytes, eocd + 16)
      raise Error, 'zip64 archive is not supported' if count == 0xffff || cd_offset == 0xffffffff

      entries = []
      pos = cd_offset
      count.times do
        raise Error, 'truncated central directory' unless le32(bytes, pos) == CENTRAL_SIG

        version_made_by = le16(bytes, pos + 4)
        version_needed = le16(bytes, pos + 6)
        flags = le16(bytes, pos + 8)
        method = le16(bytes, pos + 10)
        time = le16(bytes, pos + 12)
        date = le16(bytes, pos + 14)
        crc = le32(bytes, pos + 16)
        comp_size = le32(bytes, pos + 20)
        uncomp_size = le32(bytes, pos + 24)
        name_len = le16(bytes, pos + 28)
        extra_len = le16(bytes, pos + 30)
        comment_len = le16(bytes, pos + 32)
        internal_attrs = le16(bytes, pos + 36)
        external_attrs = le32(bytes, pos + 38)
        local_offset = le32(bytes, pos + 42)
        name = bytes.byteslice(pos + 46, name_len)
        extra = bytes.byteslice(pos + 46 + name_len, extra_len)
        pos += 46 + name_len + extra_len + comment_len

        entries << read_entry(bytes, name: name, flags: flags, method: method, time: time, date: date,
                              extra: extra, crc: crc, comp_size: comp_size, uncomp_size: uncomp_size,
                              local_offset: local_offset, version_made_by: version_made_by,
                              version_needed: version_needed, internal_attrs: internal_attrs,
                              external_attrs: external_attrs)
      end
      entries
    end

    def read_entry(bytes, name:, flags:, method:, time:, date:, extra:, crc:, comp_size:, uncomp_size:,
                   local_offset:, version_made_by:, version_needed:, internal_attrs:, external_attrs:)
      raise Error, "bad local header for #{name}" unless le32(bytes, local_offset) == LOCAL_SIG

      l_name_len = le16(bytes, local_offset + 26)
      l_extra_len = le16(bytes, local_offset + 28)
      data_start = local_offset + 30 + l_name_len + l_extra_len
      compressed = bytes.byteslice(data_start, comp_size)

      content =
        case method
        when STORED then compressed
        when DEFLATED then inflate(compressed, -Zlib::MAX_WBITS)
        else raise Error, "unsupported compression method #{method} for #{name}"
        end

      Entry.new(name: name, flags: flags, method: method, time: time, date: date, extra: extra,
                crc: crc, comp_size: comp_size, uncomp_size: uncomp_size,
                compressed: compressed, content: content,
                deflate_level: method == DEFLATED ? detect_level(content, compressed) : nil,
                deflate_strategy: method == DEFLATED ? detect_strategy(content, compressed) : nil,
                version_made_by: version_made_by, version_needed: version_needed,
                internal_attrs: internal_attrs, external_attrs: external_attrs, data_offset: data_start)
    end

    # Rebuild an archive from entries, compressing DEFLATED entries at `level`/`strategy`. Each entry's
    # `content` is compressed fresh (a changed entry has new content; an unchanged one recompresses to the
    # same bytes because its settings are known).
    def build(entries)
      out = +''.b
      central = +''.b
      entries.each do |entry|
        offset = out.bytesize
        if entry.method == DEFLATED
          data = deflate(entry.content, entry.deflate_level, entry.deflate_strategy)
        elsif entry.method == STORED
          data = entry.content
        else
          raise Error, "unsupported compression method #{entry.method} for #{entry.name}"
        end
        crc = Zlib.crc32(entry.content)
        flags = entry.flags & ~0x0008 # no data descriptor; sizes are written inline
        version_needed = entry.version_needed || 20
        version_made_by = entry.version_made_by || 20
        internal_attrs = entry.internal_attrs || 0
        external_attrs = entry.external_attrs || 0

        local = +''.b
        local << [LOCAL_SIG, version_needed, flags, entry.method, entry.time, entry.date, crc,
                  data.bytesize, entry.content.bytesize, entry.name.bytesize, entry.extra.bytesize].pack('VvvvvvVVVvv')
        local << entry.name << entry.extra << data
        out << local

        central << [CENTRAL_SIG, version_made_by, version_needed, flags, entry.method, entry.time,
                    entry.date, crc, data.bytesize, entry.content.bytesize, entry.name.bytesize,
                    entry.extra.bytesize, 0, 0, internal_attrs, external_attrs, offset].pack('VvvvvvvVVVvvvvvVV')
        central << entry.name << entry.extra
      end

      cd_offset = out.bytesize
      out << central
      out << [EOCD_SIG, 0, 0, entries.size, entries.size, central.bytesize, cd_offset, 0].pack('VvvvvVVv')
      out
    end

    # --- deflate helpers -------------------------------------------------------

    def deflate(content, level, strategy)
      level = (level || 6).clamp(1, 9)
      strategy = (strategy || 0).clamp(0, 2)
      d = Zlib::Deflate.new(level, -Zlib::MAX_WBITS, Zlib::DEF_MEM_LEVEL, zlib_strategy(strategy))
      out = d.deflate(content) + d.finish
      d.close
      out.b
    end

    def inflate(bytes, window_bits)
      Zlib::Inflate.new(window_bits).inflate(bytes.b)
    end

    def zlib_strategy(strategy)
      case strategy
      when 1 then Zlib::FILTERED
      when 2 then Zlib::HUFFMAN_ONLY
      else Zlib::DEFAULT_STRATEGY
      end
    end

    # Find the deflate level that recompresses `content` to exactly `compressed`; nil when none does.
    def detect_level(content, compressed)
      (1..9).find { |level| deflate(content, level, 0) == compressed }
    end

    def detect_strategy(content, compressed)
      # archive-patcher's own search: try the common strategies, keeping the first that matches alongside a
      # level. Returns the strategy (0 default is the overwhelmingly common case).
      level = detect_level(content, compressed)
      return 0 if level

      (1..2).find { |strategy| (1..9).any? { |l| deflate(content, l, strategy) == compressed } }
    end

    # --- little-endian readers -------------------------------------------------

    def le16(bytes, offset)
      bytes.getbyte(offset) | (bytes.getbyte(offset + 1) << 8)
    end

    def le32(bytes, offset)
      bytes.getbyte(offset) | (bytes.getbyte(offset + 1) << 8) |
        (bytes.getbyte(offset + 2) << 16) | (bytes.getbyte(offset + 3) << 24)
    end

    def find_eocd(bytes)
      min = [bytes.bytesize - 65_557, 0].max
      pos = bytes.bytesize - 22
      while pos >= min
        return pos if le32(bytes, pos) == EOCD_SIG

        pos -= 1
      end
      nil
    end
  end
end
