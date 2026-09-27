# frozen_string_literal: true

# Task 32a: staged rollout, Play-Console-parity (see handover.md Task 32).
# Adds the two columns needed to gate a release to a percentage of installs
# the same way Play does it -- a rollout_percentage (1-100, default 100 so
# every existing and newly-created release stays fully available unless an
# admin deliberately narrows it) and a rollout_status the admin flips
# to control the ramp without re-uploading a build (active while ramping,
# complete once it's been pushed to 100 and there's no reason to keep
# computing a bucket, halted to freeze/roll back a bad rollout without
# discarding the percentage it was halted at).
#
# Deliberately separate from the existing `status` enum
# catalog_index_v2.schema.json already reserves on each version entry
# (available/halted/pulled, owned by the still-open Task 27f) -- that one is
# a release's overall lifecycle (is this build offered at all), this one is
# what fraction of installs see it once it is. A release can be
# rollout_status halted while its 27f status is still 'available': halting a
# rollout freezes it at its current percentage rather than pulling the
# release entirely, same distinction Play itself draws between "halt
# rollout" and "unpublish."
class AddStagedRolloutToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :rollout_percentage, :integer, default: 100, null: false
    add_column :releases, :rollout_status, :string, default: 'active', null: false

    add_check_constraint :releases,
      'rollout_percentage >= 0 AND rollout_percentage <= 100',
      name: 'releases_rollout_percentage_range'

    add_index :releases, :rollout_status
  end
end
