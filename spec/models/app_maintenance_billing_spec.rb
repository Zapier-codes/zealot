# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AppMaintenanceBilling do
  let(:user) do
    User.create!(email: 'maint@example.com', username: 'maint', password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: :developer)
  end
  let(:app) { App.create!(name: 'Maintained app') }

  def build_billing(**attrs)
    described_class.new({ app: app, user: user }.merge(attrs))
  end

  it 'defaults to pending, monthly, 200 cents, usd' do
    billing = build_billing
    expect(billing).to be_valid
    expect([billing.status, billing.billing_period, billing.amount_cents, billing.currency])
      .to eq(['pending', 'monthly', 200, 'usd'])
    expect(described_class::MONTHLY_FEE_CENTS).to eq(200)
  end

  it 'allows one record per app' do
    build_billing.save!
    expect(build_billing).not_to be_valid
  end

  it 'moves paid_through forward one month when a payment is recorded' do
    billing = build_billing.tap(&:save!)
    payment = Payment.create!(app: app, user: user, purpose: 'maintenance', billing_period: 'monthly',
                              amount_cents: 200, currency: 'usd', status: 'succeeded',
                              hyperswitch_payment_id: 'pay_test_1')
    billing.record_payment!(payment)
    expect(billing.status).to eq('active')
    expect(billing.last_payment_id).to eq(payment.id)
    expect(billing.paid_through).to be_within(1.minute).of(1.month.from_now)
  end

  it 'does not lose already-paid days on an early payment' do
    billing = build_billing(paid_through: 10.days.from_now).tap(&:save!)
    payment = Payment.create!(app: app, user: user, purpose: 'maintenance', billing_period: 'monthly',
                              amount_cents: 200, currency: 'usd', status: 'succeeded',
                              hyperswitch_payment_id: 'pay_test_2')
    billing.record_payment!(payment)
    expect(billing.paid_through).to be_within(1.minute).of(10.days.from_now + 1.month)
  end

  it 'ignores a payment it already recorded' do
    billing = build_billing.tap(&:save!)
    payment = Payment.create!(app: app, user: user, purpose: 'maintenance', billing_period: 'monthly',
                              amount_cents: 200, currency: 'usd', status: 'succeeded',
                              hyperswitch_payment_id: 'pay_test_3')
    billing.record_payment!(payment)
    first = billing.paid_through
    billing.record_payment!(payment)
    expect(billing.reload.paid_through).to be_within(1.second).of(first)
  end

  describe 'lapse (Task 42h)' do
    let(:app) { App.create!(name: 'Lapsing app', listing_status: :live, listed_at: Time.current) }

    it 'lists only billings unpaid more than the grace period past paid_through' do
      fresh = build_billing(status: 'active', paid_through: 2.days.ago).tap(&:save!)
      expect(described_class.lapse_candidates).not_to include(fresh)
      fresh.update!(paid_through: (described_class::GRACE_DAYS + 1).days.ago)
      expect(described_class.lapse_candidates).to include(fresh)
    end

    it 'suspends a live app and records the lapse; a later payment brings it back' do
      billing = build_billing(status: 'past_due', paid_through: 10.days.ago).tap(&:save!)
      expect(billing.suspend_for_lapse!).to be_truthy
      expect(app.reload).to be_listing_suspended
      expect(billing.reload.lapsed_at).to be_present

      payment = Payment.create!(app: app, user: user, purpose: 'maintenance', billing_period: 'monthly',
                                amount_cents: 200, currency: 'usd', status: 'succeeded',
                                hyperswitch_payment_id: 'pay_test_4')
      billing.record_payment!(payment)
      expect(app.reload).to be_listing_live
      expect(billing.reload.lapsed_at).to be_nil
    end

    it 'does not bring back an app it did not suspend' do
      app.suspend! # suspended for some other reason, so no lapsed_at on the billing
      billing = build_billing(status: 'active', paid_through: 1.day.from_now).tap(&:save!)
      payment = Payment.create!(app: app, user: user, purpose: 'maintenance', billing_period: 'monthly',
                                amount_cents: 200, currency: 'usd', status: 'succeeded',
                                hyperswitch_payment_id: 'pay_test_5')
      billing.record_payment!(payment)
      expect(app.reload).to be_listing_suspended
    end
  end
end
