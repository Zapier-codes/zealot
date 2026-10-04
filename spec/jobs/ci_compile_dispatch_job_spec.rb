# frozen_string_literal: true

require 'rails_helper'

# Task 40b: queued -> dispatched | failed. Needs Postgres. Builds a release like release_status_control_spec.rb
# does; the dispatcher and the mirror job are stubbed, so no GitHub call and no file is touched. NOT run (the
# operator said no testing); look here first if CI is red for this slice.
RSpec.describe CiCompileDispatchJob do
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:state) { 'queued' }
  let(:storage_key) { 'uploads/apps/a1/r1/binary/app.aab' }
  let!(:release) do
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1', build_version: '1',
                ci_compile_state: state, file_storage_key: storage_key)
           .tap { |r| r.save!(validate: false) }
  end
  let(:dispatcher) { instance_double(CiCompileDispatcher, call: true) }

  before do
    stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_ENABLED' => 'true'))
    allow(CiCompileDispatcher).to receive(:new).and_return(dispatcher)
    allow(ReleaseFileMirrorJob).to receive(:perform_now)
  end

  describe '#perform' do
    it 'moves a queued release to dispatched' do
      described_class.new.perform(release.id)

      expect(release.reload.ci_compile_state).to eq('dispatched')
      expect(CiCompileDispatcher).to have_received(:new).with(having_attributes(id: release.id))
    end

    it 'does not mirror a release whose file is already stored' do
      described_class.new.perform(release.id)

      expect(ReleaseFileMirrorJob).not_to have_received(:perform_now)
    end

    context 'when the file is not stored yet' do
      let(:storage_key) { nil }

      it 'mirrors it first and fails the release if it is still not stored' do
        allow(dispatcher).to receive(:call).and_raise(CiCompileDispatcher::DispatchError, 'not in storage yet')

        described_class.new.perform(release.id)

        expect(ReleaseFileMirrorJob).to have_received(:perform_now).with(release.id)
        expect(release.reload.ci_compile_state).to eq('failed')
        expect(release.ci_compile_error).to eq('not in storage yet')
        expect(release.ci_compile_finished_at).to be_present
      end
    end

    it 'fails the release with the reason when the dispatch is refused' do
      allow(dispatcher).to receive(:call).and_raise(CiCompileDispatcher::DispatchError, 'GitHub refused (HTTP 404)')

      described_class.new.perform(release.id)

      expect(release.reload.ci_compile_state).to eq('failed')
      expect(release.ci_compile_error).to eq('GitHub refused (HTTP 404)')
    end

    it 'fails the release, not the job, on an unexpected error' do
      allow(dispatcher).to receive(:call).and_raise(RuntimeError, 'boom')

      expect { described_class.new.perform(release.id) }.not_to raise_error
      expect(release.reload.ci_compile_state).to eq('failed')
      expect(release.ci_compile_error).to include('RuntimeError')
    end

    it 'fails the release when CI was switched off after it was queued' do
      stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_ENABLED' => 'false'))

      described_class.new.perform(release.id)

      expect(release.reload.ci_compile_state).to eq('failed')
      expect(release.ci_compile_error).to include('CI_COMPILE_ENABLED')
      expect(dispatcher).not_to have_received(:call)
    end

    it 'never overwrites a result that arrived before the dispatch was recorded' do
      allow(dispatcher).to receive(:call) { release.update_columns(ci_compile_state: 'done') }

      described_class.new.perform(release.id)

      expect(release.reload.ci_compile_state).to eq('done')
    end

    %w[dispatched done failed].each do |other|
      context "when the release is already #{other}" do
        let(:state) { other }

        it 'does nothing' do
          described_class.new.perform(release.id)

          expect(release.reload.ci_compile_state).to eq(other)
          expect(dispatcher).not_to have_received(:call)
        end
      end
    end

    it 'ignores an unknown release' do
      expect { described_class.new.perform(0) }.not_to raise_error
    end
  end

  describe '.enqueue_for' do
    let(:state) { nil }

    before { allow(described_class).to receive(:perform_later) }

    it 'marks the release queued and enqueues the job' do
      expect(described_class.enqueue_for(release)).to be(true)

      expect(release.reload.ci_compile_state).to eq('queued')
      expect(described_class).to have_received(:perform_later).with(release.id)
    end

    it 'requeues a failed release and clears the old reason' do
      release.update_columns(ci_compile_state: 'failed', ci_compile_error: 'old reason',
                             ci_compile_finished_at: Time.current)

      expect(described_class.enqueue_for(release)).to be(true)

      release.reload
      expect(release.ci_compile_state).to eq('queued')
      expect(release.ci_compile_error).to be_nil
      expect(release.ci_compile_finished_at).to be_nil
    end

    %w[queued dispatched done].each do |busy|
      it "leaves a #{busy} release alone" do
        release.update_columns(ci_compile_state: busy)

        expect(described_class.enqueue_for(release)).to be(false)
        expect(described_class).not_to have_received(:perform_later)
      end
    end

    it 'does nothing when CI is off' do
      stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_ENABLED' => 'false'))

      expect(described_class.enqueue_for(release)).to be(false)
      expect(release.reload.ci_compile_state).to be_nil
    end

    it 'does nothing for a release that is not an AAB' do
      release.update_columns(file_storage_key: 'uploads/apps/a1/r1/binary/app.apk')

      expect(described_class.enqueue_for(release)).to be(false)
      expect(release.reload.ci_compile_state).to be_nil
    end
  end
end
