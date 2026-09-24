# frozen_string_literal: true

require 'rails_helper'

# Task 23: updates to an app (new builds, edits, deletes, team changes) come
# from the people attached to that app — its owner (whoever created / first
# uploaded it), manage collaborators and admins — not from every developer on
# the instance.
RSpec.describe 'App ownership policies' do
  def make_user(name, role)
    User.create!(email: "#{name}@example.com", username: name, password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: role)
  end

  let(:app)     { App.create!(name: 'Owned app') }
  let(:scheme)  { app.schemes.create!(name: 'Production') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }

  let(:admin)        { make_user('boss', :admin) }
  let(:owner)        { make_user('owner', :developer) }
  let(:teammate)     { make_user('teammate', :member) }
  let(:viewer)       { make_user('viewer', :member) }
  let(:stranger_dev) { make_user('stranger', :developer) }

  before do
    app.create_owner(owner)
    Collaborator.create!(user: teammate, app: app, role: :developer, owner: false)
    Collaborator.create!(user: viewer, app: app, role: :member, owner: false)
  end

  def allowed?(user, record, query)
    Pundit.policy!(user, record).public_send(query)
  end

  describe 'uploading a new build (ReleasePolicy)' do
    let(:release) { channel.releases.new }

    it 'allows the owner, a developer collaborator and an admin' do
      expect(allowed?(owner, release, :create?)).to be true
      expect(allowed?(teammate, release, :create?)).to be true
      expect(allowed?(admin, release, :create?)).to be true
    end

    it 'denies a plain member collaborator and any other developer' do
      expect(allowed?(viewer, release, :create?)).to be false
      expect(allowed?(stranger_dev, release, :create?)).to be false
      expect(allowed?(stranger_dev, release, :new?)).to be false
    end
  end

  describe 'changing the app itself' do
    it 'lets the owner and admin edit and delete it, not another developer' do
      expect(allowed?(owner, app, :update?)).to be true
      expect(allowed?(admin, app, :destroy?)).to be true
      expect(allowed?(stranger_dev, app, :update?)).to be false
      expect(allowed?(stranger_dev, app, :destroy?)).to be false
    end

    it 'still lets any developer create a new app and read existing ones' do
      expect(allowed?(stranger_dev, App.new, :create?)).to be true
      expect(allowed?(stranger_dev, app, :show?)).to be true
    end

    it 'guards channels and schemes the same way' do
      expect(allowed?(owner, channel, :update?)).to be true
      expect(allowed?(stranger_dev, channel, :update?)).to be false
      expect(allowed?(owner, scheme, :destroy?)).to be true
      expect(allowed?(stranger_dev, scheme, :destroy?)).to be false
    end
  end

  describe 'who is on the app' do
    it 'is decided by the owner or an admin only' do
      record = Collaborator.new(app: app)

      expect(allowed?(owner, record, :create?)).to be true
      expect(allowed?(admin, record, :create?)).to be true
      expect(allowed?(teammate, record, :create?)).to be false
      expect(allowed?(stranger_dev, record, :create?)).to be false
    end

    it 'only lets the real owner (not any collaborator) transfer ownership' do
      expect(allowed?(owner, app, :new_owner?)).to be true
      expect(allowed?(viewer, app, :new_owner?)).to be false
      expect(allowed?(teammate, app, :new_owner?)).to be false
    end
  end

  describe 'publisher alias (Task 24)' do
    it 'is admin-only until company verification exists' do
      expect(allowed?(admin, app, :set_publisher_alias?)).to be true
      expect(allowed?(owner, app, :set_publisher_alias?)).to be false
      expect(allowed?(teammate, app, :set_publisher_alias?)).to be false
      expect(allowed?(stranger_dev, app, :set_publisher_alias?)).to be false
    end
  end

  describe 'Play update line' do
    it 'has no highest versionCode until a build is approved for Play' do
      expect(app.highest_play_version_code).to be_nil
    end
  end
end
