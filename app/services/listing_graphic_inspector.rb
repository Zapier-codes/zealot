# frozen_string_literal: true

# Task 27d-d2-a: establishes the FACTS about an image file from its own bytes, never from its name
# or the browser's content type, so `ListingGraphicRules` (27d-d1) can judge them. This is the
# "checks the real file type" half of the 27d-d2 uploader; it stores nothing and writes nothing.
#
# Pure Ruby on purpose (no Rails, no MiniMagick, no gems): it reads only the header bytes it needs
# from an IO, so a huge or hostile upload is never loaded whole, and it can be run and tested alone.
#
#   facts = ListingGraphicInspector.facts_from_file('/tmp/shot.png')
#   ListingGraphicRules.file_violations(kind: 'screenshot', **facts.to_h.slice(*RULE_KEYS))
#
# What it reports:
#   content_type  'image/png' | 'image/jpeg' for the two accepted formats; 'image/gif', 'image/webp'
#                 and 'image/apng' (an animated PNG, which Play refuses) so the rules can name what
#                 was refused; nil when the bytes are none of these.
#   width, height integers from the header, or nil when the header is truncated or unreadable.
#   alpha         true when the PNG carries an alpha channel or a transparency chunk (Play wants a
#                 24-bit PNG); false for JPEG and for a PNG proven opaque; nil when it could not be
#                 established (the rules refuse nil).
#   byte_size     the file's size in bytes.
module ListingGraphicInspector
  Facts = Struct.new(:content_type, :width, :height, :alpha, :byte_size, keyword_init: true)

  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze
  JPEG_SIGNATURE = "\xFF\xD8\xFF".b.freeze

  # PNG colour types 4 (grey + alpha) and 6 (RGB + alpha) carry an alpha channel.
  PNG_ALPHA_COLOR_TYPES = [4, 6].freeze

  # JPEG start-of-frame markers, which hold the pixel size. C4 (DHT), C8 (JPG) and CC (DAC) sit in
  # the same range but are not frames.
  JPEG_SOF_MARKERS = ((0xC0..0xCF).to_a - [0xC4, 0xC8, 0xCC]).freeze
  JPEG_SOS = 0xDA

  # Enough for every signature check; the chunk and marker walks read more, a piece at a time.
  SIGNATURE_BYTES = 12

  # @param path [String]
  # @return [Facts]
  def self.facts_from_file(path)
    File.open(path, 'rb') { |io| facts(io) }
  end

  # @param io [IO, StringIO] positioned anywhere; it is rewound first
  # @return [Facts]
  def self.facts(io)
    io.binmode if io.respond_to?(:binmode)
    io.rewind
    head = io.read(SIGNATURE_BYTES).to_s.b
    facts = Facts.new(byte_size: byte_size_of(io))

    if head.start_with?(PNG_SIGNATURE) then png(io, facts)
    elsif head.start_with?(JPEG_SIGNATURE) then jpeg(io, facts)
    elsif head.start_with?('GIF87a'.b, 'GIF89a'.b) then gif(head, facts)
    elsif head.byteslice(0, 4) == 'RIFF'.b && head.byteslice(8, 4) == 'WEBP'.b then unreadable(facts, 'image/webp')
    else facts
    end
  end

  def self.byte_size_of(io)
    io.seek(0, IO::SEEK_END)
    io.pos
  end
  private_class_method :byte_size_of

  # PNG: 8-byte signature, then chunks of [length(4) type(4) data crc(4)]. IHDR comes first and holds
  # the size and colour type. tRNS (a transparency chunk) and acTL (animation) must both come before
  # the first IDAT, so walking chunks up to IDAT is enough to answer for the whole file.
  def self.png(io, facts)
    facts.content_type = 'image/png'
    io.seek(PNG_SIGNATURE.bytesize)
    ihdr = read_chunk_header(io)
    return facts unless ihdr && ihdr[:type] == 'IHDR' && ihdr[:length] >= 13

    data = io.read(13)
    return facts unless data && data.bytesize == 13

    facts.width, facts.height = data.unpack('NN')
    color_type = data.getbyte(9)
    return facts.tap { |f| f.alpha = true } if PNG_ALPHA_COLOR_TYPES.include?(color_type)

    io.seek(ihdr[:length] - 13 + 4, IO::SEEK_CUR) # rest of IHDR, then its CRC
    walk_png_chunks(io, facts)
    facts
  end
  private_class_method :png

  # Sets alpha and, for an animated PNG, the type. Leaves alpha nil when the file ends before IDAT.
  def self.walk_png_chunks(io, facts)
    transparent = false
    while (chunk = read_chunk_header(io))
      case chunk[:type]
      when 'tRNS' then transparent = true
      when 'acTL' then facts.content_type = 'image/apng'
      when 'IDAT'
        facts.alpha = transparent
        return
      end
      io.seek(chunk[:length] + 4, IO::SEEK_CUR) # the data, then the CRC
    end
  end
  private_class_method :walk_png_chunks

  def self.read_chunk_header(io)
    raw = io.read(8)
    return nil unless raw && raw.bytesize == 8

    length, type = raw.unpack('Na4')
    { length: length, type: type }
  end
  private_class_method :read_chunk_header

  # JPEG: walk the marker segments until a start-of-frame, which holds precision(1) height(2) width(2).
  # A start-of-scan before any frame means the header is broken, so size stays nil.
  def self.jpeg(io, facts)
    facts.content_type = 'image/jpeg'
    facts.alpha = false # JPEG has no alpha channel
    io.seek(2)
    while (marker = next_jpeg_marker(io))
      next if marker == 0x00 || marker == 0x01 || (0xD0..0xD9).cover?(marker) # no length field

      length = io.read(2)&.unpack1('n')
      return facts if length.nil? || length < 2
      return facts if marker == JPEG_SOS

      if JPEG_SOF_MARKERS.include?(marker)
        frame = io.read(5)
        facts.height, facts.width = frame.unpack('xnn') if frame && frame.bytesize == 5
        return facts
      end

      io.seek(length - 2, IO::SEEK_CUR)
    end
    facts
  end
  private_class_method :jpeg

  # The next marker byte after one or more 0xFF bytes, or nil at end of file.
  def self.next_jpeg_marker(io)
    byte = io.getbyte
    byte = io.getbyte while byte && byte != 0xFF
    return nil unless byte

    byte = io.getbyte while byte == 0xFF
    byte
  end
  private_class_method :next_jpeg_marker

  # GIF header: "GIF89a" then width and height as little-endian 16-bit numbers. Only read so the
  # refusal can name the format; a GIF is never accepted.
  def self.gif(head, facts)
    facts.content_type = 'image/gif'
    facts.width, facts.height = head.byteslice(6, 4).unpack('vv') if head.bytesize >= 10
    facts
  end
  private_class_method :gif

  # Formats that are recognised only so they can be refused by name (WebP).
  def self.unreadable(facts, content_type)
    facts.content_type = content_type
    facts
  end
  private_class_method :unreadable
end
