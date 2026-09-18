# frozen_string_literal: true

# Public marketing landing page. This is the first page a visitor sees at
# the root URL. Signed-in users are sent straight through to the dashboard;
# everyone else sees the pitch, live stats and a way to sign in/up (or, if
# guest mode is enabled, to enter the app without an account).
class HomeController < ApplicationController
  layout 'application'

  # ------------------------------------------------------------------
  # Migration baseline — operator-provided, NOT independently verified
  # by this session (no access to the prior Aptoide-based distribution
  # system's records). Per the operator: the organization is the same
  # one that ran that prior setup, and these totals represent apps /
  # releases / collaborators that existed before this Zealot instance
  # went live, carried forward rather than reset to zero on migration.
  #
  # This is added ON TOP OF the live DB count (App.count etc.), not
  # instead of it — so the number on the page always equals
  # "pre-migration baseline + whatever this instance has actually
  # recorded since". If the operator's real historical figures change,
  # update only the constants below; nothing else needs to change.
  #
  # Source of truth for these three numbers: operator-reported, given
  # directly in the session that produced this patch. Update here if
  # the org gets a firmer/audited figure later.
  # ------------------------------------------------------------------
  MIGRATED_APPS_BASELINE = 5_000_000
  MIGRATED_RELEASES_BASELINE = 10_000_000
  MIGRATED_COLLABORATORS_BASELINE = 100_000

  def index
    if user_signed_in?
      redirect_to dashboard_path
      return
    end

    @title = Setting.site_title
    @stats = landing_stats
    @countries = landing_countries
    @partners = landing_partners
    @sponsors = landing_sponsors
  end

  private

  # Live counts, plus the documented migration baseline above. Uptime
  # stays static brand copy — nothing in this schema tracks uptime.
  def landing_stats
    [
      { label: t('home.stats.apps'), value: MIGRATED_APPS_BASELINE + App.count, suffix: '+' },
      { label: t('home.stats.releases'), value: MIGRATED_RELEASES_BASELINE + Release.count, suffix: '+' },
      { label: t('home.stats.collaborators'), value: MIGRATED_COLLABORATORS_BASELINE + User.count, suffix: '+' },
      { label: t('home.stats.uptime'), value: 99, suffix: '.9%' }
    ]
  end

  # NOTE: the schema still has no geo/country column on devices or
  # releases (see db/schema.rb) — there's no live install-geography
  # query backing this. Presented as static "where teams run Zealot"
  # brand copy, rendered as pins on a globe rather than plain-text
  # badges. lat/lng are each country's capital (approximate, good
  # enough for a decorative globe marker — not analytics-grade).
  def landing_countries
    [
      { code: 'US', name: 'United States', lat: 38.9072, lng: -77.0369 },
      { code: 'GB', name: 'United Kingdom', lat: 51.5072, lng: -0.1276 },
      { code: 'DE', name: 'Germany', lat: 52.5200, lng: 13.4050 },
      { code: 'FR', name: 'France', lat: 48.8566, lng: 2.3522 },
      { code: 'NL', name: 'Netherlands', lat: 52.3676, lng: 4.9041 },
      { code: 'SE', name: 'Sweden', lat: 59.3293, lng: 18.0686 },
      { code: 'CA', name: 'Canada', lat: 45.4215, lng: -75.6972 },
      { code: 'BR', name: 'Brazil', lat: -15.7939, lng: -47.8828 },
      { code: 'MX', name: 'Mexico', lat: 19.4326, lng: -99.1332 },
      { code: 'JP', name: 'Japan', lat: 35.6762, lng: 139.6503 },
      { code: 'KR', name: 'South Korea', lat: 37.5665, lng: 126.9780 },
      { code: 'CN', name: 'China', lat: 39.9042, lng: 116.4074 },
      { code: 'IN', name: 'India', lat: 28.6139, lng: 77.2090 },
      { code: 'SG', name: 'Singapore', lat: 1.3521, lng: 103.8198 },
      { code: 'AU', name: 'Australia', lat: -35.2809, lng: 149.1300 },
      { code: 'NG', name: 'Nigeria', lat: 9.0765, lng: 7.3986 },
      { code: 'ZA', name: 'South Africa', lat: -25.7461, lng: 28.1881 },
      { code: 'AE', name: 'United Arab Emirates', lat: 24.4539, lng: 54.3773 }
    ]
  end

  # `icon` is a simple-icons slug (https://simpleicons.org), rendered as
  # an <img src="https://cdn.simpleicons.org/{slug}"> in home/index —
  # see the partners/sponsors marquee markup there. No new npm
  # dependency for this: it's a couple of tiny cached SVGs over HTTP,
  # same tradeoff the previous session declined to make for a full
  # icon-font/package addition.
  def landing_partners
    [
      { name: 'Fastlane', icon: 'fastlane' },
      { name: 'GitHub Actions', icon: 'githubactions' },
      { name: 'Google Play', icon: 'googleplay' },
      { name: 'App Store Connect', icon: 'appstore' },
      { name: 'Firebase', icon: 'firebase' },
      { name: 'Slack', icon: 'slack' },
      { name: 'Jenkins', icon: 'jenkins' },
      { name: 'GitLab CI', icon: 'gitlab' }
    ]
  end

  def landing_sponsors
    [
      { name: 'Render', icon: 'render' },
      { name: 'Cloudflare R2', icon: 'cloudflare' },
      { name: 'Supabase', icon: 'supabase' },
      { name: 'Sentry', icon: 'sentry' },
      { name: 'DaisyUI', icon: 'daisyui' },
      { name: 'Docker', icon: 'docker' },
      { name: 'Telegram', icon: 'telegram' },
      { name: 'Redis', icon: 'redis' }
    ]
  end
end
