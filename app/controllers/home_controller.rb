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
  # releases that existed before this Zealot instance went live,
  # carried forward rather than reset to zero on migration.
  #
  # This is added ON TOP OF the live DB count (App.count etc.), not
  # instead of it — so the number on the page always equals
  # "pre-migration baseline + whatever this instance has actually
  # recorded since". If the operator's real historical figures change,
  # update only the constants below; nothing else needs to change.
  #
  # Source of truth for these numbers: operator-reported, given
  # directly in the session that produced this patch. Update here if
  # the org gets a firmer/audited figure later.
  # ------------------------------------------------------------------
  MIGRATED_APPS_BASELINE = 5_000_000
  MIGRATED_RELEASES_BASELINE = 10_000_000

  def index
    if user_signed_in?
      redirect_to dashboard_path
      return
    end

    @title = Setting.site_title
    @stats = landing_stats
    @countries = landing_countries
    @lights = landing_lights
    @partners = landing_partners
    @sponsors = landing_sponsors
  end

  private

  # Live counts, plus the documented migration baseline above. Uptime
  # stays static brand copy — nothing in this schema tracks uptime.
  #
  # `compact: true` stats are rendered/animated as "5M+" style shorthand
  # once they reach the millions (see HomeHelper#compact_count and
  # counter_controller.js) instead of a long run of digits.
  def landing_stats
    [
      { label: t('home.stats.apps'), value: MIGRATED_APPS_BASELINE + App.count, compact: true },
      { label: t('home.stats.releases'), value: MIGRATED_RELEASES_BASELINE + Release.count, compact: true },
      { label: t('home.stats.uptime'), value: 99, suffix: '.9%' }
    ]
  end

  # NOTE: the schema still has no geo/country column on devices or
  # releases (see db/schema.rb) — there's no live install-geography
  # query backing this. Presented as static "where teams run Zealot"
  # brand copy, rendered as pins on a globe rather than plain-text
  # badges. lat/lng are each country's capital (approximate, good
  # enough for a decorative globe marker — not analytics-grade).
  #
  # Task 14g: grew this from the original 18 to 48 (see handover.md's
  # "14g detail" for the full candidate list and the D6/D7 defaults this
  # was built on). 48 was the suggested ceiling ("go past it only after
  # seeing it on a phone"), so the 6 lowest-priority candidates
  # (Czechia, Greece, Belgium, Kazakhstan, Qatar, Senegal) were cut to
  # land exactly on it rather than over it, since nobody has looked at
  # this on a phone yet — add them back first if there's headroom.
  # Taiwan, Russia, Israel and Ukraine stay out per D6 (flagged as
  # geopolitically sensitive, left for the operator to decide).
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
      { code: 'AE', name: 'United Arab Emirates', lat: 24.4539, lng: 54.3773 },
      # --- Task 14g additions below (18 -> 48) ---
      # Africa
      { code: 'EG', name: 'Egypt', lat: 30.0444, lng: 31.2357 },
      { code: 'KE', name: 'Kenya', lat: -1.2921, lng: 36.8219 },
      { code: 'GH', name: 'Ghana', lat: 5.6037, lng: -0.1870 },
      { code: 'ET', name: 'Ethiopia', lat: 9.0320, lng: 38.7469 },
      { code: 'MA', name: 'Morocco', lat: 34.0209, lng: -6.8416 },
      { code: 'TZ', name: 'Tanzania', lat: 6.1630, lng: 35.7516 },
      # Middle East
      { code: 'SA', name: 'Saudi Arabia', lat: 24.7136, lng: 46.6753 },
      { code: 'TR', name: 'Türkiye', lat: 39.9334, lng: 32.8597 },
      # Asia
      { code: 'ID', name: 'Indonesia', lat: -6.2088, lng: 106.8456 },
      { code: 'TH', name: 'Thailand', lat: 13.7563, lng: 100.5018 },
      { code: 'VN', name: 'Vietnam', lat: 21.0285, lng: 105.8542 },
      { code: 'PH', name: 'Philippines', lat: 14.5995, lng: 120.9842 },
      { code: 'MY', name: 'Malaysia', lat: 3.1390, lng: 101.6869 },
      { code: 'PK', name: 'Pakistan', lat: 33.6844, lng: 73.0479 },
      { code: 'BD', name: 'Bangladesh', lat: 23.8103, lng: 90.4125 },
      # Europe
      { code: 'ES', name: 'Spain', lat: 40.4168, lng: -3.7038 },
      { code: 'IT', name: 'Italy', lat: 41.9028, lng: 12.4964 },
      { code: 'PL', name: 'Poland', lat: 52.2297, lng: 21.0122 },
      { code: 'CH', name: 'Switzerland', lat: 46.9480, lng: 7.4474 },
      { code: 'IE', name: 'Ireland', lat: 53.3498, lng: -6.2603 },
      { code: 'PT', name: 'Portugal', lat: 38.7223, lng: -9.1393 },
      { code: 'NO', name: 'Norway', lat: 59.9139, lng: 10.7522 },
      { code: 'DK', name: 'Denmark', lat: 55.6761, lng: 12.5683 },
      { code: 'FI', name: 'Finland', lat: 60.1699, lng: 24.9384 },
      { code: 'AT', name: 'Austria', lat: 48.2082, lng: 16.3738 },
      # Americas
      { code: 'AR', name: 'Argentina', lat: -34.6037, lng: -58.3816 },
      { code: 'CO', name: 'Colombia', lat: 4.7110, lng: -74.0721 },
      { code: 'PE', name: 'Peru', lat: -12.0464, lng: -77.0428 },
      { code: 'CL', name: 'Chile', lat: -33.4489, lng: -70.6693 },
      # Oceania
      { code: 'NZ', name: 'New Zealand', lat: -41.2865, lng: 174.7762 }
    ]
  end

  # Decorative "constellation" hubs — major metro areas plotted as small
  # glowing dots on the globe and joined to their nearest neighbours by
  # faint arcs (see globe_controller.js). Like the country pins above
  # this is brand imagery, not analytics: nothing here is backed by real
  # install geography. lat/lng are approximate city centres.
  def landing_lights
    [
      [40.7128, -74.0060], [34.0522, -118.2437], [37.7749, -122.4194], [41.8781, -87.6298],
      [43.6532, -79.3832], [29.7604, -95.3698], [25.7617, -80.1918], [19.4326, -99.1332],
      [4.7110, -74.0721], [-12.0464, -77.0428], [-23.5505, -46.6333], [-34.6037, -58.3816],
      [51.5072, -0.1276], [48.8566, 2.3522], [52.5200, 13.4050], [40.4168, -3.7038],
      [41.9028, 12.4964], [59.3293, 18.0686], [55.7558, 37.6173], [41.0082, 28.9784],
      [30.0444, 31.2357], [6.5244, 3.3792], [-1.2921, 36.8219], [-26.2041, 28.0473],
      [-33.9249, 18.4241], [25.2048, 55.2708], [24.7136, 46.6753], [19.0760, 72.8777],
      [12.9716, 77.5946], [28.6139, 77.2090], [13.7563, 100.5018], [1.3521, 103.8198],
      [-6.2088, 106.8456], [22.3193, 114.1694], [31.2304, 121.4737], [39.9042, 116.4074],
      [37.5665, 126.9780], [35.6762, 139.6503], [-33.8688, 151.2093], [-37.8136, 144.9631],
      [-36.8485, 174.7633], [9.0765, 7.3986]
    ].map { |lat, lng| { lat: lat, lng: lng } }
  end

  # `icon` is a simple-icons slug (https://simpleicons.org — check it still exists
  # there before adding one; e.g. `slack` was removed upstream), rendered as
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
      { name: 'CircleCI', icon: 'circleci' },
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
