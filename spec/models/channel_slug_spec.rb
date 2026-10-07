# frozen_string_literal: true

require 'rails_helper'

# Task 44d: the slug of a new channel comes from its app's name. Needs Postgres. Written by reading the code; NOT run
# (the operator's standing rule: syntax checks only), so look here first if CI is red for this slice.
RSpec.describe Channel, 'slug (Task 44d)' do
  let!(:app) { App.create!(name: 'Appstore') }
  let(:scheme) { app.schemes.create!(name: 'Main') }

  def make(slug: nil, owner: scheme)
    attrs = { name: 'Android', device_type: :android }
    attrs[:slug] = slug if slug
    owner.channels.create!(attrs)
  end

  it 'is the cleaned name of the app when none is given' do
    expect(make.slug).to eq('appstore')
  end

  it 'is numbered when another channel already has it' do
    first = make
    second = make
    other_app = App.create!(name: 'APPSTORE!')
    third = make(owner: other_app.schemes.create!(name: 'Main'))

    expect([first.slug, second.slug, third.slug]).to eq(%w[appstore appstore-2 appstore-3])
  end

  it 'falls back to a short random value when the name has no usable character' do
    odd = App.create!(name: '!!!')

    expect(make(owner: odd.schemes.create!(name: 'Main')).slug).to match(/\A[A-Za-z0-9]{1,5}\z/)
  end

  it 'keeps a well-formed slug the caller gives' do
    expect(make(slug: 'custom-name').slug).to eq('custom-name')
  end

  it 'refuses a malformed slug the caller gives, and says why' do
    expect { make(slug: 'Foo Bar') }.to raise_error(ActiveRecord::RecordInvalid, /Slug.*lowercase letters/)
  end

  describe 'a channel that already has an old-style slug' do
    let!(:channel) { make.tap { |c| c.update_columns(slug: '48Mhr') } }

    it 'still saves other changes' do
      expect { channel.reload.update!(name: 'Android 2') }.not_to raise_error
      expect(channel.reload.slug).to eq('48Mhr')
    end

    it 'can be renamed to a well-formed slug and not to a malformed one' do
      expect(channel.reload.update(slug: 'Appstore')).to be(false)
      expect(channel.update(slug: 'appstore')).to be(true)
      expect(channel.reload.slug).to eq('appstore')
    end
  end
end
