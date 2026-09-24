# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CatalogIndexSigningKey do
  it 'generates a key and derives the public key and id from it' do
    key = described_class.generate!

    expect(key.public_key).to eq(CatalogIndex::Ed25519.public_key_b64(key.private_key_pem))
    expect(key.key_id).to eq(CatalogIndex::Ed25519.key_id(key.public_key))
    expect(described_class.current).to eq(key)
  end

  it 'is a singleton: a second key is refused' do
    described_class.generate!

    expect { described_class.generate! }.to raise_error(ActiveRecord::RecordInvalid)
    expect(described_class.count).to eq(1)
  end

  it 'signs bytes that verify against its own public key' do
    key = described_class.generate!

    expect(CatalogIndex::Ed25519.verify(key.public_key, 'hello', key.sign('hello'))).to be true
  end

  it 'keeps the private key encrypted at rest' do
    key = described_class.generate!
    raw = described_class.connection.select_value("SELECT private_key_pem FROM catalog_index_signing_keys WHERE id = #{key.id}")

    expect(raw).not_to include('PRIVATE KEY')
  end
end
