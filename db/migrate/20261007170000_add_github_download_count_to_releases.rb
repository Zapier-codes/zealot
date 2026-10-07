# frozen_string_literal: true

# Task 45e: the storage host (GitHub) already counts downloads per file, so Zealot reads that number instead of
# counting clicks itself. Kept per release, and only ever raised (a file that is replaced starts from 0 on the
# host), so an app's total never falls. The index adds the sum to the carried-over base (Task 45a).
class AddGithubDownloadCountToReleases < ActiveRecord::Migration[8.1]
  def change
    change_table :releases, bulk: true do |t|
      t.bigint :github_download_count, null: false, default: 0
      t.datetime :github_download_count_synced_at
    end
  end
end
