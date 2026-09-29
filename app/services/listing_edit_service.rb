# frozen_string_literal: true

# Task 30a. Not itself the transactional commit/discard logic (that lives
# on ListingEdit, so it holds regardless of caller) -- this is the
# app-facing entry point a future 27e controller calls instead of
# `@app.update` directly: find-or-create the app's one draft, merge new
# staged changes into it, then commit or discard it.
#
# Usage a 27e controller would follow:
#   service = ListingEditService.new(app: @app, editor: current_user)
#   edit = service.stage(name: 'New name')   # returns the ListingEdit, saved as a draft
#   service.commit!                          # or service.discard!
class ListingEditService
  attr_reader :app, :editor

  def initialize(app:, editor: nil)
    @app = app
    @editor = editor
  end

  # The app's current draft, creating an empty one if none exists yet.
  # Kept public (not just an internal helper) so a 27e preview pane can
  # read `service.draft.previewed_attributes` before staging anything.
  def draft
    @draft ||= app.listing_edits.status_draft.first_or_initialize.tap do |edit|
      edit.editor ||= editor
      edit.save! if edit.new_record?
    end
  end

  # Merges `attributes` into the draft's staged copy and saves it.
  # Unknown keys are silently dropped rather than raising -- the same
  # "ignore what isn't a listing field" leniency ListingEdit's own
  # `staged_attributes_keys_allowed` validation enforces strictly once
  # saved; slicing here means a caller building the hash from raw params
  # (which may include non-listing fields the form also submits) doesn't
  # need to pre-filter itself.
  def stage(attributes)
    permitted = attributes.to_h.stringify_keys.slice(*ListingEdit::LISTING_FIELDS)
    draft.staged_attributes = draft.staged_attributes.merge(permitted)
    draft.save
    draft
  end

  # Task 27e-c: takes fields back out of the draft, so they read through to the live app again. The text
  # editor calls this for a field the owner has put back to what is live now: leaving it staged would
  # commit an old copy over any change made to the live app since. Does nothing (and creates nothing)
  # when there is no draft, and silently ignores a key that is not staged.
  def unstage(*fields)
    return nil unless app.listing_edits.status_draft.exists?

    keys = fields.flatten.map(&:to_s)
    draft.staged_attributes = draft.staged_attributes.except(*keys)
    draft.save
    draft
  end

  def commit!
    draft.commit!
  end

  def discard!
    draft.discard!
  end
end
