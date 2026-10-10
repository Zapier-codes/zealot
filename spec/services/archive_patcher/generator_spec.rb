# frozen_string_literal: true

require 'rails_helper'

# Z-P13: the generator half's integration glue -- when it runs, what it stores, what it writes to the
# release. Written, NOT run (no bundle/Postgres in the sandbox that wrote it); the File-by-File algorithm
# it calls is runtime-verified by the three specs beside this one.
RSpec.describe ArchivePatcher::Generator do
  let(:app_record) { create(:app) }
  let(:channel) { app_record.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android) }

  def make_release(version, build, key)
    Release.new(channel: channel, version: version, build_version: build, release_version: "1.0.#{version}",
                file_storage_key: key).tap { |r| r.save!(validate: false) }
  end

  let(:old_key) { "/tmp/zealot-gen-spec-old-#{Process.pid}.apk" }
  let(:new_key) { "/tmp/zealot-gen-spec-new-#{Process.pid}.apk" }
  let(:old_release) { make_release(1, '100', old_key) }
  let(:new_release) { make_release(2, '200', new_key) }

  # Only two methods matter: fetch (write the stored bytes to `to:` and hand back that path, as the real
  # adapter does) and store_delta_patch_bytes (record the patch and return its storage key).
  let(:storage) do
    instance_double(ReleaseStorage).tap do |s|
      allow(s).to receive(:fetch) do |key, to:|
        FileUtils.mkdir_p(File.dirname(to))
        File.binwrite(to, File.binread(key))
        to
      end
      allow(s).to receive(:store_delta_patch_bytes) do |_bytes, from_release:, from_version_code:|
        "uploads/apps/a1/r#{new_release.id}/pipeline/delta-from-#{from_version_code}.gfb"
      end
    end
  end

  def write_release(key, content)
    zip = ArchivePatcher::ZipArchive
    entry = zip::Entry.new(name: 'classes.dex', flags: 0, method: zip::DEFLATED, time: 0, date: 0, extra: '',
                           crc: 0, comp_size: 0, uncomp_size: 0, content: content,
                           deflate_level: 6, deflate_strategy: 0)
    File.binwrite(key, zip.build([entry]))
  end

  before { allow(described_class).to receive(:enabled?).and_return(true) }
  after { [old_key, new_key].each { |k| File.delete(k) if File.exist?(k) } }

  describe '.enabled?' do
    it 'reads the config flag' do
      allow(described_class).to receive(:enabled?).and_call_original
      allow(Rails.application.config.x.anthropic).to receive(:delta_patching_enabled).and_return(false)
      expect(described_class.enabled?).to be(false)
    end
  end

  describe '#generate_from' do
    it 'stores a patch and records a manifest on the newer release' do
      write_release(old_key, 'dex version one')
      write_release(new_key, 'dex version two')

      manifest = described_class.new(new_release, storage: storage).generate_from(old_release)

      expect(manifest).to include('from_release_id' => old_release.id, 'from_version_code' => '100',
                                  'format' => 'GFbFv1_0')
      expect(manifest['size']).to be.positive
      expect(manifest['storage_key']).to end_with('.gfb')
      expect(new_release.reload.delta_patches.map { |p| p['from_release_id'] }).to eq([old_release.id])
    end

    it 'replaces an earlier patch from the same base rather than accumulating' do
      write_release(old_key, 'dex version one')
      write_release(new_key, 'dex version two')
      generator = described_class.new(new_release, storage: storage)
      2.times { generator.generate_from(old_release) }

      expect(new_release.reload.delta_patches.size).to eq(1)
    end

    it 'is a no-op for a release with no previous version' do
      expect(described_class.new(new_release, storage: storage).generate_from(nil)).to be_nil
      expect(new_release.delta_patches).to eq([])
    end

    it 'refuses when the two archives are identical' do
      write_release(old_key, 'identical bytes here')
      write_release(new_key, 'identical bytes here')
      expect(described_class.new(new_release, storage: storage).generate_from(old_release)).to be_nil
    end

    it 'produces nothing when the feature is off' do
      allow(described_class).to receive(:enabled?).and_return(false)
      write_release(old_key, 'a')
      write_release(new_key, 'b')
      expect(described_class.new(new_release, storage: storage).generate_from(old_release)).to be_nil
    end

    it 'logs and returns nil instead of raising on an unreadable archive' do
      write_release(new_key, 'not really an archive')
      write_release(old_key, 'not really an archive either')
      expect(described_class.new(new_release, storage: storage).generate_from(old_release)).to be_nil
    end

    it 'diffs the universal APK for a CI-built release' do
      write_release(old_key, 'dex version one')
      allow(new_release).to receive(:serves_universal_apk?).and_return(true)
      allow(new_release).to receive(:universal_apk_storage_key).and_return('a1/r2/pipeline/universal.apk')
      allow(storage).to receive(:fetch).with('a1/r2/pipeline/universal.apk', to: anything) do |_key, to:|
        File.binwrite(to, 'not an archive') # the universal key is what it asks for, not the bundle
        to
      end

      expect(described_class.new(new_release, storage: storage).generate_from(old_release)).to be_nil
      expect(storage).to have_received(:fetch).with('a1/r2/pipeline/universal.apk', to: anything)
    end
  end
end
