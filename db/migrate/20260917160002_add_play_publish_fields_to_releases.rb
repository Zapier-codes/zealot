# frozen_string_literal: true

# Task #7 proper: fields to track the *actual* Play Developer API publish
# call, separate from task #11's play_approval_status (which only tracks
# whether an admin signed off — see Release model comments). A release can
# be play_approval_approved without ever having been published (the job
# hasn't run yet, or it failed and needs a retry); these columns are what
# distinguish those states.
class AddPlayPublishFieldsToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :play_publish_status, :string, null: false, default: 'not_published'
    add_column :releases, :play_publish_error, :text
    add_column :releases, :play_published_at, :datetime
    add_column :releases, :play_edit_id, :string

    add_index :releases, :play_publish_status

    # Which Play Console track ("internal", "alpha", "beta", "production")
    # a given App's releases go to. Per-App because different apps in this
    # org's Play Console account may legitimately be at different rollout
    # stages; unlike the signing key/credentials, there's no reason this
    # would be shared. Defaults to "internal" — the safest choice for an
    # app publishing here for the first time, since the handover notes the
    # *first* listing/track setup is manual and only *subsequent* releases
    # are automated. An admin can raise it to a wider track once an app
    # has one manually.
    add_column :apps, :play_publish_track, :string, null: false, default: 'internal'
  end
end
