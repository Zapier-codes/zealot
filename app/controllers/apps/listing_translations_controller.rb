# frozen_string_literal: true

# Z-P21 (Play Console parity): the "Translations" page for an app's store listing. An owner picks target
# locales, machine-translates the listing's free text into them, reviews each result and approves or
# discards it. Only approved, non-stale translations are published in the signed catalog index
# (`CatalogIndex::Serializer#translations_for`), so a machine result never reaches a storefront unseen.
#
#   GET    /apps/:app_id/listing_translations            the table of stored translations
#   POST   /apps/:app_id/listing_translations/translate  machine-translate the chosen locales
#   POST   /apps/:app_id/listing_translations/:locale/review   approve one
#   DELETE /apps/:app_id/listing_translations/:locale          discard one
#
# Translation is off unless ZEALOT_TRANSLATE_URL is set; the page says so and the translate action refuses,
# the same "capability is opt-in" shape as the crash/vitals and analytics cards. Nothing is destroyed by a
# discard beyond the one stored entry, and no source text is ever overwritten.
class Apps::ListingTranslationsController < ApplicationController
  include AppArchived

  SOURCE_LOCALE = 'en'

  before_action :authenticate_user!
  before_action :set_app
  before_action -> { set_app_breadcrumbs(app: @app) }

  # GET /apps/:app_id/listing_translations
  def show
    authorize @app, :update?
    load_page
  end

  # POST /apps/:app_id/listing_translations/translate
  def translate
    authorize @app, :update?
    raise_if_app_archived!(@app)

    unless MachineTranslation.configured?
      return redirect_to(app_listing_translations_path(@app), alert: t('.disabled'))
    end

    locales = Array(params[:locales]).map(&:to_s).map(&:strip).reject(&:empty?)
    return redirect_to(app_listing_translations_path(@app), alert: t('.no_locales')) if locales.empty?

    result = MachineTranslation.new(@app, editor: current_user).translate!(locales: locales, source: SOURCE_LOCALE)
    redirect_to app_listing_translations_path(@app), flash_for(result)
  end

  # POST /apps/:app_id/listing_translations/:locale/review
  def review
    authorize @app, :update?
    raise_if_app_archived!(@app)

    if MachineTranslation.new(@app, editor: current_user).review!(params[:locale])
      redirect_to app_listing_translations_path(@app), notice: t('.approved', locale: params[:locale])
    else
      redirect_to app_listing_translations_path(@app), alert: t('.approve_failed', locale: params[:locale])
    end
  end

  # DELETE /apps/:app_id/listing_translations/:locale
  def destroy
    authorize @app, :update?
    raise_if_app_archived!(@app)

    if MachineTranslation.new(@app).discard!(params[:locale])
      redirect_to app_listing_translations_path(@app), notice: t('.discarded', locale: params[:locale])
    else
      redirect_to app_listing_translations_path(@app), alert: t('.missing', locale: params[:locale])
    end
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  def load_page
    raw = @app.listing_translations.is_a?(Hash) ? @app.listing_translations : {}
    @rows = raw.map do |locale, entry|
      entry = {} unless entry.is_a?(Hash)
      { locale: locale, entry: entry, stale: MachineTranslation.stale_entry?(@app, entry) }
    end.sort_by { |row| row[:locale] }
    @configured = MachineTranslation.configured?
    @source = { description: @app.description, short_description: @app.short_description }
    @locales = Array(params[:locales]).map(&:to_s)
    @title = t('apps.listing_translations.show.title')
  end

  # One flash summarising a batch: what translated, what failed. Never hides a failure.
  def flash_for(result)
    if result.failed.any?
      reasons = result.failed.map { |locale, message| "#{locale}: #{message}" }.to_sentence
      return { alert: t('apps.listing_translations.translate.failed', reasons: reasons) } if result.translated.empty?

      return { notice: t('apps.listing_translations.translate.partial',
                         locales: result.translated.to_sentence, reasons: reasons) }
    end
    return { notice: t('apps.listing_translations.translate.done', locales: result.translated.to_sentence) } if result.translated.any?

    { alert: t('apps.listing_translations.translate.none') }
  end
end
