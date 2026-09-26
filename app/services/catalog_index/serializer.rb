# frozen_string_literal: true

require 'digest'
require 'time'

module CatalogIndex
  # Task 29b: catalog index v2 -- see docs/catalog_index_v2.md and
  # docs/catalog_index_v2.schema.json, which this class is kept in sync
  # with by hand (all three are updated together, per the schema doc's own
  # note). Supersedes the v1 shape this class used to emit (that code is in
  # git history, not duplicated here -- nothing ever consumed v1 in
  # production; see Task 29's board entry).
  #
  # Scope of this slice, deliberately: fill in every v2 field the current
  # data model can actually answer, and leave every field a later slice owns
  # (27f's version status, 31a's editorial/sponsored/collections, 30's
  # staged listing edits) at its documented reserved default -- null, empty
  # array/object, or false. Nothing here invents data that doesn't exist.
  #
  # 29c later filled in `compatibility` (see #compatibility_for below) --
  # this comment block is 29b's original scope note, left as history rather
  # than rewritten, since 27f/31a/30 are still genuinely open.
  #
  # Two things this slice deliberately does NOT do, both flagged in
  # handover.md's Task 29 entry rather than silently expanded into: it does
  # not wire a real strictly-increasing `sequence` (Signer/CatalogIndexSigningKey
  # own the counter that would make that meaningful, same way they already
  # own `generated_at`'s rollback protection -- passed through here as a
  # keyword the caller supplies, defaulting to 0 so existing callers keep
  # working); and it does not persist `slug` anywhere -- the schema requires
  # a non-null slug per app (unlike the other v2 additions, `null` is not a
  # valid value), so this slice derives one deterministically from the
  # app's name until Task 30's write-side machinery generates and freezes a
  # real one per "The slug rule" in the v2 doc. Both are called out again at
  # the bottom of this file.
  class Serializer
    SCHEMA_VERSION = 2

    # Matches docs/catalog_index_v2.md's "Category vocabulary" list and the
    # schema's `category` enum exactly. Not used to validate an app's
    # category here (nothing sets one yet -- see CATEGORY_ATTRIBUTE below);
    # kept alongside the schema as the one other place this vocabulary is
    # written down, same convention as CatalogIndex::Serializer::SCHEMA_VERSION
    # tracking catalog_index_v2.schema.json's `schema_version` const.
    CATEGORIES = %w[
      system multimedia games internet navigation science-education
      theming time reading writing development finance
    ].freeze

    # Freshness bound for `expires_at` when the caller doesn't supply one.
    # Arbitrary and undecided for real (not one of Task 29's two recorded
    # ❓s, but should be treated as a third): a signed index that isn't
    # re-published inside this window is, per the v2 schema, something a
    # reader should refuse. 24h matches "publish on every listing change,
    # worst case once a day even with no changes" -- revisit once 27c wires
    # actual publish triggers and this can be measured against real
    # publish frequency instead of guessed.
    DEFAULT_TTL = 24 * 60 * 60 # seconds; avoids a hard ActiveSupport::Duration dependency here

    # apps: an app, or an enumerable of apps. Production code should pass
    # `App.listing_live` (see .for_live_apps) -- an app not live on our
    # store has no business in a public catalog D-Store reads. The
    # serializer itself takes whatever it's given; scoping is the caller's
    # job, not this class's, so fixtures/specs can hand it anything.
    #
    # sequence/expires_at: kept as plain keyword args, not computed here --
    # see the class comment above on why wiring the real counter is out of
    # this slice's scope. A caller that doesn't pass them gets a schema-valid
    # but not-yet-meaningful sequence (always 0) and a DEFAULT_TTL-out
    # expires_at, same "reserved, not invented" spirit as the per-app fields.
    def self.call(apps, generated_at: Time.now.utc, sequence: 0, expires_at: nil)
      new(apps, generated_at: generated_at, sequence: sequence, expires_at: expires_at).call
    end

    def self.for_live_apps(generated_at: Time.now.utc, sequence: 0, expires_at: nil)
      call(App.listing_live, generated_at: generated_at, sequence: sequence, expires_at: expires_at)
    end

    def initialize(apps, generated_at:, sequence:, expires_at:)
      # NOT `Array(apps)`: a single duck-typed "app" can itself be
      # Enumerable (a Struct fixture is, as of modern Ruby) and `Array()`
      # would then explode it into its member values instead of wrapping
      # it. Check for the app interface directly instead of guessing from
      # Enumerable-ness.
      @apps = apps.respond_to?(:play_package_name) ? [ apps ] : apps.to_a
      @generated_at = generated_at
      @sequence = sequence
      @expires_at = expires_at || (@generated_at + DEFAULT_TTL)
    end

    def call
      {
        schema_version: SCHEMA_VERSION,
        generated_at: @generated_at.utc.iso8601,
        sequence: @sequence,
        expires_at: @expires_at.utc.iso8601,
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
          bio: nil,          # reserved -- no developer-profile UI yet
          profile_url: nil,  # reserved
          joined_at: nil,    # reserved -- App/User's created_at once wired up
        },
        listing: {
          title: app.name,
          description: nil,                # reserved for 27e (store-listing editor)
          icon: { url: nil, sha256: nil },  # reserved for 27d (icon/screenshot pipeline)
          screenshots: [],                  # reserved for 27d
          content_rating: nil,              # reserved -- vocabulary not decided
          data_safety: {
            collects_data: nil,
            data_types: [],
            shared_with_third_parties: nil,
            encrypted_in_transit: nil,
            deletion_request_url: nil,
          },
          contains_ads: nil,
          has_in_app_purchases: nil,
        },
        slug: slug_for(app),
        summary: nil,     # reserved -- no summary column yet
        category: nil,    # reserved -- no category column yet; see CATEGORIES
        license: nil,     # reserved
        links: { site: nil, source: nil, tracker: nil, donate: nil }, # reserved
        available_regions: nil, # nil = all regions; reserved until an owner/org default exists
        created_at: iso(app.created_at),
        updated_at: iso(app.updated_at),
        editorial: { featured: false, editors_pick: false }, # reserved for 31a
        sponsored_slots: [],                                 # reserved for 31a
        collections: [],                                     # reserved for 31a
        versions: releases_for(app).map { |release| serialize_version(release) },
      }
    end

    # `slug` is the one v2 field the schema does not allow to come back
    # null (unlike everything else reserved for a later slice), so this
    # derives a deterministic, schema-valid value from the app's name --
    # lowercased, non-alphanumerics collapsed to single hyphens, no
    # leading/trailing hyphen -- falling back to `app-<id>` for a name that
    # has no alphanumeric characters at all. This is NOT the real slug the
    # v2 doc's "The slug rule" describes (generated once at first go-live,
    # frozen forever, collision-checked at generation time): it is
    # recomputed from current app state on every call, so it changes if the
    # app is renamed. Task 30's listing-edit machinery is what needs to
    # replace this with a persisted, truly immutable value -- tracked in
    # handover.md's Task 29 entry as a correction to file alongside this
    # patch, not silently left implicit here.
    def slug_for(app)
      base = app.name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
      base.empty? ? "app-#{app.id}" : base
    end

    # Duck-typed like the rest of this class: an ActiveRecord App answers
    # `catalog_releases` (added alongside this slice, all releases newest
    # first); a Struct fixture built for the old v1 spec shape that only
    # knows `recently_release` still works, just with a single-element
    # versions[] instead of the full history. Anything answering neither
    # gets an empty versions[] rather than raising.
    def releases_for(app)
      if app.respond_to?(:catalog_releases)
        Array(app.catalog_releases)
      elsif app.respond_to?(:recently_release)
        [ app.recently_release ].compact
      else
        []
      end
    end

    def serialize_version(release)
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
        changelog: text_changelog_for(release),
        released_at: iso(release.created_at),
        # No `status` column exists yet (27f owns halt/pull transitions) --
        # "available" is the honest current state of every release that
        # exists today, not an invented value: nothing can currently mark
        # one halted or pulled, so every release the serializer sees is, by
        # definition, available. 27f replaces this with the real column.
        status: 'available',
        compatibility: compatibility_for(release),
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

    def iso(timestamp)
      timestamp&.utc&.iso8601
    end

    # Task 29c fills these columns in for Android releases at upload time
    # (see app/models/concerns/release_parser.rb); every other case --
    # non-Android releases, and any release uploaded before this migration
    # or before 29c shipped -- simply has them at their column defaults
    # (nil/[]), which is exactly the "empty, not invented" value 29a/29b
    # already documented and shipped for this block. `respond_to?` keeps
    # this duck-typed like the rest of the class, so the old v1-style
    # Struct fixtures (with none of these columns) still produce a
    # schema-valid, all-empty compatibility block instead of raising.
    def compatibility_for(release)
      {
        min_sdk: release.respond_to?(:min_sdk_version) ? release.min_sdk_version : nil,
        target_sdk: release.respond_to?(:target_sdk_version) ? release.target_sdk_version : nil,
        abis: release.respond_to?(:abis) ? Array(release.abis) : [],
        screen_densities: release.respond_to?(:screen_densities) ? Array(release.screen_densities) : [],
        required_features: release.respond_to?(:required_features) ? Array(release.required_features) : [],
        permissions: release.respond_to?(:permissions) ? Array(release.permissions) : [],
      }
    end

    # `Release#changelog` is jsonb internally -- an array of `{'message' =>
    # ...}` hashes, never a plain string (see `Release#convert_changelog`).
    # `#text_changelog(default_template: false)` is this codebase's own
    # existing helper for rendering that as a joined `"- message"` string
    # (already used by the release-deployed email and the release detail
    # page) -- reused here rather than duplicating that formatting, and
    # `default_template: false` specifically so an empty changelog comes
    # back as `""`/`nil`, not Zealot's own "no changelog was given"
    # placeholder text stacked underneath D-store's separate "No changelog
    # provided." fallback for the exact same case.
    #
    # This was originally `release.changelog` (the raw jsonb) with a v2
    # schema comment saying its "shape not constrained further"; fixed
    # here after cross-repo review (Task 29d) found D-store's reader
    # already committed to reading this field as a plain string and
    # calling `.trim()` on it directly -- the raw jsonb would have thrown
    # at runtime the first time a real release had a changelog entry.
    def text_changelog_for(release)
      return nil unless release.respond_to?(:text_changelog)

      release.text_changelog(default_template: false).presence
    end
  end
end
