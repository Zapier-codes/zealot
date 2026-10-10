# frozen_string_literal: true

require 'rails_helper'

# Z-P18 (SSO/SAML half; Play Console parity): SAML is in the provider list and only offered when it can
# actually work. Written by reading the model, like the other slices' specs.
RSpec.describe UserOmniauth do
  describe '#enabled_saml?' do
    let(:user) { build(:user) }

    around do |example|
      previous = Setting.saml
      example.run
    ensure
      Setting.saml = previous
    end

    it 'is false when the IdP config is incomplete' do
      Setting.saml = { 'enabled' => true, 'idp_sso_url' => 'https://idp/sso' }
      expect(user.enabled_saml?).to be(false)
    end

    it 'is true when enabled with the IdP SSO URL and certificate and the strategy is loaded' do
      Setting.saml = { 'enabled' => true, 'idp_sso_url' => 'https://idp/sso', 'idp_cert' => 'PEM' }
      skip 'omniauth-saml strategy not loaded in this environment' unless defined?(OmniAuth::Strategies::SAML)

      expect(user.enabled_saml?).to be(true)
    end
  end

  describe 'the provider list' do
    it 'offers saml among the omniauth providers' do
      expect(User.omniauth_providers).to include(:saml)
    end
  end
end
