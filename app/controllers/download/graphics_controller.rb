# frozen_string_literal: true

# Task 27d-d2-d: the stable, public URL of a store-listing graphic (`GET /download/graphics/:id`), the
# URL the catalog index will carry (27d-e1). Redirects to the signed storage URL, or serves the bytes
# (ListingGraphicDownload), so the URL survives a redeploy.
#
# No login and no channel password: a listing graphic is public by definition, it is what the store
# shows everyone. It does not redirect to a tenant's canonical host like the release pages do: a graphic
# belongs to an app, not a channel, and the canonical-host rule needs a channel; the same image is served
# on any host. No download web hook, no counter.
#
# The content type is the one recorded from the file's bytes when it was ingested, never one guessed from
# a name, and the response is `inline` with the browser told not to sniff it (Rails' default header).
class Download::GraphicsController < ApplicationController
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_entity_response

  def show
    graphic = ListingGraphic.find(params[:id])
    source = ListingGraphicDownload.new(graphic).resolve
    case source.kind
    when :redirect
      # Signed, short-lived storage URL; never cache it.
      response.headers['Cache-Control'] = 'no-store'
      redirect_to source.url, allow_other_host: true
    when :data
      # A graphic's bytes never change (a new image is a new row), so a short public cache is safe.
      expires_in 1.hour, public: true
      send_data source.data, type: source.content_type, disposition: 'inline'
    else
      render_not_found_entity_response
    end
  end

  private

  def render_not_found_entity_response
    render json: { error: t('download.releases.show.not_found') }, status: :not_found
  end
end
