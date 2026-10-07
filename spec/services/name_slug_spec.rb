# frozen_string_literal: true

require 'rails_helper'

# Task 44a: written by reading the code; the spec was NOT run (operator's standing rule: syntax checks only).
RSpec.describe NameSlug do
  describe '.base' do
    it 'lowercases and joins words with single hyphens' do
      expect(described_class.base('Vyxel Apps!')).to eq('vyxel-apps')
      expect(described_class.base('  My  Store (beta) ')).to eq('my-store-beta')
    end

    it 'drops accents' do
      expect(described_class.base('Café Ünïcode')).to eq('cafe-unicode')
    end

    it 'never lets a path or a leading dot through' do
      expect(described_class.base('../../etc/passwd')).to eq('etc-passwd')
      expect(described_class.base('.hidden')).to eq('hidden')
    end

    it 'answers an empty string when the name has nothing usable' do
      expect(described_class.base('!!!')).to eq('')
      expect(described_class.base(nil)).to eq('')
      expect(described_class.base('应用商店')).to eq('')
    end

    it 'prefixes an all-digit name so it is not read as an id' do
      expect(described_class.base('2048')).to eq('app-2048')
    end

    it 'suffixes a route word' do
      expect(described_class.base('Admin')).to eq('admin-app')
      expect(described_class.base('API')).to eq('api-app')
    end

    it 'bounds a long name and does not end on a hyphen' do
      slug = described_class.base("#{'x' * 39} #{'y' * 50}")

      expect(slug.length).to be <= described_class::MAX
      expect(slug).to eq('x' * 39)
      expect(slug).to match(described_class::FORMAT)
    end

    it 'always matches the slug format when it is not empty' do
      ['Storeapp', 'a b', '1.2.3', 'Zeal-Ot_2'].each do |name|
        expect(described_class.base(name)).to match(described_class::FORMAT)
      end
    end
  end

  describe '.unique' do
    it 'answers the base when it is free' do
      expect(described_class.unique('appstore') { |_slug| false }).to eq('appstore')
    end

    it 'numbers a taken base from 2' do
      taken = %w[appstore appstore-2]

      expect(described_class.unique('appstore') { |slug| taken.include?(slug) }).to eq('appstore-3')
    end

    it 'falls back to a random suffix instead of looping for ever' do
      slug = described_class.unique('appstore') { |_slug| true }

      expect(slug).to match(/\Aappstore-[0-9a-f]{6}\z/)
    end
  end
end
