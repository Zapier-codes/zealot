# frozen_string_literal: true

# Z-P17 (Play Console parity; docs/PARITY-KANBAN.md): one reported crash, ANR or handled exception from an
# app's opt-in crash reporter (the Storeapp half uses ACRA pointed at `POST /api/crash_reports`).
#
# Privacy first: a report is accepted ONLY for an app whose owner turned `crash_reporting_enabled` on, and the
# data collected is the minimum that makes a crash actionable -- message, stack trace, app version, Android
# version, device model. No user id, no advertising id, no free-form "user data" field: a reporter cannot
# smuggle personal data in, because there is no column for it. This is the standing "no telemetry by default"
# rule (PLAY-PARITY.md line 11) made concrete.
#
# Reports are grouped by `fingerprint` (a hash of the normalized message and the top stack frames) so the
# Console shows one row per distinct crash with a count, not one per event. Append-only: there is no destroy
# path, like the audit log.
class CrashReport < ApplicationRecord
  KINDS = %w[crash anr exception].freeze
  # How many leading stack frames the fingerprint folds in. The top frames are what distinguish two crashes
  # with the same message from different causes; the whole trace is too brittle (a line number shift would
  # split one crash into many).
  FINGERPRINT_FRAMES = 5

  belongs_to :app
  belongs_to :release, optional: true
  belongs_to :tenant, optional: true

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :fingerprint, presence: true

  scope :recent, -> { order(occurred_at: :desc, id: :desc) }
  scope :for_tenant, ->(tenant) { where(tenant_id: tenant&.id) }

  # The grouping key: the normalized message line plus the first few stack frames. Deterministic, so the same
  # crash always lands in the same group whatever order reports arrive in.
  def self.fingerprint_for(kind:, message:, stack_trace:)
    first_message = message.to_s.lines.first.to_s.strip
    frames = stack_trace.to_s.lines.map(&:strip).reject(&:empty?).first(FINGERPRINT_FRAMES)
    ::Digest::SHA256.hexdigest([kind.to_s, first_message, frames].join("\n"))
  end

  # The distinct crashes for an app, worst (most frequent) first, with a count and the last time seen. A plain
  # AR group, so it pages with `limit`/`offset` at the caller.
  def self.grouped_for(app)
    where(app_id: app.id)
      .group(:fingerprint, :kind, :message)
      .select('fingerprint, kind, message, COUNT(*) AS occurrences, MAX(occurred_at) AS last_seen_at')
      .order(Arel.sql('COUNT(*) DESC'))
  end
end
