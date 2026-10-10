# frozen_string_literal: true

require 'rails_helper'

# Z-P23 (Play Console parity): the installable console. The manifest and the service worker are public
# GETs (a browser reads them before any session exists), and the worker never caches dynamic data.
# Written-not-run in the sandbox (no bundle); the worker's cache rule is also exercised by a node harness.
RSpec.describe 'Installable console (PWA)', type: :request do
  describe 'GET /manifest.webmanifest' do
    it 'is served without a session and names the deployment' do
      Setting.site_title = 'Acme Store'
      get '/manifest.webmanifest'

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/manifest+json')

      manifest = JSON.parse(response.body)
      expect(manifest['name']).to eq('Acme Store')
      expect(manifest['start_url']).to eq('/')
      expect(manifest['display']).to eq('standalone')
      expect(manifest['icons'].map { |i| i['sizes'] }).to include('192x192', '512x512')
      expect(manifest['icons'].map { |i| i['purpose'] }).to include('maskable')
    end
  end

  describe 'GET /service-worker.js' do
    it 'is served as JavaScript without a session' do
      get '/service-worker.js'

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/javascript')
      expect(response.body).to include('isCacheableShell')
    end
  end
end
