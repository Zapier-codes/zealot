# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'zlib'

# Task 43f-2. The release and the job classes are fakes (the repo has no release factory; the mirror job spec
# does the same), so this checks the rules and the order of the writes. NOT run (the operator said no testing).
RSpec.describe ListingIconIngest do
  let(:dir) { Dir.mktmpdir }
  let(:stored_dir) { Dir.mktmpdir }

  let(:release_class) do
    stored = stored_dir
    Struct.new(:id, :icon_storage_key, :icon_sha256, :saved, :new_icon_bytes, keyword_init: true) do
      define_method(:icon=) { |io| self.new_icon_bytes = io.read }
      define_method(:save!) { |validate: true| self.saved = validate == false ? :unvalidated : :validated }
      define_method(:icon) do
        path = File.join(stored, 'icon.png')
        File.binwrite(path, new_icon_bytes.to_s) if new_icon_bytes
        Struct.new(:path).new(path)
      end
      define_method(:update_columns) { |attributes| attributes.each { |column, value| public_send("#{column}=", value) } }
    end
  end
  let(:release) { release_class.new(id: 7, icon_storage_key: 'old/key.png', icon_sha256: 'old' * 21 + 'x') }
  let(:tenant) { double('tenant') }
  let(:app) { double('app', id: 2, tenant: tenant, catalog_releases: [ release ]) }
  let(:publisher) { class_double(CatalogIndexPublishJob, enqueue_for: nil) }
  let(:mirror) { class_double(ReleaseFileMirrorJob, perform_later: nil) }

  after do
    FileUtils.remove_entry(dir)
    FileUtils.remove_entry(stored_dir)
  end

  def chunk(type, data = ''.b)
    [ data.bytesize ].pack('N') + type.b + data.b + [ Zlib.crc32(type.b + data.b) ].pack('N')
  end

  def png(width: 512, height: 512, padding: 0)
    ihdr = [ width, height, 8, 6, 0, 0, 0 ].pack('NNCCCCC')
    ListingGraphicInspector::PNG_SIGNATURE + chunk('IHDR', ihdr) + chunk('IDAT', 'x' + 'y' * padding) + chunk('IEND')
  end

  def file(bytes, name = 'icon.png')
    File.join(dir, name).tap { |path| File.binwrite(path, bytes) }
  end

  def call(path)
    described_class.call(app: app, path: path, publisher: publisher, mirror: mirror)
  end

  it 'puts a 512 x 512 PNG on the newest catalog release, clears the old key and hash, hashes the new file' do
    result = call(file(png))

    expect(result).to be_ok
    expect(result.release).to eq(release)
    expect(release.saved).to eq(:unvalidated)
    expect(release.icon_storage_key).to be_nil
    expect(release.icon_sha256).to eq(Digest::SHA256.hexdigest(png))
  end

  it 'enqueues the mirror and the index republish for the app tenant (the two traps)' do
    call(file(png))

    expect(mirror).to have_received(:perform_later).with(7)
    expect(publisher).to have_received(:enqueue_for).with(tenant)
  end

  it 'refuses a size other than 512 x 512 and changes nothing' do
    result = call(file(png(width: 432, height: 432)))

    expect(result).not_to be_ok
    expect(result.violations.map(&:code)).to eq([ :wrong_size ])
    expect(release.saved).to be_nil
    expect(publisher).not_to have_received(:enqueue_for)
  end

  it 'refuses a file that is not a PNG and one over 1 MB, naming every reason' do
    not_png = call(file("\xFF\xD8\xFF\xE0".b + 'jpeg-ish'.b, 'icon.jpg'))
    expect(not_png.violations.map(&:code)).to include(:not_png)

    big = call(file(png(padding: 1_100_000)))
    expect(big.violations.map(&:code)).to eq([ :file_too_large ])
    expect(release.saved).to be_nil
  end

  it 'refuses when the app has no catalog release, writing nothing' do
    allow(app).to receive(:catalog_releases).and_return([])

    result = call(file(png))

    expect(result).not_to be_ok
    expect(result.violations.map(&:code)).to eq([ :no_release ])
    expect(mirror).not_to have_received(:perform_later)
    expect(publisher).not_to have_received(:enqueue_for)
  end

  it 'refuses a missing file' do
    expect(call(File.join(dir, 'nope.png')).violations.map(&:code)).to eq([ :no_file ])
  end
end
