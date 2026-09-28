# frozen_string_literal: true

require 'rails_helper'

# Task 37b-ii-k6: the four key-lifecycle steps are admin-only, and no one can destroy a key row.
RSpec.describe TenantSigningKeyPolicy do
  let(:record) { TenantSigningKey.new }
  let(:admin) { instance_double(User, admin?: true, manage?: true) }
  let(:developer) { instance_double(User, admin?: false, manage?: true) }

  %i[generate? stage_next? promote? retire?].each do |action|
    it "allows an admin to #{action}" do
      expect(described_class.new(admin, record).public_send(action)).to be(true)
    end

    it "refuses a developer, even though they can manage other records, to #{action}" do
      expect(described_class.new(developer, record).public_send(action)).to be(false)
    end

    it "refuses a signed-out visitor to #{action}" do
      expect(described_class.new(nil, record).public_send(action)).to be_falsey
    end
  end

  it 'has no destroy, not even for an admin' do
    expect(described_class.new(admin, record).destroy?).to be(false)
  end
end
