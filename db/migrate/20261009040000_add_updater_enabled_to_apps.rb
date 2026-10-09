# frozen_string_literal: true

# Task 47e: the publisher's switch for the injected updater (Task 47). On by default: an app published through
# Zealot is adopted and patched without any work from the publisher, and the publisher can turn it off. The
# injection step (47c) reads it when a release is built, so a change applies from the next release.
class AddUpdaterEnabledToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :updater_enabled, :boolean, default: true, null: false
  end
end
