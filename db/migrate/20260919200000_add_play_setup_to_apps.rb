# frozen_string_literal: true

# Task 18: Google Play only learns an app's applicationId from the first
# bundle uploaded to Play Console — it is NOT a "create app" field there.
# So Zealot records the *intended* applicationId per App (verified against
# every Play-targeted AAB, adopted from the first one when left blank) and
# the result of the last automated Play-side check, so the one manual step
# (the first upload of a new app) is visible and Zealot can
# resume on its own once it is done.
class AddPlaySetupToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :play_package_name, :string
    add_column :apps, :play_setup_status, :string, null: false, default: 'unchecked'
    add_column :apps, :play_setup_message, :text
    add_column :apps, :play_setup_checked_at, :datetime

    # One Play listing per applicationId; NULL (not yet known) may repeat.
    add_index :apps, :play_package_name, unique: true, where: 'play_package_name IS NOT NULL'
  end
end
