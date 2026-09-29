# frozen_string_literal: true

require 'rails_helper'

# Task 27e-e. Pure Ruby (strings in, structs out; no database); run in the sandbox that wrote it with a
# shim in place of rails_helper. The rules under test are the ones recorded in the handover under
# "Task 27 open questions", Q3.
RSpec.describe ListingCopyAdvisor do
  def keys(field, text)
    described_class.for_field(field, text).map(&:key)
  end

  def warning(field, text, key)
    described_class.for_field(field, text).find { |entry| entry.key == key }
  end

  # `word` used `uses` times in a text of exactly `total` words; the filler words carry digits, so none of
  # them is a keyword.
  def text_with(word, uses, total)
    ([ word ] * uses + (1..(total - uses)).map { |index| "x#{index}" }).join(' ')
  end

  describe '.call' do
    it 'answers every field, with an empty list when the text is clean' do
      result = described_class.call('name' => 'Notes', 'short_description' => 'Keep notes', 'description' => 'Plain text.')

      expect(result.keys).to eq(%w[name short_description description])
      expect(result.values).to all(eq([]))
    end

    it 'takes symbol keys and treats a missing or nil field as empty' do
      result = described_class.call(name: 'BEST APP!!!', description: nil)

      expect(result['name']).not_to be_empty
      expect(result['short_description']).to eq([])
      expect(result['description']).to eq([])
    end

    it 'takes nil' do
      expect(described_class.call(nil).values).to all(eq([]))
    end

    it 'runs each field through its own rules' do
      result = described_class.call('name' => 'Notes!!!', 'short_description' => 'Notes!!!', 'description' => 'Notes!!!')

      expect(result['name'].map(&:key)).to eq(%i[repeated_punctuation])
      expect(result['short_description'].map(&:key)).to eq(%i[repeated_punctuation])
      expect(result['description']).to eq([]) # repeated punctuation is not checked in the full description
    end
  end

  describe '.for_field' do
    it 'answers an empty list for an unknown field, a blank text and nil' do
      expect(described_class.for_field('summary', 'BEST!!!')).to eq([])
      expect(described_class.for_field('name', '   ')).to eq([])
      expect(described_class.for_field('name', nil)).to eq([])
    end

    it 'warns for BEST APP!!! Free and not for Notes' do
      expect(keys('name', 'BEST APP!!! Free')).to eq(%i[repeated_punctuation all_caps_word performance deal])
      expect(keys('name', 'Notes')).to eq([])
    end
  end

  describe 'the name' do
    describe 'length' do
      it 'warns above 30 characters and says how long it is' do
        entry = warning('name', 'a' * 31, :too_long)

        expect(entry.count).to eq(31)
        expect(entry.limit).to eq(30)
      end

      it 'does not warn at exactly 30 characters' do
        expect(keys('name', 'a' * 30)).to eq([])
      end
    end

    describe 'emoji and emoticons' do
      it 'warns for an emoji and lists it' do
        expect(warning('name', 'Notes 😀', :emoji).match).to eq('😀')
      end

      it 'warns for text emoticons' do
        expect(keys('name', 'Notes :)')).to eq(%i[emoji])
        expect(keys('name', 'Notes ;-)')).to eq(%i[emoji])
        expect(keys('name', 'Notes <3')).to eq(%i[emoji])
        expect(keys('name', 'Notes :D')).to eq(%i[emoji])
      end

      it 'does not warn for symbols that are not emoji' do
        expect(keys('name', 'Acme™ © Notes ✓ ★')).to eq([])
      end

      it 'warns for an emoticon written against a word' do
        expect(warning('name', 'Great:)', :emoji).match).to eq(':)')
      end

      it 'does not warn for punctuation that only looks like an emoticon' do
        expect(keys('name', 'http://example.org')).to eq([])
        expect(keys('name', 'Note:(a)')).to eq([])
        expect(keys('name', 'Mode:Dark')).to eq([])
        expect(keys('name', 'Notes: Dark')).to eq([])
        expect(keys('name', 'x<3')).to eq([])
      end
    end

    describe 'repeated punctuation' do
      it 'warns for three of the same mark and lists them' do
        %w[!!! ??? *** ---].each do |run|
          expect(warning('name', "Notes#{run}", :repeated_punctuation).match).to eq(run)
        end
      end

      it 'warns for an ellipsis, as the rule is written' do
        expect(keys('name', 'Notes...')).to eq(%i[repeated_punctuation])
      end

      it 'does not warn for two, or for three different marks' do
        expect(keys('name', 'Notes!!')).to eq([])
        expect(keys('name', 'Notes!?!')).to eq([])
      end
    end

    describe 'ALL-CAPS words' do
      it 'warns for a word of four or more capital letters' do
        expect(warning('name', 'Super NOTES', :all_caps_word).match).to eq('NOTES')
      end

      it 'leaves a short acronym alone' do
        expect(keys('name', 'GPS USB Tracker')).to eq([])
      end

      it 'does not warn for a capitalised or mixed-case word' do
        expect(keys('name', 'Notes NotesApp')).to eq([])
      end
    end

    describe 'performance and ranking words' do
      it 'warns for each of them, whatever the case' do
        [ 'Best Notes', 'top notes', 'Popular Notes', 'Notes #1', 'Notes # 1', 'App of the Year' ].each do |name|
          expect(keys('name', name)).to include(:performance), name
        end
      end

      it 'matches whole words only' do
        expect(keys('short_description', 'Desktop Bestiary Topaz Popularity')).to eq([])
        expect(keys('name', 'Notes #10')).to eq([])
      end
    end

    describe 'deal and price words' do
      it 'warns for each of them' do
        [ 'Free Notes', 'Notes no ads', 'Ad-free Notes', 'Ad free Notes', 'Notes discount', 'Notes 50% off',
          'Notes % off', 'Notes sale' ].each do |name|
          expect(keys('name', name)).to include(:deal), name
        end
      end

      it 'matches whole words only, and does not read -free as a price' do
        expect(keys('short_description', 'Freedom Wholesale Freeway Discounted')).to eq([])
        expect(keys('name', 'Sugar-free Recipes')).to eq([])
        expect(keys('name', '100% official')).to eq([])
      end

      it 'lists the match' do
        expect(warning('name', 'Notes 50% off', :deal).match).to eq('50% off')
      end
    end

    describe 'calls to action' do
      it 'warns for each of them' do
        [ 'Download now', 'Install NOW', 'update  now', 'Play now', 'Try now' ].each do |name|
          expect(keys('name', name)).to include(:call_to_action), name
        end
      end

      it 'needs the whole phrase' do
        expect(keys('name', 'Notes now')).to eq([])
        expect(keys('name', 'Download')).to eq([])
      end
    end
  end

  describe 'the short description' do
    it 'runs the name rules except the length' do
      expect(keys('short_description', 'a' * 81)).to eq([])
      expect(keys('short_description', 'BEST notes!!! Free, download now :)'))
        .to eq(%i[emoji repeated_punctuation all_caps_word performance deal call_to_action])
    end

    it 'is clean for an ordinary line' do
      expect(keys('short_description', 'Keep your notes in one place.')).to eq([])
    end
  end

  describe 'the full description' do
    describe 'the shared word rules' do
      it 'warns for performance words, deal words and calls to action' do
        text = 'The best notes app. Free to try. Download now.'

        expect(keys('description', text)).to eq(%i[performance deal call_to_action])
      end
    end

    describe 'what it does not check' do
      it 'leaves emoticons, repeated punctuation and a single capital word alone' do
        expect(keys('description', 'Great :) notes!!! Supports HTML export')).to eq([])
      end
    end

    describe 'a run of ALL-CAPS words' do
      it 'warns for three or more in a row' do
        expect(warning('description', 'Try it. AMAZING DEALS TODAY only.', :all_caps_run).match)
          .to eq('AMAZING DEALS TODAY')
      end

      it 'does not warn for two in a row' do
        expect(keys('description', 'Try it. AMAZING DEALS only.')).to eq([])
      end

      it 'does not read a comma-separated list as a run' do
        expect(keys('description', 'Supports HTML, JSON, YAML and more.')).to eq([])
      end

      it 'does not count short capital words as part of a run' do
        expect(keys('description', 'THIS IS THE ONE')).to eq([])
      end
    end

    describe 'too many emoji' do
      it 'warns above five and says how many' do
        entry = warning('description', '😀😀😀😀😀😀 notes', :many_emoji)

        expect(entry.count).to eq(6)
        expect(entry.limit).to eq(5)
      end

      it 'does not warn at five' do
        expect(keys('description', '😀😀😀😀😀 notes')).to eq([])
      end

      it 'counts a skin-tone, flag or family sequence as one each' do
        expect(keys('description', '👍🏽 🇺🇸 👨‍👩‍👧 ❤️ ⭐')).to eq([])
        expect(warning('description', '👍🏽 🇺🇸 👨‍👩‍👧 ❤️ ⭐ 🎉', :many_emoji).count).to eq(6)
      end

      it 'does not count text symbols' do
        expect(keys('description', '© ™ ✓ ★ ☺ © ™ ✓ ★')).to eq([])
      end
    end

    describe 'keyword stuffing' do
      it 'warns for a word used 8 times in a text of 100 words' do
        entry = warning('description', text_with('notes', 8, 100), :keyword_stuffing)

        expect(entry.match).to eq('notes')
        expect(entry.count).to eq(8)
      end

      it 'does not warn at 7 uses' do
        expect(keys('description', text_with('notes', 7, 100))).to eq([])
      end

      it 'does not warn under 100 words' do
        expect(keys('description', text_with('notes', 20, 99))).to eq([])
      end

      it 'needs more than 3 percent of the words' do
        expect(keys('description', text_with('notes', 8, 266))).to eq(%i[keyword_stuffing]) # 3.008%
        expect(keys('description', text_with('notes', 8, 267))).to eq([]) # 2.996%
        expect(keys('description', text_with('notes', 9, 300))).to eq([]) # exactly 3%
      end

      it 'ignores case' do
        text = (%w[Notes NOTES notes] * 3).join(' ') + ' ' + (1..91).map { |index| "x#{index}" }.join(' ')

        expect(keys('description', text)).to eq(%i[keyword_stuffing])
      end

      it 'ignores stopwords and words shorter than four letters' do
        expect(keys('description', text_with('with', 30, 100))).to eq([])
        expect(keys('description', text_with('app', 30, 100))).to eq([])
      end

      it 'ignores numbers' do
        expect(keys('description', text_with('2026', 30, 100))).to eq([])
      end

      it 'lists the worst three, the most used first' do
        text = ([ 'alpha' ] * 10 + [ 'bravo' ] * 12 + [ 'charlie' ] * 9 + [ 'delta' ] * 8 + [ 'echoes' ] * 2 +
                (1..59).map { |index| "x#{index}" }).join(' ')
        entry = warning('description', text, :keyword_stuffing)

        expect(entry.match).to eq('bravo, alpha, charlie')
        expect(entry.count).to eq(12)
      end
    end
  end

  describe 'the matches' do
    it 'lists each distinct snippet once, ignoring case, and no more than three' do
      expect(warning('name', 'Best BEST best', :performance).match).to eq('Best')
      expect(warning('name', 'Best top popular #1', :performance).match).to eq('Best, top, popular')
    end
  end
end
