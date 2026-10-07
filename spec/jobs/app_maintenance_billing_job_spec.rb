# frozen_string_literal: true

require 'rails_helper'

# Task 42h: the recurring maintenance charge and the lapse rule. B-PAY is stubbed (HyperswitchClient); the job
# only starts a charge, so these examples check the Payment it creates and what it leaves alone. NOT run.
RSpec.describe AppMaintenanceBillingJob do
  let(:user) do
    User.create!(email: 'job@example.com', username: 'jobuser', password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: :developer)
  end
  let(:app) { App.create!(name: 'Billed app', listing_status: :live, listed_at: Time.current) }
  let(:mandate) { 'mandate_1' }
  let!(:billing) do
    AppMaintenanceBilling.create!(app: app, user: user, status: 'active', hyperswitch_mandate_id: mandate,
                                  paid_through: 1.hour.ago, next_charge_at: 1.minute.ago)
  end

  before { allow(HyperswitchClient).to receive(:configured?).and_return(true) }

  it 'starts one $2 off-session charge on the stored mandate for a due billing' do
    allow(HyperswitchClient).to receive(:charge_mandate)
      .and_return(HyperswitchClient::Result.new(payment_id: 'pay_m1', status: 'processing', raw: {}))

    described_class.perform_now

    expect(HyperswitchClient).to have_received(:charge_mandate)
      .with(amount_cents: 200, currency: 'usd', customer_id: "app-#{app.id}", mandate_id: mandate)
    payment = Payment.find_by!(hyperswitch_payment_id: 'pay_m1')
    expect(payment).to have_attributes(purpose: 'maintenance', status: 'pending', amount_cents: 200)
    expect(billing.reload.paid_through).to be < Time.current # only the webhook extends it
  end

  it 'does not charge a second time while one is pending' do
    Payment.create!(app: app, user: user, purpose: 'maintenance', billing_period: 'monthly', amount_cents: 200,
                    currency: 'usd', status: 'pending', hyperswitch_payment_id: 'pay_m0')
    allow(HyperswitchClient).to receive(:charge_mandate)

    described_class.perform_now

    expect(HyperswitchClient).not_to have_received(:charge_mandate)
  end

  it 'records a failed Payment and retries tomorrow when B-PAY refuses' do
    allow(HyperswitchClient).to receive(:charge_mandate)
      .and_raise(HyperswitchClient::PermanentError, 'mandate not found')

    described_class.perform_now

    expect(Payment.where(app_id: app.id, purpose: 'maintenance').pluck(:status)).to eq(['failed'])
    expect(billing.reload.status).to eq('past_due')
    expect(billing.next_charge_at).to be_within(1.minute).of(1.day.from_now)
  end

  it 'skips a billing that has no mandate' do
    billing.update!(hyperswitch_mandate_id: nil)
    allow(HyperswitchClient).to receive(:charge_mandate)

    described_class.perform_now

    expect(HyperswitchClient).not_to have_received(:charge_mandate)
  end

  it 'suspends an app unpaid past the grace period' do
    billing.update!(status: 'past_due', paid_through: (AppMaintenanceBilling::GRACE_DAYS + 1).days.ago,
                    next_charge_at: 1.day.from_now)

    described_class.perform_now

    expect(app.reload).to be_listing_suspended
    expect(billing.reload.lapsed_at).to be_present
  end

  it 'leaves an app inside the grace period live' do
    billing.update!(status: 'past_due', paid_through: 2.days.ago, next_charge_at: 1.day.from_now)

    described_class.perform_now

    expect(app.reload).to be_listing_live
  end

  it 'never touches an app with no billing record, such as one an admin made live by hand' do
    manual = App.create!(name: 'Hand-listed app', listing_status: :live, listed_at: 40.days.ago)
    allow(HyperswitchClient).to receive(:charge_mandate)

    described_class.perform_now

    expect(manual.reload).to be_listing_live
    expect(Payment.where(app_id: manual.id)).to be_empty
  end
end
