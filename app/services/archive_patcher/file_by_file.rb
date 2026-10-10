# frozen_string_literal: true

require 'digest'
require_relative 'bsdiff'
require_relative 'zip_archive'

module ArchivePatcher
  # The File-by-File v1 patch generator, the "Zealot makes the patch" half of Z-P13. It is the counterpart
  # of Google's archive-patcher (the client applies it, in Storeapp), and it writes the real v1 container so
  # a real archive-patcher client can read it.
  #
  # What it does: an APK is a zip. Deflate hides small edits (one changed file rewrites a whole compressed
  # region), so a byte delta of two APKs is nearly the size of one. archive-patcher's trick is to
  # *uncompress the changed entries only* into a "delta-friendly space", delta that space with bsdiff, and
  # record how to *recompress* the changed entries so the result is byte-for-byte the new archive.
  #
  # Patch layout (all integers big-endian; see the archive-patcher README "The File-by-File v1 Patch
  # Format"):
  #
  #   Versioned Identifier       8 bytes   "GFbFv1_0"
  #   Flags                      4 bytes   0
  #   Delta-friendly old size    8 bytes   uint64
  #   Num uncompression ops      4 bytes   uint32
  #   <uncompression op>         ...        {offset uint64, nbytes uint64}  (regions of the OLD archive to
  #    x N                                  inflate to build the delta-friendly old blob)
  #   Num recompression ops      4 bytes   uint32
  #   <recompression op>         ...        {offset uint64, size uint64, settings 4 bytes}  (regions of the
  #    x N                                  delta-friendly NEW blob the applier re-deflates in place)
  #   Num delta descriptors      4 bytes   1
  #   <delta descriptor>         ...        {format uint8=0, old start, old len, new start, new len, delta len}
  #   <delta>                    ...        the bsdiff stream (BsDiff.diff of the two delta-friendly blobs)
  #
  # Recompression settings: compatibility-window id (1 byte, only 0 defined), deflate level (1), deflate
  # strategy (1), wrap mode (1). The v1 patch carries the *post-apply* index mapping (the "DeltaDescriptor
  # Record with the recompression applied in place and a suffix offset update" described in the README's
  # Appendix), which is the form the applier consumes: recompress the named region, and because deflate
  # never changes the byte length, every later offset shifts by 0.
  #
  # The applier (server-side twin below, and the real client) does NOT recompress: it splices the
  # compressed ranges into the bsdiff output and shifts the following delta-friendly offsets by the length
  # change. `apply_verified` additionally runs the recorded recompression ops to prove they reconstruct the
  # new archive exactly, which is what the client relies on.
  module FileByFile
    MAGIC = 'GFbFv1_0'
    FLAGS = "\x00\x00\x00\x00".b
    COMPATIBILITY_WINDOW = 0
    WRAP_NOWRAP = 1
    DELTA_FORMAT_ID = 0

    class Error < ArchivePatcher::Error; end
    class VerificationError < Error; end

    Result = Struct.new(:patch, :old_size, :new_size, :old_sha256, :new_sha256,
                        :uncompression_ops, :recompression_ops, keyword_init: true)

    module_function

    # Build a v1 patch that turns `old_bytes` into `new_bytes`.
    #
    # @param verify [Boolean] when true, apply the patch it just made and raise unless it reproduces
    #   `new_bytes` byte for byte. Default true: a patch that does not round-trip is never stored.
    # @return [Result]
    def generate(old_bytes, new_bytes, verify: true)
      old_bytes = old_bytes.b
      new_bytes = new_bytes.b

      old_entries = ZipArchive.read(old_bytes)
      new_entries = ZipArchive.read(new_bytes)

      changed = changed_names(old_entries, new_entries)
      old_dfs, old_ops = build_old_space(old_bytes, old_entries, changed)
      new_dfs, new_ops = build_new_space(new_bytes, new_entries, changed)

      delta = BsDiff.diff(old_dfs, new_dfs)
      patch = assemble(old_dfs.bytesize, old_ops, new_ops, new_dfs.bytesize, delta)

      if verify
        reconstructed = apply(old_bytes, patch)
        unless reconstructed == new_bytes
          raise VerificationError, "generated patch does not reproduce the new archive " \
                                   "(#{reconstructed.bytesize} vs #{new_bytes.bytesize} bytes)"
        end
      end

      Result.new(patch: patch, old_size: old_bytes.bytesize, new_size: new_bytes.bytesize,
                 old_sha256: Digest::SHA256.hexdigest(old_bytes),
                 new_sha256: Digest::SHA256.hexdigest(new_bytes),
                 uncompression_ops: old_ops.size, recompression_ops: new_ops.size)
    end

    # Apply a patch. The applier inflates the OLD archive's changed regions into the delta-friendly space,
    # applies the bsdiff delta to reach the delta-friendly NEW blob, then re-deflates each recorded region
    # so the result is the new archive exactly. Deflate never changes a region's byte length, so every
    # later offset is stable.
    def apply(old_bytes, patch)
      old_bytes = old_bytes.b
      parsed = parse(patch.b)
      dfs_old = uncompress_ranges(old_bytes, parsed[:uncompression_ops])
      dfs_new = BsDiff.patch(dfs_old, parsed[:delta])
      raise Error, 'delta output has the wrong length' unless dfs_new.bytesize == parsed[:new_space_size]

      recompress(dfs_new, parsed[:recompression_ops])
    end

    alias apply_with_recompression apply

    # Re-deflate each recorded region of the delta-friendly new blob in place. Offsets are already adjusted
    # for the length change of every earlier region (see build_new_space), so a single ascending pass over a
    # shrinking buffer is correct. `size` is the uncompressed length at that offset.
    def recompress(dfs_new, ops)
      out = dfs_new.dup
      ops.sort_by { |op| op[:offset] }.each do |op|
        content = out.byteslice(op[:offset], op[:size])
        compressed = ZipArchive.deflate(content, op[:level], op[:strategy])
        out = out.byteslice(0, op[:offset]) + compressed + out.byteslice(op[:offset] + op[:size], out.bytesize)
      end
      out
    end

    # --- space building --------------------------------------------------------

    # Names whose bytes differ between the two archives (present in only one of them counts too).
    def changed_names(old_entries, new_entries)
      old_by = old_entries.to_h { |e| [e.name, e] }
      new_by = new_entries.to_h { |e| [e.name, e] }
      names = old_by.keys | new_by.keys
      names.select do |name|
        a = old_by[name]
        b = new_by[name]
        a.nil? || b.nil? || a.method != b.method || a.content != b.content
      end
    end

    # The delta-friendly old blob: the whole old archive except that each changed, reproducible entry's
    # compressed data region is inflated in place. Returns [blob, uncompression_ops], the ops naming the
    # region's offset and compressed length in the OLD archive.
    def build_old_space(old_bytes, old_entries, changed)
      blob = +''.b
      ops = []
      cursor = 0
      old_entries.each do |entry|
        region = data_region(entry)
        next unless region

        if changed.include?(entry.name) && reproduces?(entry) && !entry.stored?
          blob << old_bytes.byteslice(cursor, region[:offset] - cursor) if region[:offset] > cursor
          blob << entry.content
          ops << { offset: region[:offset], size: region[:comp_size] }
          cursor = region[:offset] + region[:comp_size]
        end
      end
      blob << old_bytes.byteslice(cursor, old_bytes.bytesize - cursor) if cursor < old_bytes.bytesize
      [blob, ops]
    end

    # The delta-friendly new blob, and a recompression op for each changed deflated entry. The op's offset
    # is its position in the delta-friendly blob *after* every earlier recompression has changed the blob
    # length (archive-patcher's "shift on the suffix"): the applier recompresses ops in ascending offset
    # order on a growing buffer and every later offset is already correct. `size` is the uncompressed length
    # to compress.
    def build_new_space(new_bytes, new_entries, changed)
      blob = +''.b
      ops = []
      cursor = 0
      shift = 0
      new_entries.each do |entry|
        region = data_region(entry)
        next unless region

        if changed.include?(entry.name) && reproduces?(entry) && !entry.stored?
          blob << new_bytes.byteslice(cursor, region[:offset] - cursor) if region[:offset] > cursor
          ops << { offset: blob.bytesize + shift, size: entry.content.bytesize,
                   level: entry.deflate_level || 6, strategy: entry.deflate_strategy || 0 }
          shift += entry.comp_size - entry.content.bytesize
          blob << entry.content
          cursor = region[:offset] + region[:comp_size]
        end
      end
      blob << new_bytes.byteslice(cursor, new_bytes.bytesize - cursor) if cursor < new_bytes.bytesize
      [blob, ops]
    end

    # The compressed data region of a deflated entry inside its archive. Stored entries have no compressed
    # form to inflate, and local-header parsing beyond the data offset is not carried, so they never move.
    def data_region(entry)
      return nil unless entry.deflated? && entry.data_offset

      { offset: entry.data_offset, comp_size: entry.comp_size }
    end

    # Can we put this entry's bytes back after a change? A deflated entry is only reproducible when we
    # recovered its exact deflate settings; a stored entry is already raw and never needs recompression.
    def reproduces?(entry)
      entry.stored? || (entry.deflated? && !entry.deflate_level.nil?)
    end

    # --- patch container -------------------------------------------------------

    def assemble(old_space_size, old_ops, new_ops, new_space_size, delta)
      out = +''.b
      out << MAGIC
      out << FLAGS
      write_u64(out, old_space_size)
      write_u32(out, old_ops.size)
      old_ops.each do |op|
        write_u64(out, op[:offset])
        write_u64(out, op[:size])
      end
      write_u32(out, new_ops.size)
      new_ops.each do |op|
        write_u64(out, op[:offset])
        write_u64(out, op[:size])
        out << [COMPATIBILITY_WINDOW, op[:level], op[:strategy], WRAP_NOWRAP].pack('C4')
      end
      write_u32(out, 1)
      out << [DELTA_FORMAT_ID].pack('C')
      write_u64(out, 0)                    # old space start
      write_u64(out, old_space_size)       # old space length
      write_u64(out, 0)                    # new space start
      write_u64(out, new_space_size)       # new space length
      write_u64(out, delta.bytesize)       # delta length
      out << delta
      out
    end

    def parse(patch)
      raise Error, 'not a File-by-File v1 patch' unless patch.byteslice(0, 8) == MAGIC

      pos = 12 # magic + flags
      old_space_size = read_u64(patch, pos); pos += 8
      old_ops = []
      old_count = read_u32(patch, pos); pos += 4
      old_count.times do
        off = read_u64(patch, pos); pos += 8
        size = read_u64(patch, pos); pos += 8
        old_ops << { offset: off, size: size }
      end
      new_ops = []
      new_count = read_u32(patch, pos); pos += 4
      new_count.times do
        off = read_u64(patch, pos); pos += 8
        size = read_u64(patch, pos); pos += 8
        settings = patch.byteslice(pos, 4).unpack('C4'); pos += 4
        new_ops << { offset: off, size: size, window: settings[0], level: settings[1], strategy: settings[2] }
      end
      count = read_u32(patch, pos); pos += 4
      raise Error, 'expected exactly one delta descriptor' unless count == 1

      format = patch.getbyte(pos); pos += 1
      raise Error, "unsupported delta format #{format}" unless format == DELTA_FORMAT_ID

      _old_start = read_u64(patch, pos); pos += 8
      _old_len = read_u64(patch, pos); pos += 8
      _new_start = read_u64(patch, pos); pos += 8
      _new_len = read_u64(patch, pos); pos += 8
      delta_len = read_u64(patch, pos); pos += 8
      delta = patch.byteslice(pos, delta_len)
      { old_space_size: old_space_size, new_space_size: _new_len,
        uncompression_ops: old_ops, recompression_ops: new_ops, delta: delta }
    end

    # --- assembly helpers ------------------------------------------------------

    # Inflate each named region of the archive, producing the delta-friendly old blob. Ops are recorded in
    # archive order (build_old_space walks the entries in order), so the regions are already ascending.
    def uncompress_ranges(old_bytes, ops)
      out = +''.b
      cursor = 0
      ops.each do |op|
        out << old_bytes.byteslice(cursor, op[:offset] - cursor) if op[:offset] > cursor
        out << ZipArchive.inflate(old_bytes.byteslice(op[:offset], op[:size]), -Zlib::MAX_WBITS)
        cursor = op[:offset] + op[:size]
      end
      out << old_bytes.byteslice(cursor, old_bytes.bytesize - cursor) if cursor < old_bytes.bytesize
      out
    end

    def write_u32(io, value)
      io << [value].pack('N')
    end

    def write_u64(io, value)
      io << [value].pack('Q>')
    end

    def read_u32(bytes, pos)
      raise Error, 'truncated patch' if pos + 4 > bytes.bytesize

      bytes.byteslice(pos, 4).unpack1('N')
    end

    def read_u64(bytes, pos)
      raise Error, 'truncated patch' if pos + 8 > bytes.bytesize

      bytes.byteslice(pos, 8).unpack1('Q>')
    end
  end
end
