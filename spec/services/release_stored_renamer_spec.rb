# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# Task 44f: ReleaseStoredRenamer on the local adapter (a temp folder). Written, NOT run (no Ruby in the sandbox
# that wrote it), so look here first if CI is red for this slice.
RSpec.describe ReleaseStoredRenamer do
  let!(:app) { create(:app, name: 'Appstore') }
  let!(:channel) { app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android) }
  let(:state) { 'done' }
  let!(:release) do
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.1.4', build_version: '218',
                ci_compile_state: state).tap { |r| r.save!(validate: false) }
  end
  let(:root) { Dir.mktmpdir }
  let(:storage) { ReleaseStorage.new(release, adapter: ReleaseStorage::LocalAdapter.new(root: root)) }
  let(:source) { File.join(root, 'source.bin').tap { |path| File.binwrite(path, 'bytes') } }

  def key(folder, name)
    "uploads/apps/a#{app.id}/r#{release.id}/#{folder}/#{name}"
  end

  before do
    {
      file_storage_key: key('binary', 'app-release.aab'),
      universal_apk_storage_key: key('pipeline', 'universal.apk'),
      compressed_apks_storage_key: key('pipeline', 'release.apks.br'),
      icon_storage_key: key('icons', 'icon.png')
    }.each do |column, stored|
      storage.adapter.put(stored, source)
      release.update_columns(column => stored)
    end
  end

  it 'renames every stored file to <name>-<version> and records the new keys' do
    changes = described_class.new(release, storage: storage).call

    expect(changes.map(&:status)).to all(eq(:renamed))
    expect(release.reload).to have_attributes(
      file_storage_key: key('binary', 'appstore-1.1.4.aab'),
      universal_apk_storage_key: key('pipeline', 'appstore-1.1.4.apk'),
      compressed_apks_storage_key: key('pipeline', 'appstore-1.1.4.apks.br'),
      icon_storage_key: key('icons', 'appstore-1.1.4.png')
    )
    expect(storage.exist?(key('pipeline', 'appstore-1.1.4.apk'))).to be(true)
    expect(storage.exist?(key('pipeline', 'universal.apk'))).to be(false)
  end

  it 'answers :same on a repeat and changes nothing' do
    described_class.new(release, storage: storage).call
    changes = described_class.new(release.reload, storage: storage).call

    expect(changes.map(&:status)).to all(eq(:same))
  end

  it 'finishes a run that stopped half way: a file already moved is recorded, not an error' do
    storage.rename(key('pipeline', 'universal.apk'), key('pipeline', 'appstore-1.1.4.apk'))

    changes = described_class.new(release, storage: storage).call

    expect(changes.find { |c| c.column == :universal_apk_storage_key }.status).to eq(:already)
    expect(release.reload.universal_apk_storage_key).to eq(key('pipeline', 'appstore-1.1.4.apk'))
  end

  it 'never overwrites: when the new name exists next to the old one the key keeps the old name' do
    storage.adapter.put(key('pipeline', 'appstore-1.1.4.apk'), source)

    expect { described_class.new(release, storage: storage).call }.to raise_error(ReleaseStorage::StorageError)
    expect(release.reload.universal_apk_storage_key).to eq(key('pipeline', 'universal.apk'))
  end

  %w[queued dispatched].each do |busy|
    context "when CI is #{busy}" do
      let(:state) { busy }

      it 'refuses and renames nothing' do
        expect { described_class.new(release, storage: storage).call }.to raise_error(described_class::Refused, 'ci_busy')
        expect(storage.exist?(key('pipeline', 'universal.apk'))).to be(true)
      end
    end
  end

  it 'refuses a release with no stored file' do
    described_class::COLUMNS.each { |column| release.update_columns(column => nil) }

    expect { described_class.new(release, storage: storage).call }
      .to raise_error(described_class::Refused, 'nothing_stored')
  end
end
