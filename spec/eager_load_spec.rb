# frozen_string_literal: true

require 'rails_helper'

# Task 42c: production eager-loads every class at boot, tests do not, so a class that cannot load (the
# `Unknown validator: 'MessageValidator'` crash of 2026-10-03, the duplicate `skip_before_action` of 2026-10-06)
# passed CI and failed three Render deploys. Loading everything here makes that fail the test run first.
RSpec.describe 'Eager loading' do
  it 'loads every application class without raising' do
    expect { Zeitwerk::Loader.eager_load_all }.not_to raise_error
  end
end
