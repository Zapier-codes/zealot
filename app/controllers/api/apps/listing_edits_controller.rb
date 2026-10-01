# frozen_string_literal: true

# Task 34a-3 (Storeapp leaf `f.xiv`): the listing text (name, short description, full description) over
# the API, the same draft-then-publish flow as the console page (Apps::ListingTextsController, 27e-c/d).
#
#   GET    /api/apps/:app_id/listing_edit          the live text, the staged draft and what would publish
#   PATCH  /api/apps/:app_id/listing_edit          name | short_description | description  (stage; nothing live changes)
#   POST   /api/apps/:app_id/listing_edit/commit   publish the draft
#   DELETE /api/apps/:app_id/listing_edit          discard the draft
#
# Credentials: the user token (`?token=`, as every other /api controller) OR a per-app token
# (`Authorization: Bearer zpa_...`, Api::AppTokenAuth), never both and never a fallback: a presented
# `zpa_` header that is bad is a 401, and a valid one for another app is a 403.
#
# Everything goes through `ListingEditService` and the same policy the console asks
# (`ListingEditPolicy`: admin, owner or a manage collaborator, plus the tenant rule), so the rules that
# run at commit (the real `App` validations) are the console's, and a refusal is a 422 with the model's
# messages. `commit` writes the draft in one transaction; `App`'s own after_commit then republishes the
# catalog index once for a live app, so nothing here enqueues anything. Only the three text fields can
# be staged here, exactly the console page's set; the other listing fields are not reachable by a token.
#
# Only a field that differs from the live app is staged; one put back to the live value is taken out of
# the draft (`unstage`), so the draft never carries an old copy that a later commit would write over.
class Api::Apps::ListingEditsController < Api::BaseController
  include AppArchived

  FIELDS = %w[name short_description description].freeze

  before_action :validate_app_token, if: :app_token_presented?
  before_action :validate_user_token, unless: :app_token_presented?
  before_action :set_app
  before_action :require_token_app, if: :app_token_presented?

  # GET /api/apps/:app_id/listing_edit
  def show
    authorize ListingEdit.new(app: @app), :show?
    render json: page
  end

  # PATCH /api/apps/:app_id/listing_edit
  def update
    authorize ListingEdit.new(app: @app), :update?
    raise_if_app_archived!(@app)

    submitted = submitted_text
    return render_no_fields if submitted.nil?

    changes, reverts = split_changes(submitted)
    service = ListingEditService.new(app: @app, editor: current_user)
    if changes.any?
      draft = service.stage(changes)
      return render_refused(draft.errors.map(&:message)) if draft.errors.any?
    end
    service.unstage(*reverts) if reverts.any?

    render json: page
  end

  # POST /api/apps/:app_id/listing_edit/commit
  def commit
    authorize ListingEdit.new(app: @app), :commit?
    raise_if_app_archived!(@app)

    draft = open_draft
    return render_no_draft if draft.nil?

    service = ListingEditService.new(app: @app, editor: current_user)
    # An empty draft (a refused first save leaves one) has nothing to publish: clear it.
    if draft.staged_attributes.blank?
      service.discard!
      return render json: { committed: false, listing: @app.reload.attributes.slice(*FIELDS) }
    end

    if service.commit!
      render json: { committed: true, listing: @app.reload.attributes.slice(*FIELDS) }
    else
      render_refused(service.draft.errors.map(&:message))
    end
  end

  # DELETE /api/apps/:app_id/listing_edit
  def destroy
    authorize ListingEdit.new(app: @app), :discard?
    raise_if_app_archived!(@app)

    return render_no_draft if open_draft.nil?

    ListingEditService.new(app: @app, editor: current_user).discard!
    render json: { discarded: true }
  end

  private

  def set_app
    @app = scoped_apps.find(params[:app_id])
  end

  def require_token_app
    require_app_token_for!(@app)
  end

  # The app's draft if it has one. Never creates it (`ListingEditService#draft` would).
  def open_draft
    @app.listing_edits.status_draft.first
  end

  # The submitted fields as a hash of strings, or nil when none was sent or a value is not a plain
  # string. A field that is not sent is left alone; only an explicit blank string clears one.
  def submitted_text
    sent = FIELDS.select { |field| params.key?(field) }
    return nil if sent.empty? || sent.any? { |field| !params[field].is_a?(String) }

    sent.index_with { |field| params[field] }
  end

  # Splits what was submitted into fields that differ from the live app (to stage, already tidied the
  # way `App` will tidy them) and fields that equal the live app (to drop from the draft if staged).
  def split_changes(submitted)
    changes = {}
    reverts = []
    submitted.each do |field, value|
      tidy = tidy_value(field, value)
      if tidy == tidy_value(field, @app[field])
        reverts << field
      else
        changes[field] = tidy
      end
    end
    [ changes, reverts ]
  end

  # Mirrors `App`'s own tidying (same as Apps::ListingTextsController#tidy_value).
  def tidy_value(field, value)
    case field
    when 'description' then ListingText.tidy_description(value)
    when 'short_description' then ListingText.tidy_short_description(value)
    else value.to_s.strip
    end
  end

  def page
    draft = open_draft
    live = @app.attributes.slice(*FIELDS)
    staged = draft ? draft.staged_attributes.stringify_keys.slice(*FIELDS) : {}
    {
      app_id: @app.id,
      draft: draft.present?,
      live: live,
      staged: staged.reject { |field, value| value == live[field] },
      would_publish: draft ? draft.previewed_attributes.slice(*FIELDS) : live
    }
  end

  def render_no_fields
    render json: { error: t('api.listing_edit_no_fields', fields: FIELDS.to_sentence) },
           status: :unprocessable_entity
  end

  def render_no_draft
    render json: { error: t('api.listing_edit_none') }, status: :not_found
  end

  def render_refused(messages)
    render json: { error: t('api.listing_edit_refused', reasons: messages.to_sentence) },
           status: :unprocessable_entity
  end
end
