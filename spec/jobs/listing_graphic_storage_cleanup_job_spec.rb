# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ListingGraphicStorageCleanupJob do
  let(:adapter) { instance_double(ReleaseStorage::LocalAdapter) }
  let(:key) { 'uploads/apps/a12/graphics/g7/graphic.png' }

  before { allow(ReleaseStorage).to receive(:build_adapter).and_return(adapter) }

  it 'deletes the key it is given' do
    allow(adapter).to receive(:delete)

    described_class.new.perform(7, [key])

    expect(adapter).to have_received(:delete).with(key)
  end

  it 'deletes on the local adapter too, because no CarrierWave copy would remove that file' do
    allow(ReleaseStorage).to receive(:remote?).and_return(false)
    allow(adapter).to receive(:delete)

    described_class.new.perform(7, [key])

    expect(adapter).to have_received(:delete).with(key)
  end

  it 'drops blank and duplicate keys before calling storage' do
    allow(adapter).to receive(:delete)

    described_class.new.perform(7, [key, nil, key])

    expect(adapter).to have_received(:delete).once.with(key)
  end

  it 'keeps going when one delete fails, and never raises' do
    other = 'uploads/apps/a12/graphics/g8/graphic.jpg'
    allow(adapter).to receive(:delete).with(key).and_raise(ReleaseStorage::StorageError, 'boom')
    allow(adapter).to receive(:delete).with(other)

    expect { described_class.new.perform(7, [key, other]) }.not_to raise_error

    expect(adapter).to have_received(:delete).with(other)
  end

  it 'logs instead of raising when storage is misconfigured' do
    allow(ReleaseStorage).to receive(:build_adapter).and_raise(ReleaseStorage::ConfigurationError, 'no token')

    expect { described_class.new.perform(7, [key]) }.not_to raise_error
  end
end
