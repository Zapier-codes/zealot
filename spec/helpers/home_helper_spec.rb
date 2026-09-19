# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HomeHelper, type: :helper do
  describe '#compact_count' do
    it 'collapses whole millions to "NM+" with no trailing zeros' do
      expect(helper.compact_count(10_000_000)).to eq('10M+')
      expect(helper.compact_count(5_000_000)).to eq('5M+')
    end

    it 'ignores small live counts added on top of a baseline' do
      expect(helper.compact_count(10_000_037)).to eq('10M+')
    end

    it 'keeps one decimal when it is non-zero, truncating instead of rounding' do
      expect(helper.compact_count(5_250_000)).to eq('5.2M+')
      expect(helper.compact_count(5_299_999)).to eq('5.2M+')
      expect(helper.compact_count(1_000_000)).to eq('1M+')
    end

    it 'shows plain delimited digits below one million' do
      expect(helper.compact_count(750_000)).to eq('750,000+')
      expect(helper.compact_count(999_999)).to eq('999,999+')
    end

    it 'switches to billions at 1,000,000,000' do
      expect(helper.compact_count(2_500_000_000)).to eq('2.5B+')
    end
  end
end
