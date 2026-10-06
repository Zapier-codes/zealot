# frozen_string_literal: true

require 'rails_helper'

# Task 40s-a: the multipart plan and its settings. Pure arithmetic, no database and no R2. Written, NOT run in
# Rails; the same checks were run once against the module with a plain Ruby script (no Rails) in the session
# that wrote it. Look here first if CI is red for this slice.
RSpec.describe ReleaseUploadParts do
  let(:mib) { described_class::MIB }
  let(:on) { { 'RELEASE_UPLOAD_MULTIPART_ENABLED' => 'true' } }

  describe '.enabled?' do
    it 'is off unless the flag is exactly "true"' do
      expect(described_class.enabled?({})).to be(false)
      expect(described_class.enabled?('RELEASE_UPLOAD_MULTIPART_ENABLED' => 'yes')).to be(false)
      expect(described_class.enabled?(on)).to be(true)
    end
  end

  describe '.part_size_bytes' do
    it 'defaults to 16 MiB and reads RELEASE_UPLOAD_PART_SIZE_MIB' do
      expect(described_class.part_size_bytes({})).to eq(16 * mib)
      expect(described_class.part_size_bytes('RELEASE_UPLOAD_PART_SIZE_MIB' => '8')).to eq(8 * mib)
      expect(described_class.part_size_bytes('RELEASE_UPLOAD_PART_SIZE_MIB' => '5')).to eq(5 * mib)
    end

    %w[4 0 -1 abc 1.5].each do |bad|
      it "falls back to the default for #{bad.inspect} (below the 5 MiB floor or not a whole number)" do
        expect(described_class.part_size_bytes('RELEASE_UPLOAD_PART_SIZE_MIB' => bad)).to eq(16 * mib)
      end
    end
  end

  describe '.threshold_bytes' do
    it 'defaults to 100 MiB and reads RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB' do
      expect(described_class.threshold_bytes({})).to eq(100 * mib)
      expect(described_class.threshold_bytes('RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB' => '200')).to eq(200 * mib)
    end

    it 'never goes below one part' do
      expect(described_class.threshold_bytes('RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB' => '8')).to eq(16 * mib)
    end

    it 'falls back to the default for a value that is not a positive whole number' do
      expect(described_class.threshold_bytes('RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB' => 'x')).to eq(100 * mib)
    end
  end

  describe '.use_multipart?' do
    it 'is true from the threshold up, only when the flag is on' do
      expect(described_class.use_multipart?(100 * mib, on)).to be(true)
      expect(described_class.use_multipart?((100 * mib) - 1, on)).to be(false)
      expect(described_class.use_multipart?(100 * mib, {})).to be(false)
      expect(described_class.use_multipart?(nil, on)).to be(false)
    end
  end

  describe ReleaseUploadParts::Plan do
    let(:part) { 16 * 1024 * 1024 }
    let(:plan) { described_class.new(size: 40_000_000, part_size: part) }
    let(:held_class) { ReleaseUploadParts::Held }

    def held(number, size)
      held_class.new(part_number: number, size: size)
    end

    it 'counts parts and sizes the last one as what is left' do
      expect(plan.count).to eq(3)
      expect(plan.size_of(1)).to eq(part)
      expect(plan.size_of(3)).to eq(40_000_000 - (2 * part))
      expect(plan.size_of(4)).to eq(0)
    end

    it 'gives a full last part when the file is an exact multiple' do
      exact = described_class.new(size: 2 * part, part_size: part)
      expect(exact.count).to eq(2)
      expect(exact.size_of(2)).to eq(part)
    end

    it 'needs at most 128 parts for a file at the 2 GiB cap with 16 MiB parts' do
      expect(described_class.new(size: ReleaseUpload::MAX_BYTES, part_size: part).count).to eq(128)
    end

    it 'refuses a zero size' do
      expect { described_class.new(size: 0, part_size: part) }.to raise_error(ArgumentError)
    end

    it 'finds no problem when R2 holds exactly the planned parts' do
      parts = [held(1, part), held(2, part), held(3, plan.size_of(3))]
      expect(plan.problem_with(parts)).to be_nil
      expect(plan.missing(parts)).to eq([])
    end

    it 'names the missing and wrong-size parts' do
      parts = [held(1, part), held(2, 5 * 1024 * 1024)]
      expect(plan.problem_with(parts))
        .to eq('Parts 2, 3 of 3 are missing or have the wrong size. Send them again, then finalize.')
      expect(plan.missing(parts)).to eq([2, 3])
    end

    it 'refuses parts outside the plan' do
      parts = [held(1, part), held(2, part), held(3, plan.size_of(3)), held(9, 1)]
      expect(plan.problem_with(parts)).to start_with('R2 holds parts that are not part of this upload')
    end

    it 'keeps the message short when many parts are missing' do
      big = described_class.new(size: 30 * part, part_size: part)
      expect(big.problem_with([])).to include('and 22 more')
    end
  end
end
