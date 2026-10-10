# frozen_string_literal: true

# Z-P11 (Play Console parity, docs/PARITY-KANBAN.md): the table behind `DebugSymbol` — a release's
# deobfuscation material (R8/ProGuard `mapping.txt`, or the native debug symbols zip). This is the
# "trained-upgrade mapping / native symbol upload" Play Console offers beside a release for its vitals
# feed. One row per (release, kind). `checksum` lets a re-upload of the same bytes be a no-op and proves
# a fetched file is the uploaded one. `app_id` is carried alongside `release_id` so the tenant scope
# (`for_tenant`) can join straight to the app without a second hop.
class CreateDebugSymbols < ActiveRecord::Migration[8.1]
  def change
    create_table :debug_symbols do |t|
      t.references :app, foreign_key: true, null: false, index: true
      t.references :release, foreign_key: true, null: false, index: true
      t.string :kind, null: false
      t.string :file, null: false
      t.string :checksum
      t.bigint :size, default: 0, null: false

      t.timestamps
    end

    add_index :debug_symbols, %i[release_id kind], unique: true
  end
end
