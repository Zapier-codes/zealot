# frozen_string_literal: true

# Z-P25 §2 (docs/UNOFFICIAL-ROUTES.md): "Import from Play". A publisher's app usually already exists in
# Play Console; this page reads that listing back through the official Play Developer API (see
# Anthropic::PlayImportService) and offers it as the starting point for Zealot's own listing, instead of a
# blank form typed a second time.
#
# Same staged-draft model as the store-listing text editor (Apps::ListingTextsController) and the app
# content editor (Apps::AppContentsController): GET reads the listing from Play and shows it, POST stages
# the fields the owner chose into the app's one draft through ListingEditService, and the ordinary listing
# editor's Publish commits it. Nothing here writes to the live listing directly and nothing is ever sent
# back to Play -- this is an import, not a sync.
#
# Only the fields Play and Zealot share are imported: name (Play's title), short_description, description
# (Play's full_description) and play_package_name (adopted onto the app, since that is what the read came
# from). Play's per-language listings are all fetched, but only one is staged at a time -- the language the
# request names, defaulting to the one PlayImportService#preferred_listing picks. Zealot's per-language
# translations (Z-P21) are a separate feature; importing one language into the app is the honest scope here.
#
# Track state is shown for reference only. It is not staged, because Zealot models releases and channels,
# not Play tracks; wiring a track into that model is a separate change.
class Apps::PlayImportsController < ApplicationController
  include AppArchived

  # The App columns this page can stage from Play, and the Play listing field each is read from.
  IMPORTABLE = {
    'name' => :title,
    'short_description' => :short_description,
    'description' => :full_description
  }.freeze

  before_action :authenticate_user!
  before_action :set_app
  before_action -> { set_app_breadcrumbs(app: @app) }

  # GET /apps/:app_id/play_import
  def show
    authorize ListingEdit.new(app: @app), :show?
    load_page
  end

  # POST /apps/:app_id/play_import
  def create
    authorize ListingEdit.new(app: @app), :update?
    raise_if_app_archived!(@app)

    load_page
    return render :show, status: :unprocessable_entity unless @result.ok?

    listing = @result.listings.find { |l| l.language == @language } || @result.preferred_listing
    return redirect_to(app_play_import_path(@app), alert: t('.nothing')) if listing.nil?

    changes, reverts = split_changes(listing)
    return redirect_to(app_play_import_path(@app), notice: t('.unchanged')) if changes.empty? && reverts.empty?

    service = ListingEditService.new(app: @app, editor: current_user)
    if changes.any?
      draft = service.stage(changes)
      return refuse(changes, draft.errors.map(&:message)) if draft.errors.any?
    end
    service.unstage(*reverts) if reverts.any?

    adopt_package_name
    redirect_to app_listing_text_path(@app), notice: t('.staged')
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  # Reads Play and picks the listing to show. Safe to call twice (once in `show`, again in `create`): it
  # returns the same Result both times and writes nothing.
  def load_page
    @language = params[:locale].to_s.strip.presence || 'en-US'
    @result = Anthropic::PlayImportService.new.fetch(@app.play_package_name)
    @tracks = @result.tracks || []
    @listing = @result.listings&.find { |l| l.language == @language } || @result.preferred_listing
    @values = @listing ? @listing.to_h.stringify_keys.slice(*IMPORTABLE.values.map(&:to_s)) : {}
    @title = t('apps.play_imports.show.title')
  end

  # Splits the Play listing into App fields that differ from the live app (to stage) and those that equal it
  # (to drop from the draft if staged), tidying each the way `App` will store it -- exactly as the listing
  # editor does, so the same values compare, stage and preview identically.
  def split_changes(listing)
    changes = {}
    reverts = []
    IMPORTABLE.each do |field, play_key|
      value = tidy_value(field, listing.public_send(play_key))
      next if field == 'name' && value.blank?

      if value == tidy_value(field, @app[field])
        reverts << field
      else
        changes[field] = value
      end
    end
    [ changes, reverts ]
  end

  def tidy_value(field, value)
    case field
    when 'description' then ListingText.tidy_description(value)
    when 'short_description' then ListingText.tidy_short_description(value)
    else value.to_s.strip.presence
    end
  end

  # The import is the app's real Play listing, so record the package name it came from when the app does not
  # have one yet. Only fills a blank -- never overwrites a package name the owner already set.
  def adopt_package_name
    return if @app.play_package_name.present? || @result.package_name.blank?

    @app.adopt_play_package_name!(@result.package_name)
  end

  def refuse(changes, messages)
    @staged = changes.keys
    flash.now[:alert] = t('.refused', reasons: messages.to_sentence)
    render :show, status: :unprocessable_entity
  end
end
