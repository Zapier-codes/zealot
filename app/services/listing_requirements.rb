# frozen_string_literal: true

# Task 43b-1 (operator-directed, 2026-10-07): what an app's store listing still lacks before it may be published.
# The operator overrode Task 27d's "optional, not a publish gate": the icon and the screenshots must exist before
# a publish succeeds (decisions D43-1 and D43-2 in handover.md, Task 43).
#
#   ListingRequirements.call(app)   # => [] when complete, else [Missing(:icon), Missing(:screenshots, count: 1, target: 2)]
#   ListingRequirements.sentence(missing)  # => "no icon; 1 of 2 screenshots"
#
# "Complete" = an icon on a catalog release AND at least `ListingGraphicChecklist::MIN_SCREENSHOTS` stored phone
# screenshots. The feature graphic stays advice. An app that has already been listed (`listed_at` set, which
# `go_live!` records the first time) is exempt, and so is anything that never asks: the admin `mark_paid`, the
# payment webhook, the billing job and `go_live!` do not call this (D43-1).
#
# The icon test mirrors `CatalogIndex::Serializer#icon_available?` (a copy mirrored to storage, or the file still
# on disk): the same two tiers, so "has an icon" here means "the index would carry one". Keep them in step.
# Reads plain facts off the objects it is given and writes nothing.
module ListingRequirements
  Missing = Struct.new(:key, :count, :target, keyword_init: true) do
    def to_s
      key == :screenshots ? "#{count} of #{target} screenshots" : 'no icon'
    end

    def as_json(*)
      { key: key, count: count, target: target }.compact
    end
  end

  # @param app [App] (anything answering `listed_at`, `catalog_releases` and `listing_graphics`)
  # @return [Array<Missing>] empty when the listing is complete or exempt
  def self.call(app)
    return [] if app.listed_at.present?

    missing = []
    missing << Missing.new(key: :icon) unless icon?(app)
    shots = screenshot_count(app)
    missing << Missing.new(key: :screenshots, count: shots, target: ListingGraphicChecklist::MIN_SCREENSHOTS) if shots < ListingGraphicChecklist::MIN_SCREENSHOTS
    missing
  end

  # @return [String] "no icon; 1 of 2 screenshots" (English, for API messages and logs)
  def self.sentence(missing)
    missing.map(&:to_s).join('; ')
  end

  def self.icon?(app)
    Array(app.catalog_releases).any? { |release| icon_available?(release) }
  end
  private_class_method :icon?

  def self.icon_available?(release)
    return true if release.respond_to?(:icon_storage_key) && release.icon_storage_key.present?

    path = release.respond_to?(:icon) ? release.icon&.path : nil
    path.present? && File.exist?(path)
  end
  private_class_method :icon_available?

  # Only a row whose bytes are stored and hashed is part of the listing (the index leaves the others out).
  def self.screenshot_count(app)
    app.listing_graphics.to_a.count do |graphic|
      graphic.kind.to_s == 'screenshot' && graphic.storage_key.to_s != '' && graphic.sha256.to_s != ''
    end
  end
  private_class_method :screenshot_count
end
