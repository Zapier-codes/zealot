# frozen_string_literal: true

# Task 32/33 (D-Store leaves 7.a.vii.zi / 7.a.vii.zo): replace an app's store-listing pictures over the API,
# so a CI re-run is idempotent. The console and the one-shot API (Task 43a) still add one picture at a time;
# this service replaces a whole set.
#
#   ListingGraphicsReplacer.call(app: app, kind: 'feature_graphic', uploads: [path])   # one picture, in place
#   ListingGraphicsReplacer.call(app: app, kind: 'screenshot', uploads: [p1, p2, p3])  # the ordered set
#
# What "replace" means:
#   - feature graphic: the app's existing feature graphic (one per device) is removed and the new one takes
#     its place, so a re-run never leaves two.
#   - screenshots: the app's existing screenshots for the device are removed and the uploaded files become
#     the whole ordered set, positions 0, 1, 2 ... in the order given, so a re-run neither duplicates nor
#     reorders.
#
# Everything is judged by `ListingGraphicIngest` (the same rules the console uses: type, size, aspect,
# count). If ANY upload is refused, the whole call is a no-op -- the existing pictures are left exactly as
# they were -- because the removal and the re-add run in one transaction and the first refusal rolls it
# back. Nothing is stored for a rolled-back call.
#
# The caller supplies already-fitted paths (the controller runs `ListingGraphicFit` first, unless the caller
# asked for `fit=false`); this service only replaces, it never reshapes bytes.
class ListingGraphicsReplacer
  Result = Struct.new(:graphics, :violations, keyword_init: true) do
    def ok?
      violations.empty?
    end
  end

  MAX_SCREENSHOTS = ListingGraphicRules::MAX_SCREENSHOTS

  # @param uploads [Array<String>] readable file paths, in display order
  # @return [Result]
  def self.call(app:, kind:, uploads:, alt_texts: [], device: 'phone', adapter: nil)
    new(app: app, kind: kind.to_s, uploads: Array(uploads), alt_texts: Array(alt_texts),
        device: device.to_s, adapter: adapter).call
  end

  def initialize(app:, kind:, uploads:, alt_texts:, device:, adapter:)
    @app = app
    @kind = kind
    @uploads = uploads
    @alt_texts = alt_texts
    @device = device
    @adapter = adapter
  end

  def call
    return refused([too_many_violation]) if screenshot? && @uploads.size > MAX_SCREENSHOTS
    return refused([no_file_violation]) if @uploads.empty?
    return refused([one_feature_violation]) if !screenshot? && @uploads.size != 1

    graphics = []
    violations = []

    ListingGraphic.transaction do
      @app.lock!
      remove_existing
      @uploads.each_with_index do |path, index|
        result = ListingGraphicIngest.call(app: @app, path: path, kind: @kind,
                                           alt_text: @alt_texts[index], device: @device, adapter: @adapter)
        unless result.ok?
          violations = result.violations
          raise ActiveRecord::Rollback
        end
        graphics << result.graphic
      end
    end

    return refused(violations) unless violations.empty?

    Result.new(graphics: graphics, violations: [])
  end

  private

  def screenshot?
    @kind == 'screenshot'
  end

  # Screenshots: the whole ordered set is replaced. Feature graphic: the single one is replaced (ingest
  # itself destroys the previous feature graphic, but removing here too keeps the two paths identical).
  def remove_existing
    scope = ListingGraphic.where(app_id: @app.id, kind: @kind, device: @device)
    scope.each(&:destroy!)
  end

  def refused(violations)
    Result.new(graphics: [], violations: violations)
  end

  def no_file_violation
    ListingGraphicRules::Violation.new(:file, :file_missing, 'no file was provided')
  end

  def too_many_violation
    ListingGraphicRules::Violation.new(:base, :screenshot_slots_full,
                                       "an app may have at most #{MAX_SCREENSHOTS} screenshots per device")
  end

  def one_feature_violation
    ListingGraphicRules::Violation.new(:base, :feature_graphic_count,
                                       'a feature graphic is a single image; send exactly one file')
  end
end
