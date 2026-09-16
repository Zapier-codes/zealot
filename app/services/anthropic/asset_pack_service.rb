# frozen_string_literal: true

module Anthropic
  # Processes an AAB that already contains Play Asset Delivery (PAD) asset
  # packs, producing split APKs grouped by pack delivery type
  # (install_time / fast_follow / on_demand).
  #
  # This service does NOT create asset packs — the developer's AAB must
  # already declare them (via their Gradle/bundle config). If the AAB has
  # no asset packs, this falls back to plain split APK generation via
  # BundletoolService.
  class AssetPackService
    PACK_TYPES = %w[install_time fast_follow on_demand].freeze

    class AssetPackConfigError < StandardError; end

    attr_reader :aab_path, :bundletool_service

    def initialize(aab_path, bundletool_service: BundletoolService.new(aab_path))
      @aab_path = aab_path
      @bundletool_service = bundletool_service
    end

    # @param output_dir [String]
    # @param pack_config [Hash, nil] e.g.
    #   { "level1" => "install_time", "extra_maps" => "fast_follow", "dlc" => "on_demand" }
    # @return [Hash] { apks_path:, packs: { "install_time" => [...], "fast_follow" => [...], "on_demand" => [...] } }
    def process(output_dir:, pack_config: nil)
      config_path = pack_config.present? ? write_config(pack_config, output_dir) : nil

      apks_path = bundletool_service.build_apk_set(
        output_dir: output_dir,
        asset_pack_config: config_path
      )

      {
        apks_path: apks_path,
        packs: group_by_pack_type(apks_path, pack_config)
      }
    end

    private

    # bundletool expects an asset-pack-config JSON file mapping pack names
    # to their delivery mode. See:
    # https://developer.android.com/guide/playcore/asset-delivery
    def write_config(pack_config, output_dir)
      validate_pack_config!(pack_config)

      config = {
        'asset_pack_config' => pack_config.map do |pack_name, delivery_type|
          { 'name' => pack_name, 'delivery_type' => delivery_type }
        end
      }

      FileUtils.mkdir_p(output_dir)
      path = File.join(output_dir, 'asset-pack-config.json')
      File.write(path, JSON.pretty_generate(config))
      path
    end

    def validate_pack_config!(pack_config)
      pack_config.each do |name, type|
        next if PACK_TYPES.include?(type)

        raise AssetPackConfigError, "Unknown pack delivery type '#{type}' for pack '#{name}'. " \
                                     "Expected one of: #{PACK_TYPES.join(', ')}"
      end
    end

    # Without deeper parsing of the generated .apks (a zip containing a
    # toc.pb protobuf table of contents), we can only report pack types
    # from the caller-supplied config. A future iteration could parse
    # toc.pb directly to enumerate the actual generated splits per pack.
    def group_by_pack_type(_apks_path, pack_config)
      grouped = PACK_TYPES.index_with { [] }
      return grouped if pack_config.blank?

      pack_config.each { |pack_name, delivery_type| grouped[delivery_type] << pack_name }
      grouped
    end
  end
end
