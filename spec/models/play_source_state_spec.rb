# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PlaySourceState do
  it 'is not usable before a canary has ever passed' do
    state = described_class.new(backend: 'gplayapi', status: 'unknown')

    expect(state).not_to be_usable
  end

  it 'is usable after an ok within the window' do
    state = described_class.record!('gplayapi', ok: true)

    expect(state).to be_usable
  end

  it 'is not usable once the last ok is older than the window' do
    described_class.record!('gplayapi', ok: true, now: 3.days.ago)

    expect(described_class.find_by(backend: 'gplayapi')).not_to be_usable
  end

  it 'a degraded record keeps the previous last_ok_at for visibility' do
    described_class.record!('gplayapi', ok: true, now: 2.hours.ago)
    ok_at = described_class.find_by(backend: 'gplayapi').last_ok_at

    state = described_class.record!('gplayapi', ok: false, error: 'boom')

    expect(state.status).to eq('degraded')
    expect(state.error).to eq('boom')
    expect(state.last_ok_at).to eq(ok_at) # still says when it last worked
  end

  it 'rejects an unknown backend name' do
    expect(described_class.new(backend: 'nope', status: 'ok')).not_to be_valid
  end
end
