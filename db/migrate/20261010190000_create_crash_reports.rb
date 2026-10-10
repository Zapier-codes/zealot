# frozen_string_literal: true

# Z-P17 (Play Console parity; docs/PARITY-KANBAN.md): the opt-in crash/vitals endpoint.
#
#   * `apps.crash_reporting_enabled` -- the per-app opt-in. OFF by default; nothing is accepted for an app
#     until its owner turns it on (the standing "no telemetry by default" rule, PLAY-PARITY.md line 11).
#   * `crash_reports` -- one row per reported crash/ANR/exception, tenant-scoped like everything else, grouped
#     by a `fingerprint` (a hash of the message and the top stack frames) so the Console can show "this crash
#     happened N times" instead of N rows.
#
# An app's release may be nullable: a crash can arrive from a build Zealot never saw (a debug build), and it
# is still worth recording. A crash report is kept append-only (no destroy path) like the audit log.
class CreateCrashReports < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :crash_reporting_enabled, :boolean, default: false, null: false

    create_table :crash_reports do |t|
      t.references :app, null: false, foreign_key: true
      t.references :release, null: true, foreign_key: true
      t.bigint :tenant_id
      t.string :kind, null: false, default: 'crash'
      t.string :fingerprint, null: false
      t.text :message
      t.text :stack_trace
      t.string :app_version_name
      t.string :app_version_code
      t.string :android_version
      t.string :device_model
      t.string :report_id
      t.datetime :occurred_at
      t.timestamps
    end

    add_index :crash_reports, %i[app_id fingerprint]
    add_index :crash_reports, :occurred_at
    add_index :crash_reports, :tenant_id
  end
end
