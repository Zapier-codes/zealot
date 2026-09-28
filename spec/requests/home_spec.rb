# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Landing page', type: :request do
  it 'has a single Get started button that goes to the login page' do
    get root_path

    expect(response).to have_http_status(:ok)
    body = response.body
    expect(body).to include('landing-cta')
    expect(body).to include(%(href="#{new_user_session_path}"))
    expect(body).not_to include('/users/sign_up')
    expect(body.scan('d-btn-lg').size).to eq(1)
  end

  # Task 37b-iii-s7a: the public counters are the default site's number, so a tenant's apps and
  # releases must not move them. The raw value is rendered in `data-counter-count-value`.
  describe 'stat counters' do
    def counter_values
      response.body.scan(/data-counter-count-value="?(\d+)"?/).flatten.map(&:to_i)
    end

    def make_release(app)
      scheme = app.schemes.create!(name: 'Main')
      channel = scheme.channels.create!(name: 'Android', device_type: :android)
      Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1',
                  build_version: '1').tap { |release| release.save!(validate: false) }
    end

    let(:apps_baseline) { HomeController::MIGRATED_APPS_BASELINE }
    let(:releases_baseline) { HomeController::MIGRATED_RELEASES_BASELINE }

    it 'is the baseline plus the default tenant\'s own apps and releases' do
      make_release(App.create!(name: 'Default app'))

      get root_path

      expect(counter_values.first(2)).to eq([apps_baseline + 1, releases_baseline + 1])
    end

    it 'does not count another tenant\'s apps or releases' do
      make_release(App.create!(name: 'Default app'))
      make_release(App.create!(name: 'Acme app', tenant: create(:tenant, tenant_id: 'acme')))

      get root_path

      expect(counter_values.first(2)).to eq([apps_baseline + 1, releases_baseline + 1])
    end

    it 'is just the baseline when only a tenant owns apps' do
      make_release(App.create!(name: 'Acme app', tenant: create(:tenant, tenant_id: 'acme')))

      get root_path

      expect(counter_values.first(2)).to eq([apps_baseline, releases_baseline])
    end
  end
end
