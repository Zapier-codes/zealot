# frozen_string_literal: true

# Task 30a: the staged-copy layer under the future 27e store-listing editor
# -- "change a copy of the listing, validate, then commit or discard". One
# row per in-progress edit, holding only the fields that differ from the
# live App (see ListingEdit::LISTING_FIELDS), never the live listing itself.
#
# `editor` is nullable and on_delete: :nullify (not :cascade) deliberately:
# a draft or committed edit is a record of what changed, so it should
# survive the editing user's account being removed, same reasoning
# `releases.play_approved_by_id`/`play_rejected_by_id` already use for
# their own user references.
class CreateListingEdits < ActiveRecord::Migration[7.1]
  def change
    create_table :listing_edits do |t|
      t.references :app, null: false, foreign_key: { on_delete: :cascade }
      t.references :editor, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.jsonb :staged_attributes, null: false, default: {}
      t.string :status, null: false, default: 'draft'
      t.datetime :committed_at
      t.datetime :discarded_at

      t.timestamps
    end

    add_index :listing_edits, %i[app_id status]

    # Belt-and-braces alongside the model-level uniqueness validation: at
    # most one draft per app at the database layer too, so a race between
    # two requests can't create two drafts that later disagree about what
    # "the" staged copy is.
    add_index :listing_edits, :app_id, unique: true, where: "status = 'draft'",
              name: 'index_listing_edits_on_app_id_when_draft'
  end
end
