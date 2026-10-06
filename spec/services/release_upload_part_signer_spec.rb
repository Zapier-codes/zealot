# frozen_string_literal: true

require 'rails_helper'

# Task 40s-c: signing part URLs and listing the parts R2 holds. Needs Postgres for the upload row. R2 is a fake: no
# network, no bucket. Written, NOT run (no Rails in the sandbox it was written in); look here first if CI is red.
RSpec.describe ReleaseUploadPartSigner do
  let!(:app) { create(:app, name: 'Part app') }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:part_size) { 16 * 1024 * 1024 }
  let(:size) { 40_000_000 } # 3 parts: 16 MiB, 16 MiB and 6,445,568 bytes
  let(:state) { 'awaiting_bytes' }
  let(:expires_at) { 6.hours.from_now }
  let(:upload_id) { 'mp-1' }
  let!(:upload) do
    ReleaseUpload.create!(channel: channel, filename: 'app.aab', declared_size: size, part_size: part_size,
                          expires_at: expires_at).tap do |row|
      row.update_columns(state: state, multipart_upload_id: upload_id)
    end
  end
  let(:held) { [] }
  let(:staging) do
    instance_double(ReleaseUploadStaging, list_parts: held).tap do |double|
      allow(double).to receive(:presign_part) do |_upload, part_number:, expires_in:|
        ReleaseUploadStaging::Presigned.new(url: "https://r2.example/part/#{part_number}?ttl=#{expires_in}",
                                            method: 'PUT', headers: {}, expires_at: expires_in.seconds.from_now)
      end
    end
  end

  def signer(now: Time.current)
    described_class.new(upload.reload, staging: staging, now: now)
  end

  def held_part(number, bytes)
    ReleaseUploadParts::Held.new(part_number: number, size: bytes, etag: "e#{number}")
  end

  describe '.parse_numbers' do
    it 'reads an array, an array of strings and a comma list' do
      expect(described_class.parse_numbers([1, 2])).to eq([1, 2])
      expect(described_class.parse_numbers(%w[3 4])).to eq([3, 4])
      expect(described_class.parse_numbers('5, 6,7')).to eq([5, 6, 7])
    end

    it 'answers nil for nothing, an empty list, a hash or anything that is not a whole number' do
      expect(described_class.parse_numbers(nil)).to be_nil
      expect(described_class.parse_numbers([])).to be_nil
      expect(described_class.parse_numbers({ a: 1 })).to be_nil
      expect(described_class.parse_numbers('1,x')).to be_nil
      expect(described_class.parse_numbers([1.5])).to be_nil
    end
  end

  describe '#sign' do
    it 'signs one URL per part with the size each part must have' do
      result = signer.sign([1, 3])

      expect(result.http).to eq(200)
      payload = result.payload
      expect(payload).to include(id: upload.id, part_size: part_size, part_count: 3)
      expect(payload[:parts].map { |part| part[:part_number] }).to eq([1, 3])
      expect(payload[:parts].map { |part| part[:size] }).to eq([part_size, 6_445_568])
      expect(payload[:parts].first)
        .to include(method: 'PUT', headers: {}, url: a_string_starting_with('https://r2.example/part/1'))
      expect(staging).to have_received(:presign_part).twice
    end

    it 'never signs for longer than the single-PUT window' do
      signer.sign([1])

      expect(staging).to have_received(:presign_part)
        .with(upload, part_number: 1, expires_in: ReleaseUploadStaging::DEFAULT_EXPIRES_IN)
    end

    context 'when the row has less time left than that' do
      let(:expires_at) { 10.minutes.from_now }

      it 'signs for the time that is left, so no URL outlives the row' do
        signer.sign([1])

        expect(staging).to have_received(:presign_part) do |_upload, expires_in:, **|
          expect(expires_in).to be_between(500, 600)
        end
      end
    end

    it 'refuses no part numbers, a part outside the plan, a repeated number and more than a batch' do
      [nil, [], [0], [4], [1, 1], (1..11).to_a].each do |numbers|
        result = signer.sign(numbers)

        expect(result.code).to eq(:invalid_parts)
        expect(result.http).to eq(422)
        expect(result.body).to have_key(:error)
      end
      expect(staging).not_to have_received(:presign_part)
    end

    it 'signs a full batch when the plan is large enough' do
      upload.update_columns(declared_size: 12 * part_size)

      result = signer.sign((1..ReleaseUploadParts::MAX_BATCH).to_a)

      expect(result.code).to eq(:ok)
      expect(result.payload[:parts].size).to eq(10)
    end

    it 'answers 503 when R2 cannot sign' do
      allow(staging).to receive(:presign_part).and_raise(ReleaseStorage::StorageError, 'R2 part presign failed')

      result = signer.sign([1])

      expect(result.code).to eq(:storage_unavailable)
      expect(result.http).to eq(503)
    end
  end

  describe '#list' do
    context 'when R2 holds nothing yet' do
      it 'says every part is still to send' do
        result = signer.list

        expect(result.http).to eq(200)
        expect(result.payload).to include(part_size: part_size, part_count: 3, uploaded: [], missing: [1, 2, 3])
      end
    end

    context 'when R2 holds parts 1 and 3 at the right size and part 2 at the wrong one' do
      let(:held) { [held_part(1, part_size), held_part(2, 5), held_part(3, 6_445_568)] }

      it 'counts only the right-sized ones as uploaded' do
        expect(signer.list.payload).to include(uploaded: [1, 3], missing: [2])
      end
    end

    context 'when R2 no longer knows the upload' do
      let(:held) { nil }

      it 'answers 409 and tells the client to finalize or start again' do
        result = signer.list

        expect(result.code).to eq(:upload_gone)
        expect(result.http).to eq(409)
      end
    end

    it 'answers 503 when R2 cannot be read' do
      allow(staging).to receive(:list_parts).and_raise(ReleaseStorage::StorageError, 'R2 list parts failed')

      expect(signer.list.http).to eq(503)
    end
  end

  describe 'the row must be open and opened in parts' do
    %w[uploaded failed expired processing done].each do |other|
      context "when the row is #{other}" do
        let(:state) { other }

        it 'refuses to sign or list with 409' do
          expect(signer.sign([1]).code).to eq(:not_open)
          expect(signer.list.http).to eq(409)
          expect(staging).not_to have_received(:presign_part)
          expect(staging).not_to have_received(:list_parts)
        end
      end
    end

    context 'when the window has closed' do
      let(:expires_at) { 1.minute.ago }

      it 'refuses to sign or list with 409 and does not touch R2' do
        expect(signer.sign([1]).code).to eq(:expired)
        expect(signer.list.code).to eq(:expired)
        expect(staging).not_to have_received(:presign_part)
      end
    end

    context 'when the row is a single PUT' do
      let(:part_size) { nil }

      it 'refuses with 422' do
        expect(signer.sign([1]).code).to eq(:not_multipart)
        expect(signer.list.http).to eq(422)
      end
    end

    context 'when no multipart upload was ever started in R2' do
      let(:upload_id) { nil }

      it 'answers 409 upload_gone without asking R2' do
        expect(signer.sign([1]).code).to eq(:upload_gone)
        expect(signer.list.code).to eq(:upload_gone)
        expect(staging).not_to have_received(:list_parts)
      end
    end
  end
end
