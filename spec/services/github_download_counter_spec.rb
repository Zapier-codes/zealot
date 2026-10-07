# frozen_string_literal: true

require 'rails_helper'

# Task 45e: GitHub's own download count for the one installable file, kept as a never-falling high-water mark.
# Written, NOT run (no Ruby in the sandbox that wrote it).
RSpec.describe GithubDownloadCounter do
  let(:release) { Struct.new(:github_download_count, :id) { def update_columns(attrs) = attrs.each { |k, v| self[k] = v } }.new(3, 6) }
  let(:storage) { instance_double(ReleaseStorage) }

  before do
    allow(ReleaseStorage).to receive(:adapter_name).and_return('github')
    allow(ReleaseDownload).to receive(:new).and_return(instance_double(ReleaseDownload, served_storage_key: 'a2/r6/pipeline__universal.apk'))
  end

  it 'asks only for the served file and raises the stored count' do
    allow(storage).to receive(:download_count).with('a2/r6/pipeline__universal.apk').and_return(10)

    expect(described_class.refresh(release, storage: storage)).to be(true)
    expect(release.github_download_count).to eq(10)
  end

  it 'never lowers the count when the host starts again from 0' do
    allow(storage).to receive(:download_count).and_return(0)

    expect(described_class.refresh(release, storage: storage)).to be(false)
    expect(release.github_download_count).to eq(3)
  end

  it 'does nothing when storage is not GitHub, there is no served file, or the file is missing' do
    allow(ReleaseStorage).to receive(:adapter_name).and_return('local')
    expect(described_class.refresh(release, storage: storage)).to be(false)

    allow(ReleaseStorage).to receive(:adapter_name).and_return('github')
    allow(storage).to receive(:download_count).and_return(nil)
    expect(described_class.refresh(release, storage: storage)).to be(false)

    allow(ReleaseDownload).to receive(:new).and_return(instance_double(ReleaseDownload, served_storage_key: nil))
    expect(described_class.refresh(release, storage: storage)).to be(false)
  end
end
