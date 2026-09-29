# frozen_string_literal: true

# Task 27d-e2-c2: move one screenshot up or down one place in its app's list.
#
#   result = ListingGraphicReorder.call(app: app, graphic: graphic, direction: 'up')
#   result.changed?   # => true when the order changed (and, for a live app, one publish was enqueued)
#
# All the screenshots of the graphic's device are re-numbered 0, 1, 2 ... in ONE transaction under a
# lock on the app row (the same lock `ListingGraphicIngest` takes, so a move and an upload cannot
# interleave). Two things follow from doing it this way rather than saving rows one by one:
#
#   - The unique index on (app_id, kind, device, position) is not deferrable, so two rows cannot swap
#     positions directly. The rows are first shifted out of the way (+OFFSET), then given their final
#     numbers; at no point do two rows share one.
#   - `update_all` runs no model callbacks, so the per-row `after_commit` that republishes the index
#     (27d-e1) does not fire N times. One publish is enqueued after the transaction commits, and only
#     if the order really changed.
#
# A move that changes nothing (already first and asked to go up, already last and asked to go down, an
# unknown direction) writes nothing and publishes nothing. Gaps left by removals are closed only when a
# real move happens; the index sorts by position, so a gap never shows to a reader.
class ListingGraphicReorder
  DIRECTIONS = %w[up down].freeze

  # Far larger than the 8-screenshot cap, so the shifted numbers can never meet the final ones.
  OFFSET = 100_000

  Result = Struct.new(:changed, keyword_init: true) do
    def changed?
      changed
    end
  end

  # The pure part: the ids after moving `id` one place in `direction`. Returns a copy; the input is
  # never changed. An id that is not in the list, an unknown direction or a move off either end
  # returns the list as it was.
  def self.moved(ids, id, direction)
    index = ids.index(id)
    return ids.dup if index.nil? || !DIRECTIONS.include?(direction.to_s)

    target = direction.to_s == 'up' ? index - 1 : index + 1
    return ids.dup if target.negative? || target >= ids.size

    ids.dup.tap { |list| list[index], list[target] = list[target], list[index] }
  end

  # @return [Result]
  def self.call(app:, graphic:, direction:)
    changed = false

    ListingGraphic.transaction do
      app.lock!
      scope = ListingGraphic.where(app_id: app.id, kind: 'screenshot', device: graphic.device)
      ids = scope.order(:position, :id).pluck(:id)
      new_ids = moved(ids, graphic.id, direction)

      if new_ids != ids
        scope.update_all(['position = position + ?', OFFSET])
        new_ids.each_with_index do |id, position|
          ListingGraphic.where(id: id).update_all(position: position, updated_at: Time.current)
        end
        changed = true
      end
    end

    CatalogIndexPublishJob.enqueue_for(app.tenant) if changed && app.listing_live?
    Result.new(changed: changed)
  end
end
