# frozen_string_literal: true

require 'rails_helper'

# Task 47f: what the upload page and the release page say Zealot adds. Pure (an App is not saved). Written, NOT run.
RSpec.describe InjectedComponents do
  let(:app) { App.new(name: 'Notice App') }

  around do |example|
    old = ENV['UPDATER_INJECTION']
    example.run
  ensure
    ENV['UPDATER_INJECTION'] = old
  end

  it 'lists the updater as planned and the SDK as conditional while the updater injection is off' do
    ENV['UPDATER_INJECTION'] = nil

    list = described_class.for(app)

    expect(list.map { |c| [c.key, c.status] }).to eq([%i[updater planned], %i[sdk conditional]])
  end

  it 'lists the updater as active once the updater injection is on' do
    ENV['UPDATER_INJECTION'] = 'true'

    expect(described_class.for(app).first).to have_attributes(key: :updater, status: :active)
  end

  it 'leaves the updater out when the publisher switched it off, but still lists the SDK' do
    app.updater_enabled = false

    expect(described_class.for(app).map(&:key)).to eq([:sdk])
  end

  it 'gives every component a non-empty permission list' do
    described_class.for(app).each { |c| expect(c.permissions).not_to be_empty }
  end

  it 'has an English and a Chinese text for every listed key' do
    %i[en zh-CN].each do |locale|
      I18n.with_locale(locale) do
        %w[title intro permissions updater_limits updater_off status.planned status.conditional updater.name
           updater.what sdk.name sdk.what].each do |key|
          expect(I18n.exists?("releases.injected.#{key}", locale)).to be(true), "#{locale} #{key}"
        end
      end
    end
  end
end
