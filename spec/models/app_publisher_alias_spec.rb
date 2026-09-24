# frozen_string_literal: true

require 'rails_helper'

# Task 24: the front-facing publisher name printed on public store pages.
RSpec.describe App, 'publisher alias' do
  it 'has no display name by default' do
    expect(App.new(name: 'Plain').publisher_display_name).to be_nil
  end

  it 'tidies the alias before saving (control chars, extra whitespace)' do
    app = App.create!(name: 'Tidy', publisher_alias: "  Acme \n\t Studio  ")

    expect(app.publisher_alias).to eq('Acme Studio')
    expect(app.publisher_display_name).to eq('Acme Studio')
  end

  it 'turns a blank alias into nil so nothing is displayed' do
    app = App.create!(name: 'Blank', publisher_alias: "   ")

    expect(app.publisher_alias).to be_nil
    expect(app.publisher_display_name).to be_nil
  end

  it 'rejects an alias longer than the limit' do
    app = App.new(name: 'Long', publisher_alias: 'x' * (App::PUBLISHER_ALIAS_MAX_LENGTH + 1))

    expect(app).not_to be_valid
    expect(app.errors[:publisher_alias]).to be_present
  end
end
