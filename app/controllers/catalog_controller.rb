# frozen_string_literal: true

# Task 45g: serves the signed catalog index from Zealot's own host, so a reader (Storeapp) can use the Render
# address instead of the Pages repo:
#
#   GET /catalog/index.json      the exact bytes that were signed
#   GET /catalog/index.json.sig  the detached Ed25519 signature (base64 and a newline, as published to Pages)
#
# Public by definition (the same file is public on Pages): no login, no channel, no web hook, no counter. The
# bytes come from CatalogIndexSnapshot, written by CatalogIndex::Publish in the same step that commits to the
# Pages repo, and are sent untouched: a reader verifies the signature over the raw bytes. 404 until the first
# publish after this feature was deployed. Default tenant only. A short public cache keeps a busy store cheap;
# a reader that fetches the two files across a publish can see an index and a signature from different
# publishes, fails verification once and falls back to its last good copy (which every reader already does).
class CatalogController < ApplicationController
  def index
    serve(:index_json, 'application/json; charset=utf-8')
  end

  def signature
    serve(:signature, 'text/plain; charset=utf-8')
  end

  # Task 47d: GET /catalog/updates/:package_name -- the newest version of an app a device can install in place
  # (see CatalogUpdateLookup for every rule). Public and unauthenticated: it is what the injected updater
  # library calls, and it carries no device id or account. The answer is the same for every caller, so it is
  # cacheable; the request's query string is never read. 404 (empty body) for an unknown package, an app that
  # is not live, or one with nothing installable, so a library treats every 404 as "no update".
  def latest
    answer = CatalogUpdateLookup.call(params[:package_name])
    return head(:not_found) unless answer

    response.headers['Access-Control-Allow-Origin'] = '*'
    expires_in 5.minutes, public: true
    return unless stale?(etag: Digest::SHA256.hexdigest(answer.to_json), public: true)

    render json: answer
  end

  private

  def serve(column, content_type)
    snapshot = CatalogIndexSnapshot.for_tenant
    return head(:not_found) unless snapshot

    response.headers['Access-Control-Allow-Origin'] = '*'
    expires_in 1.minute, public: true
    return unless stale?(etag: [ snapshot.id, snapshot.updated_at.to_f ], public: true)

    send_data snapshot.public_send(column), type: content_type, disposition: 'inline'
  end
end
