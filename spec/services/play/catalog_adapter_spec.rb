# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Play::CatalogAdapter do
  # A backend runner double that returns a fixed Result, so the adapter's ordering (cache → usable backend
  # → failover → stale → unavailable) is exercised without spawning a process.
  class AdapterFakeRunner
    Result = Play::BackendRunner::Result

    def self.results=(map)
      @results = map
    end
    def self.calls = @calls ||= []
    def self.reset!
      @calls = []
      @results = {}
    end

    def initialize(command)
      @command = command
    end

    def call(package)
      self.class.calls << [@command, package]
      self.class.results.fetch(@command, Result.new(ok: false, error: 'no stub'))
    end
  end

  let(:enabled_config) do
    ActiveSupport::OrderedOptions.new.tap do |c|
      c.enabled = true
      c.gplayapi_command = 'gplay'
      c.playstoreapi_command = 'pystore'
      c.canary_package = 'com.canary'
    end
  end

  before do
    AdapterFakeRunner.reset!
    # The cache is on disk and persists between runs; clear the keys this file touches so a previous run
    # cannot make a "backend was invoked" assertion pass vacuously.
    %w[com.x com.unique.failover com.stale com.nothing.cached].each do |pkg|
      path = PlayCatalogCache.path_for("play_panel__#{pkg}")
      File.delete(path) if File.exist?(path)
    end
  end

  it 'is disabled when the switch is off, and invokes nothing' do
    config = ActiveSupport::OrderedOptions.new.tap { |c| c.enabled = false }
    adapter = described_class.new(config: config, runner_class: AdapterFakeRunner)

    result = adapter.call('com.x')

    expect(result.status).to eq('disabled')
    expect(result.panel).to be_nil
    expect(AdapterFakeRunner.calls).to be_empty
  end

  it 'skips a backend that has never passed its canary' do
    PlaySourceState.delete_all
    adapter = described_class.new(config: enabled_config, runner_class: AdapterFakeRunner)

    result = adapter.call('com.x')

    expect(result.status).to eq('unavailable')
    expect(AdapterFakeRunner.calls).to be_empty # no proven backend -> never tried blind
  end

  it 'uses a backend whose canary last passed, and caches the panel' do
    PlaySourceState.record!('gplayapi', ok: true)
    AdapterFakeRunner.results = { 'gplay' => Play::BackendRunner::Result.new(ok: true, raw: { 'title' => 'From Play' }) }
    adapter = described_class.new(config: enabled_config, runner_class: AdapterFakeRunner)

    result = adapter.call('com.x')

    expect(result.status).to eq('ok')
    expect(result.backend).to eq('gplayapi')
    expect(result.panel['title']).to eq('From Play')
    expect(result.panel['source']).to eq('play')

    # Second call is served from the cache: no new backend invocation.
    before = AdapterFakeRunner.calls.length
    again = adapter.call('com.x')
    expect(again.status).to eq('ok')
    expect(AdapterFakeRunner.calls.length).to eq(before)
  end

  it 'fails over to the second backend when the first misses' do
    PlaySourceState.record!('gplayapi', ok: true)
    PlaySourceState.record!('playstoreapi', ok: true)
    AdapterFakeRunner.results = {
      'gplay' => Play::BackendRunner::Result.new(ok: false, error: 'boom'),
      'pystore' => Play::BackendRunner::Result.new(ok: true, raw: { 'title' => 'Fallback' }),
    }
    adapter = described_class.new(config: enabled_config, runner_class: AdapterFakeRunner)

    result = adapter.call('com.unique.failover')

    expect(result.status).to eq('ok')
    expect(result.backend).to eq('playstoreapi')
    expect(result.panel['title']).to eq('Fallback')
  end

  it 'serves a stale cached panel when every backend fails' do
    PlaySourceState.record!('gplayapi', ok: true)
    AdapterFakeRunner.results = { 'gplay' => Play::BackendRunner::Result.new(ok: false, error: 'boom') }
    # Seed the cache with an entry that is older than the fresh window but inside the stale window.
    PlayCatalogCache.write('play_panel__com.stale', { 'source' => 'play', 'title' => 'Old' },
                           now: 3.days.ago)
    adapter = described_class.new(config: enabled_config, runner_class: AdapterFakeRunner)

    result = adapter.call('com.stale')

    expect(result.status).to eq('stale')
    expect(result.backend).to eq('cache')
    expect(result.panel['title']).to eq('Old')
    expect(result.error).to include('boom')
  end

  it 'is unavailable when nothing is cached and every backend fails' do
    PlaySourceState.record!('gplayapi', ok: true)
    AdapterFakeRunner.results = { 'gplay' => Play::BackendRunner::Result.new(ok: false, error: 'boom') }
    adapter = described_class.new(config: enabled_config, runner_class: AdapterFakeRunner)

    result = adapter.call('com.nothing.cached')

    expect(result.status).to eq('unavailable')
    expect(result.panel).to be_nil
    expect(result.error).to include('boom')
  end
end
