# frozen_string_literal: true

# Task 42i: the hosted checkout page needs the B-PAY client secret of a still-pending payment, but B-PAY's
# secret cannot be read back, so the pending Payment keeps it (encrypted, like hyperswitch_raw_response) until
# the payment succeeds or fails, when it is cleared. Additive; NULL for every existing row.
class AddClientSecretToPayments < ActiveRecord::Migration[8.1]
  def change
    add_column :payments, :client_secret, :text
  end
end
