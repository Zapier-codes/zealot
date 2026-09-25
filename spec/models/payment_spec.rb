# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Payment do
  def make_user(name)
    User.create!(email: "#{name}@example.com", username: name, password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: :developer)
  end

  let(:app) { App.create!(name: 'Paid app') }
  let(:user) { make_user('payer') }

  def build_payment(**attrs)
    described_class.new({ app: app, user: user, purpose: 'listing_fee', amount_cents: 1499,
                          currency: 'usd' }.merge(attrs))
  end

  it 'is valid with the minimum listing_fee attributes' do
    expect(build_payment).to be_valid
  end

  it 'requires billing_period only for purpose: maintenance' do
    listing = build_payment(billing_period: 'monthly')
    expect(listing).not_to be_valid
    expect(listing.errors[:billing_period]).to be_present

    maintenance = build_payment(purpose: 'maintenance', billing_period: 'monthly', amount_cents: 200)
    expect(maintenance).to be_valid
  end

  it 'rejects an unknown purpose, billing_period or status' do
    expect(build_payment(purpose: 'bogus')).not_to be_valid
    expect(build_payment(purpose: 'maintenance', billing_period: 'weekly')).not_to be_valid
    expect(build_payment(status: 'bogus')).not_to be_valid
  end

  it 'requires a positive integer amount_cents' do
    expect(build_payment(amount_cents: 0)).not_to be_valid
    expect(build_payment(amount_cents: -100)).not_to be_valid
  end

  describe '#mark_succeeded!' do
    it 'sets status, ids, paid_at and the encrypted raw response' do
      payment = build_payment.tap(&:save!)

      payment.mark_succeeded!(hyperswitch_payment_id: 'pay_123', mandate_id: 'mandate_1', raw: '{"ok":true}')

      expect(payment).to be_succeeded
      expect(payment.hyperswitch_payment_id).to eq('pay_123')
      expect(payment.hyperswitch_mandate_id).to eq('mandate_1')
      expect(payment.hyperswitch_raw_response).to eq('{"ok":true}')
      expect(payment.paid_at).to be_present
    end

    it 'keeps the existing mandate_id when none is passed' do
      payment = build_payment(hyperswitch_mandate_id: 'mandate_old').tap { |p| p.save!(validate: false) }

      payment.mark_succeeded!(hyperswitch_payment_id: 'pay_123')

      expect(payment.hyperswitch_mandate_id).to eq('mandate_old')
    end
  end

  describe '#mark_failed!' do
    it 'sets status to failed without touching paid_at' do
      payment = build_payment.tap(&:save!)

      payment.mark_failed!(raw: '{"error":"declined"}')

      expect(payment.status).to eq('failed')
      expect(payment.paid_at).to be_nil
    end
  end

  describe '.due_for_charge' do
    it 'only returns succeeded maintenance payments past their next_charge_at' do
      due = build_payment(purpose: 'maintenance', billing_period: 'monthly', amount_cents: 200,
                          status: 'succeeded', next_charge_at: 1.day.ago).tap { |p| p.save!(validate: false) }
      build_payment(purpose: 'maintenance', billing_period: 'monthly', amount_cents: 200,
                    status: 'succeeded', next_charge_at: 1.day.from_now).tap { |p| p.save!(validate: false) }
      build_payment(purpose: 'listing_fee', status: 'succeeded', next_charge_at: 1.day.ago).tap { |p| p.save!(validate: false) }

      expect(described_class.due_for_charge).to contain_exactly(due)
    end
  end
end
