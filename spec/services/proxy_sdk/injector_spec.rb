# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe ProxySdk::Injector do
  # Columns update_columns may touch. `file_size` is deliberately absent: it is
  # a method on Release, not a column, and writing it raised.
  let(:release_columns) { %i[file patched_file_path] }
  let(:tmp) { Dir.mktmpdir }
  let(:updates) { [] }
  let(:platform) { 'android' }
  let(:play_target) { false }
  let(:path) { File.join(tmp, 'app.aab') }
  let(:release) do
    columns = release_columns
    recorded = updates
    double('Release', platform: platform, file: double(path: path), play_store_target?: play_target).tap do |r|
      allow(r).to receive(:update_columns) do |attrs|
        raise ArgumentError, "unknown column #{(attrs.keys - columns).inspect}" unless (attrs.keys - columns).empty?

        recorded << attrs
      end
    end
  end

  before do
    File.write(path, 'original-bytes')
    allow(described_class).to receive(:puts)
    # Stand-in for `python3 patcher in out dex key`: writes the patched file.
    allow(described_class).to receive(:system) do |command|
      output = command.split[3]
      File.write(output, 'patched-bytes')
      true
    end
  end

  after { FileUtils.remove_entry(tmp) }

  it 'leaves non-Android releases alone' do
    allow(release).to receive(:platform).and_return('iOS')

    described_class.call(release)

    expect(described_class).not_to have_received(:system)
    expect(File.read(path)).to eq('original-bytes')
  end

  context 'with an internal AAB' do
    it 'replaces it with the patched APK and points the release at the renamed file' do
      described_class.call(release)

      apk = File.join(tmp, 'app.apk')
      expect(File).not_to exist(path)
      expect(File.read(apk)).to eq('patched-bytes')
      expect(updates).to eq([{ file: 'app.apk', patched_file_path: nil }])
    end
  end

  context 'with an internal APK' do
    let(:path) { File.join(tmp, 'app.apk') }

    it 'patches it in place' do
      described_class.call(release)

      expect(File.read(path)).to eq('patched-bytes')
      expect(updates).to eq([{ file: 'app.apk', patched_file_path: nil }])
    end
  end

  context 'with a Play-targeted release' do
    let(:play_target) { true }

    it 'keeps the clean AAB and records the patched internal APK next to it' do
      described_class.call(release)

      expect(File.read(path)).to eq('original-bytes')
      expect(updates.size).to eq(1)
      internal = updates.first.fetch(:patched_file_path)
      expect(File.dirname(internal)).to eq(tmp)
      expect(File.extname(internal)).to eq('.apk')
      expect(File.read(internal)).to eq('patched-bytes')
      expect(updates.first.keys).to eq([:patched_file_path])
    end
  end

  it 'changes nothing when the patcher fails' do
    allow(described_class).to receive(:system).and_return(false)

    described_class.call(release)

    expect(File.read(path)).to eq('original-bytes')
    expect(updates).to be_empty
  end
end
