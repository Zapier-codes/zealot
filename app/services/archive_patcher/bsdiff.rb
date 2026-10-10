# frozen_string_literal: true

require 'open3'
require_relative 'errors'

module ArchivePatcher
  # A small, self-contained implementation of the classic bsdiff container format. Google's
  # archive-patcher uses bsdiff as the byte-delta algorithm *inside* the delta-friendly space (see
  # file_by_file.rb), so the generated file must be a real bsdiff stream: the canonical 32-byte header,
  # then three bzip2 streams (control, diff, extra). We do not shell out to `bsdiff`/`bspatch` (they are
  # not installed here); we produce and consume the same bytes ourselves, using `bzip2` (present) for the
  # three streams.
  #
  # Format (as the reference implementation writes it):
  #   "BSDIFF40"                        (8 bytes, magic)
  #   length of the control block       (8 bytes, sign-magnitude, big-endian)
  #   length of the diff block          (8 bytes, sign-magnitude, big-endian)
  #   length of the new file            (8 bytes, sign-magnitude, big-endian)
  #   <control block>  bzip2 of N triples of three sign-magnitude 8-byte ints: (x, y, z)
  #   <diff block>     bzip2 of bytes added to old to form new regions
  #   <extra block>    bzip2 of literal bytes
  #
  # A triple means: copy `x` bytes from the diff block, each added to the old file at the current old
  # offset, to the output; then copy `y` bytes from the extra block; then seek the old offset by `z`.
  #
  # The delta is produced by a block matcher, not the reference suffix sort: it is a genuine delta (an
  # unchanged region of an archive collapses to a zero-filled copy plus a seek) and it round-trips byte
  # for byte, which is the contract this program relies on. A later slice may swap in the reference
  # bsdiff; the container is stable either way, so the client reads the same thing.
  module BsDiff
    MAGIC = 'BSDIFF40'
    BLOCK = 24

    class Error < ArchivePatcher::Error; end

    module_function

    # @param old [String] the base bytes
    # @param new [String] the target bytes
    # @return [String] a bsdiff stream
    def diff(old, new)
      old = old.b
      new = new.b
      ctrl = binary
      diff = binary
      extra = binary
      oldpos = 0

      plan_matches(old, new).each do |kind, offset, length|
        if kind == :match
          seek = offset - oldpos
          write_triple(ctrl, 0, 0, seek) unless seek.zero?
          oldpos = offset
          write_triple(ctrl, length, 0, 0)
          # An exact match adds nothing to old, so the diff region is `length` zero bytes.
          diff << ("\x00" * length)
          oldpos += length
        else # :literal
          write_triple(ctrl, 0, length, 0)
          extra << new.byteslice(offset, length)
        end
      end

      ctrl_bz = bzip(ctrl)
      diff_bz = bzip(diff)
      extra_bz = bzip(extra)

      header = binary
      header << MAGIC
      write_i64(header, ctrl_bz.bytesize)
      write_i64(header, diff_bz.bytesize)
      write_i64(header, new.bytesize)
      header + ctrl_bz + diff_bz + extra_bz
    end

    # @param old [String] the base bytes
    # @param patch [String] a bsdiff stream
    # @return [String] the reconstructed target bytes
    def patch(old, patch)
      old = old.b
      patch = patch.b
      raise Error, 'not a bsdiff stream' unless patch.byteslice(0, 8) == MAGIC.b

      ctrl_len = read_i64(patch, 8)
      diff_len = read_i64(patch, 16)
      new_size = read_i64(patch, 24)
      raise Error, 'negative block length' if ctrl_len.negative? || diff_len.negative? || new_size.negative?

      ctrl = bunzip(patch.byteslice(32, ctrl_len))
      diff = bunzip(patch.byteslice(32 + ctrl_len, diff_len))
      extra = bunzip(patch.byteslice(32 + ctrl_len + diff_len, patch.bytesize - 32 - ctrl_len - diff_len))

      out = binary
      oldpos = 0
      cpos = 0
      dpos = 0
      epos = 0

      while out.bytesize < new_size
        break if cpos + BLOCK > ctrl.bytesize

        x = read_i64(ctrl, cpos)
        y = read_i64(ctrl, cpos + 8)
        z = read_i64(ctrl, cpos + 16)
        cpos += BLOCK

        if x.positive?
          raise Error, 'old offset out of range' if oldpos.negative? || oldpos + x > old.bytesize

          x.times { |i| out << (((old.getbyte(oldpos + i) + diff.getbyte(dpos + i)) & 0xff).chr) }
        end
        oldpos += x
        dpos += x

        out << extra.byteslice(epos, y) if y.positive?
        epos += y

        oldpos += z
      end

      out.byteslice(0, new_size)
    end

    # --- helpers ---------------------------------------------------------------

    def binary
      String.new(encoding: Encoding::BINARY)
    end

    # An index of short key -> a few positions in `old`, so a match can be found without a suffix sort.
    def build_index(old)
      index = Hash.new { |h, k| h[k] = [] }
      last = old.bytesize - BLOCK
      i = 0
      while i <= last
        key = old.byteslice(i, BLOCK)
        list = index[key]
        list << i if list.size < 8
        i += 1
      end
      index
    end

    # A greedy walk over the new bytes: the longest match in old if it is at least BLOCK bytes, else a
    # literal run. Returns [[:match, old_offset, length] | [:literal, new_offset, length], ...].
    def plan_matches(old, new)
      index = build_index(old)
      out = []
      literal_start = nil
      i = 0
      while i < new.bytesize
        position = nil
        if i + BLOCK <= new.bytesize
          candidates = index[new.byteslice(i, BLOCK)]
          position = candidates.find { |p| old.byteslice(p, BLOCK) == new.byteslice(i, BLOCK) } unless candidates.empty?
        end

        if position
          length = BLOCK
          length += 1 while i + length < new.bytesize && position + length < old.bytesize &&
                            old.getbyte(position + length) == new.getbyte(i + length)
          if literal_start
            out << [:literal, literal_start, i - literal_start]
            literal_start = nil
          end
          out << [:match, position, length]
          i += length
        else
          literal_start ||= i
          i += 1
        end
      end
      out << [:literal, literal_start, new.bytesize - literal_start] if literal_start
      out
    end

    def write_triple(io, x, y, z)
      write_i64(io, x)
      write_i64(io, y)
      write_i64(io, z)
    end

    # sign-magnitude 64-bit, big-endian (the reference format)
    def write_i64(io, value)
      sign = value.negative? ? 1 : 0
      v = value.abs
      bytes = Array.new(8) { |k| (v >> (8 * (7 - k))) & 0xff }
      bytes[0] |= 0x80 if sign == 1
      io << bytes.pack('C*')
    end

    def read_i64(bytes, offset)
      raise Error, 'truncated integer' if bytes.nil? || bytes.bytesize < offset + 8

      v = bytes.getbyte(offset) & 0x7f
      7.times { |k| v = (v << 8) | bytes.getbyte(offset + 1 + k) }
      (bytes.getbyte(offset) & 0x80).positive? ? -v : v
    end

    def bzip(bytes)
      out, status = Open3.capture2('bzip2', '-c', stdin_data: bytes.b)
      raise Error, 'bzip2 failed' unless status.success?

      out.b
    end

    def bunzip(bytes)
      out, status = Open3.capture2('bunzip2', '-c', stdin_data: bytes.b)
      raise Error, 'bunzip2 failed' unless status.success?

      out.b
    end
  end
end
