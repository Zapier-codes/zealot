# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReleaseStorageCleanupJob do
  let(:adapter) { instance_double(ReleaseStorage::GithubAdapter) }

  before do
    allow(ReleaseStorage).to receive(:remote?).and_return(true)
    allow(ReleaseStorage).to receive(:build_adapter).and_return(adapter)
  end

  it 'deletes every key it is given' do
    allow(adapter).to receive(:delete)

    described_class.new.perform(7, %w[uploads/apps/a1/r7/binary/app.apk uploads/apps/a1/r7/pipeline/release.apks.br])

    expect(adapter).to have_received(:delete).with('uploads/apps/a1/r7/binary/app.apk')
    expect(adapter).to have_received(:delete).with('uploads/apps/a1/r7/pipeline/release.apks.br')
  end

  it 'drops blank and duplicate keys before calling storage' do
    allow(adapter).to receive(:delete)

    described_class.new.perform(7, ['uploads/apps/a1/r7/binary/app.apk', nil, 'uploads/apps/a1/r7/binary/app.apk'])

    expect(adapter).to have_received(:delete).once.with('uploads/apps/a1/r7/binary/app.apk')
  end

  it 'does nothing on the local adapter' do
    allow(ReleaseStorage).to receive(:remote?).and_return(false)

    described_class.new.perform(7, ['uploads/apps/a1/r7/binary/app.apk'])

    expect(ReleaseStorage).not_to have_received(:build_adapter)
  end

  it 'keeps deleting the remaining keys when one delete fails, and never raises' do
    allow(adapter).to receive(:delete).with('uploads/apps/a1/r7/binary/app.apk').and_raise(ReleaseStorage::StorageError, 'boom')
    allow(adapter).to receive(:delete).with('uploads/apps/a1/r7/pipeline/x.br')

    expect { described_class.new.perform(7, %w[uploads/apps/a1/r7/binary/app.apk uploads/apps/a1/r7/pipeline/x.br]) }
      .not_to raise_error

    expect(adapter).to have_received(:delete).with('uploads/apps/a1/r7/pipeline/x.br')
  end

  it 'logs instead of raising when storage is misconfigured' do
    allow(ReleaseStorage).to receive(:build_adapter).and_raise(ReleaseStorage::ConfigurationError, 'no token')

    expect { described_class.new.perform(7, ['uploads/apps/a1/r7/binary/app.apk']) }.not_to raise_error
  end

  it 'is a no-op for an empty key list' do
    allow(adapter).to receive(:delete)

    described_class.new.perform(7, [])

    expect(adapter).not_to have_received(:delete)
  end
end
