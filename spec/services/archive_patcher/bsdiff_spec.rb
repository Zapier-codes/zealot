# frozen_string_literal: true

require 'rails_helper'

# Z-P13: the bsdiff codec that carries the File-by-File delta. Runtime-verified in the sandbox that wrote it
# (pure Ruby + the bzip2 binary; no Rails needed). A round trip of every shape a real pair of APKs shows:
# identical, inserted, deleted, repeated and moved (a seek that goes backwards) content.
RSpec.describe ArchivePatcher::BsDiff do
  def roundtrip(old, new)
    described_class.patch(old.b, described_class.diff(old.b, new.b))
  end

  it 'produces an empty-payload patch for identical inputs' do
    old = 'the same bytes for both sides'
    patch = described_class.diff(old.b, old.b)
    expect(described_class.patch(old.b, patch)).to eq(old.b)
    expect(patch.bytesize).to be < 200 # header + framing only, not the 27 bytes of content
  end

  it 'round-trips an insertion' do
    old = 'abcabcabc'
    new = 'abcXXXabcabc'
    expect(roundtrip(old, new)).to eq(new.b)
  end

  it 'round-trips a deletion' do
    old = '0123456789'
    new = '014589'
    expect(roundtrip(old, new)).to eq(new.b)
  end

  it 'round-trips a repeated block (a match that looks backwards and forward)' do
    old = Random.new(1).bytes(4000)
    new = old + old
    expect(roundtrip(old, new)).to eq(new.b)
  end

  it 'round-trips swapped halves (a match that must seek backwards)' do
    old = Random.new(2).bytes(8000)
    new = old[4000..] + old[0, 4000]
    expect(roundtrip(old, new)).to eq(new.b)
  end

  it 'round-trips a random pair with no shared structure' do
    old = Random.new(3).bytes(3000)
    new = Random.new(4).bytes(2500)
    expect(roundtrip(old, new)).to eq(new.b)
  end

  it 'keeps binary (non-text) bytes intact' do
    old = +"\x00\xff\xfePK\x03\x04".b
    new = +"\x00\xff\xfePK\x03\x05\x80".b
    expect(roundtrip(old, new)).to eq(new.b)
  end
end
