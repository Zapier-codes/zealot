# frozen_string_literal: true

# Task 32 (continues the board after Task 26's D-store correction): the
# payment slice Task 25 left as a stand-in (`Apps::StoreListingsController
# #mark_paid`). Processed through B-PAY (the operator's self-hosted
# Hyperswitch instance — see HyperswitchClient and handover.md's Task 32
# entry). Field is named `purpose`, not `kind`, specifically to avoid
# colliding in meaning with PublisherProfile#kind (individual/company) —
# these are two different axes on two different records.
#
# Deliberately does NOT store card data: Hyperswitch tokenizes payment
# methods on its own side. What lands here is B-PAY's payment/mandate IDs
# and enough of the response to support a receipt and a support lookup —
# nothing PCI-scoped touches this table.
class CreatePayments < ActiveRecord::Migration[7.1]
  def change
    create_table :payments do |t|
      t.references :app, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true

      # 'listing_fee' (the one-time $14.99, drives App#go_live! on success)
      # or 'maintenance' (the recurring $2/mo charge). Plain string, not
      # enum, so a future purpose doesn't need a migration.
      t.string :purpose, null: false, default: 'listing_fee'

      # Only set for purpose: 'maintenance'. Drives the mandate-charge
      # cadence and what `next_charge_at` steps by.
      t.string :billing_period

      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: 'usd'

      # pending -> succeeded|failed; succeeded can later move to refunded.
      t.string :status, null: false, default: 'pending'

      t.string :hyperswitch_payment_id
      t.string :hyperswitch_mandate_id
      # Encrypted (see Payment#encrypts): last known raw response from
      # B-PAY — cardholder-*adjacent* metadata (masked PAN, billing name)
      # can appear here even though the PAN itself never does.
      t.text :hyperswitch_raw_response

      t.datetime :paid_at

      # Recurring maintenance only: when the next mandate charge is due.
      # A future GoodJob scheduled job reads this, same pattern as the
      # existing GoodJob scheduler already running in this app.
      t.datetime :next_charge_at

      t.timestamps
    end

    add_index :payments, :hyperswitch_payment_id, unique: true
    add_index :payments, :hyperswitch_mandate_id
    add_index :payments, [:app_id, :purpose]
    add_index :payments, :next_charge_at
  end
end
