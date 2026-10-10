# frozen_string_literal: true

require 'rails_helper'

# Z-P10 / Task 50: the revenue report's arithmetic (the pure half). Written, NOT run in the sandbox that wrote
# it (no bundle there); plain doubles, like base_stats_spec.rb, because the point is the rules, not the DB.
RSpec.describe RevenueReport do
  NOW = Time.zone.parse('2026-10-10 12:00:00')

  def payment(cents:, purpose: 'listing_fee', stat: 'succeeded', paid_at: nil, created_at: NOW, app_name: 'App')
    app = double('app', name: app_name)
    double('payment', amount_cents: cents, purpose: purpose, status: stat,
                      paid_at: paid_at, created_at: created_at, app: app, app_id: 1,
                      succeeded?: stat == 'succeeded')
  end

  def payout(cents:, stat: 'succeeded', created_at: NOW)
    double('payout', amount_cents: cents, status: stat, created_at: created_at, id: 1)
  end

  it 'totals only succeeded payments as earnings and ignores failed/refunded ones' do
    report = described_class.new(
      payments: [ payment(cents: 1499), payment(cents: 200, purpose: 'maintenance'),
                  payment(cents: 999, stat: 'failed'), payment(cents: 500, stat: 'refunded') ],
      payouts: [], now: NOW
    )
    expect(report.earnings_cents).to eq(1699)
    expect(report.earning_count).to eq(2)
  end

  it 'groups earnings by app and by purpose, largest first' do
    report = described_class.new(
      payments: [ payment(cents: 100, app_name: 'A'), payment(cents: 300, app_name: 'A'),
                  payment(cents: 200, app_name: 'B') ],
      payouts: [], now: NOW
    )
    expect(report.by_app.map(&:label)).to eq(%w[A B])
    expect(report.by_app.first.cents).to eq(400)
    expect(report.by_purpose.map(&:label)).to eq(%w[listing_fee])
  end

  it 'buckets earnings into the last N months, oldest first, keeping empty months as zero' do
    report = described_class.new(
      payments: [ payment(cents: 100, paid_at: Time.zone.parse('2026-10-02')),
                  payment(cents: 300, paid_at: Time.zone.parse('2026-08-15')) ],
      payouts: [], months: 3, now: NOW
    )
    expect(report.by_period.map { |c| c.period.strftime('%Y-%m') }).to eq(%w[2026-08 2026-09 2026-10])
    expect(report.by_period.map(&:cents)).to eq([ 300, 0, 100 ])
  end

  it 'counts only succeeded payouts as paid out and floors outstanding at zero' do
    report = described_class.new(
      payments: [ payment(cents: 1000) ],
      payouts: [ payout(cents: 400), payout(cents: 9000) ], now: NOW
    )
    expect(report.payouts_cents).to eq(400)
    expect(report.outstanding_cents).to eq(600)

    overpaid = described_class.new(payments: [ payment(cents: 100) ], payouts: [ payout(cents: 500) ], now: NOW)
    expect(overpaid.outstanding_cents).to eq(0)
  end
end
