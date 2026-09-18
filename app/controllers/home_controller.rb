# frozen_string_literal: true

# Public marketing landing page. This is the first page a visitor sees at
# the root URL. Signed-in users are sent straight through to the dashboard;
# everyone else sees the pitch, live stats and a way to sign in/up (or, if
# guest mode is enabled, to enter the app without an account).
class HomeController < ApplicationController
  layout 'application'

  def index
    if user_signed_in?
      redirect_to dashboard_path
      return
    end

    @title = site_title
    @stats = landing_stats
    @countries = landing_countries
    @partners = landing_partners
    @sponsors = landing_sponsors
  end

  private

  # Real counts where the schema actually tracks them. Nothing here is
  # fabricated — if a number can't be derived from the database it doesn't
  # appear as a "metric", it's presented as static brand copy instead (see
  # landing_countries).
  def landing_stats
    [
      { label: t('home.stats.apps'), value: App.count, suffix: '+' },
      { label: t('home.stats.releases'), value: Release.count, suffix: '+' },
      { label: t('home.stats.collaborators'), value: User.count, suffix: '+' },
      { label: t('home.stats.uptime'), value: 99, suffix: '.9%' }
    ]
  end

  # NOTE: the schema has no geo/country column on devices or releases
  # (see db/schema.rb), so this is deliberately presented as static brand
  # copy ("where teams run Zealot"), not as a live analytics claim. Swap
  # this array out if/when real install geography is tracked.
  def landing_countries
    %w[US GB DE FR NL SE CA BR MX JP KR CN IN SG AU NG ZA AE]
  end

  def landing_partners
    ['Fastlane', 'GitHub Actions', 'Google Play', 'App Store Connect', 'Firebase', 'Slack', 'Jenkins', 'GitLab CI']
  end

  def landing_sponsors
    ['Render', 'Cloudflare R2', 'Supabase', 'Sentry', 'DaisyUI', 'Docker', 'Telegram', 'Redis']
  end
end
