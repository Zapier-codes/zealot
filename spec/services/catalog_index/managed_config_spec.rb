# frozen_string_literal: true

require 'rails_helper'

# Z-P24 (enterprise device management): the normaliser that turns an organisation's settings hash into the
# document a DPC reads and Storeapp's RestrictionsManager expects. Pure; no Rails.
RSpec.describe CatalogIndex::ManagedConfig do
  describe '.from' do
    it 'leaves every key unset for an empty policy (the person keeps their choices)' do
      config = described_class.from({})

      expect(config).not_to be_configured
      expect(config.enabled_sources).to be_nil
      expect(config.show_desktop_sources).to be_nil
      expect(config.hidden_packages).to eq([])
      expect(config.managed_keys).to eq([])
    end

    it 'normalises enabled_sources to the canonical SourceId names' do
      config = described_class.from('enabled_sources' => 'fdroid, izzyondroid ,Zealot')

      expect(config.enabled_sources).to eq(%w[FDroid IzzyOnDroid Zealot])
      expect(config.managed_keys).to eq(['enabled_sources'])
    end

    it 'understands the literal none as "no sources" (configured, empty)' do
      config = described_class.from('enabled_sources' => 'none')

      expect(config.enabled_sources).to eq([])
      expect(config.managed_keys).to eq(['enabled_sources'])
    end

    it 'ignores unknown source names and treats an all-unknown list as unset' do
      config = described_class.from('enabled_sources' => 'made-up, whatever')

      expect(config.enabled_sources).to be_nil
      expect(config).not_to be_configured
    end

    it 'parses show_desktop_sources booleans and treats anything else as unset' do
      expect(described_class.from('show_desktop_sources' => 'off').show_desktop_sources).to be(false)
      expect(described_class.from('show_desktop_sources' => true).show_desktop_sources).to be(true)
      expect(described_class.from('show_desktop_sources' => 'maybe').show_desktop_sources).to be_nil
    end

    it 'cleans hidden_packages to valid package names, deduped and capped' do
      config = described_class.from('hidden_packages' => "com.a, not a package\ncom.a; com.b")

      expect(config.hidden_packages).to eq(%w[com.a com.b])
      expect(config.managed_keys).to eq(['hidden_packages'])
    end

    it 'accepts an array value as well as a string' do
      config = described_class.from('hidden_packages' => ['com.a', 'com.b'])

      expect(config.hidden_packages).to eq(%w[com.a com.b])
    end
  end

  describe '#to_h' do
    it 'always carries every key, unset ones null, plus the managed-key list' do
      doc = described_class.from('enabled_sources' => 'fdroid').to_h

      expect(doc['schema_version']).to eq(described_class::SCHEMA_VERSION)
      expect(doc['source']).to eq('zealot')
      expect(doc['managed_keys']).to eq(['enabled_sources'])
      expect(doc['config']).to eq(
        'enabled_sources' => ['FDroid'],
        'show_desktop_sources' => nil,
        'hidden_packages' => []
      )
    end
  end

  describe '.from_settings' do
    it 'reads the organisation policy from Setting.managed_config' do
      Setting.managed_config = { 'hidden_packages' => 'com.secret' }

      expect(described_class.from_settings.hidden_packages).to eq(['com.secret'])
    end

    it 'is unmanaged when the setting is empty' do
      expect(described_class.from_settings).not_to be_configured
    end
  end
end
