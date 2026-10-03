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

  # D-Store leaf 7.a.ii.zi. NOT run (no Ruby in the sandbox that wrote it). `file` is stubbed with a
  # double that only has a path, because a real Release needs a CarrierWave upload and this repo
  # carries no .aab fixture; the real upload route is covered by the request spec in
  # spec/requests/api_app_token_upload_spec.rb, which is also unrun.
  describe '#manifest_unreadable_reason and Release#manifest_readable' do
    def release_with_file(path)
      release = build_release
      allow(release).to receive(:file).and_return(double('file', path: path))
      release
    end

    def aab_parser(bundle_id: 'com.example.app', build_version: '42', release_version: '1.0')
      double('parser', platform: AppInfo::Platform::ANDROID, name: 'Example', bundle_id: bundle_id,
                       release_version: release_version, build_version: build_version,
                       device: 'Android', icons: [], min_sdk_version: 21, target_sdk_version: 34,
                       zip: nil, use_features: [], use_permissions: [])
    end

    it 'is nil for a release that was never parsed, even an .aab with no package name' do
      release = release_with_file('/tmp/app.aab')
      release.bundle_id = nil
      release.build_version = nil

      expect(release.manifest_unreadable_reason).to be_nil
    end

    it 'is nil when the bundle was read and has a package name and a version code' do
      release = release_with_file('/tmp/app.aab')
      release.parse!(aab_parser, 'api')

      expect(release.manifest_unreadable_reason).to be_nil
    end

    it 'does not need a versionName, which Android does not require' do
      release = release_with_file('/tmp/app.aab')
      release.release_version = nil
      release.parse!(aab_parser(release_version: nil), 'api')
      release.release_version = nil

      expect(release.manifest_unreadable_reason).to be_nil
    end

    it 'is :unknown_format when AppInfo does not recognise the file' do
      allow(AppInfo).to receive(:parse).and_raise(AppInfo::UnknownFormatError)
      release = release_with_file('/tmp/app.aab')
      release.bundle_id = nil
      release.build_version = nil
      release.parse!(nil, 'api')

      expect(release.manifest_unreadable_reason).to eq(:unknown_format)
    end

    it 'is :read_failed when AppInfo raises while reading, and the parse itself still does not raise' do
      parser = aab_parser
      allow(parser).to receive(:name).and_raise(StandardError, 'bad resources.pb')
      release = release_with_file('/tmp/app.aab')
      release.bundle_id = nil
      release.build_version = nil

      expect { release.parse!(parser, 'api') }.not_to raise_error
      expect(release.manifest_unreadable_reason).to eq(:read_failed)
    end

    it 'is :identity_missing when the read gives no error but no version code' do
      release = release_with_file('/tmp/app.aab')
      release.build_version = nil
      release.parse!(aab_parser(build_version: nil), 'api')

      expect(release.manifest_unreadable_reason).to eq(:identity_missing)
    end

    it 'is nil for an .apk that could not be read: only an App Bundle is refused (a separate decision)' do
      allow(AppInfo).to receive(:parse).and_raise(AppInfo::UnknownFormatError)
      release = release_with_file('/tmp/app.apk')
      release.bundle_id = nil
      release.build_version = nil
      release.parse!(nil, 'api')

      expect(release.manifest_unreadable_reason).to be_nil
    end

    it 'adds one error on :file carrying the fixed reason word, and none for a readable bundle' do
      allow(AppInfo).to receive(:parse).and_raise(AppInfo::UnknownFormatError)
      broken = release_with_file('/tmp/app.aab')
      broken.bundle_id = nil
      broken.build_version = nil
      broken.parse!(nil, 'api')
      broken.send(:manifest_readable)

      expect(broken.errors[:file].size).to eq(1)
      expect(broken.errors[:file].first).to include('unknown_format')

      fine = release_with_file('/tmp/app.aab')
      fine.parse!(aab_parser, 'api')
      fine.send(:manifest_readable)

      expect(fine.errors[:file]).to be_empty
    end
  end
end
