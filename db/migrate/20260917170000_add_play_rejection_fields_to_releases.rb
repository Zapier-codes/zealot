# frozen_string_literal: true

# Fixes the known gap flagged since session 11 (see handover.md task #11 /
# Release#reject_play_publish!): rejecting a release's Play Store publish
# request reused the play_approved_at/play_approved_by columns, since the
# original approval-bookkeeping migration only ever added "approved"
# columns. That worked (the workflow functioned correctly end-to-end) but
# made the columns semantically ambiguous — "play_approved_at" on a
# rejected release doesn't actually mean it was approved, it means it was
# last reviewed. This migration adds dedicated rejection columns so
# approval history and rejection history can be told apart at a glance,
# without changing behavior for any release already reviewed under the old
# scheme (see Release#reject_play_publish! for the model-side change and
# its backfill note).
class AddPlayRejectionFieldsToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :play_rejected_at, :datetime
    add_reference :releases, :play_rejected_by, foreign_key: { to_table: :users }, index: true
  end
end
