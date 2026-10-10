# frozen_string_literal: true

require 'rails_helper'
require 'json'
require 'digest'
require 'open3'
require 'tmpdir'

# Z-P15b: signing entry.json into entry.jar and publishing the F-Droid repo. The JAR-building half is
# pure Ruby (no gem), so it is exercised here without a keystore; the signing half shells out to a JDK
# `jarsigner`, and both it and the publisher are tested with a real, freshly-generated keystore when a
# JDK is present (skipped otherwise, so the suite still runs where one is not installed).
RSpec.describe FdroidIndex::JarSigner do
  let(:index_json) { JSON.generate('repo' => { 'name' => { 'en-US' => 'Zealot' } }, 'packages' => {}) + "\n" }
  let(:entry_json) do
    JSON.generate(
      'timestamp' => 1_760_000_000_000, 'version' => 30_000, 'maxAge' => 14,
      'index' => { 'name' => '/index-v2.json', 'sha256' => Digest::SHA256.hexdigest(index_json),
                   'size' => index_json.bytesize, 'numPackages' => 0 }
    ) + "\n"
  end

  def entry_bytes_of(jar, want = 'entry.json')
    data = jar.b
    off = 0
    while (i = data.index("PK\x01\x02".b, off))
      nlen = data[i + 28, 2].unpack1('v')
      name = data[i + 46, nlen]
      if name == want
        lho = data[i + 42, 4].unpack1('V')
        lnlen = data[lho + 26, 2].unpack1('v')
        lelen = data[lho + 28, 2].unpack1('v')
        csize = data[lho + 18, 4].unpack1('V')
        return data[lho + 30 + lnlen + lelen, csize]
      end
      off = i + 46 + nlen
    end
    nil
  end

  describe '#call (build the unsigned JAR)' do
    it 'writes a ZIP whose single entry is entry.json at the root, byte-identical' do
      jar = described_class.new(entry_json: entry_json, index_json: index_json).call

      expect(jar[0, 4]).to eq("PK\x03\x04") # local file header
      expect(jar).to include('entry.json')
      expect(jar).not_to include('META-INF')
      expect(entry_bytes_of(jar)).to eq(entry_json)
    end

    # Z-P15c: extra JSON documents (the signer index) ride inside the same signed JAR under their own
    # names, so they are covered by the one signature without a second signed JAR.
    it 'carries extra entries beside entry.json, each byte-identical, in the order given' do
      signer_index = "{\"com.example.app\":{\"signer\":\"#{'d' * 64}\"}}\n"
      jar = described_class.new(entry_json: entry_json, index_json: index_json,
                                extra_entries: { 'signer-index.json' => signer_index }).call

      expect(jar).to include('entry.json')
      expect(jar).to include('signer-index.json')
      expect(entry_bytes_of(jar, 'entry.json')).to eq(entry_json)
      expect(entry_bytes_of(jar, 'signer-index.json')).to eq(signer_index)
      # entry.json is written first, so a client that reads the first root entry still finds it.
      expect(jar.index('entry.json')).to be < jar.index('signer-index.json')
    end

    it 'refuses when entry.json points at a different index than the bytes given' do
      bad = entry_json.sub(Digest::SHA256.hexdigest(index_json), 'f' * 64)
      expect { described_class.new(entry_json: bad, index_json: index_json).call }
        .to raise_error(described_class::UnsignedIndexError, /does not match/)
    end

    it 'refuses when entry.json is not valid JSON' do
      expect { described_class.new(entry_json: '{not json', index_json: index_json).call }
        .to raise_error(described_class::UnsignedIndexError, /not valid JSON/)
    end

    it 'refuses when entry.json has no index.sha256' do
      expect { described_class.new(entry_json: '{"index":{}}', index_json: index_json).call }
        .to raise_error(described_class::UnsignedIndexError, /no index.sha256/)
    end
  end

  describe '.sign_jar! (requires a JDK)' do
    let(:keystore_path) { nil }

    it 'signs the JAR so jarsigner verifies it and entry.json still round-trips' do
      skip 'no JDK (jarsigner/keytool) in this environment' unless system('command -v jarsigner >/dev/null 2>&1') && system('command -v keytool >/dev/null 2>&1')

      Dir.mktmpdir do |dir|
        ks = File.join(dir, 'k.jks')
        ok = system('keytool', '-genkeypair', '-keystore', ks, '-storepass', 'pass1234', '-keypass', 'pass1234',
                    '-alias', 'fdroidrepo', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '3650',
                    '-dname', 'CN=Zealot Test', out: File::NULL, err: File::NULL)
        skip 'keytool could not generate a test keystore' unless ok
        keystore_bytes = File.binread(ks)

        unsigned = described_class.new(entry_json: entry_json, index_json: index_json).call
        signed = described_class.sign_jar!(unsigned, keystore_bytes: keystore_bytes,
                                           keystore_password: 'pass1234', key_alias: 'fdroidrepo',
                                           key_password: 'pass1234')

        expect(signed.bytesize).to be > unsigned.bytesize
        expect(signed).to include('META-INF')
        expect(signed).to include('FDROIDRE.SF') # jarsigner's signature file (alias upper-cased, truncated)
        expect(entry_bytes_of(signed)).to eq(entry_json)

        signed_path = File.join(dir, 'signed.jar')
        File.binwrite(signed_path, signed)
        _out, _err, status = Open3.capture3('jarsigner', '-verify', '-keystore', ks, signed_path)
        expect(status).to be_success
      end
    end
  end
end
