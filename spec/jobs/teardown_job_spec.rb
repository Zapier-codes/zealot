# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TeardownJob do
  let(:release) { double('Release', id: 7, release_type: nil) }
  let(:storage) { instance_double(ReleaseStorage) }
  let(:metadata) { double('AppInfo', release_type: 'debug', user_id: nil) }

  before do
    stub_const('Release', class_double('Release', find: release))
    allow(ReleaseStorage).to receive(:new).with(release).and_return(storage)
  end

  it 'parses whatever local path ReleaseStorage hands it and links the metadata to the release' do
    allow(storage).to receive(:with_local_file).and_yield('/local/app.apk')
    parsed = instance_double(TeardownService, call: metadata)
    allow(TeardownService).to receive(:new).with('/local/app.apk').and_return(parsed)
    allow(metadata).to receive(:update_attribute)
    allow(release).to receive(:update)
    allow(release).to receive(:blank?).and_return(false)

    described_class.new.perform(7, 42)

    expect(metadata).to have_received(:update_attribute).with(:user_id, 42)
    expect(metadata).to have_received(:update_attribute).with(:release_id, release.id)
    expect(release).to have_received(:update).with(release_type: 'debug')
  end

  it 'does not touch the release when TeardownService finds nothing' do
    allow(storage).to receive(:with_local_file).and_yield('/local/app.apk')
    allow(TeardownService).to receive(:new).and_return(instance_double(TeardownService, call: nil))

    expect { described_class.new.perform(7, 42) }.not_to raise_error
  end

  it 'logs and does not raise when neither a local nor a mirrored file exists' do
    allow(storage).to receive(:with_local_file).and_raise(ReleaseStorage::MissingFileError, 'nothing anywhere')

    expect { described_class.new.perform(7, 42) }.not_to raise_error
  end

  it 'ignores a file AppInfo cannot recognise' do
    allow(storage).to receive(:with_local_file).and_raise(AppInfo::UnknownFormatError, 'nope')

    expect { described_class.new.perform(7, 42) }.not_to raise_error
  end
end
