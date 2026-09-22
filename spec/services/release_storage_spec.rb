# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReleaseStorage do
  def with_env(overrides)
    stub_const('ENV', ENV.to_hash.except('RELEASE_STORAGE_ADAPTER').merge(overrides))
  end

  describe '.adapter_name' do
    it 'defaults to local outside production so dev setups keep working' do
      with_env({})
      allow(Rails.env).to receive(:production?).and_return(false)

      expect(described_class.adapter_name).to eq('local')
    end

    it 'refuses to fall back to local disk in production' do
      with_env({})
      allow(Rails.env).to receive(:production?).and_return(true)

      expect { described_class.adapter_name }
        .to raise_error(ReleaseStorage::ConfigurationError, /RELEASE_STORAGE_ADAPTER is not set/)
    end

    it 'treats a blank value like an unset one' do
      with_env('RELEASE_STORAGE_ADAPTER' => '  ')
      allow(Rails.env).to receive(:production?).and_return(true)

      expect { described_class.adapter_name }.to raise_error(ReleaseStorage::ConfigurationError)
    end

    it 'is case-insensitive when set' do
      with_env('RELEASE_STORAGE_ADAPTER' => 'GitHub')

      expect(described_class.adapter_name).to eq('github')
    end
  end

  describe '.remote?' do
    it 'is false for local disk and true for r2 and github' do
      with_env('RELEASE_STORAGE_ADAPTER' => 'local')
      expect(described_class.remote?).to be(false)

      with_env('RELEASE_STORAGE_ADAPTER' => 'github')
      expect(described_class.remote?).to be(true)

      with_env('RELEASE_STORAGE_ADAPTER' => 'r2')
      expect(described_class.remote?).to be(true)
    end
  end

  describe '#store_binary' do
    it "stores the file under the release's binary directory and returns the key" do
      with_env('RELEASE_STORAGE_ADAPTER' => 'local')
      release = double('Release', id: 9, app: double(id: 3))
      storage = described_class.new(release)
      allow(storage.adapter).to receive(:put)

      key = storage.store_binary('/somewhere/on/disk/app_internal_proxy.apk')

      expect(key).to eq('uploads/apps/a3/r9/binary/app_internal_proxy.apk')
      expect(storage.adapter).to have_received(:put).with(key, '/somewhere/on/disk/app_internal_proxy.apk')
    end
  end

  describe '#with_local_file' do
    let(:tmp) { Dir.mktmpdir }
    let(:release) { double('Release', id: 9, app: double(id: 4)) }

    after { FileUtils.remove_entry(tmp) }

    it 'yields the local path without touching storage when the local file exists' do
      with_env('RELEASE_STORAGE_ADAPTER' => 'local')
      local = File.join(tmp, 'app.apk')
      File.write(local, 'bytes')
      allow(release).to receive(:file).and_return(double(path: local))
      storage = described_class.new(release)
      allow(storage.adapter).to receive(:get)

      yielded = nil
      storage.with_local_file { |path| yielded = path }

      expect(yielded).to eq(local)
      expect(storage.adapter).not_to have_received(:get)
    end

    it 'downloads the mirrored copy to a tempdir when the local file is gone, then cleans it up' do
      with_env('RELEASE_STORAGE_ADAPTER' => 'local')
      allow(release).to receive(:file).and_return(double(path: File.join(tmp, 'gone.apk')))
      allow(release).to receive(:file_storage_key).and_return('uploads/apps/a4/r9/binary/app.apk')
      storage = described_class.new(release)
      allow(storage.adapter).to receive(:get) do |_key, to|
        File.write(to, 'mirrored-bytes')
        to
      end

      captured_path = nil
      storage.with_local_file { |path| captured_path = path }

      expect(File.basename(captured_path)).to eq('app.apk')
      expect(File).not_to exist(captured_path) # cleaned up once the block returned
      expect(storage.adapter).to have_received(:get).with('uploads/apps/a4/r9/binary/app.apk', anything)
    end

    it 'cleans up the tempdir even when the block raises' do
      with_env('RELEASE_STORAGE_ADAPTER' => 'local')
      allow(release).to receive(:file).and_return(double(path: File.join(tmp, 'gone.apk')))
      allow(release).to receive(:file_storage_key).and_return('uploads/apps/a4/r9/binary/app.apk')
      storage = described_class.new(release)
      allow(storage.adapter).to receive(:get) { |_key, to| File.write(to, 'x'); to }
      captured_path = nil

      expect {
        storage.with_local_file { |path| captured_path = path; raise 'boom' }
      }.to raise_error('boom')
      expect(File).not_to exist(captured_path)
    end

    it 'raises MissingFileError when there is no local file and no storage key' do
      with_env('RELEASE_STORAGE_ADAPTER' => 'local')
      allow(release).to receive(:file).and_return(double(path: File.join(tmp, 'gone.apk')))
      allow(release).to receive(:file_storage_key).and_return(nil)
      storage = described_class.new(release)

      expect { storage.with_local_file { |_| } }.to raise_error(ReleaseStorage::MissingFileError, /never mirrored/)
    end

    it 'raises MissingFileError when storage has no object for the key' do
      with_env('RELEASE_STORAGE_ADAPTER' => 'local')
      allow(release).to receive(:file).and_return(double(path: File.join(tmp, 'gone.apk')))
      allow(release).to receive(:file_storage_key).and_return('uploads/apps/a4/r9/binary/app.apk')
      storage = described_class.new(release)
      allow(storage.adapter).to receive(:get).and_return(nil)

      expect { storage.with_local_file { |_| } }.to raise_error(ReleaseStorage::MissingFileError, /no object/)
    end
  end

  describe '.build_adapter' do
    it 'builds the github adapter' do
      with_env('RELEASE_STORAGE_ADAPTER' => 'github', 'GITHUB_STORAGE_REPO' => 'org/store',
               'GITHUB_STORAGE_TOKEN' => 'token')

      expect(described_class.build_adapter).to be_a(ReleaseStorage::GithubAdapter)
    end

    it 'builds the local adapter' do
      with_env('RELEASE_STORAGE_ADAPTER' => 'local')

      expect(described_class.build_adapter).to be_a(ReleaseStorage::LocalAdapter)
    end

    it 'rejects unknown adapters and lists the valid ones' do
      with_env('RELEASE_STORAGE_ADAPTER' => 's3')

      expect { described_class.build_adapter }
        .to raise_error(ReleaseStorage::ConfigurationError, /Unknown RELEASE_STORAGE_ADAPTER.*local, r2, github/)
    end
  end
end
