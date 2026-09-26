# frozen_string_literal: true

module ReleaseParser
  extend ActiveSupport::Concern

  def parse!(parser, default_source)
    parse_app(parser, default_source)

    self
  end

  private

  def parse_app(parser, default_source)
    parser ||= AppInfo.parse(self.file.path)
    build_metadata(parser, default_source)
    relates_to_devices(parser)
  rescue AppInfo::UnknownFormatError
    # ignore
  rescue => e
    logger.error e.full_message
  ensure
    parser&.clear! if parser&.respond_to?(:clear!)
  end

  def build_metadata(parser, default_source)
    # iOS, Android only
    self.name ||= parser.name
    self.bundle_id = parser.bundle_id if parser.respond_to?(:bundle_id)
    self.source = default_source if self.source.blank?
    self.device_type = parser.device
    self.release_version = parser.release_version
    self.build_version = parser.build_version
    self.release_type = parser.release_type if release_type.blank? && parser.respond_to?(:release_type)

    extract_compatibility(parser) if parser.platform == AppInfo::Platform::ANDROID

    icon_file = fetch_icon(parser)
    self.icon = icon_file if icon_file
  end

  # Task 29c: what docs/catalog_index_v2.md's `compatibility` block (29a) and
  # CatalogIndex::Serializer (29b) already reserve, actually filled in from
  # the uploaded APK. Own rescue block, separate from build_metadata's
  # surrounding one in #parse_app -- a malformed or unusual manifest
  # shouldn't cost the release its name/version/icon, which is why this is
  # its own guarded step rather than inline in build_metadata.
  #
  # AppInfo::APK's public API doesn't expose ABIs or screen densities
  # directly (only min/target_sdk_version, use_permissions, use_features --
  # see rubydoc.info/gems/app-info/AppInfo/APK). Both are instead read off
  # the APK's own zip entry paths: `lib/<abi>/*` for native libraries,
  # `res/*-<density>/*` resource-qualifier directories for densities. This
  # is a real, if unofficial, signal -- it's exactly how `bundletool` and
  # the Play Console itself report supported ABIs for an APK -- but it's
  # necessarily a lower bound: an APK with no native code has an empty
  # `lib/` (correctly abis: []), and one bundling no density-specific
  # resources reports no densities (correctly, not a parsing failure --
  # Android's own runtime falls back to nearest-density scaling in that
  # case, so "no signal" and "supports every density" look the same from
  # inside the APK).
  def extract_compatibility(parser)
    self.min_sdk_version = safe_integer(parser.min_sdk_version) if parser.respond_to?(:min_sdk_version)
    self.target_sdk_version = safe_integer(parser.target_sdk_version) if parser.respond_to?(:target_sdk_version)
    self.abis = extract_abis(parser)
    self.screen_densities = extract_screen_densities(parser)
    self.required_features = extract_required_features(parser)
    self.permissions = extract_permissions(parser)
  rescue => e
    logger.error e.full_message
  end

  ANDROID_ABIS = %w[armeabi armeabi-v7a arm64-v8a x86 x86_64 mips mips64].freeze
  SCREEN_DENSITY_BUCKETS = %w[ldpi mdpi hdpi xhdpi xxhdpi xxxhdpi tvdpi nodpi anydpi].freeze
  private_constant :ANDROID_ABIS, :SCREEN_DENSITY_BUCKETS

  def extract_abis(parser)
    return [] unless parser.respond_to?(:zip) && parser.zip.present?

    entry_names(parser).filter_map { |name| name[%r{\Alib/([^/]+)/}, 1] }
                        .uniq
                        .select { |abi| ANDROID_ABIS.include?(abi) }
  end

  def extract_screen_densities(parser)
    return [] unless parser.respond_to?(:zip) && parser.zip.present?

    pattern = /-(#{SCREEN_DENSITY_BUCKETS.join('|')})(?:-|\z|\/)/
    entry_names(parser).select { |name| name.start_with?('res/') }
                        .filter_map { |name| name[pattern, 1] }
                        .uniq
  end

  def entry_names(parser)
    parser.zip.entries.map(&:name)
  end

  # `use_features` entries are duck-typed here (object with #name/#required?,
  # or a Hash with string/symbol keys) since AppInfo's own return shape for
  # this isn't pinned down by its public docs -- only rubygems.org has the
  # actual source and it isn't reachable from this sandbox to confirm
  # directly (see handover.md's Task 22/27b-i verification notes for the
  # same constraint elsewhere on this board).
  def extract_required_features(parser)
    return [] unless parser.respond_to?(:use_features) && parser.use_features.present?

    parser.use_features.filter_map do |feature|
      name, required = feature_name_and_required(feature)
      name if required && name.present?
    end
  end

  def feature_name_and_required(feature)
    if feature.respond_to?(:name)
      [ feature.name, feature.respond_to?(:required?) ? feature.required? : feature.try(:required) ]
    elsif feature.is_a?(Hash)
      [ feature[:name] || feature['name'], feature[:required] || feature['required'] ]
    end
  end

  def extract_permissions(parser)
    return [] unless parser.respond_to?(:use_permissions)

    Array(parser.use_permissions).filter_map do |permission|
      permission.respond_to?(:name) ? permission.name : permission
    end.uniq
  end

  def safe_integer(value)
    return nil if value.blank?

    Integer(value.to_s, exception: false)
  end

  def relates_to_devices(parser)
    # Parse UDID list for iOS adhoc app
    if parser.platform == AppInfo::Platform::IOS &&
       parser.release_type == AppInfo::IPA::ExportType::ADHOC && 
       parser.devices.present?

      parser.devices.each do |udid|
        self.devices.find_or_initialize_by(udid: udid)
      end
    end
  end

  def fetch_icon(parser)
    file = case parser.platform
           when AppInfo::Platform::IOS
            return if parser.icons.blank?

            # NOTE: uncrushed_file may be return nil (#1196)
            biggest_icon(parser.icons, file_key: :uncrushed_file) ||
              biggest_icon(parser.icons, file_key: :file)
           when AppInfo::Platform::MACOS
             return if parser.icons.blank?

             biggest_icon(parser.icons[:sets])
           when AppInfo::Platform::ANDROID
            return if parser.icons.blank?

            biggest_icon(parser.icons(exclude: :xml))
           when AppInfo::Platform::WINDOWS
             return if parser.icons.blank?

             biggest_icon(parser.icons)
           when AppInfo::Platform::HARMONYOS
             return if parser.icons.blank?

             biggest_icon(parser.icons)
           end

    File.open(file, 'rb') if file
  end

  def biggest_icon(icons, file_key: :file)
    return if icons.blank?

    icons.max_by { |icon| icon[:dimensions][0] }
         .try(:[], file_key)
  end
end
