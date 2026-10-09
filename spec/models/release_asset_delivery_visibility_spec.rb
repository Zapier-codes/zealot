# frozen_string_literal: true

require 'rails_helper'

# Operator-directed fix (2026-10-09). Zealot answered HTTP 500 to the stage-2 callback of the first real compile
# because `record_asset_delivery!` sat below `private` in Release while three callers use it with an explicit
# receiver (`release.record_asset_delivery!`): ReleaseUploadFinisher, Api::CiCompileController and
# AnthropicAssetDeliveryJob. The first example needs no database and is the one that would have caught it.
# NOT run in the sandbox that wrote it (no Ruby, Rails or database there).
RSpec.describe Release, 'record_asset_delivery! visibility' do
  it 'is a public instance method, because callers outside the model use it with an explicit receiver' do
    expect(Release.public_method_defined?(:record_asset_delivery!)).to be(true)
    expect(Release.private_method_defined?(:record_asset_delivery!)).to be(false)
  end

  it 'records the state when called from outside the model' do
    app = App.create!(name: 'Delivery app', listing_status: :live, listed_at: Time.current)
    channel = app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android)
    release = Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1', build_version: '1')
    release.save!(validate: false)

    release.record_asset_delivery!(:failed, error: 'boom')

    expect(release.reload.asset_delivery_state).to eq('failed')
    expect(release.asset_delivery_error).to eq('boom')
  end
end
