# frozen_string_literal: true

require 'rails_helper'
require 'base64'

# Z-P13: the zip reader/rebuilder under the File-by-File generator. Runtime-verified in the sandbox that
# wrote it (pure Ruby + zlib). The acceptance for this card is a byte-for-byte round trip, so the first test
# pins a real archive written by an independent tool (Python's zipfile) and demands the rebuild equal it.
RSpec.describe ArchivePatcher::ZipArchive do
  # 3 entries: one STORED, two DEFLATED at python's default level. Written by python zipfile, not by us.
  PYTHON_ARCHIVE = Base64.decode64(
    'UEsDBBQAAAAAAAAAIQBrSX50EgAAABIAAAAKAAAAc3RvcmVkLnR4dHJhdyBieXRlcyBzdGF5IHJhd1BLAwQU' \
    'AAAACAAAACEAehUPxhMAAADgAQAACAAAAG5vdGUudHh0y0jNyclXKM8vyknhyhhlDzs2AFBLAwQUAAAA' \
    'CAC6ZkpdyyICZz4BAAAAFAAACwAAAHBheWxvYWQuYmluY2BkYmZhZWPn4OTi5uHl4xcQFBIWERUTl5CU' \
    'kpaRlZNXUFRSVlFVU9fQ1NLW0dXTNzA0MjYxNTO3sLSytrG1s3dwdHJ2cXVz9/D08vbx9fMPCAwKDgkN' \
    'C4+IjIqOiY2LT0hMSk5JTUvPyMzKzsnNyy8oLCouKS0rr6isqq6pratvaGxqbmlta+/o7Oru6e3rnzBx' \
    '0uQpU6dNnzFz1uw5c+fNX7Bw0eIlS5ctX7Fy1eo1a9et37Bx0+YtW7dt37Fz1+49e/ftP3Dw0OEjR48d' \
    'P3Hy1OkzZ8+dv3Dx0uUrV69dv3Hz1u07d+/df/Dw0eMnT589f/Hy1es3b9+9//Dx0+cvX799//Hz1+8/' \
    'f//9Zxj1/6j/R/0/6v9R/4/6f9T/o/4f9f+o/0f9P+r/Uf+P+n/U/6P+H/X/qP+Hsf8BUEsBAhQDFAAA' \
    'AAAAAAAhAGtJfnQSAAAAEgAAAAoAAAAAAAAAAAAAAIABAAAAAHN0b3JlZC50eHRQSwECFAMUAAAACAAA' \
    'ACEAehUPxhMAAADgAQAACAAAAAAAAAAAAAAAgAE6AAAAbm90ZS50eHRQSwECFAMUAAAACAC6ZkpdyyIC' \
    'Zz4BAAAAFAAACwAAAAAAAAAAAAAAgAFzAAAAcGF5bG9hZC5iaW5QSwUGAAAAAAMAAwCnAAAA2gEAAAAA'
  )

  let(:python_archive) { PYTHON_ARCHIVE }

  describe '.read' do
    it 'lists the entries with their method, sizes and content' do
      entries = described_class.read(python_archive)
      expect(entries.map(&:name)).to eq(%w[stored.txt note.txt payload.bin])
      expect(entries[0].stored?).to be(true)
      expect(entries[1].deflated?).to be(true)
      expect(entries[0].content).to eq('raw bytes stay raw')
      expect(entries[1].content.bytesize).to eq(480)
      expect(entries[2].content.bytesize).to eq(5120)
    end

    it 'recovers the deflate level so the entry can be re-compressed to the same bytes' do
      entries = described_class.read(python_archive)
      entries.select(&:deflated?).each do |entry|
        expect(entry.deflate_level).not_to be_nil
        expect(described_class.deflate(entry.content, entry.deflate_level, entry.deflate_strategy))
          .to eq(entry.compressed)
      end
    end
  end

  describe '.build' do
    it 'rebuilds an archive read from disk byte for byte' do
      expect(described_class.build(described_class.read(python_archive))).to eq(python_archive)
    end

    it 'is byte-identical across a second round trip (idempotent)' do
      once = described_class.build(described_class.read(python_archive))
      twice = described_class.build(described_class.read(once))
      expect(twice).to eq(once)
    end

    it 'round-trips an archive it built itself' do
      entries = [
        described_class::Entry.new(name: 'a.txt', flags: 0, method: described_class::DEFLATED,
                                   time: 0x4a5d, date: 0x5d65, extra: '', crc: 0, comp_size: 0,
                                   uncomp_size: 0, content: 'compress me ' * 50, deflate_level: 6,
                                   deflate_strategy: 0),
        described_class::Entry.new(name: 'b.bin', flags: 0, method: described_class::STORED,
                                   time: 0x4a5d, date: 0x5d65, extra: '', crc: 0, comp_size: 0,
                                   uncomp_size: 0, content: (0..255).to_a.pack('C*')),
      ]
      built = described_class.build(entries)
      expect(described_class.build(described_class.read(built))).to eq(built)
      expect(described_class.read(built).map(&:content)).to eq(entries.map(&:content))
    end

    it 'keeps independent entries independent when one content changes' do
      base = described_class.read(python_archive)
      base[1].content = 'a different note entirely'
      rebuilt = described_class.build(base)
      entries = described_class.read(rebuilt)
      expect(entries[1].content).to eq('a different note entirely')
      expect(entries[0].content).to eq('raw bytes stay raw') # untouched neighbour unchanged
    end

    it 'refuses an archive that is not a zip' do
      expect { described_class.read('not a zip at all') }.to raise_error(ArchivePatcher::ZipArchive::Error)
    end
  end
end
