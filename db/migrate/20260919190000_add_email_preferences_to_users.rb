# frozen_string_literal: true

# Task 12: per-user opt-outs for the platform's automated emails. Existing and
# new users start opted in; every email carries a link to change these.
# (Payment receipts, when they exist, are transactional and have no switch.)
class AddEmailPreferencesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :email_deploys, :boolean, default: true, null: false
    add_column :users, :email_notices, :boolean, default: true, null: false
    add_column :users, :email_campaigns, :boolean, default: true, null: false
  end
end
