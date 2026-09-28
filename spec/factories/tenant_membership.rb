# frozen_string_literal: true

FactoryBot.define do
  factory :tenant_membership do
    tenant
    user { User.create!(email: "member-#{SecureRandom.hex(4)}@example.com", username: "member-#{SecureRandom.hex(4)}",
                        password: 'correct-horse-9', password_confirmation: 'correct-horse-9',
                        confirmed_at: Time.current) }
    role { 'member' }

    trait(:owner) { role { 'owner' } }
  end
end
