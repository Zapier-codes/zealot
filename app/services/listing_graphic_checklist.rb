# frozen_string_literal: true

# Task 27d-e2-e: the Play-style checklist on the store-graphics panel. ADVICE, NOT A GATE: nothing here
# blocks an upload, a publish or going live. (Task 43b added the real gate, `ListingRequirements`: an icon and
# `MIN_SCREENSHOTS` screenshots before a listing request or payment; this checklist stays advice.)
# It answers one question for the owner: how close is this listing to what Play's console asks for
# and recommends?
#
# Pure Ruby on purpose, like ListingGraphicRules: it reads plain facts off the objects it is given
# (`kind`, `width`, `height`, `alt_text`, `storage_key`, `sha256`) and touches no database, so it can
# be run and tested alone. The numbers come from ListingGraphicRules; only the two recommendation
# figures below are new, and both are from the standard doc's "Recommendations for store promotion
# eligibility" (read from Google's help page on 2026-09-28).
#
#   ListingGraphicChecklist.call(app.listing_graphics, video_youtube_id: app.promo_video_youtube_id)
#   # => [#<struct Item key=:min_screenshots, met=true, count=2, target=2>, ...]
module ListingGraphicChecklist
  # `key` is what the view localizes by (apps.show.listing_graphics.checklist.items.<key>); `count` and
  # `target` are set only for the items that count something (the others leave them nil).
  Item = Struct.new(:key, :met, :count, :target)

  # Play needs at least 2 screenshots to publish; Zealot only recommends it.
  MIN_SCREENSHOTS = 2

  # Play's promotion recommendation: at least 4 screenshots of at least 1080 px, in 16:9 landscape
  # (1920 x 1080 minimum) or 9:16 portrait (1080 x 1920 minimum).
  PROMO_SCREENSHOTS = 4
  PROMO_SHORT_SIDE = 1080
  PROMO_LONG_SIDE = 1920

  # A ratio within 1% of 16:9 (or 9:16) counts. Play states the ratio, not a tolerance; 1% is ours, so a
  # rounded export (1079 x 1920) is not marked wrong while 20:9 phone captures (1080 x 2400) still are.
  RATIO_TOLERANCE_PERCENT = 1

  # @param graphics [Enumerable] the app's ListingGraphic rows (or anything that answers the same)
  # @param video_youtube_id [String, nil] the app's stored promo video ID
  # @return [Array<Item>] in the order the panel shows them
  def self.call(graphics, video_youtube_id: nil)
    stored = graphics.to_a.select { |graphic| stored?(graphic) }
    screenshots = stored.select { |graphic| graphic.kind.to_s == 'screenshot' }
    promo = screenshots.count { |graphic| promo_ready?(graphic.width, graphic.height) }

    [
      Item.new(:min_screenshots, screenshots.size >= MIN_SCREENSHOTS, screenshots.size, MIN_SCREENSHOTS),
      Item.new(:promo_screenshots, promo >= PROMO_SCREENSHOTS, promo, PROMO_SCREENSHOTS),
      Item.new(:feature_graphic, stored.any? { |graphic| graphic.kind.to_s == 'feature_graphic' }, nil, nil),
      Item.new(:alt_text, stored.any? && stored.all? { |graphic| graphic.alt_text.to_s.strip != '' }, nil, nil),
      Item.new(:video, ListingGraphicRules.youtube_id?(video_youtube_id), nil, nil)
    ]
  end

  # How many items are met, for a "3 of 5" summary.
  def self.met_count(items)
    items.count(&:met)
  end

  # Whether one screenshot is big enough and the right shape for Play's promotion recommendation.
  # Integer arithmetic only; anything that is not a positive Integer is not ready.
  def self.promo_ready?(width, height)
    return false unless [ width, height ].all? { |side| side.is_a?(Integer) && side.positive? }

    long = [ width, height ].max
    short = [ width, height ].min
    return false if short < PROMO_SHORT_SIDE || long < PROMO_LONG_SIDE

    # long/short against 16/9, compared as long * 9 against short * 16.
    (long * 9 - short * 16).abs * 100 <= short * 16 * RATIO_TOLERANCE_PERCENT
  end

  # The panel's tiles show only stored graphics as images and the index lists only those; a row still
  # waiting for its bytes is not part of the listing yet, so it does not tick anything.
  def self.stored?(graphic)
    graphic.storage_key.to_s != '' && graphic.sha256.to_s != ''
  end
  private_class_method :stored?
end
