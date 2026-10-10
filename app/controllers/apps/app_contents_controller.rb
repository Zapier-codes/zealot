# frozen_string_literal: true

# Z-P5 / Z-P6 (Play Console parity): the "App content" section of the Console. Play keeps the content/age
# rating, the Data Safety answers, the ads and in-app-purchase declarations, the store privacy-policy URL
# and the reviewer access on one "App content" screen; this is that screen.
#
# Same staged-draft model as the store-listing text editor (Apps::ListingTextsController): GET shows the
# form filled with what the draft would publish, PATCH stages into the app's one draft through
# ListingEditService, POST commit publishes it in one transaction, DELETE discards it. Nothing on the live
# listing changes until the owner publishes. The App columns and the index support landed in Z-P5/Z-P6's
# data layer (migrations 20261010050000 / 20261010060000, App::CATALOG_INDEX_LISTING_FIELDS); this is only
# the UI over them.
#
# The reviewer access instructions are the one field that is NOT staged: they hold a reviewer test account
# and must never reach the public signed index. They are saved straight to the app (App#update) in the same
# PATCH request, before staging, so a bad URL in the public fields still re-shows the form with both halves
# as the owner typed them.
class Apps::AppContentsController < ApplicationController
  include AppArchived

  # The public, index-published fields this form stages. A field the owner is not sent is left alone; an
  # explicit blank clears it. `data_safety_types` is a repeated form value, so it is handled separately.
  STAGED_FIELDS = %w[
    content_rating data_safety_collects data_safety_shared data_safety_encrypted
    data_safety_deletion_url contains_ads has_in_app_purchases privacy_policy_url available_regions
  ].freeze

  # Z-P17: the crash-reporting opt-in is NOT a public listing fact -- it is an operational switch, so it is
  # saved straight to the app like the reviewer access, never staged and never published in the signed index.
  # It is off by default ("no telemetry by default"); this is the one place a person turns it on.
  TOGGLE_FIELDS = %w[crash_reporting_enabled].freeze

  # A short, stable list of the countries the Console offers (the column itself is a free-form alpha-2 array).
  # Empty = offered everywhere; the index publishes null for that.
  REGION_CHOICES = %w[
    US CA MX BR AR GB DE FR ES IT NL SE NO DK FI PL PT IE AT CH BE GR CZ RO HU
    RU UA TR IL AE SA EG ZA NG KE IN PK BD LK CN JP KR TW HK SG MY ID TH VN PH
    AU NZ
  ].freeze

  # The content-rating buckets Play offers. Stored as the label, published as-is (the index field is a free
  # string, and Storeapp normalizes it into its own classes on read).
  CONTENT_RATINGS = [
    'Everyone', 'Everyone 10+', 'Teen', 'Mature 17+', 'Adults only 18+', 'Unrated',
  ].freeze

  # The Data Safety data types Play's form offers (a stable subset; the column itself is free-form).
  DATA_SAFETY_TYPES = %w[
    location personal_info financial_info health_and_fitness messages photos_and_videos
    files_and_docs calendar contacts app_activity web_browsing app_info_and_performance device_or_other_ids
  ].freeze

  BOOLEAN_FIELDS = %w[
    data_safety_collects data_safety_shared data_safety_encrypted contains_ads has_in_app_purchases
  ].freeze

  before_action :authenticate_user!
  before_action :set_app
  before_action -> { set_app_breadcrumbs(app: @app) }

  # GET /apps/:app_id/app_content
  def show
    authorize ListingEdit.new(app: @app), :show?
    load_page
  end

  # PATCH /apps/:app_id/app_content
  def update
    authorize ListingEdit.new(app: @app), :update?
    raise_if_app_archived!(@app)

    submitted = submitted_values
    return head(:bad_request) if submitted.nil?

    # Backend-only: never staged, never published. Saved directly.
    saved_reviewer = save_reviewer_access(submitted.delete('reviewer_access_instructions'))
    saved_toggle = save_toggles(submitted)

    changes, reverts = split_changes(submitted)
    if changes.empty? && reverts.empty?
      return redirect_to(app_app_content_path(@app),
                         notice: saved_reviewer || saved_toggle ? t('.reviewer_saved') : t('.unchanged'))
    end

    service = ListingEditService.new(app: @app, editor: current_user)
    if changes.any?
      draft = service.stage(changes)
      return refuse(submitted, draft.errors.map(&:message)) if draft.errors.any?
    end
    service.unstage(*reverts) if reverts.any?

    redirect_to app_app_content_path(@app), notice: t('.saved')
  end

  # POST /apps/:app_id/app_content/commit
  def commit
    authorize ListingEdit.new(app: @app), :commit?
    raise_if_app_archived!(@app)

    service = ListingEditService.new(app: @app, editor: current_user)
    draft = open_draft
    return redirect_to(app_app_content_path(@app), alert: t('.nothing')) if draft.nil?

    if draft.staged_attributes.blank?
      service.discard!
      return redirect_to(app_app_content_path(@app), notice: t('.nothing_staged'))
    end

    if service.commit!
      redirect_to app_app_content_path(@app), notice: t('.published')
    else
      reasons = service.draft.errors.map(&:message).to_sentence.presence || t('.unknown')
      redirect_to app_app_content_path(@app), alert: t('.refused', reasons: reasons)
    end
  end

  # DELETE /apps/:app_id/app_content
  def destroy
    authorize ListingEdit.new(app: @app), :discard?
    raise_if_app_archived!(@app)

    return redirect_to(app_app_content_path(@app), alert: t('.nothing')) if open_draft.nil?

    ListingEditService.new(app: @app, editor: current_user).discard!
    redirect_to app_app_content_path(@app), notice: t('.discarded')
  end

  private

  def open_draft
    @app.listing_edits.status_draft.first
  end

  def set_app
    @app = App.find(params[:app_id])
  end

  # The submitted fields as a hash, or nil when the request is malformed (no `app_content` hash). A field
  # that is not sent is left alone; an explicit blank clears one. Booleans come back as the strings "1"/""
  # from the form and are normalized in tidy_value; `data_safety_types` stays an array.
  def submitted_values
    raw = params[:app_content]
    return nil unless raw.respond_to?(:key?) && raw.respond_to?(:permit)

    permitted = raw.permit(*STAGED_FIELDS, *TOGGLE_FIELDS, :reviewer_access_instructions, data_safety_types: [], available_regions: [])
    kept = permitted.to_h
    return nil if kept.empty?

    # `available_regions` is a repeated checkbox, so it arrives as an array only when at least one box is
    # ticked; normalize it to an array here so `split_changes` compares it like any other field.
    kept['available_regions'] = Array(kept['available_regions']).map(&:to_s).reject(&:blank?) if kept.key?('available_regions')
    kept
  end

  # Saves the reviewer access instructions straight to the app (never staged). Returns true when the app was
  # changed without error, false otherwise (a refusal is not fatal to the public half; the page re-renders).
  def save_reviewer_access(value)
    return false if value.nil?

    @app.update(reviewer_access_instructions: value.to_s.presence).tap do |ok|
      @reviewer_error = @app.errors.full_messages.to_sentence unless ok
    end
  end

  # Splits what was submitted into fields that differ from the live app (to stage) and fields that equal it
  # (to drop from the draft if staged).
  def split_changes(submitted)
    changes = {}
    reverts = []
    submitted.each do |field, value|
      tidy = tidy_value(field, value)
      live = tidy_value(field, @app[field])
      if tidy == live
        reverts << field
      else
        changes[field] = tidy
      end
    end
    [ changes, reverts ]
  end

  # Z-P17: the crash-reporting switch and the other operational toggles, saved straight to the app (never
  # staged, never published). Returns true when any changed without error. Deleting each key means the shared
  # `split_changes` never sees it as a public field to stage.
  def save_toggles(submitted)
    saved = false
    TOGGLE_FIELDS.each do |field|
      next unless submitted.key?(field)

      value = boolean_value(submitted.delete(field)) || false
      next if @app[field] == value

      @app.update(field => value)
      saved = true
    end
    saved
  end

  # Normalizes a submitted value the way the column stores it, so a comparison, a stage and a preview all
  # agree. Booleans: a form checkbox sends "1" when ticked and nothing when not, but this form's radios
  # send "", "true" or "false" -- an unanswered field ("" not offered) stays nil, never false.
  def tidy_value(field, value)
    case field
    when 'data_safety_types' then Array(value).map(&:to_s).reject(&:blank?)
    when 'available_regions' then Array(value).map { |c| c.to_s.upcase }.select { |c| c.match?(/\A[A-Z]{2}\z/) }.sort
    when 'data_safety_collects', 'data_safety_shared', 'data_safety_encrypted',
         'contains_ads', 'has_in_app_purchases'
      boolean_value(value)
    else value.to_s.strip.presence
    end
  end

  def boolean_value(value)
    case value
    when true then true
    when false then false
    else
      s = value.to_s
      return nil if s.empty? # the "not answered" option
      return true if %w[1 true on yes].include?(s.downcase)
      return false if %w[0 false off no].include?(s.downcase)

      nil
    end
  end

  def refuse(submitted, messages)
    load_page(values: submitted)
    flash.now[:alert] = t('.refused', reasons: messages.to_sentence)
    render :show, status: :unprocessable_entity
  end

  # `values` are what the form shows: what the owner just submitted after a refusal, else what the draft
  # would publish, else the live app.
  def load_page(values: nil)
    @draft = @app.listing_edits.status_draft.first
    @live = @app.attributes.slice(*STAGED_FIELDS)
    shown = @draft ? @draft.previewed_attributes.slice(*STAGED_FIELDS) : @live
    @values = shown.merge(values || {})
    @values['data_safety_types'] = Array(@values['data_safety_types'])
    # Which radio is ticked per boolean field: 'true', 'false', or '' for the honest "not answered".
    @boolean_radio = BOOLEAN_FIELDS.index_with do |field|
      case boolean_value(@values[field])
      when true then 'true'
      when false then 'false'
      else ''
      end
    end
    @reviewer_access = @app.reviewer_access_instructions
    @crash_reporting_enabled = @app.crash_reporting_enabled?
    staged = @draft ? @draft.staged_attributes.stringify_keys : {}
    @staged = STAGED_FIELDS.select { |field| staged.key?(field) && staged[field] != @live[field] }
    @title = t('apps.app_contents.show.title')
  end
end
