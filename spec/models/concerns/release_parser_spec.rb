# frozen_string_literal: true

require 'rails_helper'

# Task 29c. See app/models/concerns/release_parser.rb for the extraction
# design notes -- why ABIs/screen densities come from the APK's own zip
# entry paths rather than AppInfo::APK's public API, and why this has its
# own rescue separate from #parse_app's.
#
# No Release factory exists in this repo (checked spec/factories/); built
# directly against db/schema.rb's non-null columns, same approach
# spec/services/catalog_index/serializer_spec.rb (Task 29b) already uses
# for the same reason. The doubles standing in for AppInfo::APK below are
# the same duck-typed shapes the commit that introduced this method
# verified against with a standalone harness outside RSpec (rubygems.org
# isn't reachable from every sandbox this board has been worked from, so
# the real gem can't always be installed to fixture against).
RSpec.describe ReleaseParser do
  FakeZipEntry = Struct.new(:name)
  FakeFeature = Struct.new(:name, :required) do
    def required?
      required
    end
  end

  def build_release
    Release.new(version: 1, changelog: [], release_version: '1.2.3', build_version: '42')
  end

  def fake_zip(*entry_names)
    double('zip', entries: entry_names.map { |n| FakeZipEntry.new(n) })
  end

  def android_parser(min_sdk: 21, target_sdk: 34, zip: fake_zip, features: [], permissions: [])
    double('parser',
           platform: AppInfo::Platform::ANDROID,
           min_sdk_version: min_sdk, target_sdk_version: target_sdk,
           zip: zip, use_features: features, use_permissions: permissions)
  end

  describe '#extract_compatibility' do
    it 'derives ABIs and screen densities from the zip entry paths (multi-arch, multi-density)' do
      release = build_release
      zip = fake_zip(
        'lib/arm64-v8a/libfoo.so', 'lib/armeabi-v7a/libfoo.so',
        'res/drawable-xhdpi-v4/icon.png', 'res/mipmap-hdpi/icon.png',
        'AndroidManifest.xml'
      )

      release.send(:extract_compatibility, android_parser(zip: zip))

      expect(release.abis).to contain_exactly('arm64-v8a', 'armeabi-v7a')
      expect(release.screen_densities).to contain_exactly('xhdpi', 'hdpi')
      expect(release.min_sdk_version).to eq(21)
      expect(release.target_sdk_version).to eq(34)
    end

    it 'reports an empty ABI/density signal, not an error, for an APK with no native code or density resources' do
      release = build_release

      release.send(:extract_compatibility, android_parser(zip: fake_zip('AndroidManifest.xml', 'classes.dex')))

      expect(release.abis).to eq([])
      expect(release.screen_densities).to eq([])
    end

    it 'keeps only required use_features, duck-typed against both object and Hash shapes' do
      release = build_release
      features = [
        FakeFeature.new('android.hardware.camera', true),
        FakeFeature.new('android.hardware.nfc', false),
        { name: 'android.hardware.bluetooth', required: true }
      ]

      release.send(:extract_compatibility, android_parser(features: features))

      expect(release.required_features).to contain_exactly('android.hardware.camera', 'android.hardware.bluetooth')
    end

    it 'reads use_permissions off either an object with #name or a plain string, de-duplicated' do
      release = build_release
      permission = Struct.new(:name).new('android.permission.CAMERA')
      permissions = [ permission, 'android.permission.INTERNET', 'android.permission.INTERNET' ]

      release.send(:extract_compatibility, android_parser(permissions: permissions))

      expect(release.permissions).to contain_exactly('android.permission.CAMERA', 'android.permission.INTERNET')
    end

    it 'rescues a raising parser without losing the SDK versions already assigned (not atomic, by design)' do
      release = build_release
      parser = android_parser
      allow(parser).to receive(:zip).and_raise(StandardError, 'corrupt zip')

      expect { release.send(:extract_compatibility, parser) }.not_to raise_error
      expect(release.min_sdk_version).to eq(21)
      expect(release.target_sdk_version).to eq(34)
      expect(release.abis).to eq([])
    end
  end

  describe '#build_metadata' do
    it 'never touches compatibility columns for a non-Android (iOS) release' do
      release = build_release
      parser = double('parser', platform: AppInfo::Platform::IOS, name: 'Example', device: 'iPhone',
                                 release_version: '1.0', build_version: '1', icons: [])

      release.send(:build_metadata, parser, 'web')

      expect(release.min_sdk_version).to be_nil
      expect(release.target_sdk_version).to be_nil
      expect(release.abis).to eq([])
      expect(release.screen_densities).to eq([])
      expect(release.required_features).to eq([])
      expect(release.permissions).to eq([])
    end
  end
end
