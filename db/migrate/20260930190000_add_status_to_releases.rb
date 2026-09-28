# frozen_string_literal: true

# Task 27f-a: a release's overall lifecycle in our own store, distinct from the staged-rollout
# ramp (`rollout_status`, Task 30f). `available` is what every release is today (the default, so
# nothing disappears from the index when this migration runs); `held` keeps a release out of the
# signed index until it is released (Play's managed publishing); `halted` and `pulled` stay in the
# index's `versions[]` so a store client can stop offering them and roll back. The index schema
# already reserves `available | halted | pulled` per version; `held` is never published, because a
# held release is left out of `versions[]` altogether.
class AddStatusToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :status, :string, default: 'available', null: false

    add_check_constraint :releases,
                         "status = 'available' OR status = 'held' OR status = 'halted' OR status = 'pulled'",
                         name: 'releases_status_known'

    add_index :releases, :status
  end
end
