# frozen_string_literal: true

# Holds the keystore our own employees sign their own app's release
# artifacts with (task #5). One per App — see handover.md's "Scope, stated
# plainly": this signs builds this organization produces, for internal
# distribution; it is not a re-signing service for third-party apps.
#
# The keystore file itself and both passwords are encrypted at rest via
# Active Record Encryption (config/initializers/active_record_encryption.rb).
# `checksum` is a non-secret SHA1 of the keystore bytes, used the same way
# AppleKey uses its checksum: to prevent the same keystore being stored
# twice, and as a lightweight audit trail (Release#signing_key_checksum)
# without exposing the key material itself.
class AndroidSigningKey < ApplicationRecord
  belongs_to :app

  encrypts :keystore, :keystore_password, :key_password

  validates :filename, :key_alias, :keystore, :keystore_password, :key_password, presence: true
  validates :checksum, uniqueness: true, on: :create
  validates :app_id, uniqueness: true

  before_validation :generate_checksum

  # Best-effort validation that the keystore is at least well-formed and
  # the given alias/passwords actually open it, by shelling out to `keytool`
  # (bundled with the same JDK bundletool already needs). Not run
  # automatically on save because it requires the JDK to be present, which
  # this sandbox does not have — call explicitly once deployed, e.g. from
  # a controller action before persisting.
  def verify!
    Anthropic::ApkSigningService.verify_keystore!(
      keystore_bytes: keystore,
      keystore_password: keystore_password,
      key_alias: key_alias,
      key_password: key_password
    )
  end

  # Yields local paths for the decrypted keystore and both passwords, each
  # written to a mode-0600 tempfile for the duration of the block, then
  # removed. Callers pass these to bundletool via its `--ks-pass file:...`
  # / `--key-pass file:...` schemes rather than `pass:...`, specifically so
  # the plaintext password never appears in `ps`/process-argv output on a
  # shared host. Never write the decrypted keystore or passwords anywhere
  # longer-lived than this block.
  def with_keystore_files
    Tempfile.create(['android-signing', '.jks'], binmode: true) do |keystore_file|
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

  def write_secret_file(secret)
    Tempfile.create(['android-signing-pass']) do |file|
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
