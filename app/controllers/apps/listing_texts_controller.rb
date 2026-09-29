# frozen_string_literal: true

# Task 27e-c: the owner edits the text of the store listing: the name, the short description and the
# full description. Nothing here changes the live listing.
#
#   GET   /apps/:app_id/listing_text    the form, filled with what the draft would publish
#   PATCH /apps/:app_id/listing_text    listing_text[name|short_description|description]
#
# PATCH stages the change into the app's one draft through `ListingEditService#stage`, never through
# `@app.update`. The draft is checked against the real `App` validations when it is saved (length limits,
# a name that is not blank), so this controller repeats none of them; a refusal re-shows the form with what
# the owner typed and leaves the saved draft as it was. Publishing or discarding the draft is 27e-d.
#
# Only a field the owner has actually changed is staged. A field put back to what is live now is taken out
# of the draft again (`ListingEditService#unstage`), so the draft never carries an old copy of a field the
# owner did not touch, which a later commit would write over the live app.
class Apps::ListingTextsController < ApplicationController
  include AppArchived

  FIELDS = %w[name short_description description].freeze

  before_action :authenticate_user!
  before_action :set_app
  before_action -> { set_app_breadcrumbs(app: @app) }

  # GET /apps/:app_id/listing_text
  def show
    authorize ListingEdit.new(app: @app), :show?
    load_page
  end

  # PATCH /apps/:app_id/listing_text
  def update
    authorize ListingEdit.new(app: @app), :update?
    raise_if_app_archived!(@app)

    submitted = submitted_text
    return head(:bad_request) if submitted.nil?

    changes, reverts = split_changes(submitted)
    return redirect_to(app_listing_text_path(@app), notice: t('.unchanged')) if changes.empty? && reverts.empty?

    service = ListingEditService.new(app: @app, editor: current_user)
    if changes.any?
      draft = service.stage(changes)
      return refuse(submitted, draft.errors.map(&:message)) if draft.errors.any?
    end
    service.unstage(*reverts) if reverts.any?

    redirect_to app_listing_text_path(@app), notice: t('.saved')
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  # The submitted fields as a hash of strings, or nil when the request is malformed (no `listing_text`
  # hash, or a value that is not a plain string). A field that is not sent is left alone; only an
  # explicit blank string clears one.
  def submitted_text
    raw = params[:listing_text]
    return nil unless raw.respond_to?(:key?) && raw.respond_to?(:permit)

    sent = FIELDS.select { |field| raw.key?(field) }
    return nil if sent.empty? || sent.any? { |field| !raw[field].is_a?(String) }

    sent.index_with { |field| raw[field] }
  end

  # Splits what was submitted into fields that differ from the live app (to stage, already tidied the way
  # `App` will tidy them) and fields that equal the live app (to drop from the draft if they are staged).
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

  # Mirrors `App`'s own tidying so a value is compared, staged and previewed exactly as it would be
  # stored. The name has no tidy rule in `App`, so it is only trimmed here; a blank name stays an empty
  # string and is refused by `validates :name, presence: true` when the draft is saved.
  def tidy_value(field, value)
    case field
    when 'description' then ListingText.tidy_description(value)
    when 'short_description' then ListingText.tidy_short_description(value)
    else value.to_s.strip
    end
  end

  def refuse(submitted, messages)
    load_page(values: submitted)
    flash.now[:alert] = t('apps.listing_texts.update.refused', reasons: messages.to_sentence)
    render :show, status: :unprocessable_entity
  end

  # `values` are what the form shows: what the owner just typed after a refusal, else what the draft would
  # publish (the draft's staged fields over the live ones), else the live listing.
  def load_page(values: nil)
    @draft = @app.listing_edits.status_draft.first
    @live = @app.attributes.slice(*FIELDS)
    shown = @draft ? @draft.previewed_attributes.slice(*FIELDS) : @live
    @values = shown.merge(values || {})
    staged = @draft ? @draft.staged_attributes.stringify_keys : {}
    @staged = FIELDS.select { |field| staged.key?(field) && staged[field] != @live[field] }
    @title = t('apps.listing_texts.show.title')
  end
end
