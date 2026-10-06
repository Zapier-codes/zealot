# frozen_string_literal: true

require 'rails_helper'

# Task 40h-b: awaiting_bytes -> uploaded | failed | expired. Needs Postgres. R2 is a fake: no network, no
# bucket. NOT run (the operator said no testing); look here first if CI is red for this slice.
RSpec.describe ReleaseUploadFinalizer do
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:declared) { 1234 }
  let(:state) { 'awaiting_bytes' }
  let!(:upload) do
    ReleaseUpload.create!(channel: channel, filename: 'app.aab', declared_size: declared).tap do |u|
      u.update_columns(state: state)
    end
  end
  let(:held) { ReleaseUploadStaging::Head.new(size: 1234, etag: 'abc123') }
  let(:staging) { instance_double(ReleaseUploadStaging, head: held, delete: true) }

  def finalize(now: Time.current)
    described_class.new(upload.reload, staging: staging, now: now).call
  end

  it 'moves the row to uploaded and records what R2 holds' do
    result = finalize

    expect(result.code).to eq(:uploaded)
    expect(result.http).to eq(200)
    upload.reload
    expect(upload.state).to eq('uploaded')
    expect(upload.uploaded_size).to eq(1234)
    expect(upload.etag).to eq('abc123')
    expect(upload.uploaded_at).to be_present
  end

  # Task 40i-a: a successful finalize sends the upload to the stage-1 workflow; nothing else does.
  it 'enqueues the stage-1 dispatch once, on the finalize that wins' do
    expect { finalize }.to have_enqueued_job(ReleaseUploadDispatchJob).with(upload.id).exactly(:once)
    expect { finalize }.not_to have_enqueued_job(ReleaseUploadDispatchJob)
  end

  it 'is idempotent: a second finalize answers 200 and does not ask R2 again' do
    finalize
    result = finalize

    expect(result.code).to eq(:already_uploaded)
    expect(result.http).to eq(200)
    expect(staging).to have_received(:head).once
  end

  context 'when nothing reached the bucket' do
    let(:held) { nil }

    it 'answers 422 and leaves the row open so the client can retry' do
      result = finalize

      expect(result.code).to eq(:no_bytes)
      expect(result.http).to eq(422)
      expect(upload.reload.state).to eq('awaiting_bytes')
    end
  end

  context 'when the staged file is not the declared size' do
    let(:held) { ReleaseUploadStaging::Head.new(size: 9999, etag: 'x') }

    it 'fails the row with the reason and deletes the staged object' do
      result = finalize

      expect(result.code).to eq(:size_mismatch)
      expect(result.http).to eq(422)
      upload.reload
      expect(upload.state).to eq('failed')
      expect(upload.error).to include('9999').and include('1234')
      expect(staging).to have_received(:delete).with(upload)
    end

    it 'still answers the same when the delete fails' do
      allow(staging).to receive(:delete).and_raise(ReleaseStorage::StorageError, 'boom')

      expect(finalize.code).to eq(:size_mismatch)
      expect(upload.reload.state).to eq('failed')
    end
  end

  context 'when the window closed long ago' do
    it 'expires the row without asking R2' do
      result = finalize(now: upload.expires_at + ReleaseUploadFinalizer::GRACE + 1.minute)

      expect(result.code).to eq(:expired)
      expect(result.http).to eq(409)
      expect(upload.reload.state).to eq('expired')
      expect(staging).not_to have_received(:head)
    end

    it 'still accepts a finalize inside the grace period' do
      result = finalize(now: upload.expires_at + 5.minutes)

      expect(result.code).to eq(:uploaded)
    end
  end

  %w[failed expired processing done].each do |other|
    context "when the row is already #{other}" do
      let(:state) { other }

      it 'refuses with 409 and changes nothing' do
        result = finalize

        expect(result.code).to eq(:not_open)
        expect(result.http).to eq(409)
        expect(upload.reload.state).to eq(other)
        expect(staging).not_to have_received(:head)
      end
    end
  end

  it 'answers 503 and leaves the row open when R2 cannot be reached' do
    allow(staging).to receive(:head).and_raise(ReleaseStorage::StorageError, 'R2 head failed')

    result = finalize

    expect(result.code).to eq(:storage_unavailable)
    expect(result.http).to eq(503)
    expect(upload.reload.state).to eq('awaiting_bytes')
  end

  it 'never overwrites a row another request moved in between' do
    allow(staging).to receive(:head) do
      ReleaseUpload.where(id: upload.id).update_all(state: 'expired')
      held
    end

    result = finalize

    expect(result.code).to eq(:not_open)
    expect(upload.reload.state).to eq('expired')
  end

  # Task 40s-c: a row opened in parts is finalized by listing what R2 holds, completing with R2's own ETags and
  # then checking the object like any other.
  describe 'a multipart upload' do
    let(:part_size) { 16 * 1024 * 1024 }
    let(:declared) { 40_000_000 } # 3 parts: 16 MiB, 16 MiB and 6,445,568 bytes
    let!(:upload) do
      ReleaseUpload.create!(channel: channel, filename: 'app.aab', declared_size: declared,
                            part_size: part_size).tap do |u|
        u.update_columns(state: state, multipart_upload_id: 'mp-1')
      end
    end
    let(:part) do
      ->(number, bytes) { ReleaseUploadParts::Held.new(part_number: number, size: bytes, etag: "e#{number}") }
    end
    let(:listed) { [part.call(1, part_size), part.call(2, part_size), part.call(3, 6_445_568)] }
    let(:held) { ReleaseUploadStaging::Head.new(size: 40_000_000, etag: 'final-3') }
    let(:staging) do
      instance_double(ReleaseUploadStaging, head: held, delete: true, list_parts: listed, complete_multipart: true)
    end

    it 'completes with the ETags R2 listed, then records the object as uploaded' do
      result = finalize

      expect(result.code).to eq(:uploaded)
      expect(staging).to have_received(:complete_multipart)
        .with(upload, parts: [{ part_number: 1, etag: 'e1' }, { part_number: 2, etag: 'e2' },
                              { part_number: 3, etag: 'e3' }])
      upload.reload
      expect(upload).to have_attributes(state: 'uploaded', uploaded_size: 40_000_000, etag: 'final-3')
    end

    it 'enqueues the stage-1 dispatch once' do
      expect { finalize }.to have_enqueued_job(ReleaseUploadDispatchJob).with(upload.id).exactly(:once)
    end

    context 'when a part is missing' do
      let(:listed) { [part.call(1, part_size), part.call(3, 6_445_568)] }

      it 'answers 422 parts_incomplete, names the missing part and leaves the row open' do
        result = finalize

        expect(result.code).to eq(:parts_incomplete)
        expect(result.http).to eq(422)
        expect(result.missing).to eq([2])
        expect(result.details).to eq(code: :parts_incomplete, missing: [2])
        expect(upload.reload.state).to eq('awaiting_bytes')
        expect(staging).not_to have_received(:complete_multipart)
        expect(staging).not_to have_received(:head)
      end
    end

    context 'when a part has the wrong size' do
      let(:listed) { [part.call(1, part_size), part.call(2, 5), part.call(3, 6_445_568)] }

      it 'counts it as missing' do
        expect(finalize.missing).to eq([2])
      end
    end

    context 'when R2 no longer knows the upload and the object is there (a finalize that lost its write)' do
      let(:listed) { nil }

      it 'checks the object instead and records it' do
        result = finalize

        expect(result.code).to eq(:uploaded)
        expect(staging).not_to have_received(:complete_multipart)
      end
    end

    context 'when R2 no longer knows the upload and there is no object' do
      let(:listed) { nil }
      let(:held) { nil }

      it 'answers 422 no_bytes and leaves the row open' do
        expect(finalize.code).to eq(:no_bytes)
        expect(upload.reload.state).to eq('awaiting_bytes')
      end
    end

    context 'when a racing finalize completed the upload between the listing and the completion' do
      it 'checks the object and records it' do
        allow(staging).to receive(:complete_multipart).and_return(false)

        expect(finalize.code).to eq(:uploaded)
      end
    end

    it 'answers 503 and leaves the row open when R2 refuses to complete' do
      allow(staging).to receive(:complete_multipart)
        .and_raise(ReleaseStorage::StorageError, 'R2 multipart complete failed')

      result = finalize

      expect(result.code).to eq(:storage_unavailable)
      expect(upload.reload.state).to eq('awaiting_bytes')
    end

    it 'answers 503 when the parts cannot be listed' do
      allow(staging).to receive(:list_parts).and_raise(ReleaseStorage::StorageError, 'R2 list parts failed')

      expect(finalize.http).to eq(503)
    end

    context 'when the completed object is not the declared size' do
      let(:held) { ReleaseUploadStaging::Head.new(size: 1, etag: 'x') }

      it 'fails the row and deletes the object, as for a single PUT' do
        expect(finalize.code).to eq(:size_mismatch)
        expect(upload.reload.state).to eq('failed')
        expect(staging).to have_received(:delete).with(upload)
      end
    end

    context 'when the window closed long ago' do
      it 'expires the row without asking R2' do
        expect(finalize(now: upload.expires_at + ReleaseUploadFinalizer::GRACE + 1.minute).code).to eq(:expired)
        expect(staging).not_to have_received(:list_parts)
      end
    end

    it 'leaves a single PUT row on the old path, never listing parts' do
      single = ReleaseUpload.create!(channel: channel, filename: 'single.aab', declared_size: 1234)
      allow(staging).to receive(:head).and_return(ReleaseUploadStaging::Head.new(size: 1234, etag: 's'))

      described_class.new(single, staging: staging).call

      expect(single.reload.state).to eq('uploaded')
      expect(staging).not_to have_received(:list_parts)
    end
  end
end
