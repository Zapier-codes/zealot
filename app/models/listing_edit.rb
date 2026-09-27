# frozen_string_literal: true

# Task 30a: "change a copy of the listing, validate, then commit or
# discard" -- the layer the future 27e store-listing editor sits on top
# of. A ListingEdit never holds the whole listing, only the fields that
# differ from the live App (`staged_attributes`), so an untouched field
# always reads through to whatever the live App currently has -- there is
# nothing here that can go stale by *not* being edited.
#
# Scope of LISTING_FIELDS today is deliberately exactly the App columns
# that exist and represent "the listing" as of this session: the same set
# App#publish_catalog_index_if_needed already watches
# (App::CATALOG_INDEX_LISTING_FIELDS), plus `description`, which is a
# listing field (27e's own table lists "descriptions" first) that has had
# a column since the original apps migration but has no editor UI and
# isn't serialized into the index yet (see
# CatalogIndex::Serializer's `description: nil, # reserved for 27e`).
# 27e's other listed surfaces -- graphics (27d), data safety, content
# rating -- have no App columns at all yet, so they simply cannot be
# staged here until those slices add the columns; extend LISTING_FIELDS
# when they do, the rest of this class (validation, commit, discard)
# needs no change to grow with it.
class ListingEdit < ApplicationRecord
  belongs_to :app
  belongs_to :editor, class_name: 'User', optional: true

  LISTING_FIELDS = (App::CATALOG_INDEX_LISTING_FIELDS + %w[description]).freeze

  enum :status, { draft: 'draft', committed: 'committed', discarded: 'discarded' }, prefix: :status

  # Only one draft per app at a time -- same "one edit in flight" model
  # Play Console's own unpublished-changes concept uses. Committed and
  # discarded rows are history, not drafts, and are exempt (this
  # validation only ever looks at other *draft* rows), and a partial
  # unique index in the migration backs this up at the database layer.
  validates :app_id, uniqueness: { conditions: -> { where(status: 'draft') } },
            if: :status_draft?,
            message: 'already has a draft listing edit for this app'

  validate :staged_attributes_keys_allowed
  validate :staged_attributes_valid_against_app

  # Everything actually mutating state below runs inside one transaction
  # (30a's acceptance check: "commit is one transaction").
  #
  # Returns false (does not raise) on validation failure or on a
  # non-draft edit, so callers can check the return value the same way
  # ActiveRecord's own #save does, rather than rescuing.
  def commit!
    return false unless status_draft?
    return false unless valid?
    return true if staged_attributes.blank? # nothing staged: no-op commit, still marks it done

    ActiveRecord::Base.transaction do
      app.update!(staged_attributes)
      update!(status: 'committed', committed_at: Time.current)
    end

    true
  rescue ActiveRecord::RecordInvalid
    false
  end

  # Deliberately touches nothing on `app` -- discarding a draft is just
  # marking this row done. "Discard leaves the live listing untouched" is
  # therefore true by construction, not by a check.
  def discard!
    return false unless status_draft?

    update!(status: 'discarded', discarded_at: Time.current)
  end

  # What the listing would look like if this edit committed right now,
  # without staging App itself -- for a future 27e preview pane.
  def previewed_attributes
    app.attributes.slice(*LISTING_FIELDS).merge(staged_attributes.stringify_keys)
  end

  private

  def staged_attributes_keys_allowed
    unknown = staged_attributes.keys.map(&:to_s) - LISTING_FIELDS
    return if unknown.empty?

    errors.add(:staged_attributes, "contains fields outside the listing: #{unknown.join(', ')}")
  end

  # Runs the *real* App validations (uniqueness included) against the
  # live app with only this edit's staged fields applied, without saving
  # or mutating the `app` association held here -- a fresh load, mutated
  # in memory, thrown away. Errors are attributed back to `:staged_attributes`
  # rather than raised, and only errors on fields this edit actually
  # touches are surfaced: an unrelated pre-existing data problem on the
  # live app (not something 27e's editor exposes for) must not block a
  # draft that never touched that field.
  def staged_attributes_valid_against_app
    return if staged_attributes.blank?
    return unless app&.persisted? # let `belongs_to :app`'s own presence validation report an unset/new app

    dry_run = App.find(app_id)
    dry_run.assign_attributes(staged_attributes)
    dry_run.valid?

    staged_keys = staged_attributes.keys.map(&:to_s)
    dry_run.errors.select { |error| staged_keys.include?(error.attribute.to_s) }.each do |error|
      errors.add(:staged_attributes, "#{error.attribute}: #{error.message}")
    end
  end
end
