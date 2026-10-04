# frozen_string_literal: true

require 'rails_helper'

# Task 40d: the two older jobs that touch an uploaded bundle step aside when CI compile is on, so Zealot
# never compiles (AnthropicAssetDeliveryJob) and never swaps the bundle for a patched APK
# (ProxySdkInjectionJob). Both are checked at the job, with the work they would do stubbed to fail loudly.
# Written, NOT run (the operator said no testing): look here first if CI is red for this slice.
RSpec.describe 'Jobs that step aside for CI compile (Task 40d)' do
  def with_ci(value)
    stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_ENABLED' => value))
  end

  describe AnthropicAssetDeliveryJob do
    it 'does nothing, not even a lookup, when CI compile is on' do
      with_ci('true')
      expect(Release).not_to receive(:find_by)
      expect(Anthropic::AssetPackService).not_to receive(:new)

      described_class.perform_now(123)
    end
  end

  describe ProxySdkInjectionJob do
    let(:release) { instance_double(Release, id: 5) }

    before { allow(Release).to receive(:find_by).with(id: 5).and_return(release) }

    it 'skips a bundle when CI compile is on: no injector, no mirror' do
      with_ci('true')
      allow(CiCompileDispatchJob).to receive(:aab?).with(release).and_return(true)
      expect(ProxySdk::Injector).not_to receive(:call)

      expect { described_class.perform_now(5) }.not_to have_enqueued_job(ReleaseFileMirrorJob)
    end

    it 'still injects an APK when CI compile is on' do
      with_ci('true')
      allow(CiCompileDispatchJob).to receive(:aab?).with(release).and_return(false)
      expect(ProxySdk::Injector).to receive(:call).with(release)

      expect { described_class.perform_now(5) }.to have_enqueued_job(ReleaseFileMirrorJob).with(5)
    end

    it 'injects a bundle as before when CI compile is off' do
      with_ci('false')
      allow(CiCompileDispatchJob).to receive(:aab?).with(release).and_return(true)
      expect(ProxySdk::Injector).to receive(:call).with(release)

      expect { described_class.perform_now(5) }.to have_enqueued_job(ReleaseFileMirrorJob).with(5)
    end
  end
end
