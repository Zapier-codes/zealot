# frozen_string_literal: true

require 'json'
require 'open3'
require 'shellwords'
require 'timeout'

module Play
  # Z-P14 (docs/PARITY-KANBAN.md): the auto-fill half of device targeting. `ReleaseParser` reads an APK
  # with the `AppInfo` gem, but `AppInfo` cannot open an Android App Bundle's split APKs, so an .aab
  # upload reaches the catalog with blank `min_sdk_version`/`target_sdk_version`/`abis`/`screen_densities`
  # and no `required_features` — which the S-P2 "works on your device" filter reads. `bundletool` (already
  # in the image, see the Dockerfile) DOES read them from an .aab/.apk. This class is the seam: it shells
  # out to `bundletool`, on its own process, and never raises — a missing tool or an unreadable bundle is a
  # `Result(ok: false)`, exactly the posture of `Play::BackendRunner`. Nothing here is imported by the
  # upload path unless a command is actually configured, so a deployment with no `bundletool` behaves as
  # before (AppInfo's best effort).
  #
  # Contract: `<command> dump manifest --features --file <path>` -> one JSON object on stdout, exit 0. The
  # default command is `bundletool dump manifest --features --file` (bundletool accepts `--file` last).
  class ApkInspector
    Result = Struct.new(:ok, :compatibility, :error, keyword_init: true) do
      def ok? = !!ok
    end

    DEFAULT_COMMAND = 'bundletool dump manifest --features --file'
    DEFAULT_TIMEOUT = (ENV['PLAY_INSPECT_TIMEOUT_SECONDS'] || 30).to_i

    ANDROID_ABIS = %w[armeabi armeabi-v7a arm64-v8a x86 x86_64 mips mips64].freeze
    SCREEN_DENSITY_BUCKETS = %w[ldpi mdpi hdpi xhdpi xxhdpi xxxhdpi tvdpi nodpi anydpi].freeze

    def self.call(path, **kwargs) = new(**kwargs).call(path)

    def initialize(command: nil, timeout: DEFAULT_TIMEOUT)
      @command = (command || ENV['PLAY_INSPECT_COMMAND'] || DEFAULT_COMMAND).to_s
      @timeout = timeout
    end

    # @param path [String] an .aab or .apk on disk
    # @return [Result] ok=true with a `compatibility` hash (any key may be absent), or ok=false with `error`
    def call(path)
      return Result.new(ok: false, error: 'no command configured') if @command.strip.empty?
      return Result.new(ok: false, error: 'no file') if path.to_s.strip.empty?
      return Result.new(ok: false, error: 'file not found') unless File.file?(path)

      stdout, stderr, status = Timeout.timeout(@timeout) do
        Open3.capture3(*Shellwords.split(@command), path.to_s)
      end
      unless status.success?
        return Result.new(ok: false, error: "exit #{status.exitstatus}: #{clip(stderr.to_s.strip)}")
      end

      parsed = JSON.parse(stdout)
      unless parsed.is_a?(Hash)
        return Result.new(ok: false, error: 'inspector returned no JSON object')
      end

      Result.new(ok: true, compatibility: normalize(parsed))
    rescue JSON::ParserError
      Result.new(ok: false, error: 'inspector output was not JSON')
    rescue Errno::ENOENT
      Result.new(ok: false, error: 'inspector command not found')
    rescue Timeout::Error
      Result.new(ok: false, error: "inspector timed out after #{@timeout}s")
    rescue StandardError => e
      Result.new(ok: false, error: "inspector failed: #{e.message}")
    end

    # bundletool's `manifest` dump nests the Android manifest; the version fields and `uses-feature`
    # live under `manifest` -> `uses-sdk` / `uses-feature`. Accept both a nested and a flat shape so a
    # different implementation (or an .apk) can answer with the same keys.
    def normalize(doc)
      manifest = doc['manifest'].is_a?(Hash) ? doc['manifest'] : doc
      uses_sdk = manifest['uses-sdk'] || doc['uses-sdk'] || {}
      uses_feature = manifest['uses-feature'] || doc['uses-feature'] || []

      compatibility = {}
      min = integer_or_nil(uses_sdk['minSdkVersion'] || doc['minSdkVersion'])
      target = integer_or_nil(uses_sdk['targetSdkVersion'] || doc['targetSdkVersion'])
      compatibility[:min_sdk_version] = min if min
      compatibility[:target_sdk_version] = target if target

      features = required_features(uses_feature)
      compatibility[:required_features] = features unless features.empty?
      compatibility.compact
    end

    private

    def required_features(value)
      Array(value).filter_map do |feature|
        next unless feature.is_a?(Hash)
        # `android:required` defaults to true when omitted, so an unmarked feature IS required.
        required = feature.fetch('required', feature.fetch('android:required', true))
        next unless required == true || required.to_s == 'true'

        name = feature['name'] || feature['android:name']
        stripped = name.to_s.strip
        stripped.empty? ? nil : stripped
      end.uniq
    end

    def integer_or_nil(value)
      Integer(value.to_s, 10, exception: false)
    end

    def clip(text, max = 300) = text.to_s.length > max ? text.to_s[0, max] : text.to_s
  end
end
