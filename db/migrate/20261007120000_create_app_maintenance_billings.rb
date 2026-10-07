# frozen_string_literal: true

# Task 42g: per-app maintenance billing. The listing fee is a one-time payment; the maintenance fee is charged
# per app, $2 per month, so each app needs its own billing record: what it is charged, how far it is paid up and
# when the next charge is due. One row per app (unique index); the payer is the app's owner at the time the
# record is created. Additive: nothing reads or writes this table yet (the webhook and the charge job come in
# the next slice), and existing Payment rows are untouched.
class CreateAppMaintenanceBillings < ActiveRecord::Migration[8.1]
  def change
    create_table :app_maintenance_billings do |t|
      t.references :app, null: false, foreign_key: true, index: { unique: true }
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: 'pending'
      t.string :billing_period, null: false, default: 'monthly'
      t.integer :amount_cents, null: false, default: 200
      t.string :currency, null: false, default: 'usd'
      t.string :hyperswitch_mandate_id
      t.bigint :last_payment_id
      t.datetime :paid_through
      t.datetime :next_charge_at
      t.timestamps
    end
    add_index :app_maintenance_billings, :next_charge_at
    add_index :app_maintenance_billings, :status
    add_check_constraint :app_maintenance_billings, 'amount_cents > 0',
                         name: 'app_maintenance_billings_amount_positive'
  end
end
