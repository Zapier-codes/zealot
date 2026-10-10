# frozen_string_literal: true

# Z-P2/Z-P3/Z-P4 (Play Console parity): the machine review verdict. Play runs automated pre-review checks
# and shows the result on the app before a person ever looks. Zealot's runner (ReleaseChecks::AutomatedReview,
# driven by AutomatedReviewJob) records its verdict here so the Console can surface it (Z-P3) and no human
# has to read every upload.
#
#   automated_review_status   not_run | running | done | failed   (the runner's own lifecycle)
#   automated_review_verdict   pass | flag | reject | nil          (what a person would act on)
#   automated_review_reasons   jsonb array of {code, message, severity}
#   automated_review_trackers  jsonb array of the third-party SDKs found (Z-P4)
#   automated_reviewed_at      when the verdict was last written
class AddAutomatedReviewToReleases < ActiveRecord::Migration[8.1]
  def change
    add_column :releases, :automated_review_status, :string, default: 'not_run', null: false
    add_column :releases, :automated_review_verdict, :string
    add_column :releases, :automated_review_reasons, :jsonb, default: [], null: false
    add_column :releases, :automated_review_trackers, :jsonb, default: [], null: false
    add_column :releases, :automated_reviewed_at, :datetime

    add_index :releases, :automated_review_status
    add_index :releases, :automated_review_verdict
  end
end
