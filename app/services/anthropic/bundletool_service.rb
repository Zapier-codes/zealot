# frozen_string_literal: true

module Anthropic
  # Wraps Google's `bundletool` CLI to generate device-specific APK sets
  # (split by ABI, screen density, and language) from an uploaded Android
  # App Bundle (.aab).
  #
  # This does not talk to Google Play in any way; it only shells out to a
  # locally installed `bundletool` binary/jar.
  class BundletoolService
    class BundletoolNotFoundError < StandardError; end
    class InvalidAabError < StandardError; end
    class BuildFailedError < StandardError; end

    DEFAULT_BUNDLETOOL_PATH = ENV.fetch('BUNDLETOOL_PATH', '/usr/local/bin/bundletool')

    attr_reader :aab_path, :bundletool_path

    # @param aab_path [String] absolute path to the .aab file on local disk
    # @param bundletool_path [String] path to the bundletool executable
    def initialize(aab_path, bundletool_path: DEFAULT_BUNDLETOOL_PATH)
      @aab_path = aab_path
      @bundletool_path = bundletool_path
    end

    # Builds a universal/device-spec APK set from the AAB.
    #
    # @param output_dir [String] directory to write the .apks file into
    # @param asset_pack_config [String, nil] optional path to a JSON file
    #   describing asset pack delivery config (install-time/fast-follow/on-demand)
    # @param signing_key [AndroidSigningKey, nil] when present, the split
    #   APKs are signed with this keystore as part of the same bundletool
    #   invocation (task #5). When nil, bundletool falls back to its debug
    #   keystore, exactly as before this was added.
    # @return [String] path to the generated .apks file
    def build_apk_set(output_dir:, asset_pack_config: nil, signing_key: nil)
      ensure_bundletool_available!
      ensure_valid_aab!

      FileUtils.mkdir_p(output_dir)
      apks_path = File.join(output_dir, "#{File.basename(aab_path, '.aab')}.apks")
      FileUtils.rm_f(apks_path)

      cmd = [
        bundletool_path, 'build-apks',
        '--bundle', aab_path,
        '--output', apks_path,
        '--mode=default'
      ]
      cmd += ['--asset-pack-config', asset_pack_config] if asset_pack_config.present?

      if signing_key
        signing_key.with_keystore_files do |keystore_path, keystore_pass_path, key_pass_path|
          run_command!(cmd + signing_args(signing_key, keystore_path, keystore_pass_path, key_pass_path))
        end
      else
        run_command!(cmd)
      end

      apks_path
    end

    private

    # Passwords are passed via bundletool's `--ks-pass file:...` /
    # `--key-pass file:...` schemes, never `pass:...`, so the plaintext
    # password is never visible in `ps`/process-argv on a shared host.
    def signing_args(signing_key, keystore_path, keystore_pass_path, key_pass_path)
      [
        '--ks', keystore_path,
        '--ks-key-alias', signing_key.key_alias,
        '--ks-pass', "file:#{keystore_pass_path}",
        '--key-pass', "file:#{key_pass_path}"
      ]
    end

    def ensure_bundletool_available!
      return if File.executable?(bundletool_path) || system("command -v #{bundletool_path} > /dev/null 2>&1")

      raise BundletoolNotFoundError, "bundletool not found at #{bundletool_path}. " \
                                      'Install it or set BUNDLETOOL_PATH.'
    end

    def ensure_valid_aab!
      raise InvalidAabError, "AAB not found: #{aab_path}" unless File.exist?(aab_path)
      raise InvalidAabError, "Not an .aab file: #{aab_path}" unless aab_path.end_with?('.aab')
    end

    def run_command!(cmd)
      stdout, stderr, status = Open3.capture3(*cmd)
      return stdout if status.success?

      raise BuildFailedError, "bundletool build-apks failed: #{stderr.presence || stdout}"
    end
  end
end
