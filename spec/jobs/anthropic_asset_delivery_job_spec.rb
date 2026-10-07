# frozen_string_literal: true

require 'rails_helper'

# Task 30 (D-Store leaf 7.a.vi.zi): the compile outcome is recorded on the release, so "still running" and
# "failed" stop looking the same. Only the early, tooling-free paths are covered here (no bundletool, no
# brotli, no real bundle); the compile itself is unchanged and unrun, per the standing no-testing
# instruction.
RSpec.describe AnthropicAssetDeliveryJob do
  let!(:app) { create(:app, name: 'Job App') }
  let!(:channel) { make_channel(app) }

  def make_channel(target)
    scheme = target.schemes.create!(name: "Scheme #{target.name}")
    scheme.channels.create!(name: "Channel #{target.name}", device_type: :android)
  end

  def make_release(**attributes)
    release = channel.releases.build(release_version: '1.0.0', build_version: '1', **attributes)
    release.save!(validate: false)
    release
  end

  before do
    allow(CiCompileDispatcher).to receive(:enabled?).and_return(false)
  end

  it 'records skipped when asset pack delivery is disabled' do
    allow(Rails.application.config.x.anthropic).to receive(:asset_pack_delivery_enabled).and_return(false)
    release = make_release

    described_class.perform_now(release.id)

    expect(release.reload.asset_delivery_state).to eq('skipped')
    expect(release.asset_delivery_error).to eq('asset pack delivery is disabled')
  end

  it 'records skipped when the release has no uploaded file' do
    allow(Rails.application.config.x.anthropic).to receive(:asset_pack_delivery_enabled).and_return(true)
    release = make_release

    described_class.perform_now(release.id)

    expect(release.reload.asset_delivery_state).to eq('skipped')
    expect(release.asset_delivery_error).to eq('the release has no uploaded file')
  end

  it 'records nothing when CI compile is on (the CI callback records the outcome instead)' do
    allow(CiCompileDispatcher).to receive(:enabled?).and_return(true)
    release = make_release

    described_class.perform_now(release.id)

    expect(release.reload.asset_delivery_state).to be_nil
  end

  it 'does nothing for a release that no longer exists' do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end
end
