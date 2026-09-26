# frozen_string_literal: true

# Task 31a: real backing for the v2 index's per-app `sponsored_slots[]`
# field (reserved since 29a/29b, hardcoded to `[]` by the serializer until
# now). Deliberately the same bare `{starts_at, ends_at}` shape the schema
# already committed to -- the app's own existing listing is the creative,
# no separate name/summary/copy to author here (see the cross-repo
# "sponsored placement" decision recorded in D-store's HANDOVER.md, which
# this table is now the Zealot-side half of).
class CreateSponsoredSlots < ActiveRecord::Migration[7.1]
  def change
    create_table :sponsored_slots do |t|
      t.references :app, null: false, foreign_key: true
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false

      t.timestamps
    end

    add_index :sponsored_slots, %i[app_id starts_at]
  end
end
