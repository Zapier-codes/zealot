# frozen_string_literal: true

require 'rails_helper'

# Z-P13: the File-by-File v1 generator/applier, end to end. Runtime-verified in the sandbox that wrote it
# (pure Ruby + bzip2 + zlib). The card's acceptance -- the client applies the patch and must match byte for
# byte -- is exactly `expect(FileByFile.apply(old, patch)).to eq(new)` below, checked for an edited entry, a
# grown entry, an added entry, a removed entry and an untouched archive.
RSpec.describe ArchivePatcher::FileByFile do
  Z = ArchivePatcher::ZipArchive

  def archive(*entries)
    Z.build(entries.map do |name, content, method|
      Z::Entry.new(name: name, flags: 0, method: method, time: 0x4a5d, date: 0x5d65, extra: '',
                   crc: 0, comp_size: 0, uncomp_size: 0, content: content,
                   deflate_level: method == Z::DEFLATED ? 6 : nil,
                   deflate_strategy: method == Z::DEFLATED ? 0 : nil)
    end)
  end

  # A blob that compresses well but whose lines differ (so deflate's block boundaries move when one line
  # changes, which is exactly the case File-by-File exists to handle).
  def distinct_lines(seed, count)
    (0...count).map { |i| "record #{seed} line #{i}: the quick brown fox jumps over the lazy dog" }.join("\n")
  end

  def blob(seed, bytes)
    base = "record #{seed}: lorem ipsum dolor sit amet consectetur\n"
    (base * (bytes / base.bytesize + 1)).byteslice(0, bytes)
  end

  let(:old_archive) do
    archive(
      ['AndroidManifest.xml', '<manifest>version 1</manifest>', Z::DEFLATED],
      ['classes.dex', blob(1, 90_000), Z::DEFLATED],
      ['res/raw/data.bin', (0..255).to_a.pack('C*') * 4, Z::STORED],
      ['assets/notes.txt', 'shipping notes', Z::DEFLATED]
    )
  end

  # The same archive with one entry's content replaced. Rebuilt rather than patched byte-wise: a raw `sub`
  # on an archive would change a compressed length without updating the central directory and leave a
  # deliberately invalid zip, which is not what a real release pair looks like.
  def archive_with(overrides)
    entries = [
      ['AndroidManifest.xml', '<manifest>version 1</manifest>', Z::DEFLATED],
      ['classes.dex', blob(1, 90_000), Z::DEFLATED],
      ['res/raw/data.bin', (0..255).to_a.pack('C*') * 4, Z::STORED],
      ['assets/notes.txt', 'shipping notes', Z::DEFLATED]
    ].map { |name, content, method| [name, overrides.fetch(name, content), method] }
    archive(*entries)
  end

  def expect_round_trip(old, new)
    result = described_class.generate(old, new)
    expect(result.patch.byteslice(0, 8)).to eq('GFbFv1_0')
    expect(result.old_size).to eq(old.bytesize)
    expect(result.new_size).to eq(new.bytesize)
    expect(described_class.apply(old, result.patch)).to eq(new)
    result
  end

  it 'patches an entry whose content changed' do
    changed = archive_with('AndroidManifest.xml' => '<manifest>version 2</manifest>')
    expect_round_trip(old_archive, changed)
  end

  it 'patches an entry that grew' do
    changed = archive_with('assets/notes.txt' => 'shipping notes, now much longer and different')
    expect_round_trip(old_archive, changed)
  end

  it 'patches a STORED entry that changed' do
    changed = archive_with('res/raw/data.bin' => ('x' * 700).b)
    expect_round_trip(old_archive, changed)
  end

  it 'patches an added and a removed entry (they change the surrounding layout)' do
    with_extra = archive(
      ['AndroidManifest.xml', '<manifest>version 1</manifest>', Z::DEFLATED],
      ['classes.dex', blob(1, 90_000), Z::DEFLATED],
      ['lib/arm64-v8a/libfoo.so', blob(9, 40_000), Z::DEFLATED],
      ['res/raw/data.bin', (0..255).to_a.pack('C*') * 4, Z::STORED],
      ['assets/notes.txt', 'shipping notes', Z::DEFLATED]
    )
    expect_round_trip(old_archive, with_extra)
    expect_round_trip(with_extra, old_archive) # and back, the removed direction
  end

  it 'is much smaller than a whole-file bsdiff for a small edit in a big compressed entry' do
    old_text = distinct_lines(2, 15_000)
    large_old = archive(['assets/big.txt', old_text, Z::DEFLATED])
    large_new = archive(['assets/big.txt', old_text.sub('line 7000:', 'line 7000 CHANGED:'), Z::DEFLATED])

    file_by_file = described_class.generate(large_old, large_new).patch
    naive = ArchivePatcher::BsDiff.diff(large_old, large_new)

    expect(file_by_file.bytesize).to be < (naive.bytesize / 2)
    expect(described_class.apply(large_old, file_by_file)).to eq(large_new)
  end

  it 'verifies the patch it made before returning it (a bad patch is never stored)' do
    changed = archive_with('assets/notes.txt' => 'changed')
    expect { described_class.generate(old_archive, changed) }.not_to raise_error
  end

  it 'reports the sha256 of both sides so the client can check its inputs and output' do
    changed = archive_with('assets/notes.txt' => 'changed')
    result = described_class.generate(old_archive, changed)
    expect(result.old_sha256).to eq(Digest::SHA256.hexdigest(old_archive))
    expect(result.new_sha256).to eq(Digest::SHA256.hexdigest(changed))
  end

  it 'refuses a patch that is not a File-by-File v1 container' do
    expect { described_class.apply(old_archive, 'garbage bytes here') }
      .to raise_error(ArchivePatcher::FileByFile::Error)
  end

  it 'refuses a truncated patch' do
    changed = archive_with('assets/notes.txt' => 'changed')
    patch = described_class.generate(old_archive, changed).patch
    expect { described_class.apply(old_archive, patch.byteslice(0, patch.bytesize - 5)) }
      .to raise_error(ArchivePatcher::Error)
  end

  it 'names the changed regions in its op counts' do
    changed = archive_with('assets/notes.txt' => 'changed')
    result = described_class.generate(old_archive, changed)
    expect(result.uncompression_ops).to eq(1) # one changed deflated entry inflated on the old side
    expect(result.recompression_ops).to eq(1) # ... and recompressed on the new side
  end
end
