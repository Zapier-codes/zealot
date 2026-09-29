# frozen_string_literal: true

# Task 27d-e2-d: the owner sets or clears an app's promo video, the one YouTube link on its store
# listing (docs/store_listing_graphics.md, "Video").
#
#   PATCH /apps/:app_id/promo_video    promo_video[url]   (a blank value clears the video)
#
# The owner pastes whatever YouTube gave them; `YoutubeVideoLink` reduces it to the 11-character ID,
# and only that ID is stored, in `apps.promo_video_youtube_id`. `App` re-checks the format and
# republishes the catalog index when the column changes (CATALOG_INDEX_LISTING_FIELDS), so this
# controller neither validates the ID itself nor enqueues anything. Same rule as the graphics beside
# it: whoever may add a graphic may set the video (`ListingGraphicPolicy#update?`).
class Apps::PromoVideosController < ApplicationController
  include AppArchived

  before_action :authenticate_user!
  before_action :set_app

  def update
    authorize ListingGraphic.new(app: @app), :update?
    raise_if_app_archived!(@app)

    # Only an explicit string counts. A missing key, a list or a hash is a malformed request (400), never
    # "clear the video": clearing is the blank string.
    raw = params[:promo_video]
    url = raw.respond_to?(:permit) ? raw.permit(:url)[:url] : nil
    return head(:bad_request) unless url.is_a?(String)

    parsed = YoutubeVideoLink.parse(url)
    return redirect_to(app_path(@app), alert: t(".errors.#{parsed.error}")) unless parsed.ok?

    if @app.update(promo_video_youtube_id: parsed.id)
      redirect_to app_path(@app), notice: t(parsed.id ? '.saved' : '.removed')
    else
      redirect_to app_path(@app), alert: t('.refused', reasons: @app.errors.full_messages.to_sentence)
    end
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end
end
