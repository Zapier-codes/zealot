# frozen_string_literal: true

# Z-P18 (audit-log slice; Play Console parity, docs/PLAY-PARITY.md): the Console's audit log — the table behind
# `AuditEntry`. Play Console has a changes log; Zealot's two write places logged a line with a
# "stand-in until the audit log of Task 34c exists" comment. This is that log.
#
# Append-only by convention (nothing updates or deletes a row). `subject_type`/`subject_id` is a
# polymorphic pair WITHOUT a foreign key, so removing a key or a token does not erase its history.
# `tenant_id`/`actor_id` are nullable FKs: a job or a console session has no actor, and the default
# host has no tenant row. The indexes match the two reads the admin list makes (newest first, and by
# subject).
class CreateAuditEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_entries do |t|
      t.references :actor, foreign_key: { to_table: :users }, null: true, index: true
      t.references :tenant, foreign_key: true, null: true, index: true
      t.string :action, null: false
      t.string :subject_type, null: false
      t.bigint :subject_id
      t.string :summary_i18n_key
      t.text :summary
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :audit_entries, %i[subject_type subject_id]
    add_index :audit_entries, %i[created_at id]
    add_index :audit_entries, %i[tenant_id created_at]
  end
end
