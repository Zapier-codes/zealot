# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:username) { |n| "user#{n}" }
    password { 'correct-horse-9' }
    password_confirmation { 'correct-horse-9' }
    confirmed_at { Time.current }
    token { Digest::MD5.hexdigest(SecureRandom.uuid) }
  end
end
