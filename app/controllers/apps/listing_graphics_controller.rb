# frozen_string_literal: true

# Task 27d-e2-a: the owner adds and removes an app's store-listing graphics (screenshots and the
# feature graphic). Two actions and no page of their own: the panel that lists them and holds the form
# is a section of the app page (27d-e2-b, `apps/_listing_graphics`), which is where both redirect.
#
#   POST   /apps/:app_id/listing_graphics       multipart: listing_graphic[file], [kind], [alt_text]
#   DELETE /apps/:app_id/listing_graphics/:id
#   PATCH  /apps/:app_id/listing_graphics/:id        (27d-e2-c1: the description)
#   PATCH  /apps/:app_id/listing_graphics/:id/move   (27d-e2-c2: up or down one place)
#
# All the judgement is `ListingGraphicIngest` (27d-d2-c): it reads the type and size from the file's own
# bytes, applies Play's rules and the slot cap, and stores and hashes the bytes. This controller only
# authorizes, hands it the upload and reports the outcome; it never trusts the browser's file name or
# content type.
class Apps::ListingGraphicsController < ApplicationController
  include AppArchived

  before_action :authenticate_user!
  before_action :set_app

  # POST /apps/:app_id/listing_graphics
  def create
    authorize ListingGraphic.new(app: @app), :create?
    raise_if_app_archived!(@app)

    upload = graphic_params[:file]
    return redirect_to(app_path(@app), alert: t('.no_file')) unless upload.respond_to?(:tempfile)

    kind = graphic_params[:kind].to_s
    # Task 43e: fit the picture to Play's rules first (the ingest still judges the result).
    fitted = ListingGraphicFit.call(path: upload.tempfile.path, kind: kind)
    result = ListingGraphicIngest.call(app: @app, path: fitted.path, kind: kind, alt_text: graphic_params[:alt_text])

    if result.ok?
      redirect_to app_path(@app), notice: t(".added.#{result.graphic.kind}")
    else
      redirect_to app_path(@app), alert: t('.refused', reasons: result.violations.map(&:message).to_sentence)
    end
  rescue ListingGraphicIngest::StorageFailed => e
    Rails.logger.error("[Apps::ListingGraphicsController#create] app #{@app.id}: #{e.message}")
    redirect_to app_path(@app), alert: t('.storage_failed')
  ensure
    fitted&.cleanup
  end

  # PATCH /apps/:app_id/listing_graphics/:id  (Task 27d-e2-c1)
  # Changes the description (alt text) and nothing else: the file, its kind and its position are never
  # taken from the request. A blank value clears it. The model's length check is the only judge.
  def update
    graphic = @app.listing_graphics.find(params[:id])
    authorize graphic, :update?
    raise_if_app_archived!(@app)

    if graphic.update(alt_text: graphic_params[:alt_text].to_s.strip.presence)
      redirect_to app_path(@app), notice: t('.notice')
    else
      redirect_to app_path(@app), alert: t('.refused', reasons: graphic.errors.full_messages.to_sentence)
    end
  end

  # PATCH /apps/:app_id/listing_graphics/:id/move?direction=up|down  (Task 27d-e2-c2)
  # Screenshots only (the feature graphic has no order, so its id is a 404 here).
  def move
    graphic = @app.listing_graphics.kind_screenshot.find(params[:id])
    authorize graphic, :move?
    raise_if_app_archived!(@app)

    direction = params[:direction].to_s
    unless ListingGraphicReorder::DIRECTIONS.include?(direction)
      return redirect_to(app_path(@app), alert: t('.bad_direction'))
    end

    result = ListingGraphicReorder.call(app: @app, graphic: graphic, direction: direction)
    redirect_to app_path(@app), notice: t(result.changed? ? '.moved' : '.unchanged')
  end

  # DELETE /apps/:app_id/listing_graphics/:id
  def destroy
    graphic = @app.listing_graphics.find(params[:id])
    authorize graphic, :destroy?
    raise_if_app_archived!(@app)

    graphic.destroy!
    redirect_to app_path(@app), notice: t('.notice')
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  def graphic_params
    params.fetch(:listing_graphic, {}).permit(:file, :kind, :alt_text)
  end
end
