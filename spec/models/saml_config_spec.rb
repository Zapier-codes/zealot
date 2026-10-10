# frozen_string_literal: true

require 'rails_helper'

# Z-P18 (SSO/SAML half; Play Console parity): the SAML configuration's pure rules. Written by reading the
# model, like the other slices' specs (no Ruby/Rails/DB in the sandbox that wrote it), so this is the first
# thing to look at if CI is red for this slice.
RSpec.describe SamlConfig do
  describe '.configured?' do
    it 'is true only when enabled, an IdP SSO URL and a certificate are all present' do
      expect(described_class.configured?(enabled: true, idp_sso_url: 'https://idp/sso', idp_cert: 'PEM')).to be(true)
    end

    it 'is false when disabled even with full metadata' do
      expect(described_class.configured?(enabled: false, idp_sso_url: 'https://idp/sso', idp_cert: 'PEM')).to be(false)
    end

    it 'is false when the certificate is missing (an unverifiable assertion is no login)' do
      expect(described_class.configured?(enabled: true, idp_sso_url: 'https://idp/sso')).to be(false)
    end

    it 'is false for a nil or empty config' do
      expect(described_class.configured?(nil)).to be(false)
      expect(described_class.configured?({})).to be(false)
    end

    it 'accepts string keys and a "1" boolean, as a form or ENV would supply' do
      config = { 'enabled' => '1', 'idp_sso_url' => 'https://idp/sso', 'idp_cert' => 'PEM' }
      expect(described_class.configured?(config)).to be(true)
    end
  end

  describe '.attribute_statements' do
    it 'returns the defaults when there is no override' do
      statements = described_class.attribute_statements({})
      expect(statements['email']).to include('email')
      expect(statements['name']).to include('displayName')
    end

    it 'merges an override for one field without dropping the others' do
      statements = described_class.attribute_statements(attribute_map: { 'email' => 'mail' })
      expect(statements['email']).to eq(['mail'])
      expect(statements['name']).to include('displayName')
    end

    it 'accepts a string or an array of alternates for a field' do
      statements = described_class.attribute_statements(attribute_map: { 'uid' => ['a', 'b'] })
      expect(statements['uid']).to eq(%w[a b])
    end

    it 'never mutates the frozen defaults' do
      described_class.attribute_statements(attribute_map: { 'email' => 'mail' })
      expect(described_class::DEFAULT_ATTRIBUTE_MAP['email']).to include('email')
    end
  end

  describe '.with_defaults' do
    it 'fills the SP entity id and ACS URL from the host when blank' do
      config = described_class.with_defaults({}, host: 'https://app.example.com')
      expect(config[:sp_entity_id]).to eq('https://app.example.com/users/auth/saml/metadata')
      expect(config[:sp_acs_url]).to eq('https://app.example.com/users/auth/saml/callback')
    end

    it 'keeps values the operator set' do
      config = described_class.with_defaults({ sp_acs_url: 'https://sp/acs' }, host: 'https://app.example.com')
      expect(config[:sp_acs_url]).to eq('https://sp/acs')
    end
  end
end
