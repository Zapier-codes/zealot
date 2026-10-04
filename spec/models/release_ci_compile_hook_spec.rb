# frozen_string_literal: true

require 'rails_helper'

# Task 40d: the upload hook (`Release#anthropic_asset_delivery_job`). With CI_COMPILE_ENABLED=true an AAB goes
# to the CI path and the Ruby compile is never queued; with it off nothing changes. Needs Postgres.
# Releases are built like serializer_spec.rb builds them (an uploaded file with a real extension, saved with
# `validate: false` so the create-only parse and upload validations do not run). Written, NOT run (the
# operator said no testing): look here first if CI is red for this slice.
RSpec.describe Release, 'CI compile hook (Task 40d)' do
  let(:app) { create(:app, name: 'Hook app') }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }

  def create_upload(extension)
    release = Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1', build_version: '1')
    Tempfile.create(['release', extension]) do |tmp|
      tmp.write('bytes')
      tmp.flush
      release.file = File.open(tmp.path)
      release.save!(validate: false)
    end
    release
  end

  def with_ci(value)
    stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_ENABLED' => value))
  end

  context 'with CI compile on' do
    before { with_ci('true') }

    it 'queues the CI dispatch for an AAB and never the Ruby compile' do
      release = nil

      expect { release = create_upload('.aab') }.to have_enqueued_job(CiCompileDispatchJob)
      expect { create_upload('.aab') }.not_to have_enqueued_job(AnthropicAssetDeliveryJob)
      expect(release.reload.ci_compile_state).to eq('queued')
    end

    it 'does nothing for an APK (only bundles are compiled)' do
      release = nil

      expect { release = create_upload('.apk') }.not_to have_enqueued_job(CiCompileDispatchJob)
      expect(release.reload.ci_compile_state).to be_nil
    end
  end

  context 'with CI compile off' do
    before { with_ci('false') }

    it 'queues the Ruby compile for an AAB, exactly as before' do
      release = nil

      expect { release = create_upload('.aab') }.to have_enqueued_job(AnthropicAssetDeliveryJob)
      expect { create_upload('.aab') }.not_to have_enqueued_job(CiCompileDispatchJob)
      expect(release.reload.ci_compile_state).to be_nil
    end
  end

  context 'with the variable unset' do
    before { stub_const('ENV', ENV.to_hash.except('CI_COMPILE_ENABLED')) }

    it 'is the same as off' do
      expect { create_upload('.aab') }.to have_enqueued_job(AnthropicAssetDeliveryJob)
    end
  end
end
