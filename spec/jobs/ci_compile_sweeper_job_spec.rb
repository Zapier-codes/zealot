# frozen_string_literal: true

require 'rails_helper'

# Task 40g: queued / dispatched releases that never reported back become failed. Needs Postgres. Builds a
# release like ci_compile_dispatch_job_spec.rb does; nothing is stubbed because the job touches only the
# database. NOT run (the operator said no testing); look here first if CI is red for this slice.
RSpec.describe CiCompileSweeperJob do
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:state) { 'dispatched' }
  let(:state_at) { 3.hours.ago }
  let!(:release) do
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1', build_version: '1',
                ci_compile_state: state, ci_compile_state_at: state_at)
           .tap { |r| r.save!(validate: false) }
  end

  describe '.stale_after' do
    it 'defaults to 90 minutes' do
      stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_STALE_AFTER_MINUTES' => nil))

      expect(described_class.stale_after).to eq(90.minutes)
    end

    it 'reads CI_COMPILE_STALE_AFTER_MINUTES' do
      stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_STALE_AFTER_MINUTES' => '30'))

      expect(described_class.stale_after).to eq(30.minutes)
    end

    %w[0 -5 abc].each do |bad|
      it "falls back to the default for #{bad.inspect}" do
        stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_STALE_AFTER_MINUTES' => bad))

        expect(described_class.stale_after).to eq(90.minutes)
      end
    end
  end

  describe '#perform' do
    it 'fails a dispatched release that has been silent past the limit' do
      described_class.new.perform

      release.reload
      expect(release.ci_compile_state).to eq('failed')
      expect(release.ci_compile_error).to include('CI did not report back')
      expect(release.ci_compile_finished_at).to be_present
    end

    context 'when the release is queued' do
      let(:state) { 'queued' }

      it 'fails it with the dispatch-job reason' do
        described_class.new.perform

        release.reload
        expect(release.ci_compile_state).to eq('failed')
        expect(release.ci_compile_error).to include('dispatch job did not run')
      end
    end

    context 'when the release is still within the limit' do
      let(:state_at) { 10.minutes.ago }

      it 'leaves it alone' do
        described_class.new.perform

        expect(release.reload.ci_compile_state).to eq('dispatched')
        expect(release.ci_compile_error).to be_nil
      end
    end

    context 'when the release has no timestamp yet (dispatched before the column existed)' do
      let(:state_at) { nil }

      it 'starts counting now instead of failing it' do
        described_class.new.perform

        release.reload
        expect(release.ci_compile_state).to eq('dispatched')
        expect(release.ci_compile_state_at).to be_within(1.minute).of(Time.current)
      end
    end

    %w[done failed].each do |settled|
      context "when the release is #{settled}" do
        let(:state) { settled }

        it 'does not touch it' do
          described_class.new.perform

          release.reload
          expect(release.ci_compile_state).to eq(settled)
          expect(release.ci_compile_error).to be_nil
        end
      end
    end

    context 'when the release was never sent to CI' do
      let(:state) { nil }

      it 'does not touch it' do
        described_class.new.perform

        expect(release.reload.ci_compile_state).to be_nil
      end
    end

    it 'does not fail a release whose callback landed between the read and the write' do
      allow_any_instance_of(described_class).to receive(:reason_for) do |_job, _was|
        release.update_columns(ci_compile_state: 'done')
        'late'
      end

      described_class.new.perform

      expect(release.reload.ci_compile_state).to eq('done')
    end
  end
end
