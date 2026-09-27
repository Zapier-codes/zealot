# frozen_string_literal: true

# Task 30b: map channels to Play's tracks (internal, closed, open,
# production) so only production feeds the catalog index -- "the store
# shows production only" (Task 28's principle #4).
#
# Defaults to 'production' rather than 'internal' deliberately: every
# channel that exists today was, in practice, being treated as
# production (App#catalog_releases had no track concept to exclude it
# with), so defaulting new rows to 'internal' would silently drop every
# existing app's releases out of the next published index the moment
# this migration runs. 'production' preserves current behavior for
# everything that already exists; going quieter (internal/closed/open)
# is something an admin now has to choose deliberately per channel, the
# same "nothing disappears from the index just because this slice
# shipped" reasoning 30f's rollout_percentage/rollout_status defaults
# already used for releases.
class AddTrackToChannels < ActiveRecord::Migration[7.1]
  def change
    add_column :channels, :track, :string, null: false, default: 'production'

    add_check_constraint :channels,
      "track IN ('internal', 'closed', 'open', 'production')",
      name: 'channels_track_allowed_values'

    add_index :channels, :track
  end
end
