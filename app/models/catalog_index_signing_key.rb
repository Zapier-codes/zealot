# frozen_string_literal: true

# Task 27b-ii: the ONE Ed25519 key that signs the catalog index (the file
# D-store reads to know which apps exist). Deliberately separate from
# AndroidSigningKey, which signs the APKs: a leaked index key must not let
# anyone sign an app, and vice versa (the F-Droid split).
#
# A singleton like AndroidSigningKey: a second `create` is refused. The
# private key is encrypted at rest with Active Record Encryption; the public
# key, its id and the last signing time are non-secret and are what get
# published / used for rollback protection. Create it once with
# `rake catalog_index:generate_key`. ROTATION IS NOT DESIGNED YET — replacing
# the key makes every reader re-trust a new public key (Task 27 ❓3).
class CatalogIndexSigningKey < ApplicationRecord
  encrypts :private_key_pem

  validates :private_key_pem, :public_key, :key_id, presence: true
  validates :public_key, uniqueness: true, on: :create
  validate :only_one_record, on: :create

  before_validation :derive_public_fields

  def self.current
    first
  end

  def self.generate!
    create!(private_key_pem: CatalogIndex::Ed25519.generate_pem)
  end

  # @return [String] base64 signature over exactly these bytes
  def sign(data)
    CatalogIndex::Ed25519.sign(private_key_pem, data)
  end

  private

  def derive_public_fields
    return if private_key_pem.blank?

    self.public_key = CatalogIndex::Ed25519.public_key_b64(private_key_pem)
    self.key_id = CatalogIndex::Ed25519.key_id(public_key)
  end

  def only_one_record
    errors.add(:base, :singleton) if CatalogIndexSigningKey.exists?
  end
end
