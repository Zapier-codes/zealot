# frozen_string_literal: true

# The keystore used ONLY to sign an AAB immediately before it's uploaded
# to Google Play (task #7). Deliberately a separate key/table from
# AndroidSigningKey (task #5, which signs everything this org hands
# directly to its own users) — see this session's handover.md entry and
# 20260917160000_create_play_upload_keys.rb for why: key-material
# separation between "signs what we distribute ourselves" and "signs what
# we hand to a third-party platform" is kept regardless of Play App
# Signing's own re-signing step, on the same industry-standard
# compartmentalization grounds AndroidSigningKey's own comments already
# apply to per-App vs. org-wide scoping — this is a different axis
# (destination) rather than that one (which App).
#
# Structurally this is AndroidSigningKey's shape, unchanged, just backed
# by its own table. Kept as its own model rather than an STI/shared-table
# variant so the two keys can never accidentally collapse into "the same
# row" later (e.g. a future migration merging tables) without that being
# an explicit, reviewed decision.
class PlayUploadKey < ApplicationRecord
  encrypts :keystore, :keystore_password, :key_password

  validates :filename, :key_alias, :keystore, :keystore_password, :key_password, presence: true
  validates :checksum, uniqueness: true, on: :create
  validate :only_one_record, on: :create

  before_validation :generate_checksum

  def self.current
    first
  end

  # See AndroidSigningKey#verify! — identical mechanism (shells out to
  # `keytool`), just checking this key's material instead.
  def verify!
    Anthropic::ApkSigningService.verify_keystore!(
      keystore_bytes: keystore,
      keystore_password: keystore_password,
      key_alias: key_alias,
      key_password: key_password
    )
  end

  # See AndroidSigningKey#with_keystore_files for the full rationale
  # (file:-scheme passwords, mode-0600 tempfiles, nothing decrypted
  # longer than this block).
  def with_keystore_files
    Tempfile.create(['play-upload-signing', '.jks'], binmode: true) do |keystore_file|
      keystore_file.write(keystore)
      keystore_file.flush

      write_secret_file(keystore_password) do |keystore_pass_path|
        write_secret_file(key_password) do |key_pass_path|
          yield keystore_file.path, keystore_pass_path, key_pass_path
        end
      end
    end
  end

  private

  def only_one_record
    errors.add(:base, :singleton) if PlayUploadKey.exists?
  end

  def write_secret_file(secret)
    Tempfile.create(['play-upload-signing-pass']) do |file|
      file.chmod(0o600)
      file.write(secret)
      file.flush
      yield file.path
    end
  end

  def generate_checksum
    return if keystore.blank?

    self.checksum = Digest::SHA1.hexdigest(keystore)
  end
end
