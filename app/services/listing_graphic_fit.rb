# frozen_string_literal: true

require 'tmpdir'
require 'securerandom'

# Task 43e (operator-directed, 2026-10-07): make a picture fit Play's graphic rules BEFORE
# `ListingGraphicIngest` judges it, so an owner or a CI job that sends a real phone screenshot (1080 x 2400
# is 20:9, over the 2:1 limit) does not have to resize by hand.
#
#   fitted = ListingGraphicFit.call(path: upload_path, kind: 'screenshot')
#   fitted.path      # the file to ingest: a new temp file when something changed, else the original
#   fitted.changed?  # => true when `path` is not the file that came in
#   fitted.notes     # => ["cropped 1080x2400 to 1080x2160", ...] (empty when nothing changed)
#   fitted.cleanup   # removes the temp file; call it in an `ensure`
#
# What it does, for a screenshot: reads any image ImageMagick can open (WebP, GIF first frame, JPEG, PNG),
# flattens transparency onto white, crops a too-tall (or too-wide) picture to exactly 2:1 around its centre
# (which drops the status bar and the gesture bar of a phone capture), scales a side over 3840 px down and a
# side under 320 px up, and writes a PNG (a JPEG stays a JPEG). A file still over 8 MB is written again as a
# JPEG. For a feature graphic: scaled to cover 1024 x 500, cropped around the centre, flattened, written as PNG.
#
# It never judges: it does not refuse and does not check the slot count. A file ImageMagick cannot read, or
# any failure while fitting, returns the ORIGINAL path with a note, and the ingest then gives its own refusal
# (the real reason). The ingest stays strict, so the rules live in one place (`ListingGraphicRules`).
class ListingGraphicFit
  Result = Struct.new(:path, :changed, :notes, :tempfile, keyword_init: true) do
    def changed?
      changed
    end

    def cleanup
      FileUtils.rm_f(tempfile) if tempfile
    end
  end

  def self.call(path:, kind:)
    new(path: path, kind: kind.to_s).call
  end

  def initialize(path:, kind:)
    @path = path
    @kind = kind
  end

  def call
    return unchanged unless @path && File.file?(@path)
    return unchanged unless %w[screenshot feature_graphic].include?(@kind)

    require 'mini_magick'
    image = MiniMagick::Image.open(@path)
    @notes = []
    @kind == 'screenshot' ? fit_screenshot(image) : fit_feature_graphic(image)
    write(image)
  rescue StandardError => e
    Rails.logger.warn("[ListingGraphicFit] #{@kind} left as it came in: #{e.class}: #{e.message}")
    Result.new(path: @path, changed: false, notes: [ "could not be adjusted (#{e.class})" ], tempfile: nil)
  end

  private

  def unchanged
    Result.new(path: @path, changed: false, notes: [], tempfile: nil)
  end

  def fit_screenshot(image)
    flatten(image)
    width = image.width
    height = image.height
    limit = ListingGraphicRules::MAX_ASPECT_RATIO

    if height > limit * width
      target = limit * width
      image.crop("#{width}x#{target}+0+#{(height - target) / 2}")
      @notes << "cropped #{width}x#{height} to #{width}x#{target}"
      height = target
    elsif width > limit * height
      target = limit * height
      image.crop("#{target}x#{height}+#{(width - target) / 2}+0")
      @notes << "cropped #{width}x#{height} to #{target}x#{height}"
      width = target
    end
    image << '+repage'

    if [ width, height ].max > ListingGraphicRules::MAX_SIDE
      image.resize("#{ListingGraphicRules::MAX_SIDE}x#{ListingGraphicRules::MAX_SIDE}>")
      @notes << "scaled down to at most #{ListingGraphicRules::MAX_SIDE} px a side"
    elsif [ width, height ].min < ListingGraphicRules::MIN_SIDE
      image.resize("#{ListingGraphicRules::MIN_SIDE}x#{ListingGraphicRules::MIN_SIDE}^")
      @notes << "scaled up to at least #{ListingGraphicRules::MIN_SIDE} px a side"
    end
  end

  def fit_feature_graphic(image)
    flatten(image)
    width = ListingGraphicRules::FEATURE_GRAPHIC_WIDTH
    height = ListingGraphicRules::FEATURE_GRAPHIC_HEIGHT
    return if image.width == width && image.height == height

    image.resize("#{width}x#{height}^")
    image.gravity('center')
    image.extent("#{width}x#{height}")
    image << '+repage'
    @notes << "scaled and cropped to #{width}x#{height}"
  end

  # Transparency is refused by Play, so lay the picture on white (the first frame only, for an animation).
  def flatten(image)
    image.format('png') unless image.type.to_s.casecmp('jpeg').zero?
    image.background('white')
    image.flatten
    image.alpha('off')
  end

  def write(image)
    extension = image.type.to_s.casecmp('jpeg').zero? ? 'jpg' : 'png'
    target = File.join(Dir.tmpdir, "zealot-fit-#{SecureRandom.hex(8)}.#{extension}")
    image.strip
    image.write(target)

    if File.size(target) > ListingGraphicRules::MAX_BYTES
      image = MiniMagick::Image.open(target)
      image.format('jpg')
      image.quality('88')
      jpeg = File.join(Dir.tmpdir, "zealot-fit-#{SecureRandom.hex(8)}.jpg")
      image.write(jpeg)
      FileUtils.rm_f(target)
      target = jpeg
      @notes << 're-encoded as JPEG to fit the 8 MB limit'
    end

    # A picture that came out byte for byte as it went in needed nothing: keep the original, drop the copy.
    if FileUtils.identical?(@path, target)
      FileUtils.rm_f(target)
      return unchanged
    end

    @notes << 'normalised to a plain image file' if @notes.empty?
    Result.new(path: target, changed: true, notes: @notes, tempfile: target)
  end
end
