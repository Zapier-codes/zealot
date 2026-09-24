# frozen_string_literal: true

require 'digest'
require 'time'

module CatalogIndex
  # Task 27a: catalog index v1 -- the schema Zealot publishes and D-Store
  # (Zapier-codes/D-store) reads, replacing the earlier idea of Zealot
  # writing fields directly into D-Store's Supabase (handover.md's Task 26
  # correction; Task 27 decisions 1 and 3).
  #
  # This class only SERIALIZES an app's current state into the v1 shape --
  # it doesn't sign, publish, or persist anything. That's 27b (atomic
  # publish, index-signing key, strictly increasing timestamp) and 27c
  # (regenerate on go_live!/suspend/listing edit/new release).
  #
  # Schema lives in three places kept in sync: this class, the written
  # explanation in docs/catalog_index_v1.md, and the machine-checkable
  # docs/catalog_index_v1.schema.json.
  #
  # Deliberately duck-typed rather than `App`/`Release`-typed: it only
  # calls the methods listed in docs/catalog_index_v1.md's "Inputs"
  # section, so a plain Struct fixture works as well as a real
  # ActiveRecord instance (see the spec, and this session's standalone
  # verification harness noted in handover.md -- no Rails boot available
  # in this sandbox to run the real request/model specs, same limitation
  # every other "code-complete, not run" item on this board carries).
  class Serializer
    SCHEMA_VERSION = 1

    # apps: an app, or an enumerable of apps. Production code should pass
    # `App.listing_live` (see .for_live_apps) -- an app not live on our
    # store has no business in a public catalog D-Store reads. The
    # serializer itself takes whatever it's given; scoping is the caller's
    # job, not this class's, so fixtures/specs can hand it anything.
    def self.call(apps, generated_at: Time.now.utc)
      new(apps, generated_at: generated_at).call
    end

    def self.for_live_apps(generated_at: Time.now.utc)
      call(App.listing_live, generated_at: generated_at)
    end

    def initialize(apps, generated_at:)
      # NOT `Array(apps)`: a single duck-typed "app" can itself be
      # Enumerable (a Struct fixture is, as of modern Ruby -- confirmed the
      # hard way, see the harness in handover.md's Task 27a notes) and
      # `Array()` would then explode it into its member values instead of
      # wrapping it. Check for the app interface directly instead of
      # guessing from Enumerable-ness.
      @apps = apps.respond_to?(:play_package_name) ? [ apps ] : apps.to_a
      @generated_at = generated_at
    end

    def call
      {
        schema_version: SCHEMA_VERSION,
        generated_at: @generated_at.utc.iso8601,
        apps: @apps.map { |app| serialize_app(app) },
      }
    end

    private

    def serialize_app(app)
      {
        id: app.id,
        package_name: app.play_package_name,
        listing_status: app.listing_status,
        publisher: {
          name: app.publisher_display_name,
          # No KYB/company verification exists yet (Task 27 ❓1 area) --
          # always false until that lands, not computed from anything.
          verified: false,
        },
        listing: {
          title: app.name,
          description: nil,                # reserved for 27e (store-listing editor)
          icon: { url: nil, sha256: nil },  # reserved for 27d (icon/screenshot pipeline)
          screenshots: [],                  # reserved for 27d
        },
        latest_version: serialize_latest_version(app),
      }
    end

    # v1's release-selection rule is deliberately the simplest one that
    # already exists in the codebase (App#recently_release, used elsewhere
    # for "the app's latest build") rather than new selection logic --
    # nil when the app has no releases at all. A more deliberate "which
    # release is the public store version" concept (e.g. only
    # Play-published, or an explicit pin) is left to 27c/27e; this is a
    # known v1 simplification, not an oversight.
    def serialize_latest_version(app)
      release = app.recently_release
      return nil if release.nil?

      {
        release_id: release.id,
        version_name: release.release_version,
        version_code: release.build_version,
        # Zealot's own stable endpoint -- never a signed storage URL
        # directly (those expire; see Task 26 correction ❓ on D-Store's
        # Download button).
        download_url: release.download_url,
        sha256: sha256_for(release),
        size_bytes: release.original_size || local_file_size(release),
        # Set only for org-signed builds delivered through
        # AnthropicAssetDeliveryJob (see AndroidSigningKey); nil otherwise.
        signing_fingerprint: release.signing_key_checksum,
      }
    end

    # Task 27b-i closed the gap this method used to carry alone: as of that
    # slice, ReleaseFileMirrorJob persists file_sha256 once, while the
    # local file is guaranteed to still be there, so most releases now
    # have a real hash regardless of whether the local file has since been
    # wiped. `respond_to?` keeps this duck-typed like the rest of the
    # class -- a fixture/Struct without the column still works, it just
    # exercises the fallback path below. The fallback itself stays: a
    # release created before this migration (or one ReleaseFileMirrorJob
    # hasn't reached yet -- see .backfill) has no persisted hash and, per
    # Task 19's mirror-then-wipe, may or may not still have a local file;
    # `null` is still the honest answer once both are unavailable.
    def sha256_for(release)
      return release.file_sha256 if release.respond_to?(:file_sha256) && release.file_sha256.present?

      path = local_file_path(release)
      return nil unless path && File.exist?(path)

      Digest::SHA256.file(path).hexdigest
    end

    def local_file_size(release)
      path = local_file_path(release)
      path && File.exist?(path) ? File.size(path) : nil
    end

    def local_file_path(release)
      release.file&.path
    end
  end
end
