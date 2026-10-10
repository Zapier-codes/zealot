# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Play::Canary do
  class CanaryFakeRunner
    Result = Play::BackendRunner::Result

    def self.results=(map)
      @results = map
    end
    def self.reset! = @results = {}

    def initialize(command)
      @command = command
    end

    def call(_package)
      self.class.results.fetch(@command, Result.new(ok: false, error: 'no stub'))
    end
  end

  let(:config) do
    ActiveSupport::OrderedOptions.new.tap do |c|
      c.gplayapi_command = 'gplay'
      c.playstoreapi_command = 'pystore'
      c.canary_package = 'com.canary'
    end
  end

  before do
    CanaryFakeRunner.reset!
    PlaySourceState.delete_all
  end

  it 'records ok when a backend returns a usable panel' do
    CanaryFakeRunner.results = {
      'gplay' => Play::BackendRunner::Result.new(ok: true, raw: { 'title' => 'Canary' }),
      'pystore' => Play::BackendRunner::Result.new(ok: false, error: 'down'),
    }

    outcomes = described_class.new(config: config, runner_class: CanaryFakeRunner).run

    expect(outcomes.find { |o| o.backend == 'gplayapi' }.ok).to be(true)
    expect(outcomes.find { |o| o.backend == 'playstoreapi' }.ok).to be(false)

    expect(PlaySourceState.find_by(backend: 'gplayapi')).to be_usable
    expect(PlaySourceState.find_by(backend: 'playstoreapi').status).to eq('degraded')
  end

  it 'records degraded (and keeps the error) when the backend output is not usable' do
    CanaryFakeRunner.results = { 'gplay' => Play::BackendRunner::Result.new(ok: true, raw: {}) }

    described_class.new(config: config, runner_class: CanaryFakeRunner).run

    state = PlaySourceState.find_by(backend: 'gplayapi')
    expect(state.status).to eq('degraded')
    expect(state.error).to be_present
  end

  it 'skips backends that have no configured command' do
    config.playstoreapi_command = nil
    CanaryFakeRunner.results = { 'gplay' => Play::BackendRunner::Result.new(ok: true, raw: { 'title' => 'x' }) }

    outcomes = described_class.new(config: config, runner_class: CanaryFakeRunner).run

    expect(outcomes.map(&:backend)).to eq(['gplayapi'])
  end
end
