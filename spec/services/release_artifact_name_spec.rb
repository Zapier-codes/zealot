# frozen_string_literal: true

require 'rails_helper'

# Task 41a: written by reading the code; the pure logic was run with a stand-in for I18n.transliterate (no gems in
# the sandbox), the spec itself was NOT run.
RSpec.describe ReleaseArtifactName do
  def release(name:, version: '1.1.4', build: '218')
    double('Release', app: (name.nil? ? nil : double('App', name: name)), release_version: version, build_version: build)
  end

  it 'joins the app name, version and build' do
    expect(described_class.for(release(name: 'Storeapp'))).to eq('Storeapp-1.1.4-218')
  end

  it 'turns spaces and punctuation into single hyphens and trims the ends' do
    expect(described_class.for(release(name: '  My  Store! (beta) '))).to eq('My-Store-beta-1.1.4-218')
  end

  it 'drops accents' do
    expect(described_class.for(release(name: 'Café Ünïcode'))).to eq('Cafe-Unicode-1.1.4-218')
  end

  it 'falls back to "app" when the name has nothing usable' do
    expect(described_class.for(release(name: '!!!'))).to eq('app-1.1.4-218')
    expect(described_class.for(release(name: nil))).to eq('app-1.1.4-218')
  end

  it 'leaves out a missing version or build' do
    expect(described_class.for(release(name: 'Storeapp', version: nil, build: ''))).to eq('Storeapp')
  end

  it 'bounds a long name and always returns something the workflows accept' do
    name = described_class.for(release(name: 'x' * 500, version: '9' * 100, build: '7' * 100))

    expect(name.length).to be <= 102
    expect(name).to match(described_class::VALID)
  end

  it 'never lets a path or a leading dot through' do
    expect(described_class.for(release(name: '../../etc/passwd'))).to eq('etc-passwd-1.1.4-218')
    expect(described_class.for(release(name: '.hidden'))).to eq('hidden-1.1.4-218')
  end

  it 'gives the same string for the same release' do
    r = release(name: 'Storeapp')

    expect(described_class.for(r)).to eq(described_class.for(r))
  end
end
