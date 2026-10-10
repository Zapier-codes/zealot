# frozen_string_literal: true

require 'rails_helper'

# Z-P12: the pure half of the pre-launch report -- the raw redroid payload in, the verdict and findings out.
# No Rails objects touched (Ruby Structs and plain Hashes only), so this is the part that can be fully tested
# without a device or a database. The runner's payload shape is mirrored in docs/ci/pre-launch-runner.py.
RSpec.describe PreLaunchReport do
  def payload(overrides = {})
    {
      'devices' => [{ 'name' => 'localhost:9100' }, { 'name' => 'localhost:9101' }],
      'events' => 2000,
      'crashes' => [],
      'anrs' => [],
      'exceptions' => [],
      'startup' => { 'ok' => true, 'message' => '' }
    }.merge(overrides)
  end

  describe '.from_payload' do
    it 'passes a run with no observations' do
      result = described_class.from_payload(payload)
      expect(result.verdict).to eq('pass')
      expect(result.findings).to be_empty
      expect(result.summary).to include('2 devices').and include('2000 events each').and include('no problems found')
    end

    it 'rejects on any crash' do
      result = described_class.from_payload(payload('crashes' => [{ 'device' => 'd1', 'message' => 'FATAL EXCEPTION: main' }]))
      expect(result.verdict).to eq('reject')
      finding = result.findings.first
      expect(finding.code).to eq('device_crash')
      expect(finding.severity).to eq('reject')
      expect(finding.message).to include('d1').and include('FATAL')
    end

    it 'flags an ANR' do
      result = described_class.from_payload(payload('anrs' => [{ 'message' => 'ANR in com.x' }]))
      expect(result.verdict).to eq('flag')
      expect(result.findings.first.code).to eq('device_anr')
    end

    it 'flags a non-fatal exception' do
      result = described_class.from_payload(payload('exceptions' => [{ 'message' => 'NullPointerException' }]))
      expect(result.verdict).to eq('flag')
      expect(result.findings.first.code).to eq('device_exception')
    end

    it 'flags a startup failure' do
      result = described_class.from_payload(payload('startup' => { 'ok' => false, 'message' => 'process died' }))
      expect(result.verdict).to eq('flag')
      expect(result.findings.first.code).to eq('startup_failure')
      expect(result.findings.first.message).to include('process died')
    end

    it 'lets a crash outrank an ANR (worst severity wins)' do
      result = described_class.from_payload(payload('crashes' => [{ 'message' => 'c' }], 'anrs' => [{ 'message' => 'a' }]))
      expect(result.verdict).to eq('reject')
    end

    it 'tolerates a nil or non-hash payload' do
      expect(described_class.from_payload(nil).verdict).to eq('pass')
      expect(described_class.from_payload([1, 2]).verdict).to eq('pass')
    end

    it 'treats a non-array observation section as nothing observed, never a crash' do
      expect(described_class.from_payload(payload('crashes' => 'oops')).verdict).to eq('pass')
    end

    it 'skips a blank observation but keeps a string item' do
      expect(described_class.from_payload(payload('crashes' => [{ 'message' => '  ' }])).verdict).to eq('pass')
      expect(described_class.from_payload(payload('crashes' => ['boom'])).verdict).to eq('reject')
    end

    it 'ignores a startup section with no `ok` key' do
      expect(described_class.from_payload(payload('startup' => { 'message' => 'x' })).verdict).to eq('pass')
    end
  end

  describe '.verdict_for' do
    it 'is pass for no findings' do
      expect(described_class.verdict_for([])).to eq('pass')
    end
  end
end
