# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Play::PanelNormalizer do
  it 'labels the panel and keeps only the fields Play gave' do
    raw = {
      'packageName' => 'com.example.app',
      'title' => 'Example',
      'developer' => 'Example Co',
      'shortDescription' => 'Does a thing',
      'score' => 4.567,
      'ratingsCount' => 1234,
      'installs' => '1,000,000+',
      'formattedPrice' => 'Free',
      'icon' => { 'url' => 'https://play.example/icon.png' },
      'screenshots' => [{ 'url' => 'https://play.example/1.png' }, { 'url' => 'http://insecure/2.png' }],
    }

    panel = described_class.call(raw, package: 'com.example.app')

    expect(panel['source']).to eq('play')
    expect(panel['package']).to eq('com.example.app')
    expect(panel['title']).to eq('Example')
    expect(panel['developer']).to eq('Example Co')
    expect(panel['rating']).to eq(4.57)               # rounded, not the raw float
    expect(panel['rating_count']).to eq(1234)
    expect(panel['downloads']).to eq('1,000,000+')     # verbatim, never parsed into a false-precise number
    expect(panel['price_label']).to eq('Free')
    expect(panel['icon_url']).to eq('https://play.example/icon.png')
    expect(panel['screenshot_urls']).to eq(['https://play.example/1.png']) # http dropped
  end

  it 'omits a missing rating rather than inventing a zero' do
    panel = described_class.call({ 'title' => 'No rating' }, package: 'com.x')

    expect(panel).not_to have_key('rating')
    expect(panel).not_to have_key('rating_count')
    expect(panel).not_to have_key('downloads')
  end

  it 'reads the Aurora/aggregateRating nesting too' do
    raw = { 'title' => 'A', 'aggregateRating' => { 'starRating' => 3.5, 'ratingsCount' => 10 } }

    panel = described_class.call(raw)

    expect(panel['rating']).to eq(3.5)
  end

  it 'returns nil for an empty or non-hash body' do
    expect(described_class.call({})).to be_nil
    expect(described_class.call(nil)).to be_nil
    expect(described_class.call('nope')).to be_nil
  end
end
