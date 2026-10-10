# frozen_string_literal: true

# Z-P25 (docs/PARITY-KANBAN.md; docs/UNOFFICIAL-ROUTES.md §1.1 rule 3): the daily canary's state for one
# reverse-engineered Play backend. `ok` means the last fixed read succeeded and is dated; anything else
# means the adapter treats that backend as `degraded` and the UI hides the Play panel rather than showing
# a broken one. The row is created on first use; there is one per backend name.
class PlaySourceState < ApplicationRecord
  BACKENDS = %w[gplayapi playstoreapi].freeze
  STATUSES = %w[unknown ok degraded].freeze

  validates :backend, presence: true, inclusion: { in: BACKENDS }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :fresh, ->(within = 36.hours) { where('last_ok_at >= ?', within.ago) }

  # A backend is usable when its last check passed and is not older than `max_age` (the canary runs daily;
  # 36h tolerates one missed run before the adapter says degraded). An unknown backend is not usable — the
  # safe default is "not proven", never "assume fine".
  def usable?(max_age: 36.hours, now: Time.current)
    status == 'ok' && last_ok_at.present? && last_ok_at >= now - max_age
  end

  # The canary's two outcomes. `ok` dates the success; `degraded` keeps the last success time (so the age
  # is still visible) and records why. Both are best-effort and never raise into the canary's caller.
  def self.record!(backend, ok:, error: nil, now: Time.current)
    state = find_or_initialize_by(backend: backend)
    state.status = ok ? 'ok' : 'degraded'
    state.last_checked_at = now
    state.last_ok_at = now if ok
    state.error = ok ? nil : error.to_s.truncate(2_000)
    state.save!
    state
  end
end
