# frozen_string_literal: true

# Z-P10 / Task 50: the revenue-report half. Play shows a developer what their apps earned and what has been
# paid out; this assembles both from what Zealot already stores, with no invented numbers:
#
#   * earnings  — `payments` rows that succeeded (the listing fee and each maintenance cycle). A row counts
#                 on the day it was actually paid (`paid_at`), falling back to when it was created.
#   * payouts   — `payouts` rows, grouped by their B-Pay status.
#   * outstanding — succeeded earnings minus succeeded payouts, floored at zero. This is the honest ceiling
#                 on what could be paid next; it is NOT a promise (refunds, fees and connector rules are
#                 B-Pay's, not ours), which is why it is labelled "available to pay out", not "owed".
#
# Pure and dependency-free apart from the scope it is handed, so a spec can drive it with plain rows. The
# controller passes a publisher-scoped relation (see Apps::RevenuesController).
class RevenueReport
  Row = Struct.new(:label, :cents, :count, keyword_init: true)
  Cell = Struct.new(:period, :cents, :count, keyword_init: true)

  attr_reader :earnings_cents, :earning_count, :by_app, :by_purpose, :by_period,
              :payouts_cents, :by_payout_status, :payout_count, :recent_payouts

  # @param payments [ActiveRecord::Relation] refunded/failed rows are ignored; only successes count as earnings
  # @param payouts  [ActiveRecord::Relation] the same publisher's payout rows
  def initialize(payments:, payouts:, months: 6, now: Time.current)
    @now = now
    succeeded = payments.select(&:succeeded?)
    @earnings_cents = succeeded.sum(&:amount_cents)
    @earning_count = succeeded.size

    @by_app = group_rows(succeeded, label: ->(p) { p.app&.name.presence || "App ##{p.app_id}" })
    @by_purpose = group_rows(succeeded, label: ->(p) { p.purpose })
    @by_period = period_cells(succeeded, months: months)

    @by_payout_status = payouts.group_by(&:status).transform_values do |rows|
      Row.new(label: nil, cents: rows.sum(&:amount_cents), count: rows.size)
    end
    @payout_count = payouts.size
    @payouts_cents = payouts.select { |p| p.status == 'succeeded' }.sum(&:amount_cents)
    @recent_payouts = payouts.sort_by { |p| [ p.created_at, p.id ] }.reverse.first(10)
  end

  # What could be paid next: earnings that no successful payout has covered yet. Never negative.
  def outstanding_cents
    [ earnings_cents - payouts_cents, 0 ].max
  end

  private

  def group_rows(payments, label:)
    payments.group_by { |p| label.call(p) }
            .map { |name, rows| Row.new(label: name, cents: rows.sum(&:amount_cents), count: rows.size) }
            .sort_by { |row| -row.cents }
  end

  # The last `months` calendar months, oldest first, each with the earnings that landed in it. A month with
  # nothing is still a row (a zero), so the report shows a quiet month as zero rather than omitting it.
  def period_cells(payments, months:)
    buckets = (0...months).map do |back|
      month = (@now.to_date << back)
      [ month.beginning_of_month, { cents: 0, count: 0 } ]
    end.to_h

    payments.each do |payment|
      date = (payment.paid_at || payment.created_at)&.to_date
      next if date.nil?

      key = date.beginning_of_month
      bucket = buckets[key]
      next if bucket.nil? # outside the window; the by_app/by_purpose rows still count it

      bucket[:cents] += payment.amount_cents
      bucket[:count] += 1
    end

    buckets.map { |month, agg| Cell.new(period: month, cents: agg[:cents], count: agg[:count]) }
  end
end
