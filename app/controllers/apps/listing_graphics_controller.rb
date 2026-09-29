# frozen_string_literal: true

# Task 27d-e2-a: the owner adds and removes an app's store-listing graphics (screenshots and the
# feature graphic). Two actions and no page of their own: the panel that lists them and holds the form
# is a section of the app page (27d-e2-b, `apps/_listing_graphics`), which is where both redirect.
#
#   POST   /apps/:app_id/listing_graphics       multipart: listing_graphic[file], [kind], [alt_text]
#   DELETE /apps/:app_id/listing_graphics/:id
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
    result = ListingGraphicIngest.call(app: @app, path: upload.tempfile.path, kind: kind,
                                       alt_text: graphic_params[:alt_text])

    if result.ok?
      redirect_to app_path(@app), notice: t(".added.#{result.graphic.kind}")
    else
      redirect_to app_path(@app), alert: t('.refused', reasons: result.violations.map(&:message).to_sentence)
    end
  rescue ListingGraphicIngest::StorageFailed => e
    Rails.logger.error("[Apps::ListingGraphicsController#create] app #{@app.id}: #{e.message}")
    redirect_to app_path(@app), alert: t('.storage_failed')
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
