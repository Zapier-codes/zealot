# frozen_string_literal: true

require 'rails_helper'

# Z-P12: `POST /api/pre_launch_reports/:id`, the pre-launch CI workflow reporting the redroid run's payload.
# Needs Postgres. Built by imitating api_ci_compile_callback_spec.rb; NOT run (no Rails/Postgres in the
# authoring sandbox), so look here first if CI is red for this slice.
RSpec.describe 'API pre-launch report callback', type: :request do
  let(:token) { 'pre-launch-secret-1' }
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let!(:release) do
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1', build_version: '1',
                pre_launch_status: 'running')
           .tap { |r| r.save!(validate: false) }
  end
  let(:path) { "/api/pre_launch_reports/#{release.id}" }

  def bearer(secret = token)
    { 'Authorization' => "Bearer #{secret}" }
  end

  def payload(overrides = {})
    {
      devices: [{ name: 'localhost:9100' }],
      events: 2000,
      crashes: [{ device: 'localhost:9100', message: 'FATAL EXCEPTION: main' }],
      anrs: [],
      exceptions: [],
      startup: { ok: true, message: '' }
    }.merge(overrides)
  end

  def call(body = nil, headers: bearer, **fields)
    body = fields if body.nil?
    post path, params: body.to_json, headers: headers.merge('Content-Type' => 'application/json')
  end

  before do
    Zealot::TenantRegistry.reset!
    stub_const('ENV', ENV.to_hash.merge('PRE_LAUNCH_CALLBACK_TOKEN' => token))
  end

  describe 'authentication' do
    it 'refuses a call with no token' do
      call(payload, headers: {})

      expect(response).to have_http_status(:unauthorized)
      expect(release.reload.pre_launch_status).to eq('running')
    end

    it 'refuses a wrong token' do
      call(payload, headers: bearer('nope'))

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses everything when the server has no token configured' do
      stub_const('ENV', ENV.to_hash.merge('PRE_LAUNCH_CALLBACK_TOKEN' => ''))

      call(payload, headers: bearer(''))

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'recording the payload' do
    it 'records the verdict and findings on the release' do
      call(payload)

      expect(response).to have_http_status(:ok)
      release.reload
      expect(release.pre_launch_status).to eq('done')
      expect(release.pre_launch_verdict).to eq('reject')
      expect(release.pre_launch_findings.first['code']).to eq('device_crash')
      expect(release.pre_launch_run_at).to be_present
      expect(release.pre_launch_summary).to include('1 device')
    end

    it 'passes a clean payload' do
      call(payload(crashes: [], anrs: []))

      expect(response).to have_http_status(:ok)
      expect(release.reload.pre_launch_verdict).to eq('pass')
    end

    it 'is idempotent for a release already done' do
      release.update_columns(pre_launch_status: 'done', pre_launch_verdict: 'pass')

      call(payload)

      expect(response).to have_http_status(:conflict)
      expect(release.reload.pre_launch_verdict).to eq('pass') # unchanged
    end

    it 'returns 404 for an unknown release' do
      post '/api/pre_launch_reports/999999', params: payload.to_json,
           headers: bearer.merge('Content-Type' => 'application/json')

      expect(response).to have_http_status(:not_found)
    end
  end
end
