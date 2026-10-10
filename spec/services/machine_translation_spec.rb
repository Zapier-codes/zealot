# frozen_string_literal: true

require 'rails_helper'

# Z-P21: the machine-translation rule — what is published, what is stale, what is off. Written-not-run in
# the sandbox (no Postgres or bundle); it exercises the pure class methods so a fixture App (a Struct) is
# enough here.
RSpec.describe MachineTranslation do
  def app(description: 'Hello world', short_description: 'Hi')
    Struct.new(:description, :short_description, :listing_translations).new(description, short_description, {})
  end

  describe '.publishable' do
    it 'publishes nothing when translation is off' do
      expect(MachineTranslation.configured?).to be(false)
      expect(MachineTranslation.publishable(app)).to eq({})
    end

    it 'publishes only reviewed, non-stale entries' do
      a = app
      a.listing_translations = {
        'de' => { 'description' => 'Hallo', 'reviewed' => true },
        'fr' => { 'description' => 'Bonjour', 'reviewed' => false },
        'es' => { 'description' => 'Hola', 'reviewed' => true, 'source_digest' => 'stale' }
      }

      out = MachineTranslation.publishable(a)

      expect(out.keys).to contain_exactly('de')
      expect(out['de']['description']).to eq('Hallo')
    end

    it 'drops an entry with no text at all' do
      a = app
      a.listing_translations = { 'de' => { 'reviewed' => true } }

      expect(MachineTranslation.publishable(a)).to eq({})
    end
  end

  describe '.stale_entry?' do
    it 'is stale when the recorded digest no longer matches the source text' do
      a = app
      entry = { 'reviewed' => true, 'source_digest' => 'not-the-current-digest' }

      expect(MachineTranslation.stale_entry?(a, entry)).to be(true)
    end

    it 'is not stale right after a translation of the current text' do
      a = app
      digest = MachineTranslation.source_digest(a)
      entry = { 'reviewed' => true, 'source_digest' => digest }

      expect(MachineTranslation.stale_entry?(a, entry)).to be(false)
    end
  end
end
