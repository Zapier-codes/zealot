# frozen_string_literal: true

require 'rails_helper'

# Task 40r: the app, scheme and channel of a first upload, made at stage 1 from the report. Needs Postgres.
# Written by reading the code and imitating release_upload_release_builder_spec.rb; NOT run (no Rails or
# database in the sandbox that wrote it), so it is the first thing to look at if CI is red for this slice.
RSpec.describe ReleaseUploadAppResolver do
  let(:password) { 'correct-horse-9' }
  let(:role) { :developer }
  let!(:uploader) do
    User.create!(email: 'dev@example.com', username: 'dev', password: password, password_confirmation: password,
                 confirmed_at: Time.current, role: role)
  end
  let(:options) { { 'new_app' => true, 'source' => 'api' } }
  let(:metadata) do
    { 'kind' => 'apk', 'package_name' => 'com.example.first', 'version_code' => 1, 'version_name' => '1.0',
      'app_label' => 'First App', 'file_sha256' => 'a' * 64, 'file_size' => 10 }
  end
  let!(:upload) do
    ReleaseUpload.create!(channel: nil, user: uploader, filename: 'app.apk', declared_size: 10, form_options: options)
                 .tap do |row|
      row.update_columns(state: 'uploaded', uploaded_size: 10, stage1_at: Time.current, metadata: metadata)
    end
  end

  def resolve
    described_class.new(upload.reload).call
  end

  before { Zealot::TenantRegistry.reset! }

  it 'creates the app named by the file label, an Adhoc scheme and an Android channel, and owns the app' do
    expect { @result = resolve }.to change(App, :count).by(1).and change(Channel, :count).by(1)

    expect(@result.reason).to be_nil
    app = App.find_by!(name: 'First App')
    expect(app.owner.user).to eq(uploader)
    expect(@result.channel).to have_attributes(device_type: 'android', name: 'android')
    expect(@result.channel.scheme.app).to eq(app)
    expect(upload.reload.channel_id).to eq(@result.channel.id)
  end

  it 'prefers the name the owner chose over the file label' do
    upload.update_columns(form_options: options.merge('name' => 'Chosen Name'))

    resolve

    expect(App.find_by(name: 'Chosen Name')).to be_present
    expect(App.find_by(name: 'First App')).to be_nil
  end

  it 'applies the owner\'s slug to the new channel' do
    upload.update_columns(form_options: options.merge('slug' => 'my-first-slug'))

    expect(resolve.channel.slug).to eq('my-first-slug')
  end

  it 'falls back to the package name when the file has no label' do
    upload.update_columns(metadata: metadata.except('app_label'))

    resolve

    expect(App.find_by(name: 'com.example.first')).to be_present
  end

  it 'reuses an existing app the uploader may change and its Android channel' do
    app = create(:app, name: 'First App')
    app.create_owner(uploader)
    channel = app.schemes.create!(name: 'Adhoc').channels.create!(name: 'android', device_type: :android)

    expect { @result = resolve }.not_to change(App, :count)

    expect(@result.channel).to eq(channel)
  end

  it 'refuses an existing app the uploader may not change, and creates nothing' do
    create(:app, name: 'First App')

    expect { @result = resolve }.not_to change { [App.count, Scheme.count, Channel.count] }

    expect(@result.channel).to be_nil
    expect(@result.reason).to include('already exists')
    expect(upload.reload.channel_id).to be_nil
  end

  it 'refuses an archived app' do
    app = create(:app, name: 'First App', archived: true)
    app.create_owner(uploader)

    expect(resolve.reason).to include('archived')
  end

  context 'when the uploader is a plain member' do
    let(:role) { :member }

    it 'refuses to create an app and leaves nothing behind' do
      expect { @result = resolve }.not_to change { [App.count, Scheme.count, Channel.count] }

      expect(@result.reason).to include('may not create')
    end
  end

  it 'refuses a locked account' do
    uploader.update_columns(locked_at: Time.current)

    expect(resolve.reason).to include('locked')
  end

  it 'refuses when the uploader no longer exists' do
    upload.update_columns(user_id: nil)

    expect(resolve.reason).to include('no longer exists')
  end

  it 'rolls the app back when the channel does not validate' do
    upload.update_columns(form_options: options.merge('download_filename_type' => 'nonsense'))

    expect { @result = resolve }.not_to change { [App.count, Scheme.count, Channel.count] }

    expect(@result.reason).to start_with('The app could not be created')
  end

  it 'returns the channel of an upload that already has one, creating nothing' do
    app = create(:app, name: 'Existing')
    channel = app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android)
    upload.update_columns(channel_id: channel.id, form_options: {})

    expect { @result = resolve }.not_to change(App, :count)

    expect(@result.channel).to eq(channel)
  end

  it 'refuses a channel-less row that was not opened as a new app' do
    upload.update_columns(form_options: {})

    expect(resolve.reason).to include('does not create an app')
  end
end
