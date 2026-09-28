# frozen_string_literal: true

FactoryBot.define do
  factory :tenant do
    sequence(:tenant_id) { |n| "tenant-#{n}" }
    display_name { 'Acme App Store' }
    primary_color_hex { '#FF6600' }
    cdn_base { 'https://cdn.acme.example.com/appstore-metadata' }
    domains { [] }
  end
end
