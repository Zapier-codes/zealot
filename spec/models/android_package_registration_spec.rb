# frozen_string_literal: true

require 'rails_helper'

# Task 36b-3. Written, NOT run.
RSpec.describe AndroidPackageRegistration do
  it 'is valid with a package name and defaults to pending' do
    row = described_class.create!(package_name: 'com.example.app')

    expect(row.state).to eq('pending')
    expect(row).not_to be_settled
  end

  it 'refuses a duplicate package name' do
    described_class.create!(package_name: 'com.example.app')

    expect(described_class.new(package_name: 'com.example.app')).not_to be_valid
  end

  it 'refuses a name that is not an Android application id' do
    expect(described_class.new(package_name: '*')).not_to be_valid
    expect(described_class.new(package_name: 'nodots')).not_to be_valid
  end

  it 'refuses an unknown state' do
    expect(described_class.new(package_name: 'com.example.app', state: 'done')).not_to be_valid
  end

  it 'counts registered and needs_review as settled' do
    expect(described_class.new(state: 'registered')).to be_settled
    expect(described_class.new(state: 'needs_review')).to be_settled
    expect(described_class.new(state: 'failed')).not_to be_settled
  end

  it 'survives its app being destroyed' do
    app = App.create!(name: 'Gone')
    row = described_class.create!(package_name: 'com.example.app', app: app)

    app.destroy

    expect(row.reload.app_id).to be_nil
  end
end
