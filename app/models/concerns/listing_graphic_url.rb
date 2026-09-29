# frozen_string_literal: true

# Task 27d-e1: the stable public URL of a listing graphic (`GET /download/graphics/:id`, 27d-d2-d),
# built on the same host as `ReleaseUrl#download_url` and `#icon_download_url`. A concern rather than
# a method on the model so the route helpers are not mixed into `ListingGraphic` itself.
module ListingGraphicUrl
  extend ActiveSupport::Concern

  included do
    include Rails.application.routes.url_helpers
  end

  def download_url
    download_graphic_url(id)
  end
end
