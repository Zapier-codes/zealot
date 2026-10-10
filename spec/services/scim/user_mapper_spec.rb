# frozen_string_literal: true

require 'rails_helper'

# Z-P18 (SCIM half; Play Console parity): the SCIM User resource mapping. Pure, so it is pinned off-device.
RSpec.describe Scim::UserMapper do
  let(:user) do
    build_stubbed(:user, id: 42, email: 'ann@acme.example.com', username: 'ann',
                         created_at: Time.utc(2026, 1, 1), updated_at: Time.utc(2026, 1, 2))
  end

  describe '.to_resource' do
    it 'names the account, its email and its location' do
      resource = described_class.to_resource(user)
      expect(resource['schemas']).to eq([described_class::USER_SCHEMA])
      expect(resource['id']).to eq('42')
      expect(resource['userName']).to eq('ann@acme.example.com')
      expect(resource['emails']).to eq([{ 'value' => 'ann@acme.example.com', 'primary' => true }])
      expect(resource['meta']['location']).to eq('/scim/v2/Users/42')
    end

    it 'reads active from the membership: no membership means not provisioned here' do
      expect(described_class.to_resource(user)['active']).to be(false)
    end

    it 'reads active true when the user is a member of the tenant' do
      membership = instance_double(TenantMembership)
      expect(described_class.to_resource(user, membership: membership)['active']).to be(true)
    end
  end

  describe '.list_response' do
    it 'reports the unpaged total and the envelope schema' do
      body = described_class.list_response([{ 'id' => '1' }], total: 5, start_index: 1, items_per_page: 1)
      expect(body['schemas']).to eq([described_class::LIST_RESPONSE_SCHEMA])
      expect(body['totalResults']).to eq(5)
      expect(body['Resources'].size).to eq(1)
    end
  end

  describe '.attributes_from' do
    it 'takes the email from userName' do
      attrs = described_class.attributes_from('userName' => 'a@b.com')
      expect(attrs[:email]).to eq('a@b.com')
    end

    it 'falls back to the primary email entry' do
      attrs = described_class.attributes_from('emails' => [{ 'value' => 'p@x.com', 'primary' => true }])
      expect(attrs[:email]).to eq('p@x.com')
    end

    it 'takes a display name from name.givenName then displayName' do
      expect(described_class.attributes_from('name' => { 'givenName' => 'Ann' })[:username]).to eq('Ann')
      expect(described_class.attributes_from('displayName' => 'Ann B')[:username]).to eq('Ann B')
    end

    it 'carries active through, including false' do
      expect(described_class.attributes_from('active' => false)[:active]).to be(false)
      expect(described_class.attributes_from({})).not_to have_key(:active)
    end

    it 'omits keys the client did not send, so a PATCH cannot blank a name' do
      expect(described_class.attributes_from('active' => true)).not_to have_key(:username)
    end
  end
end
