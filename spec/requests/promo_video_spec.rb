# frozen_string_literal: true

require 'rails_helper'

# Task 27d-e2-d: PATCH /apps/:app_id/promo_video. Needs Postgres. NOT run in the sandbox that wrote it
# (no Rails boot or database there), so look here first if CI is red. The parser itself is covered,
# and was run, in spec/services/youtube_video_link_spec.rb.
RSpec.describe 'Promo video', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let(:id) { 'dQw4w9WgXcQ' }

  def make_user(name, role)
    User.create!(email: "#{name}@example.com", username: name, password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: role)
  end

  def set_video(url)
    patch app_promo_video_path(app), params: { promo_video: { url: url } }
  end

  let(:admin) { make_user('boss', :admin) }
  let(:owner) { make_user('owner', :developer) }
  let(:teammate) { make_user('teammate', :member) }
  let(:stranger) { make_user('stranger', :developer) }
  let!(:app) { create(:app, name: 'Video app') }

  before do
    allow(Setting).to receive(:guest_mode).and_return(false)
    app.create_owner(owner)
    Collaborator.create!(user: teammate, app: app, role: :member, owner: false)
  end

  context 'as the app owner' do
    before { sign_in owner }

    it 'stores only the ID from a pasted watch link' do
      set_video("https://www.youtube.com/watch?v=#{id}&t=43s&feature=share")

      expect(response).to redirect_to(app_path(app))
      expect(flash[:notice]).to eq(I18n.t('apps.promo_videos.update.saved'))
      expect(app.reload.promo_video_youtube_id).to eq(id)
    end

    it 'takes a short link and a bare ID too' do
      set_video("https://youtu.be/#{id}?si=abc")
      expect(app.reload.promo_video_youtube_id).to eq(id)

      set_video('a-b_c-d_e-f')
      expect(app.reload.promo_video_youtube_id).to eq('a-b_c-d_e-f')
    end

    it 'replaces the old video' do
      app.update!(promo_video_youtube_id: 'AAAAAAAAAAA')

      set_video("https://youtu.be/#{id}")

      expect(app.reload.promo_video_youtube_id).to eq(id)
    end

    it 'clears the video when the box is blank' do
      app.update!(promo_video_youtube_id: id)

      set_video('   ')

      expect(flash[:notice]).to eq(I18n.t('apps.promo_videos.update.removed'))
      expect(app.reload.promo_video_youtube_id).to be_nil
    end

    it 'refuses a playlist, another site and a channel, says why, and keeps the old video' do
      app.update!(promo_video_youtube_id: id)
      {
        'https://www.youtube.com/playlist?list=PLabcdefghijklmnopqrstuvwxyz0123456' => :playlist,
        'https://vimeo.com/123456789' => :other_host,
        'https://www.youtube.com/@someone' => :not_a_video,
        'not a link at all' => :not_a_url
      }.each do |url, code|
        set_video(url)

        expect(flash[:alert]).to eq(I18n.t("apps.promo_videos.update.errors.#{code}"))
        expect(app.reload.promo_video_youtube_id).to eq(id)
      end
    end

    it 'treats a malformed request as a 400 and does not clear the video' do
      app.update!(promo_video_youtube_id: id)

      patch app_promo_video_path(app)
      expect(response).to have_http_status(:bad_request)

      patch app_promo_video_path(app), params: { promo_video: { url: [ 'x' ] } }
      expect(response).to have_http_status(:bad_request)

      patch app_promo_video_path(app), params: { promo_video: 'x' }
      expect(response).to have_http_status(:bad_request)

      expect(app.reload.promo_video_youtube_id).to eq(id)
    end

    it 'enqueues an index publish for a live app when the video changes' do
      allow_any_instance_of(App).to receive(:listing_live?).and_return(true)

      expect { set_video("https://youtu.be/#{id}") }.to have_enqueued_job(CatalogIndexPublishJob)
    end

    it 'refuses an archived app' do
      app.update_columns(archived: true)

      set_video("https://youtu.be/#{id}")

      expect(app.reload.promo_video_youtube_id).to be_nil
    end
  end

  context 'as an admin' do
    it 'may set the video on any app' do
      sign_in admin

      set_video("https://youtu.be/#{id}")

      expect(app.reload.promo_video_youtube_id).to eq(id)
    end
  end

  context 'as a plain member collaborator, an unrelated developer or a signed-out visitor' do
    it 'is refused and changes nothing' do
      [ teammate, stranger ].each do |user|
        sign_in user
        set_video("https://youtu.be/#{id}")
        expect(response).to have_http_status(:forbidden)
        sign_out user
      end

      set_video("https://youtu.be/#{id}")
      expect(response).not_to have_http_status(:ok)
      expect(app.reload.promo_video_youtube_id).to be_nil
    end
  end
end
