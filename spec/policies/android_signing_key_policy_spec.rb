# frozen_string_literal: true

require 'rails_helper'

# Task 34d-1: the org-wide signing key is for platform admins only. `manage?` (true for a developer) is not
# enough, and an admin on a tenant's host is an ordinary user (❓4b-b). Written, NOT run.
RSpec.describe AndroidSigningKeyPolicy do
  let(:record) { AndroidSigningKey.new }
  let(:admin) { User.new(role: :admin) }
  let(:developer) { User.new(role: :developer) }

  %i[show? new? create? destroy?].each do |action|
    it "allows an admin on the default host to #{action}" do
      expect(described_class.new(admin, record).public_send(action)).to be(true)
    end

    it "refuses a developer to #{action}" do
      expect(described_class.new(developer, record).public_send(action)).to be(false)
    end

    it "refuses a signed-out caller to #{action}" do
      expect(described_class.new(nil, record).public_send(action)).to be_falsey
    end

    it "refuses an admin on a tenant's host to #{action}" do
      Current.set(tenant: create(:tenant)) do
        expect(described_class.new(admin, record).public_send(action)).to be(false)
      end
    end
  end
end
