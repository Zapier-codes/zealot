# frozen_string_literal: true

# Z-P6 + Z-P7 (Play Console parity, PARITY-KANBAN).
#
# Z-P6 -- the store privacy-policy URL, plus the reviewer-access instructions. The account-deletion URL is
# already covered by `data_safety_deletion_url` (Z-P5). `privacy_policy_url` is a public listing fact and is
# published under `listing.privacy_policy_url`. `reviewer_access_instructions` is deliberately NOT published
# in the signed index: it routinely holds a throwaway test account and password for reviewers, and the index
# is a public, signed, world-readable document. It stays a backend column the Console shows to the owner.
#
# Z-P7 -- developer-verification readiness. Google's Android developer verification (enforced from
# 2026-09-30 in Brazil/Indonesia/Singapore/Thailand, global 2027) needs the app's package and the org signing
# key registered. These four boolean/date columns record that per app; the serializer publishes them as the
# `verification` block so Storeapp and D-Store can show the status without re-deriving it.
class AddPolicyAndVerificationFieldsToApps < ActiveRecord::Migration[8.1]
  def change
    change_table :apps, bulk: true do |t|
      # Z-P6
      t.string :privacy_policy_url
      t.text :reviewer_access_instructions

      # Z-P7 -- all four are "not yet checked" until an admin records otherwise, so the defaults are the
      # honest unset state (false / null), never a guessed "verified".
      t.boolean :developer_verified, default: false, null: false
      t.boolean :verification_key_registered, default: false, null: false
      t.boolean :verification_package_registered, default: false, null: false
      t.datetime :verification_checked_at
    end
  end
end
