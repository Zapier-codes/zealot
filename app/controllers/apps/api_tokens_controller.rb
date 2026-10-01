# frozen_string_literal: true

# Task 34a-7 (Storeapp leaf `f.xiv`): the owner creates, lists and revokes the per-app API tokens a CI job
# uses to publish (AppApiToken, 34a-1; the `/api` side is Api::AppTokenAuth, 34a-2).
#
#   GET    /apps/:app_id/api_tokens        the list and the create form
#   POST   /apps/:app_id/api_tokens        api_token[name], api_token[expiry] (30 | 90 | 365 | none)
#   DELETE /apps/:app_id/api_tokens/:id    revoke (soft: the row stays for the audit log, 34c)
#
# This is a SESSION page (`authenticate_user!`): an API token can never open it, and the `/api` token
# routes never reach it. Gated by `AppApiTokenPolicy` (manage the app, plus the tenant rule).
#
# The secret is shown ONCE. `create` renders the page in the same response instead of redirecting, so the
# plaintext never goes through the session, the flash or a URL; the response is `no-store`. A reload asks the
# browser to resubmit the form, which would issue a second token, which is the safe failure (the first
# secret is gone for good, never shown twice). The form opts out of Turbo so this plain 200 is rendered.
class Apps::ApiTokensController < ApplicationController
  include AppArchived

  # Expiry choices of decision 34-1: 30 / 90 (default) / 365 days, or none (the view labels it).
  EXPIRY_CHOICES = { '30' => 30.days, '90' => 90.days, '365' => 365.days, 'none' => nil }.freeze
  DEFAULT_EXPIRY = '90'

  before_action :authenticate_user!
  before_action :set_app
  before_action -> { set_app_breadcrumbs(app: @app) }

  # GET /apps/:app_id/api_tokens
  def index
    authorize AppApiToken.new(app: @app), :index?
    load_page
  end

  # POST /apps/:app_id/api_tokens
  def create
    authorize AppApiToken.new(app: @app), :create?
    raise_if_app_archived!(@app)

    raw = params[:api_token]
    return head(:bad_request) unless raw.respond_to?(:key?) && raw.respond_to?(:permit)

    expiry = raw[:expiry].to_s.presence || DEFAULT_EXPIRY
    return head(:bad_request) unless raw[:name].is_a?(String) && EXPIRY_CHOICES.key?(expiry)

    begin
      issued = AppApiToken.issue!(
        app: @app, name: raw[:name].strip, created_by: current_user,
        expires_at: EXPIRY_CHOICES[expiry]&.from_now
      )
    rescue ActiveRecord::RecordInvalid => e
      load_page(name: raw[:name], expiry: expiry)
      flash.now[:alert] = t('apps.api_tokens.create.refused', reasons: e.record.errors.full_messages.to_sentence)
      return render :index, status: :unprocessable_entity
    end

    response.headers['Cache-Control'] = 'no-store'
    load_page
    @issued = issued
    flash.now[:notice] = t('apps.api_tokens.create.created')
    render :index
  end

  # DELETE /apps/:app_id/api_tokens/:id
  def destroy
    token = @app.api_tokens.find(params[:id])
    authorize token, :destroy?
    raise_if_app_archived!(@app)

    token.revoke!
    redirect_to app_api_tokens_path(@app), notice: t('.revoked', name: token.name)
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  def load_page(name: nil, expiry: DEFAULT_EXPIRY)
    @tokens = @app.api_tokens.includes(:created_by).order(created_at: :desc).limit(100)
    @live_count = @app.api_tokens.live.count
    @form_name = name
    @form_expiry = expiry
    @title = t('apps.api_tokens.index.title')
  end
end
