# frozen_string_literal: true

# Z-P12: the pre-launch report's columns on a release. Play keeps an automated pre-launch run's verdict beside
# the release; these columns are that. All nullable/defaulted so the migration is safe on live data (a release
# from before this feature is `not_run`, never a false pass). Mirrors the automated_review_* columns (Z-P2).
class AddPreLaunchReportToReleases < ActiveRecord::Migration[8.1]
  def change
    add_column :releases, :pre_launch_status, :string, default: 'not_run', null: false
    add_column :releases, :pre_launch_verdict, :string
    add_column :releases, :pre_launch_summary, :text
    add_column :releases, :pre_launch_findings, :jsonb, default: [], null: false
    add_column :releases, :pre_launch_run_at, :datetime
  end
end
