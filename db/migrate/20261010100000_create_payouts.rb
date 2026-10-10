# frozen_string_literal: true

# Z-P10 / Task 50 (Play Console parity): revenue reporting + payouts. Play shows a developer what their apps
# earned and pays it out; the reporting half reads what Zealot already stores (the `payments` table), and the
# paying half calls the program's own payments service, B-Pay-backend (`Zapier-codes/B-Pay-backend`), whose
# payout routes are in its default build (see docs/UNOFFICIAL-ROUTES.md section 8).
#
# One row per payout attempt against B-Pay. `bpay_payout_id` is the id B-Pay hands back and the key every
# later call (confirm/fulfill/cancel/manual-update) addresses; `raw_response` is the last full body, kept the
# same way Payment keeps `hyperswitch_raw_response` (sensitive, so encrypted, not plaintext). Amounts are
# integer cents, like Payment. `status` mirrors B-Pay's own payout status vocabulary.
class CreatePayouts < ActiveRecord::Migration[8.1]
  def change
    create_table :payouts do |t|
      t.references :publisher_profile, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true

      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: 'usd'
      t.string :status, null: false, default: 'created'
      t.string :bpay_payout_id
      t.string :connector
      t.string :payout_method_id
      t.string :customer_id
      t.string :merchant_id
      t.text :raw_response
      t.string :failure_reason
      t.datetime :confirmed_at
      t.datetime :fulfilled_at
      t.datetime :cancelled_at

      t.timestamps
    end

    add_index :payouts, :bpay_payout_id, unique: true
    add_index :payouts, :status
  end
end
