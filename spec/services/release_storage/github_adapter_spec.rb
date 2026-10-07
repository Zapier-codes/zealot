# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# In-memory stand-in for the handful of GitHub endpoints the adapter uses,
# plugged in through the adapter's `transport:` seam so no network is touched.
module GithubAdapterSpecSupport
  class FakeGithub
    Response = ReleaseStorage::GithubAdapter::Response

    attr_reader :requests
    attr_accessor :repo_private, :repo_push, :failures

    def initialize
      @repo_private = true
      @repo_push = true
      @releases = {}
      @next_id = 100
      @requests = []
      @failures = [] # statuses to return (once each) before behaving normally
    end

    def assets_of(tag)
      @releases.fetch(tag)[:assets].map { |a| a[:name] }
    end

    def release_tags
      @releases.keys
    end

    # Task 41e: re-creates a release as an older layout left it (an asset under another name).
    def rename_asset(tag, from, to)
      @releases.fetch(tag)[:assets].find { |a| a[:name] == from }[:name] = to
    end

    def call(method, url, headers: {}, body: nil, upload_path: nil, stream_to: nil)
      @requests << { method: method, url: url, headers: headers }
      return json(@failures.shift, message: 'boom') unless @failures.empty?

      route(method, URI.parse(url), headers, body, upload_path, stream_to)
    end

    private

    def route(method, uri, headers, body, upload_path, stream_to)
      path = uri.path
      case [method, path]
      in [:get, %r{\A/repos/org/store\z}]
        json(200, private: @repo_private, permissions: { push: @repo_push })
      in [:get, %r{\A/repos/org/store/releases/tags/(.+)\z}]
        release = @releases[Regexp.last_match(1)]
        release ? json(200, release_json(release)) : json(404, message: 'Not Found')
      in [:post, %r{\A/repos/org/store/releases\z}]
        create_release(JSON.parse(body))
      in [:get, %r{\A/repos/org/store/releases/(\d+)/assets\z}]
        release = by_id(Regexp.last_match(1).to_i)
        json(200, release[:assets].map { |a| { id: a[:id], name: a[:name], size: a[:data].bytesize } })
      in [:post, %r{\A/repos/org/store/releases/(\d+)/assets\z}]
        upload(by_id(Regexp.last_match(1).to_i), uri, upload_path)
      in [:get, %r{\A/repos/org/store/releases/assets/(\d+)\z}]
        redirect_for(Regexp.last_match(1).to_i)
      in [:patch, %r{\A/repos/org/store/releases/assets/(\d+)\z}]
        rename_via_api(Regexp.last_match(1).to_i, JSON.parse(body))
      in [:delete, %r{\A/repos/org/store/releases/assets/(\d+)\z}]
        @releases.each_value { |r| r[:assets].reject! { |a| a[:id] == Regexp.last_match(1).to_i } }
        Response.new(status: 204, headers: {}, body: '')
      in [:delete, %r{\A/repos/org/store/releases/(\d+)\z}]
        @releases.delete_if { |_tag, r| r[:id] == Regexp.last_match(1).to_i }
        Response.new(status: 204, headers: {}, body: '')
      in [:delete, %r{\A/repos/org/store/git/refs/tags/(.+)\z}]
        Response.new(status: 204, headers: {}, body: '')
      in [:get, %r{\A/signed/(\d+)\z}]
        download(Regexp.last_match(1).to_i, stream_to)
      else
        json(404, message: "unrouted #{method} #{path}")
      end
    end

    def create_release(payload)
      tag = payload.fetch('tag_name')
      return json(422, message: 'already_exists') if @releases.key?(tag)

      release = { id: (@next_id += 1), tag_name: tag, assets: [] }
      @releases[tag] = release
      json(201, release_json(release))
    end

    def release_json(release)
      { id: release[:id], tag_name: release[:tag_name],
        upload_url: "https://uploads.github.test/repos/org/store/releases/#{release[:id]}/assets{?name,label}" }
    end

    def upload(release, uri, upload_path)
      name = URI.decode_www_form(uri.query).to_h.fetch('name')
      return json(422, message: 'already_exists') if release[:assets].any? { |a| a[:name] == name }

      asset = { id: (@next_id += 1), name: name, data: File.binread(upload_path) }
      release[:assets] << asset
      json(201, id: asset[:id], name: name)
    end

    # Task 44f: GitHub's asset rename (PATCH). A name already taken in the same storage release is a 422.
    def rename_via_api(asset_id, payload)
      release = @releases.values.find { |r| r[:assets].any? { |a| a[:id] == asset_id } }
      return json(404, message: 'Not Found') unless release

      name = payload.fetch('name')
      return json(422, message: 'already_exists') if release[:assets].any? { |a| a[:name] == name }

      asset = release[:assets].find { |a| a[:id] == asset_id }
      asset[:name] = name
      json(200, id: asset_id, name: name)
    end

    def redirect_for(asset_id)
      found = @releases.values.flat_map { |r| r[:assets] }.find { |a| a[:id] == asset_id }
      return json(404, message: 'Not Found') unless found

      Response.new(status: 302, headers: { 'location' => "https://objects.github.test/signed/#{asset_id}?sig=SECRET" },
                   body: '')
    end

    def download(asset_id, stream_to)
      asset = @releases.values.flat_map { |r| r[:assets] }.find { |a| a[:id] == asset_id }
      File.binwrite(stream_to, asset[:data])
      Response.new(status: 200, headers: {}, body: nil)
    end

    def by_id(id)
      @releases.values.find { |r| r[:id] == id }
    end

    def json(status, payload)
      Response.new(status: status, headers: {}, body: JSON.generate(payload))
    end
  end
end

RSpec.describe ReleaseStorage::GithubAdapter do
  let(:github) { GithubAdapterSpecSupport::FakeGithub.new }
  let(:sleeps) { [] }
  let(:adapter) do
    described_class.new(repo: 'org/store', token: 'ghp_SECRET_TOKEN', api_url: 'https://api.github.test',
                        transport: github, sleeper: ->(seconds) { sleeps << seconds })
  end
  let(:key) { 'uploads/apps/a12/r345/pipeline/release.apks.br' }
  let(:tmp) { Dir.mktmpdir }
  let(:source) { File.join(tmp, 'source.bin').tap { |path| File.binwrite(path, 'apk-bytes') } }

  before do
    described_class.reset_verification!
    stub_const('ENV', ENV.to_hash.except('GITHUB_STORAGE_ALLOW_PUBLIC'))
  end

  after { FileUtils.remove_entry(tmp) }

  describe 'configuration' do
    it 'requires the repo and the token' do
      expect { described_class.new(repo: '', token: '') }
        .to raise_error(ReleaseStorage::ConfigurationError, /GITHUB_STORAGE_REPO, GITHUB_STORAGE_TOKEN/)
    end

    it 'requires owner/name form' do
      expect { described_class.new(repo: 'just-a-name', token: 't') }
        .to raise_error(ReleaseStorage::ConfigurationError, %r{owner/name})
    end

    it 'refuses a public storage repo unless explicitly allowed' do
      github.repo_private = false

      expect { adapter.exist?(key) }.to raise_error(ReleaseStorage::ConfigurationError, /is public/)
    end

    it 'allows a public storage repo when GITHUB_STORAGE_ALLOW_PUBLIC=true' do
      github.repo_private = false
      stub_const('ENV', ENV.to_hash.merge('GITHUB_STORAGE_ALLOW_PUBLIC' => 'true'))

      expect(adapter.exist?(key)).to be(false)
    end

    it 'refuses a token that cannot write' do
      github.repo_push = false

      expect { adapter.exist?(key) }.to raise_error(ReleaseStorage::ConfigurationError, /cannot write/)
    end

    it 'checks the repo once, not on every operation' do
      adapter.exist?(key)
      adapter.exist?(key)

      expect(github.requests.count { |r| r[:url] == 'https://api.github.test/repos/org/store' }).to eq(1)
    end
  end

  # Task 41e: GitHub saves a download under the asset name, so a file named after the app must not carry the
  # `pipeline__` prefix; the old generic names keep it, and a release stored before 41e must still resolve.
  describe 'asset names (Task 41e)' do
    let(:named_key) { 'uploads/apps/a12/r345/pipeline/Storeapp-1.1.4-218.apk' }
    let(:old_name) { 'pipeline__Storeapp-1.1.4-218.apk' }

    it 'drops pipeline/ for a file named after the app' do
      expect(described_class.location_for(named_key)).to eq(%w[a12-r345 Storeapp-1.1.4-218.apk])
      expect(described_class.location_for('uploads/apps/a12/r345/pipeline/Storeapp-1.1.4-218.apks.br').last)
        .to eq('Storeapp-1.1.4-218.apks.br')
    end

    it 'keeps pipeline__ for the old generic names' do
      expect(described_class.location_for('uploads/apps/a12/r345/pipeline/universal.apk').last)
        .to eq('pipeline__universal.apk')
      expect(described_class.location_for(key).last).to eq('pipeline__release.apks.br')
    end

    it 'leaves binary/, icons/ and nested pipeline paths as they were' do
      expect(described_class.location_for('uploads/apps/a12/r345/binary/app.aab').last).to eq('app.aab')
      expect(described_class.location_for('uploads/apps/a12/r345/icons/app.png').last).to eq('icons__app.png')
      expect(described_class.location_for('uploads/apps/a12/r345/pipeline/sub/x.apk').last)
        .to eq('pipeline__sub__x.apk')
    end

    it 'lists the pre-41e name as a second candidate only for a named pipeline file' do
      expect(described_class.locations_for(named_key)).to eq(['a12-r345', ['Storeapp-1.1.4-218.apk', old_name]])
      expect(described_class.locations_for(key)).to eq(['a12-r345', ['pipeline__release.apks.br']])
    end

    it 'stores a new file under the bare name' do
      adapter.put(named_key, source)

      expect(github.assets_of('a12-r345')).to eq(['Storeapp-1.1.4-218.apk'])
    end

    context 'when the release was stored before 41e (asset named pipeline__...)' do
      before do
        # What the 41b workflow left behind: the asset is `pipeline__<name>`, the recorded key `pipeline/<name>`.
        adapter.put('uploads/apps/a12/r345/pipeline/universal.apk', source)
        github.rename_asset('a12-r345', 'pipeline__universal.apk', old_name)
      end

      it 'still finds, fetches and reports it' do
        dest = File.join(tmp, 'old.bin')

        expect(adapter.exist?(named_key)).to be(true)
        expect(adapter.get(named_key, dest)).to eq(dest)
        expect(File.binread(dest)).to eq('apk-bytes')
      end

      it 'replaces it with one asset under the new name on put' do
        adapter.put(named_key, source)

        expect(github.assets_of('a12-r345')).to eq(['Storeapp-1.1.4-218.apk'])
      end

      it 'deletes it' do
        adapter.delete(named_key)

        expect(adapter.exist?(named_key)).to be(false)
      end
    end
  end

  describe 'round trip' do
    it 'stores under a per-release tag with a flattened asset name, then fetches the same bytes' do
      expect(adapter.put(key, source)).to eq(key)

      expect(github.release_tags).to eq(['a12-r345'])
      expect(github.assets_of('a12-r345')).to eq(['pipeline__release.apks.br'])
      expect(adapter.exist?(key)).to be(true)

      dest = File.join(tmp, 'out', 'fetched.bin')
      expect(adapter.get(key, dest)).to eq(dest)
      expect(File.binread(dest)).to eq('apk-bytes')
      expect(File).not_to exist("#{dest}.part")
    end

    it 'replaces an existing asset of the same name' do
      adapter.put(key, source)
      File.binwrite(source, 'new-bytes')
      adapter.put(key, source)

      expect(github.assets_of('a12-r345')).to eq(['pipeline__release.apks.br'])
      dest = File.join(tmp, 'fetched.bin')
      adapter.get(key, dest)
      expect(File.binread(dest)).to eq('new-bytes')
    end

    it 'sends the token to the API and upload hosts but never to the signed download URL' do
      adapter.put(key, source)
      adapter.get(key, File.join(tmp, 'fetched.bin'))

      api_and_upload = github.requests.reject { |r| r[:url].include?('objects.github.test') }
      expect(api_and_upload).to all(satisfy { |r| r[:headers]['Authorization'] == 'Bearer ghp_SECRET_TOKEN' })

      download = github.requests.find { |r| r[:url].include?('objects.github.test') }
      expect(download[:headers]).not_to have_key('Authorization')
    end

    it 'returns nil from get when the key does not exist' do
      expect(adapter.get(key, File.join(tmp, 'nope.bin'))).to be_nil
    end
  end

  describe '#url_for' do
    it 'returns the short-lived signed URL' do
      adapter.put(key, source)

      # The fake numbers ids from 100: release 101, then the uploaded asset 102.
      expect(adapter.url_for(key)).to eq('https://objects.github.test/signed/102?sig=SECRET')
    end

    it 'returns nil for a missing key' do
      expect(adapter.url_for(key)).to be_nil
    end
  end

  describe '#delete' do
    it 'removes the asset, and the release and tag once nothing is left in it' do
      adapter.put(key, source)

      expect(adapter.delete(key)).to be(true)
      expect(adapter.exist?(key)).to be(false)
      expect(github.release_tags).to be_empty
    end

    it 'keeps the release while it still has other assets' do
      adapter.put(key, source)
      adapter.put('uploads/apps/a12/r345/binary/app.apk', source)

      adapter.delete(key)

      expect(github.release_tags).to eq(['a12-r345'])
      expect(github.assets_of('a12-r345')).to eq(['app.apk'])
    end

    it 'is a no-op for a key that is not stored' do
      expect(adapter.delete(key)).to be(true)
    end
  end

  describe 'limits and validation' do
    it 'rejects files at or over 2 GiB before contacting GitHub' do
      allow(File).to receive(:size).and_call_original
      allow(File).to receive(:size).with(source).and_return(2 * 1024**3)

      expect { adapter.put(key, source) }.to raise_error(ReleaseStorage::StorageError, /under 2 GiB/)
      expect(github.release_tags).to be_empty
    end

    it "stores an app's graphics in one per-app release, tagged a<app>-graphics (27d-d2-b)" do
      graphics_key = 'uploads/apps/a12/graphics/g7/graphic.png'

      expect(adapter.put(graphics_key, source)).to eq(graphics_key)

      expect(github.release_tags).to eq(['a12-graphics'])
      expect(github.assets_of('a12-graphics')).to eq(['g7__graphic.png'])
      dest = File.join(tmp, 'out', 'graphic.png')
      expect(adapter.get(graphics_key, dest)).to eq(dest)
      expect(File.binread(dest)).to eq('apk-bytes')
    end

    it 'keeps two graphics of one app apart and deletes one without the other' do
      first = 'uploads/apps/a12/graphics/g7/graphic.png'
      second = 'uploads/apps/a12/graphics/g8/graphic.jpg'
      adapter.put(first, source)
      adapter.put(second, source)

      adapter.delete(first)

      expect(adapter.exist?(first)).to be(false)
      expect(adapter.exist?(second)).to be(true)
    end

    it 'still rejects a graphics-looking key with no app or file' do
      expect { adapter.put('uploads/apps/graphics/g7/graphic.png', source) }
        .to raise_error(ReleaseStorage::StorageError, /cannot store key/)
      expect { adapter.put('uploads/apps/a12/graphics/', source) }
        .to raise_error(ReleaseStorage::StorageError, /cannot store key/)
    end

    it 'rejects keys outside the uploads/apps/a<id>/r<id>/ convention' do
      expect { adapter.put('uploads/debug_files/a1/d2/x.zip', source) }
        .to raise_error(ReleaseStorage::StorageError, /cannot store key/)
    end

    it 'normalises characters GitHub would rewrite in asset names' do
      adapter.put('uploads/apps/a1/r2/binary/My App (v1).apk', source)

      expect(github.assets_of('a1-r2')).to eq(['My_App__v1_.apk'])
    end
  end

  describe 'failure handling' do
    it 'retries transient 5xx responses with backoff and then succeeds' do
      adapter.exist?(key) # warm the one-time repo check
      github.failures = [503, 502]

      expect(adapter.exist?(key)).to be(false)
      expect(sleeps).to eq([1, 2])
    end

    it 'gives up after three attempts and never puts the token in the message' do
      adapter.exist?(key)
      github.failures = [503, 503, 503]

      expect { adapter.exist?(key) }.to raise_error(ReleaseStorage::StorageError) { |error|
        expect(error.message).to include('HTTP 503')
        expect(error.message).not_to include('ghp_SECRET_TOKEN')
      }
    end

    it 'keeps signed URL query strings out of network error messages' do
      adapter.put(key, source)
      allow(github).to receive(:call).and_wrap_original do |original, method, url, **opts|
        raise Errno::ECONNRESET if url.include?('objects.github.test')

        original.call(method, url, **opts)
      end

      expect { adapter.get(key, File.join(tmp, 'x.bin')) }.to raise_error(ReleaseStorage::StorageError) { |error|
        expect(error.message).to include('Errno::ECONNRESET')
        expect(error.message).not_to include('SECRET')
      }
    end
  end

  # Task 44f: renaming a stored file in place. Written, NOT run (no Ruby in the sandbox that wrote it).
  describe '#rename' do
    let(:old_key) { 'uploads/apps/a12/r345/pipeline/universal.apk' }
    let(:new_key) { 'uploads/apps/a12/r345/pipeline/appstore-1.1.4.apk' }

    it 'renames the asset with one PATCH: no upload, no delete, the bytes stay readable under the new key' do
      adapter.put(old_key, source)
      github.requests.clear

      expect(adapter.rename(old_key, new_key)).to eq(:renamed)

      expect(github.assets_of('a12-r345')).to eq(['appstore-1.1.4.apk'])
      expect(github.requests.map { |r| r[:method] }).to include(:patch)
      expect(github.requests.map { |r| r[:method] }).not_to include(:delete)
      expect(github.requests.select { |r| r[:method] == :post }).to be_empty
      target = File.join(tmp, 'out.bin')
      expect(adapter.get(new_key, target)).to eq(target)
      expect(File.binread(target)).to eq('apk-bytes')
    end

    it 'finds a file stored under the pre-41e name and renames that' do
      adapter.put(old_key, source)
      expect(github.assets_of('a12-r345')).to eq(['pipeline__universal.apk'])

      expect(adapter.rename(old_key, new_key)).to eq(:renamed)
      expect(github.assets_of('a12-r345')).to eq(['appstore-1.1.4.apk'])
    end

    it 'renames an uploaded file in the binary folder' do
      adapter.put('uploads/apps/a12/r345/binary/app-release.aab', source)

      expect(adapter.rename('uploads/apps/a12/r345/binary/app-release.aab',
                            'uploads/apps/a12/r345/binary/appstore-1.1.4.aab')).to eq(:renamed)
      expect(github.assets_of('a12-r345')).to eq(['appstore-1.1.4.aab'])
    end

    it 'is safe to repeat: the second call answers :already and changes nothing' do
      adapter.put(old_key, source)
      adapter.rename(old_key, new_key)
      github.requests.clear

      expect(adapter.rename(old_key, new_key)).to eq(:already)
      expect(github.requests.map { |r| r[:method] }).not_to include(:patch)
    end

    it 'answers :same when both keys name one asset and :missing when neither exists' do
      adapter.put(old_key, source)
      expect(adapter.rename(old_key, old_key)).to eq(:same)
      expect(adapter.rename('uploads/apps/a12/r345/pipeline/none.apk', 'uploads/apps/a12/r345/pipeline/other.apk'))
        .to eq(:missing)
      expect(adapter.rename('uploads/apps/a12/r999/pipeline/a.apk', 'uploads/apps/a12/r999/pipeline/b.apk'))
        .to eq(:missing)
    end

    it 'refuses to overwrite: when both names exist nothing changes' do
      adapter.put(old_key, source)
      adapter.put(new_key, source)

      expect { adapter.rename(old_key, new_key) }.to raise_error(ReleaseStorage::StorageError, /already exists/)
      expect(github.assets_of('a12-r345')).to contain_exactly('pipeline__universal.apk', 'appstore-1.1.4.apk')
    end

    it 'refuses to move a file into another storage release' do
      adapter.put(old_key, source)

      expect { adapter.rename(old_key, 'uploads/apps/a12/r346/pipeline/appstore-1.1.4.apk') }
        .to raise_error(ReleaseStorage::StorageError, /different storage releases/)
    end

    it 'names GitHub\'s answer when the rename call fails, without the token' do
      adapter.put(old_key, source)
      adapter.exist?(old_key)
      github.failures = [422]

      expect { adapter.rename(old_key, new_key) }.to raise_error(ReleaseStorage::StorageError) { |error|
        expect(error.message).to include('HTTP 422')
        expect(error.message).not_to include('ghp_SECRET_TOKEN')
      }
    end
  end
end
