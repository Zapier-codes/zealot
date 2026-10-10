# frozen_string_literal: true

# Z-P25 (docs/PARITY-KANBAN.md): the daily canary's record. One row per backend ("gplayapi", "playstoreapi")
# holding the last check's status, so `PlayCatalogSource` can say a backend is `degraded` and the UI can
# hide the Play panel — turning "has not broken yet" into a measured, dated fact (UNOFFICIAL-ROUTES §1.1
# rule 3). This table is tiny and append/upsert-only; it is never a source of catalogue truth.
class CreatePlaySourceStates < ActiveRecord::Migration[8.1]
  def change
    create_table :play_source_states do |t|
      t.string :backend, null: false
      t.string :status, null: false, default: 'unknown' # unknown | ok | degraded
      t.datetime :last_checked_at
      t.datetime :last_ok_at
      t.text :error
      t.timestamps
    end
    add_index :play_source_states, :backend, unique: true
  end
end
