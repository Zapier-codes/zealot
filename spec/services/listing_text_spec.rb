# frozen_string_literal: true

require 'rails_helper'

# Task 27e-a / 27e-b. Pure Ruby: no database, no Rails objects. See app/services/listing_text.rb.
RSpec.describe ListingText do
  describe 'limits' do
    it 'uses the numbers Play Console uses for its main store listing' do
      expect(described_class::DESCRIPTION_MAX_LENGTH).to eq(4000)
      expect(described_class::SHORT_DESCRIPTION_MAX_LENGTH).to eq(80)
    end
  end

  describe '.tidy_description' do
    it 'returns nil for nil and for a blank value, so "no text" is one state' do
      expect(described_class.tidy_description(nil)).to be_nil
      expect(described_class.tidy_description('')).to be_nil
      expect(described_class.tidy_description("  \n \t\n ")).to be_nil
    end

    it 'keeps a plain description as it is' do
      expect(described_class.tidy_description('A fast, small notes app.')).to eq('A fast, small notes app.')
    end

    it 'keeps paragraphs and turns Windows and old-Mac line endings into "\n"' do
      expect(described_class.tidy_description("One\r\n\r\nTwo\rThree")).to eq("One\n\nTwo\nThree")
    end

    it 'collapses three or more newlines to one blank line' do
      expect(described_class.tidy_description("One\n\n\n\n\nTwo")).to eq("One\n\nTwo")
    end

    it 'drops spaces at the end of a line, and a line of only spaces counts as blank' do
      expect(described_class.tidy_description("One   \n   \n\n   \nTwo  ")).to eq("One\n\nTwo")
    end

    it 'turns other control characters, including NUL and tab, into a space' do
      expect(described_class.tidy_description("a\u0000b\tc\u001Bd")).to eq('a b c d')
    end

    it 'treats the Unicode line and paragraph separators as newlines' do
      expect(described_class.tidy_description("One\u2028Two\u2029Three")).to eq("One\nTwo\nThree")
    end

    it 'does not raise on bytes that are not valid UTF-8' do
      bad = "caf\xC3 ok".dup.force_encoding('UTF-8')

      expect { described_class.tidy_description(bad) }.not_to raise_error
      expect(described_class.tidy_description(bad)).to eq('caf ok')
    end

    it 'leaves non-ASCII text and emoji alone' do
      text = "Notizen für Ärzte 🚀\n\n日本語のテキスト"

      expect(described_class.tidy_description(text)).to eq(text)
    end

    it 'is idempotent' do
      once = described_class.tidy_description("  A\r\n\r\n\r\n\tB \u0000 \n")

      expect(described_class.tidy_description(once)).to eq(once)
    end

    it 'coerces a non-string to a string rather than raising' do
      expect(described_class.tidy_description(42)).to eq('42')
    end
  end

  describe '.tidy_short_description' do
    it 'returns nil for nil and for a blank value' do
      expect(described_class.tidy_short_description(nil)).to be_nil
      expect(described_class.tidy_short_description('  ')).to be_nil
      expect(described_class.tidy_short_description("\n\t")).to be_nil
    end

    it 'keeps a plain line as it is' do
      expect(described_class.tidy_short_description('Notes that stay out of your way')).to eq('Notes that stay out of your way')
    end

    it 'makes it one line: newlines and runs of whitespace become one space' do
      expect(described_class.tidy_short_description("Fast\n\nsmall \t notes\r\napp")).to eq('Fast small notes app')
    end

    it 'treats a non-breaking space and the Unicode separators as whitespace' do
      expect(described_class.tidy_short_description("a\u00A0\u00A0b\u2028c\u2029d")).to eq('a b c d')
    end

    it 'turns control characters into a space' do
      expect(described_class.tidy_short_description("a\u0000b\u001Bc")).to eq('a b c')
    end

    it 'does not raise on bytes that are not valid UTF-8' do
      bad = "caf\xC3 ok".dup.force_encoding('UTF-8')

      expect(described_class.tidy_short_description(bad)).to eq('caf ok')
    end

    it 'is idempotent' do
      once = described_class.tidy_short_description("  A \n B\u0000C  ")

      expect(described_class.tidy_short_description(once)).to eq(once)
    end
  end
end
