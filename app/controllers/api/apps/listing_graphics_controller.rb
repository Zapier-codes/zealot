# frozen_string_literal: true

# Task 43a (operator-directed, 2026-10-07): an app's store-listing graphics (screenshots and the feature
# graphic) over the API, so a developer or a CI job can put them on the listing without the console page.
# The console panel (Apps::ListingGraphicsController, 27d-e2) stays; both call the same service.
#
#   GET    /api/apps/:app_id/listing_graphics        the app's graphics, in display order, and the slot counts
#   POST   /api/apps/:app_id/listing_graphics        multipart: file, kind (screenshot | feature_graphic), alt_text, fit (default on; fit=false sends the file as it is)
#   DELETE /api/apps/:app_id/listing_graphics/:id    remove one
#
# Credentials: the user token (`?token=`) OR a per-app token (`Authorization: Bearer zpa_...`), never both and
# never a fallback (the same rule as Api::Apps::ListingEditsController): a presented `zpa_` header that is bad
# is a 401 and a valid one for another app is a 403.
#
# All the judgement is `ListingGraphicIngest` (27d-d2-c): it reads the type and size from the file's own bytes,
# applies Play's rules (JPEG or PNG without alpha, 320 to 3840 px a side, long side at most twice the short
# side, 8 MB, at most 8 phone screenshots) and stores and hashes the bytes. A refusal is a 422 with every
# reason and writes nothing. The file's name and content type are never read. The catalog index is republished
# by `ListingGraphic`'s own after_commit, so nothing here enqueues anything. The same policy as the console
# (`ListingGraphicPolicy`: admin, owner or a manage collaborator, plus the tenant rule) decides who may.
class Api::Apps::ListingGraphicsController < Api::BaseController
  include AppArchived

  before_action :validate_app_token, if: :app_token_presented?
  before_action :validate_user_token, unless: :app_token_presented?
  before_action :set_app
  before_action :require_token_app, if: :app_token_presented?

  # GET /api/apps/:app_id/listing_graphics
  def index
    authorize ListingGraphic.new(app: @app), :index?
    render json: page
  end

  # POST /api/apps/:app_id/listing_graphics
  def create
    authorize ListingGraphic.new(app: @app), :create?
    raise_if_app_archived!(@app)

    upload = params[:file]
    return render_error(t('api.listing_graphic_no_file'), :unprocessable_entity) unless upload.respond_to?(:tempfile)

    # Task 43e: a picture is fitted to Play's rules first (crop to 2:1, scale into 320..3840, flatten
    # transparency) unless the caller sends fit=false; the ingest still judges the result.
    fitted = params[:fit].to_s == 'false' ? nil : ListingGraphicFit.call(path: upload.tempfile.path, kind: params[:kind].to_s)
    result = ListingGraphicIngest.call(app: @app, path: fitted&.path || upload.tempfile.path, kind: params[:kind].to_s,
                                       alt_text: params[:alt_text].is_a?(String) ? params[:alt_text] : nil)
    if result.ok?
      render json: { graphic: describe(result.graphic), fitted: fitted&.changed? || false, notes: fitted&.notes || [] },
             status: :created
    else
      render_error(t('api.listing_graphic_refused', reasons: result.violations.map(&:message).to_sentence),
                   :unprocessable_entity)
    end
  rescue ListingGraphicIngest::StorageFailed => e
    Rails.logger.error("[Api::Apps::ListingGraphicsController#create] app #{@app.id}: #{e.message}")
    render_error(t('api.listing_graphic_storage_failed'), :service_unavailable)
  ensure
    fitted&.cleanup
  end

  # DELETE /api/apps/:app_id/listing_graphics/:id
  def destroy
    graphic = @app.listing_graphics.find(params[:id])
    authorize graphic, :destroy?
    raise_if_app_archived!(@app)

    graphic.destroy!
    render json: { deleted: true, id: graphic.id }
  end

  private

  def set_app
    @app = scoped_apps.find(params[:app_id])
  end

  def require_token_app
    require_app_token_for!(@app)
  end

  def page
    graphics = @app.listing_graphics.to_a.sort_by { |graphic| [ graphic.position.to_i, graphic.id.to_i ] }
    screenshots = graphics.select(&:kind_screenshot?)
    {
      app_id: @app.id,
      screenshots_count: screenshots.size,
      screenshots_max: ListingGraphicRules::MAX_SCREENSHOTS,
      feature_graphic: graphics.any?(&:kind_feature_graphic?),
      graphics: graphics.map { |graphic| describe(graphic) }
    }
  end

  def describe(graphic)
    graphic.attributes.slice('id', 'kind', 'device', 'position', 'alt_text', 'width', 'height', 'sha256')
           .merge('url' => graphic.download_url)
  end

  def render_error(message, status)
    render json: { error: message }, status: status
  end
end
