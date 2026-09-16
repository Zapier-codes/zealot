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
    # @return [String] path to the generated .apks file
    def build_apk_set(output_dir:, asset_pack_config: nil)
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

      run_command!(cmd)

      apks_path
    end

    private

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
