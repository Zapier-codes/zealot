# frozen_string_literal: true

module Anthropic
  # Keystore verification for our own AAB signing pipeline (task #5).
  #
  # The actual *signing* happens inside BundletoolService#build_apk_set,
  # which passes the keystore straight to `bundletool build-apks --ks ...`
  # — bundletool bundles its own apksigner internally, so there's no
  # separate sign-after-the-fact step here. This service exists only to
  # let AndroidSigningKey#verify! confirm a keystore/alias/passwords
  # actually work *before* they're trusted for real builds, using
  # `keytool` (part of the same JDK the Dockerfile already installs for
  # bundletool).
  class ApkSigningService
    class KeytoolNotFoundError < StandardError; end
    class InvalidKeystoreError < StandardError; end

    DEFAULT_KEYTOOL_PATH = ENV.fetch('KEYTOOL_PATH', 'keytool')

    # @raise [InvalidKeystoreError] if the keystore/alias/passwords don't
    #   actually open together
    def self.verify_keystore!(keystore_bytes:, keystore_password:, key_alias:, key_password:)
      new.verify_keystore!(
        keystore_bytes: keystore_bytes,
        keystore_password: keystore_password,
        key_alias: key_alias,
        key_password: key_password
      )
    end

    def initialize(keytool_path: DEFAULT_KEYTOOL_PATH)
      @keytool_path = keytool_path
    end

    def verify_keystore!(keystore_bytes:, keystore_password:, key_alias:, key_password:)
      ensure_keytool_available!

      Tempfile.create(['android-signing-verify', '.jks'], binmode: true) do |file|
        file.write(keystore_bytes)
        file.flush

        write_secret_file(keystore_password) do |storepass_path|
          write_secret_file(key_password) do |keypass_path|
            cmd = [
              @keytool_path, '-list',
              '-keystore', file.path,
              '-alias', key_alias,
              '-storepass:file', storepass_path,
              '-keypass:file', keypass_path
            ]
            _stdout, stderr, status = Open3.capture3(*cmd)
            raise InvalidKeystoreError, "keystore verification failed: #{stderr.presence}" unless status.success?
          end
        end
      end

      true
    end

    private

    def write_secret_file(secret)
      Tempfile.create(['android-signing-verify-pass']) do |file|
        file.chmod(0o600)
        file.write(secret)
        file.flush
        yield file.path
      end
    end

    def ensure_keytool_available!
      return if system("command -v #{@keytool_path} > /dev/null 2>&1")

      raise KeytoolNotFoundError, "keytool not found at #{@keytool_path}. Requires a JDK (same one bundletool uses)."
    end
  end
end
