# frozen_string_literal: true

# Z-P23 (Play Console parity, docs/PARITY-KANBAN.md): the console as an installable web app.
#
# Play Console has a mobile app; this is the honest web equivalent — a Web App Manifest plus a
# service worker, so a browser offers "Install" / "Add to Home Screen" and the console opens in its own
# window. It is the whole of the card: no Bubblewrap TWA (that needs a signing key and a Play listing,
# which is a separate decision, Z-P24). The manifest is built from Settings at request time so the
# name and theme match this deployment; the service worker caches the app shell only.
class PwaController < ApplicationController
  # The manifest is fetched by a browser before any session exists, and a service worker is fetched
  # outside the page's own session; neither may be blocked by authentication.
  skip_before_action :verify_authenticity_token, raise: false

  # One hour: the values behind it change with Settings, so it cannot be long-lived, but a browser
  # re-reads the manifest on every visit and this spares the render.
  MANIFEST_MAX_AGE = 1.hour

  def manifest
    expires_in MANIFEST_MAX_AGE, public: true
    render template: 'pwa/manifest', formats: [:json], content_type: 'application/manifest+json'
  end

  def service_worker
    expires_in MANIFEST_MAX_AGE, public: true
    render template: 'pwa/service_worker', formats: [:js],
           content_type: 'application/javascript'
  end
end
