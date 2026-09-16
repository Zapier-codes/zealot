# frozen_string_literal: true

# Groundwork for the Play Store publish-approval workflow (handover.md task
# #7 groundwork, decided this session): a release destined for Play Store
# doesn't get auto-published there — it needs an admin's explicit approval,
# and if that doesn't happen within 48h the request expires and the release
# stays available only through our own internal distribution (never removed
# from there; nothing about this workflow ever takes a release down). This
# is *only* the approval bookkeeping — the actual Play Developer API publish
# call is still task #7 and is not implemented by this migration/session.
class AddPlayApprovalFieldsToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :play_store_target, :boolean, null: false, default: false
    add_column :releases, :play_approval_status, :string, null: false, default: 'not_requested'
    add_column :releases, :play_approval_requested_at, :datetime
    add_column :releases, :play_approval_expires_at, :datetime
    add_column :releases, :play_approved_at, :datetime
    add_reference :releases, :play_approved_by, foreign_key: { to_table: :users }, index: true

    add_index :releases, :play_approval_status
    add_index :releases, :play_approval_expires_at
  end
end
