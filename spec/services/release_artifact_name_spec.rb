# frozen_string_literal: true

require 'rails_helper'

# Task 41a, rewritten for Task 44b: written by reading the code; the spec was NOT run (operator's standing rule:
# syntax checks only), so look here first if CI is red for this slice.
RSpec.describe ReleaseArtifactName do
  def release(name:, version: '1.1.4', build: '218')
    double('Release', app: (name.nil? ? nil : double('App', name: name)), release_version: version, build_version: build)
  end

  describe '.for (Task 44b: the app slug and the version, no build, no time)' do
    it 'joins the app slug and the version' do
      expect(described_class.for(release(name: 'Appstore'))).to eq('appstore-1.1.4')
    end

    it 'never carries the build number' do
      expect(described_class.for(release(name: 'Appstore', build: '999'))).to eq('appstore-1.1.4')
    end

    it 'turns spaces and punctuation into single hyphens and trims the ends' do
      expect(described_class.for(release(name: '  My  Store! (beta) '))).to eq('my-store-beta-1.1.4')
    end

    it 'drops accents' do
      expect(described_class.for(release(name: 'Café Ünïcode'))).to eq('cafe-unicode-1.1.4')
    end

    it 'falls back to "app" when the name has nothing usable' do
      expect(described_class.for(release(name: '!!!'))).to eq('app-1.1.4')
      expect(described_class.for(release(name: nil))).to eq('app-1.1.4')
      expect(described_class.for(release(name: '应用商店'))).to eq('app-1.1.4')
    end

    it 'leaves out a missing version' do
      expect(described_class.for(release(name: 'Appstore', version: nil))).to eq('appstore')
    end

    it 'keeps the version as the uploader wrote it' do
      expect(described_class.for(release(name: 'Appstore', version: '2.0.0-RC1'))).to eq('appstore-2.0.0-RC1')
    end

    it 'bounds a long name and always returns something the workflows accept' do
      name = described_class.for(release(name: 'x' * 500, version: '9' * 100))

      expect(name.length).to be <= 65
      expect(name).to match(described_class::VALID)
    end

    it 'never lets a path or a leading dot through' do
      expect(described_class.for(release(name: '../../etc/passwd'))).to eq('etc-passwd-1.1.4')
      expect(described_class.for(release(name: '.hidden'))).to eq('hidden-1.1.4')
    end

    it 'gives the same string for the same release' do
      r = release(name: 'Appstore')

      expect(described_class.for(r)).to eq(described_class.for(r))
    end
  end

  describe '.previous_for (the Task 41a form, kept for uploads in flight across the deploy)' do
    it 'joins the app name with its own case, the version and the build' do
      expect(described_class.previous_for(release(name: 'Storeapp'))).to eq('Storeapp-1.1.4-218')
    end

    it 'leaves out a missing version or build' do
      expect(described_class.previous_for(release(name: 'Storeapp', version: nil, build: ''))).to eq('Storeapp')
    end

    it 'falls back to "app" and always returns something the workflows accept' do
      expect(described_class.previous_for(release(name: nil))).to eq('app-1.1.4-218')
      expect(described_class.previous_for(release(name: 'x' * 500, version: '9' * 100, build: '7' * 100)))
        .to match(described_class::VALID)
    end
  end
end
