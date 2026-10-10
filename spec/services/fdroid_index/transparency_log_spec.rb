# frozen_string_literal: true

require 'rails_helper'
require 'json'

# Z-P15d: the binary transparency log. `filesystemlog.json` is `{ path: [size, ctime_ns, mtime_ns, mode, uid, gid] }`
# over every published file, sorted by path — read from fdroidserver `btlog.py#make_binary_transparency_log`.
# Sizes are the real byte lengths of the exact bytes we publish; ctime/mtime/uid/gid are zero because the
# content is rendered in memory and has none (see the class comment).
RSpec.describe FdroidIndex::TransparencyLog do
  let(:files) do
    {
      'entry.json' => '{"a":1}',
      'index-v2.json' => '{"b":2}',
      'entry.jar' => 'JARBYTES'
    }
  end

  it 'logs the real byte size of every file, keyed by relative path' do
    result = described_class.call(files)
    log = JSON.parse(result.filesystem_log_json)

    expect(log.keys).to contain_exactly('entry.json', 'index-v2.json', 'entry.jar')
    expect(log['entry.json'][0]).to eq(files['entry.json'].bytesize)
    expect(log['entry.jar'][0]).to eq(8)
    expect(result.path_count).to eq(3)
  end

  it 'is a plain map (not a size/count wrapper) with the six-value tuple btlog.py writes' do
    log = JSON.parse(described_class.call(files).filesystem_log_json)

    expect(log.values).to all(be_a(Array).and(have_attributes(size: 6)))
    expect(log['entry.json'][3]).to eq(0o100644) # mode: a regular file
  end

  it 'sorts paths so the log is stable regardless of insertion order' do
    shuffled = { 'entry.jar' => 'JARBYTES', 'index-v2.json' => '{"b":2}', 'entry.json' => '{"a":1}' }

    expect(JSON.parse(described_class.call(shuffled).filesystem_log_json).keys)
      .to eq(%w[entry.jar entry.json index-v2.json])
  end

  it 'round-trips as JSON' do
    expect { JSON.parse(described_class.call(files).filesystem_log_json) }.not_to raise_error
  end
end
