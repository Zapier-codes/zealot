# frozen_string_literal: true

# Task 27d-d1: Google Play Console's rules for a store listing's graphics, held in one place so the
# model, the uploader (27d-d2), the index (27d-e1) and the owner UI (27d-e2) all read the same
# numbers. Sources and the reasoning for every choice are in docs/store_listing_graphics.md; the
# figures marked "Play" were read from Google's own help page on 2026-09-28.
#
# Pure Ruby on purpose: it takes plain facts about a file and returns what is wrong with them. It
# reads no file, touches no database and needs no Rails, so it can be run and tested alone. The
# facts (`content_type`, `alpha`, the pixel size) are the CALLER's to establish from the file's
# bytes, never from its name: 27d-d2's uploader does that.
#
#   ListingGraphicRules.violations(kind: 'screenshot', content_type: 'image/png', byte_size: 300_000,
#                                  width: 1080, height: 1920, alpha: false)
#   # => []
module ListingGraphicRules
  # `attribute` is where a model should hang the error, `code` is what a UI localizes by (27d-e2),
  # `message` is a plain English fallback (no locale keys exist for these yet).
  Violation = Struct.new(:attribute, :code, :message)

  KINDS = %w[screenshot feature_graphic].freeze

  # Phones only for now (docs/store_listing_graphics.md); tablets, Wear OS and the rest have their
  # own rules and counts in Play and are a later card.
  DEVICES = %w[phone].freeze

  # Play: JPEG or 24-bit PNG (no alpha). No GIF, no WebP, no animated image; motion goes in the
  # video slot, which is a YouTube link, not an upload.
  ALLOWED_CONTENT_TYPES = %w[image/jpeg image/png].freeze

  # Zealot's own cap, not Play's: Play states none for phone screenshots on the page read (8 MB is
  # the figure it gives for XR screenshots). Operator question 1 in the handover; default kept.
  MAX_BYTES = 8 * 1024 * 1024

  # Play, screenshots: each side 320 to 3840 px, and the long side at most twice the short side.
  MIN_SIDE = 320
  MAX_SIDE = 3840
  MAX_ASPECT_RATIO = 2

  # Play: up to 8 per device type. (Play also needs at least 2 to publish; Zealot does not gate on
  # that, it only recommends it. See the standard doc, "Not a publish gate".)
  MAX_SCREENSHOTS = 8

  # Play: the feature graphic is exactly 1024 x 500.
  FEATURE_GRAPHIC_WIDTH = 1024
  FEATURE_GRAPHIC_HEIGHT = 500

  # Play recommends alt text of 140 characters or fewer on every graphic.
  ALT_TEXT_MAX_LENGTH = 140

  # A YouTube video ID: 11 characters of letters, digits, `_` and `-`. A playlist (34 characters
  # from `PL...`), a channel (`UC...`, 24) or a whole URL is not one. Only the stored ID is
  # checked here; turning a pasted URL into an ID is the owner UI's job (27d-e2).
  YOUTUBE_ID_FORMAT = /\A[A-Za-z0-9_-]{11}\z/

  # Everything wrong with one graphic, or `[]` when it is acceptable.
  # `alpha` must be `true` or `false`: `nil` (not established) is refused, because a file whose
  # transparency nobody checked cannot be called acceptable.
  # @return [Array<Violation>]
  def self.violations(kind:, content_type:, byte_size:, width:, height:, alpha:, alt_text: nil)
    file_violations(kind: kind, content_type: content_type, byte_size: byte_size, width: width,
                    height: height, alpha: alpha) + alt_text_violations(alt_text)
  end

  # The file's own facts: type, weight, transparency and pixel size (the alt text is separate
  # because it can change without the file changing).
  # @return [Array<Violation>]
  def self.file_violations(kind:, content_type:, byte_size:, width:, height:, alpha:)
    found = []
    found << Violation.new(:kind, :kind_unknown, "kind must be one of: #{KINDS.join(', ')}") unless KINDS.include?(kind)
    found.concat(type_violations(content_type, alpha))
    found.concat(weight_violations(byte_size))
    found.concat(size_violations(kind, width, height)) if KINDS.include?(kind)
    found
  end

  # @return [Array<Violation>]
  def self.alt_text_violations(alt_text)
    return [] unless alt_text.to_s.length > ALT_TEXT_MAX_LENGTH

    [Violation.new(:alt_text, :alt_text_too_long, "alt text must be #{ALT_TEXT_MAX_LENGTH} characters or fewer")]
  end

  # Whether an app that already has `existing_count` screenshots on a device may take another.
  def self.screenshot_slot_free?(existing_count)
    existing_count.to_i < MAX_SCREENSHOTS
  end

  # True only for a plain 11-character video ID (a String; nil and URLs are not).
  def self.youtube_id?(value)
    value.is_a?(String) && YOUTUBE_ID_FORMAT.match?(value)
  end

  def self.type_violations(content_type, alpha)
    found = []
    unless ALLOWED_CONTENT_TYPES.include?(content_type)
      found << Violation.new(:content_type, :type_not_allowed,
                             'must be a JPEG or PNG image (GIF, WebP and animated images are not accepted)')
    end
    if alpha == true
      found << Violation.new(:base, :alpha_channel, 'must not have transparency (no alpha channel)')
    elsif alpha != false
      found << Violation.new(:base, :alpha_unknown, 'transparency was not checked, so the image cannot be accepted')
    end
    found
  end
  private_class_method :type_violations

  def self.weight_violations(byte_size)
    if !byte_size.is_a?(Integer) || byte_size <= 0
      [Violation.new(:byte_size, :byte_size_invalid, 'file size is missing')]
    elsif byte_size > MAX_BYTES
      [Violation.new(:byte_size, :file_too_large, "must be #{MAX_BYTES / (1024 * 1024)} MB or smaller")]
    else
      []
    end
  end
  private_class_method :weight_violations

  # Public on purpose (unlike the other `_violations` helpers): ListingGraphic re-checks pixel
  # size on every save from its own stored `width`/`height`/`kind` columns, but has no `alpha` or
  # `content_type`-at-upload-time column to re-derive the rest of `file_violations` from, so it
  # needs just this slice, not the whole file check.
  # @return [Array<Violation>]
  def self.size_violations(kind, width, height)
    found = []
    { width: width, height: height }.each do |attribute, value|
      next if value.is_a?(Integer) && value.positive?

      found << Violation.new(attribute, :dimension_missing, "#{attribute} is missing")
    end
    return found unless found.empty?

    found.concat(kind == 'feature_graphic' ? feature_graphic_size(width, height) : screenshot_size(width, height))
  end

  def self.feature_graphic_size(width, height)
    return [] if width == FEATURE_GRAPHIC_WIDTH && height == FEATURE_GRAPHIC_HEIGHT

    [Violation.new(:base, :feature_graphic_size,
                   "a feature graphic must be exactly #{FEATURE_GRAPHIC_WIDTH} x #{FEATURE_GRAPHIC_HEIGHT} px")]
  end
  private_class_method :feature_graphic_size

  def self.screenshot_size(width, height)
    found = []
    { width: width, height: height }.each do |attribute, value|
      if value < MIN_SIDE
        found << Violation.new(attribute, :side_too_small, "each side must be at least #{MIN_SIDE} px")
      elsif value > MAX_SIDE
        found << Violation.new(attribute, :side_too_large, "each side must be at most #{MAX_SIDE} px")
      end
    end
    if [width, height].max > MAX_ASPECT_RATIO * [width, height].min
      found << Violation.new(:base, :aspect_too_wide,
                             "the long side must be at most #{MAX_ASPECT_RATIO}x the short side")
    end
    found
  end
  private_class_method :screenshot_size
end
