# frozen_string_literal: true

require 'rails_helper'
require 'json'
require 'digest'

# Z-P15: the F-Droid index-v2 / entry.json mapping. Struct fixtures, not factories: the serializer is
# duck-typed (every read behind `respond_to?`), so these exercise the mapping without a database — the same
# posture `CatalogIndex::Serializer` is tested with. The one thing that must hold structurally, `entry.json`
# agreeing with the exact `index-v2.json` bytes it points at, is asserted directly.
RSpec.describe FdroidIndex::Serializer do
  FakeRelease = Struct.new(
    :created_at, :release_version, :build_version, :file_sha256, :original_size, :download_url,
    :icon_download_url, :icon_sha256, :signing_key_checksum, :min_sdk_version, :target_sdk_version,
    :abis, :permissions, :ci_compile_state, :universal_apk_sha256, :universal_apk_size, :size_bytes,
    keyword_init: true
  )
  FakeGraphic = Struct.new(:kind, :download_url, :sha256, :byte_size, :position, :id, keyword_init: true)
  FakeApp = Struct.new(
    :play_package_name, :name, :short_description, :description, :publisher_display_name, :category,
    :created_at, :updated_at, :listing_graphics, :catalog_releases, keyword_init: true
  )

  let(:now) { Time.utc(2026, 10, 10, 12, 0, 0) }

  def release(**over)
    FakeRelease.new(**{
      created_at: Time.utc(2026, 10, 1, 9, 30, 0),
      release_version: '1.2.3',
      build_version: '42',
      file_sha256: 'a' * 64,
      original_size: 12_345,
      download_url: 'https://console.example.com/download/releases/7',
      icon_download_url: 'https://console.example.com/download/releases/7/icon',
      icon_sha256: 'b' * 64,
      signing_key_checksum: 'c' * 64,
      min_sdk_version: 26,
      target_sdk_version: 36,
      abis: %w[arm64-v8a armeabi-v7a],
      permissions: %w[android.permission.INTERNET],
      ci_compile_state: nil,
      universal_apk_sha256: nil,
      universal_apk_size: nil,
      size_bytes: nil
    }.merge(over))
  end

  def app(**over)
    FakeApp.new(**{
      play_package_name: 'com.example.app',
      name: 'Example App',
      short_description: 'A short line',
      description: 'The long description.',
      publisher_display_name: 'Example Publisher',
      category: 'Tools',
      created_at: Time.utc(2026, 1, 2, 3, 4, 5),
      updated_at: Time.utc(2026, 10, 1, 9, 30, 0),
      listing_graphics: [],
      catalog_releases: [release]
    }.merge(over))
  end

  def index_of(result) = JSON.parse(result.index_json)
  def entry_of(result) = JSON.parse(result.entry_json)

  it 'writes the index-v2 top level: a repo block and packages keyed by package name' do
    result = described_class.call([app], now: now, repo_address: 'https://console.example.com/fdroid')
    index = index_of(result)

    expect(index.keys).to contain_exactly('repo', 'packages')
    expect(index['packages'].keys).to eq(['com.example.app'])
    expect(index['repo']['address']).to eq('https://console.example.com/fdroid')
    expect(index['repo']['timestamp']).to eq(now.to_i * 1000)
  end

  it 'points entry.json at exactly the index-v2 bytes (sha256 and size must agree)' do
    result = described_class.call([app], now: now)
    entry = entry_of(result)

    expect(entry['version']).to eq(30_000) # fdroidserver METADATA_VERSION
    expect(entry['index']['name']).to eq('/index-v2.json')
    expect(entry['index']['sha256']).to eq(Digest::SHA256.hexdigest(result.index_json))
    expect(entry['index']['size']).to eq(result.index_json.bytesize)
    expect(entry['index']['numPackages']).to eq(1)
    expect(entry['timestamp']).to eq(now.to_i * 1000)
  end

  it 'keys a version by the APK sha256 and renders the manifest F-Droid reads' do
    result = described_class.call([app], now: now)
    versions = index_of(result)['packages']['com.example.app']['versions']

    expect(versions.keys).to eq(['a' * 64])
    v = versions['a' * 64]
    expect(v['file']).to eq('name' => 'https://console.example.com/download/releases/7',
                            'sha256' => 'a' * 64, 'size' => 12_345)
    expect(v['manifest']['versionName']).to eq('1.2.3')
    expect(v['manifest']['versionCode']).to eq(42) # a NUMBER, per F-Droid, not the string the column holds
    expect(v['manifest']['usesSdk']).to eq('minSdkVersion' => 26, 'targetSdkVersion' => 36)
    expect(v['manifest']['signer']).to eq('sha256' => ['c' * 64])
    expect(v['manifest']['nativecode']).to eq(%w[arm64-v8a armeabi-v7a])
    expect(v['manifest']['usesPermission']).to eq([{ 'name' => 'android.permission.INTERNET' }])
  end

  it 'renders human text as a locale map (en-US), never a bare string' do
    result = described_class.call([app], now: now)
    metadata = index_of(result)['packages']['com.example.app']['metadata']

    expect(metadata['name']).to eq('en-US' => 'Example App')
    expect(metadata['summary']).to eq('en-US' => 'A short line')
    expect(metadata['description']).to eq('en-US' => 'The long description.')
    expect(metadata['authorName']).to eq('Example Publisher')
    expect(metadata['categories']).to eq(['Tools'])
  end

  it 'omits an app that has no package name rather than inventing one' do
    result = described_class.call([app(play_package_name: nil)], now: now)

    expect(index_of(result)['packages']).to eq({})
    expect(entry_of(result)['index']['numPackages']).to eq(0)
  end

  it 'publishes the icon from the newest release that has a stored one' do
    with_icon = release(icon_download_url: 'https://console.example.com/download/releases/8/icon', icon_sha256: 'd' * 64)
    without = release(icon_download_url: nil, icon_sha256: nil)
    result = described_class.call([app(catalog_releases: [without, with_icon])], now: now)

    icon = index_of(result)['packages']['com.example.app']['metadata']['icon']['en-US']
    expect(icon).to eq('name' => 'https://console.example.com/download/releases/8/icon', 'sha256' => 'd' * 64)
  end

  it 'renders phone screenshots in position order' do
    shots = [
      FakeGraphic.new(kind: 'screenshot', download_url: 'https://c/g/2', sha256: '2' * 64, byte_size: 200, position: 1, id: 2),
      FakeGraphic.new(kind: 'feature_graphic', download_url: 'https://c/g/f', sha256: 'f' * 64, byte_size: 500, position: 0, id: 3),
      FakeGraphic.new(kind: 'screenshot', download_url: 'https://c/g/1', sha256: '1' * 64, byte_size: 100, position: 0, id: 1)
    ]
    result = described_class.call([app(listing_graphics: shots)], now: now)

    rendered = index_of(result)['packages']['com.example.app']['metadata']['screenshots']['phone']['en-US']
    expect(rendered.map { |s| s['name'] }).to eq(['https://c/g/1', 'https://c/g/2'])
    expect(rendered.first['size']).to eq(100)
  end

  it 'leaves out a release with no recorded sha256 (nothing to key it by)' do
    result = described_class.call([app(catalog_releases: [release(file_sha256: nil)])], now: now)

    expect(index_of(result)['packages']['com.example.app']['versions']).to eq({})
  end

  it 'falls back to the universal APK hash and size when the file pair is blank' do
    rel = release(file_sha256: nil, original_size: nil,
                  universal_apk_sha256: 'e' * 64, universal_apk_size: 999)
    result = described_class.call([app(catalog_releases: [rel])], now: now)

    v = index_of(result)['packages']['com.example.app']['versions']['e' * 64]
    expect(v['file']['size']).to eq(999)
  end

  it 'produces valid JSON that round-trips' do
    result = described_class.call([app], now: now)

    expect { JSON.parse(result.index_json) }.not_to raise_error
    expect { JSON.parse(result.entry_json) }.not_to raise_error
  end
end
