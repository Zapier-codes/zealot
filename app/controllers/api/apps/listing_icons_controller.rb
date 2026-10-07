# frozen_string_literal: true

# Task 43f-3 (operator-directed, 2026-10-07): the app's store icon over the API, for an app whose bundle carried
# no readable icon (Appstore 1.1.4). One call replaces the icon on the app's newest catalog release:
#
#   PUT /api/apps/:app_id/listing_icon     multipart: file, fit (default on; fit=false sends the file as it is)
#   curl -X PUT -H "Authorization: Bearer $ZEALOT_APP_TOKEN" -F file=@icon.png "$ZEALOT_URL/api/apps/2/listing_icon"
#
# Credentials: the user token (`?token=`) OR a per-app token (`Authorization: Bearer zpa_...`), never both and
# never a fallback; a bad `zpa_` header is a 401 and a valid one for another app is a 403 (the same rule as
# Api::Apps::ListingGraphicsController). The same people may do it as may change the graphics
# (`ListingGraphicPolicy#replace_icon?`).
#
# `ListingGraphicFit` (kind: 'icon') turns any readable image into a 512 x 512 PNG first; `ListingIconIngest`
# judges the result and writes it. A refusal is a 422 with every reason and changes nothing, including "the
# app has no release yet". The index is republished by the ingest.
class Api::Apps::ListingIconsController < Api::BaseController
  include AppArchived

  before_action :validate_app_token, if: :app_token_presented?
  before_action :validate_user_token, unless: :app_token_presented?
  before_action :set_app
  before_action :require_token_app, if: :app_token_presented?

  # PUT /api/apps/:app_id/listing_icon
  def update
    authorize ListingGraphic.new(app: @app), :replace_icon?
    raise_if_app_archived!(@app)

    upload = params[:file]
    return render_error(t('api.listing_graphic_no_file'), :unprocessable_entity) unless upload.respond_to?(:tempfile)

    fitted = params[:fit].to_s == 'false' ? nil : ListingGraphicFit.call(path: upload.tempfile.path, kind: 'icon')
    result = ListingIconIngest.call(app: @app, path: fitted&.path || upload.tempfile.path)
    if result.ok?
      render json: { icon: describe(result.release), fitted: fitted&.changed? || false, notes: fitted&.notes || [] }
    else
      render_error(t('api.listing_icon_refused', reasons: result.violations.map(&:message).to_sentence),
                   :unprocessable_entity)
    end
  ensure
    fitted&.cleanup
  end

  private

  def set_app
    @app = scoped_apps.find(params[:app_id])
  end

  def require_token_app
    require_app_token_for!(@app)
  end

  def describe(release)
    { release_id: release.id, version_name: release.release_version, sha256: release.icon_sha256,
      url: release.icon_download_url }
  end

  def render_error(message, status)
    render json: { error: message }, status: status
  end
end
