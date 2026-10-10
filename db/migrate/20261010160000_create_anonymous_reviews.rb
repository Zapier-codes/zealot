# frozen_string_literal: true

# Z-P9 (Play Console parity, docs/PLAY-PARITY.md principle 2): anonymous reviews. A person leaves a review
# from the Appstore client with a device-bound pseudonymous key made on the phone (Android Keystore); the
# website accepts the same review with a proof-of-work token. There is no account, no email, no profile.
#
# Three tables, one per thing the review path needs to remember:
#
#   reviewer_keys      one row per device-bound key. The phone generates an EC key in the Android Keystore
#                      (hardware-backed where the device has it) and presents the certificate chain, so the
#                      key is one device's and cannot be copied between phones. `fingerprint` (SHA-256 of the
#                      public key) is the pseudonym; `attestation_verified` is true only when the chain
#                      proved a real Android key (AndroidKeyAttestation). A key is never required to write a
#                      review -- it only earns the "verified install" mark -- so an unregistered fingerprint
#                      is still accepted (the review is simply unmarked).
#   anonymous_reviews  one row per (app, reviewer_key): the review itself. Re-submitting for the same app
#                      updates this row, so "one editable review per key per app" is a uniqueness constraint,
#                      not application logic.
#   review_challenges  a one-time proof-of-work challenge (ALTCHA shape). Issued by GET, consumed by POST;
#                      `solved_at` set once so a token cannot be replayed.
#
# `rate_hits` is deliberately NOT a table: per-key and per-network limits are counted from the reviews and
# challenges already stored (see AnonymousReviewRateLimit), so there is nothing to keep in sync.
class CreateAnonymousReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :reviewer_keys do |t|
      t.string :fingerprint, null: false              # SHA-256 hex of the device public key
      t.text :public_key_pem                          # the SPKI, kept so a signature can be re-checked
      t.boolean :attestation_verified, default: false, null: false
      t.datetime :attestation_verified_at
      t.string :attestation_status, default: 'unverified', null: false
      t.datetime :last_seen_at
      t.bigint :tenant_id
      t.timestamps
    end
    add_index :reviewer_keys, %i[fingerprint tenant_id], unique: true

    create_table :anonymous_reviews do |t|
      t.references :app, null: false, foreign_key: true
      t.references :reviewer_key, null: false, foreign_key: true
      t.integer :rating, null: false
      t.text :body
      t.boolean :verified_install, default: false, null: false
      t.string :version_code                          # the installed version the mark is about
      t.string :status, default: 'published', null: false  # published / pending / rejected
      t.string :moderation_reason
      t.integer :helpful_count, default: 0, null: false
      t.bigint :tenant_id
      t.timestamps
    end
    add_index :anonymous_reviews, %i[app_id reviewer_key_id], unique: true
    add_index :anonymous_reviews, %i[app_id status]

    create_table :review_challenges do |t|
      t.string :nonce, null: false                    # the server nonce; the client solves a hash over it
      t.string :salt, null: false                     # random, per challenge; part of the solved hash
      t.integer :cost, null: false, default: 3        # leading zero nibbles the solution must have
      t.datetime :solved_at                           # set once; a token cannot be replayed
      t.datetime :expires_at, null: false
      # A salted, daily-rotating digest of the client's network address -- enough to rate-limit per network
      # without ever storing the address itself (principle 2: no tracking).
      t.string :ip_digest
      t.bigint :tenant_id
      t.timestamps
    end
    add_index :review_challenges, :nonce, unique: true
    add_index :review_challenges, %i[ip_digest created_at]
  end
end
