# frozen_string_literal: true

# Task 40i-a: what the stage-1 CI workflow reports about a staged file (the parsed manifest, the hash, the icon
# in staging), when it was dispatched and when it reported. `metadata` is empty until stage 1 reports.
class AddStage1ToReleaseUploads < ActiveRecord::Migration[8.1]
  def change
    add_column :release_uploads, :metadata, :jsonb, null: false, default: {}
    add_column :release_uploads, :dispatched_at, :datetime
    add_column :release_uploads, :stage1_at, :datetime
  end
end
