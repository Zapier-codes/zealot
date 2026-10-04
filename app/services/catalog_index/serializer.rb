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
  # (27f's version status, 30's staged listing edits) at its documented
  # reserved default -- null, empty array/object, or false. Nothing here
  # invents data that doesn't exist.
  #
  # 29c later filled in `compatibility` (see #compatibility_for below); 31a
  # later filled in `editorial`/`sponsored_slots`/`collections` (see
  # #editorial_for/#sponsored_slots_for/#collection_slugs_for below, and the
  # new top-level #serialize_collections registry) -- this comment block is
  # 29b's original scope note, left as history rather than rewritten, since
  # 27f/30 are still genuinely open.
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

    # Resolves catalog_index_v2.md's open ❓1: full Play-parity categories
    # (App::APP_CATEGORIES/App::GAME_CATEGORIES), not the old 12-item
    # placeholder list this constant used to hardcode to match D-store's
    # categories. `App` is the single source of truth for the vocabulary
    # now that a real `category` column exists (see AddCategoryToApps);
    # this constant just mirrors it here so callers that want "the
    # published vocabulary" don't have to reach into `App` directly, same
    # convention as SCHEMA_VERSION tracking catalog_index_v2.schema.json's
    # `schema_version` const. Kept in sync with the schema's `category`
    # enum and catalog_index_v2.md's "Category vocabulary" section by hand,
    # same as the rest of this file.
    CATEGORIES = App::CATEGORY_VALUES

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
    #
    # editorial: Task 37b-iii-s4. `false` omits collections and sponsored slots altogether.
    #
    # tenant: Task 37b-iii-s6a. Whose collection registry this index carries (`Collection.for_tenant`):
    # nil is the default tenant's, exactly as before, and another tenant gets only its own collections,
    # with each app's `collections[]` slugs limited to that same registry so they always resolve.
    #
    # Sponsored slots (Task 37b-iii-s6b, operator-confirmed 3a): a slot has no tenant of its own. It
    # belongs to its app, the app belongs to one tenant, and this index only ever serializes that
    # tenant's apps, so each tenant's index carries exactly its own apps' slots with no extra scoping.
    # (s6a's `sponsored_slots:` override, which switched them off for a non-default tenant, is gone.)
    def self.call(apps, generated_at: Time.now.utc, sequence: 0, expires_at: nil, editorial: true, tenant: nil)
      new(apps, generated_at: generated_at, sequence: sequence, expires_at: expires_at, editorial: editorial,
                 tenant: tenant).call
    end

    # Task 37b-iii-s3: `tenant:` picks whose live apps go in (`App.for_tenant`; Task 38c widened that
    # to the tenant's subtree, `App.for_tenant_subtree`). With no tenant it
    # is the default tenant's catalog: the same apps as before tenants existed. Task 37b-iii-s6a: the
    # same tenant picks the collection registry, and the apps' own slots (s6b) come along with the apps.
    def self.for_live_apps(tenant: nil, generated_at: Time.now.utc, sequence: 0, expires_at: nil)
      apps = App.listing_live.for_tenant_subtree(tenant).includes(:listing_graphics) # Task 27d-e1: no N+1
      call(apps, generated_at: generated_at, sequence: sequence, expires_at: expires_at, tenant: tenant)
    end

    def initialize(apps, generated_at:, sequence:, expires_at:, editorial: true, tenant: nil)
      @editorial = editorial
      @tenant = tenant
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
        collections: @editorial ? serialize_collections : [],
      }
    end

    private

    def serialize_app(app)
      releases = releases_for(app)
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
          description: text_for(app, :description),     # Task 27e-a
          icon: icon_for(releases),         # Task 27d-c
          screenshots: graphics_for(app, 'screenshot'), # Task 27d-e1
          feature_graphic: feature_graphic_for(app),    # Task 27d-e1
          video: video_for(app),                        # Task 27d-e1
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
        summary: text_for(app, :short_description),   # Task 27e-b: the one-line short description (<= 80 characters)
        category: category_for(app),
        license: nil,     # reserved
        links: { site: nil, source: nil, tracker: nil, donate: nil }, # reserved
        available_regions: nil, # nil = all regions; reserved until an owner/org default exists
        created_at: iso(app.created_at),
        updated_at: iso(app.updated_at),
        editorial: editorial_for(app),
        sponsored_slots: @editorial ? sponsored_slots_for(app) : [],
        collections: @editorial ? collection_slugs_for(app) : [],
        suggested_version_code: suggested_version_code_for(releases), # Task 27f-c
        versions: releases.map { |release| serialize_version(release) },
      }
    end

    # Task 27f-c: the version a store client should offer, derived from what `versions[]` already says:
    # the highest `version_code` among the releases whose published status is `available`, or nil when
    # there is none. Halting or pulling the newest release therefore moves the suggestion to the previous
    # available one with no new data (a Play-style rollback). Compared as versions (`VersionCompare`),
    # never as strings, so "100" beats "99". A blank code is skipped. A code `Gem::Version` cannot parse
    # never beats one it can; if none parses, the newest available release's code is used (`releases`
    # arrives newest first). Between equal codes the first (newest) release is kept.
    def suggested_version_code_for(releases)
      codes = releases.select { |release| version_status_for(release) == 'available' }
                      .map { |release| release.respond_to?(:build_version) ? release.build_version.presence : nil }
                      .compact
      keyed = codes.filter_map { |code| (key = version_key(code)) && [ code, key ] }
      best = keyed.reduce { |kept, candidate| (candidate[1] <=> kept[1]) == 1 ? candidate : kept }
      best ? best[0] : codes.first
    end

    # A `Gem::Version` for a version code, through the same `semver` clean-up `VersionCompare` uses
    # everywhere else, or nil when it is not a version.
    def version_key(code)
      @version_compare ||= Object.new.extend(VersionCompare)
      Gem::Version.new(@version_compare.semver(code))
    rescue ArgumentError
      nil
    end

    # Task 27e-a / 27e-b: the store listing's free text. `nil` when the app has none (blank is stored as NULL,
    # see ListingText), never an empty string. Duck-typed like the rest of the class: a fixture without the
    # member reads as "no text" rather than raising.
    def text_for(app, member)
      app.respond_to?(member) ? app.public_send(member).presence : nil
    end

    # Real column as of AddCategoryToApps; duck-typed like the rest of this
    # class so an old Struct-based fixture without it still gets `nil`
    # (the same "not categorized yet" value a real app with no category set
    # would produce) instead of raising.
    def category_for(app)
      app.respond_to?(:category) ? app.category : nil
    end

    # Task 31a: real columns as of the editorial-flags migration --
    # `respond_to?` keeps this duck-typed like the rest of the class, so a
    # Struct fixture without them still gets the same all-false default the
    # hardcoded literal used to return, rather than raising.
    def editorial_for(app)
      {
        featured: app.respond_to?(:featured) ? !!app.featured : false,
        editors_pick: app.respond_to?(:editors_pick) ? !!app.editors_pick : false,
      }
    end

    # Task 31a: real `SponsoredSlot` rows once an app has any. Only
    # current-or-upcoming windows publish (see the model's own scope) --
    # an expired one has nothing left to tell a reader building today's
    # storefront, and dropping it here means no separate cleanup job is
    # needed. Chronological (soonest-to-start first), matching the shape
    # already documented in catalog_index_v2.md. `respond_to?` on the
    # association itself, not just the app, since a Struct fixture that
    # merely answers `respond_to?(:sponsored_slots)` would still blow up
    # calling Rails scope methods it doesn't implement.
    def sponsored_slots_for(app)
      return [] unless app.respond_to?(:sponsored_slots)

      app.sponsored_slots.current_or_upcoming.chronological.map do |slot|
        { starts_at: iso(slot.starts_at), ends_at: iso(slot.ends_at) }
      end
    end

    # Task 31a: the schema's per-app shape is an array of collection
    # *slugs* (see docs/catalog_index_v2.md), not the full Collection
    # object -- that's the separate top-level registry, #serialize_collections
    # below. Ordered the same way (`Collection.ordered` == by slug) so a
    # reader can join the two deterministically.
    def collection_slugs_for(app)
      return [] unless app.respond_to?(:collections)

      # Task 37b-iii-s6a: only collections of the index's own tenant, so every slug resolves against
      # the registry below. (CollectionApp refuses a cross-tenant membership; this is the read-side twin.)
      app.collections.for_tenant(@tenant).ordered.pluck(:slug)
    end

    # Task 31a: the new top-level registry the per-app `collections[]`
    # field (above) resolves against -- distinct from any single app's
    # membership list. Called directly rather than duck-typed: `Collection`
    # is a real, already-migrated ActiveRecord model as of this same slice,
    # and nothing before this slice ever populated or read it, so there is
    # no legacy fixture shape here to stay compatible with (unlike
    # `releases_for`, which predates this convention).
    def serialize_collections
      Collection.for_tenant(@tenant).ordered.map do |collection|
        {
          slug: collection.slug,
          name: collection.name,
          description: collection.description,
        }
      end
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

    # Task 27d-e1: the app's stored listing graphics (docs/store_listing_graphics.md). Only a graphic
    # that is both stored and hashed is advertised (`storage_key` and `sha256` present), the same rule
    # `icon_available?` applies: the URL is only listed when it serves bytes a reader can check. A row
    # from before 27d-d2's ingest, or one whose ingest failed half way, is simply left out.
    # Duck-typed like the rest of the class: a fixture that knows nothing about graphics gets the empty
    # value. Sorted in Ruby (not `.ordered`) so the `includes(:listing_graphics)` preload is used.
    def available_graphics(app, kind)
      return [] unless app.respond_to?(:listing_graphics)

      app.listing_graphics.select do |graphic|
        graphic.kind == kind && graphic.storage_key.present? && graphic.sha256.present?
      end.sort_by { |graphic| [ graphic.position.to_i, graphic.id.to_i ] }
    end

    # `screenshots[]`: phone screenshots in `position` order, `{url, sha256, alt, width, height}`. Phone
    # is the only device today (a check constraint says so); the filter is what keeps a future tablet
    # set out of this list rather than mixing it in, since the entry has no `device` key.
    def graphics_for(app, kind)
      available_graphics(app, kind).select { |graphic| graphic.device == 'phone' }.map do |graphic|
        { url: graphic.download_url, sha256: graphic.sha256, alt: graphic.alt_text,
          width: graphic.width, height: graphic.height }
      end
    end

    # `feature_graphic`: `{url, sha256, alt}` or nil. Its size is fixed (1024 x 500), so width and height
    # carry no information here. At most one row exists per app and device (a unique index); if that
    # ever failed, the newest wins.
    def feature_graphic_for(app)
      graphic = available_graphics(app, 'feature_graphic').max_by { |candidate| candidate.id.to_i }
      return nil unless graphic

      { url: graphic.download_url, sha256: graphic.sha256, alt: graphic.alt_text }
    end

    # `video`: `{youtube_id}` or nil. An external link, so no hash (docs/store_listing_graphics.md,
    # "Integrity"). The value was checked to be a plain video ID when it was saved.
    def video_for(app)
      youtube_id = app.respond_to?(:promo_video_youtube_id) ? app.promo_video_youtube_id : nil
      youtube_id.present? ? { youtube_id: youtube_id } : nil
    end

    # Task 27d-c: `listing.icon` is `{url, sha256}` of the newest catalog release that still has an
    # icon (releases arrive newest first), so a newer upload without one does not blank the listing.
    # `{url: nil, sha256: nil}` when none has. The URL is Zealot's stable endpoint (Task 27d-b), never
    # a signed storage URL. Duck-typed like the rest of the class: a fixture without the icon members
    # gets the empty value.
    def icon_for(releases)
      release = releases.find { |candidate| icon_available?(candidate) }
      return { url: nil, sha256: nil } unless release

      { url: release.icon_download_url, sha256: icon_sha256_for(release) }
    end

    # Served from the mirrored copy (`icon_storage_key`) or, failing that, the file still on disk --
    # the same two tiers `ReleaseIconDownload` answers from, so the URL is only advertised when it works.
    def icon_available?(release)
      return false unless release.respond_to?(:icon_download_url)
      return true if release.respond_to?(:icon_storage_key) && release.icon_storage_key.present?

      path = release.respond_to?(:icon) ? release.icon&.path : nil
      path.present? && File.exist?(path)
    end

    # The recorded hash (27d-a), else hashed from the local file, else nil -- the same fallback as
    # `sha256_for`. It matters here: the index publishes when the release is created, before the
    # mirror job has recorded `icon_sha256` (the job uses `update_columns`, which republishes nothing).
    def icon_sha256_for(release)
      return release.icon_sha256 if release.respond_to?(:icon_sha256) && release.icon_sha256.present?

      path = release.respond_to?(:icon) ? release.icon&.path : nil
      path.present? && File.exist?(path) ? Digest::SHA256.file(path).hexdigest : nil
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
        size_bytes: size_bytes_for(release),
        # Set only for org-signed builds delivered through
        # AnthropicAssetDeliveryJob (see AndroidSigningKey); nil otherwise.
        signing_fingerprint: release.signing_key_checksum,
        changelog: text_changelog_for(release),
        released_at: iso(release.created_at),
        # Task 27f-a: the real column (`available`, `halted` or `pulled`). A held release never
        # reaches here (`App#catalog_releases` leaves it out); a fixture without the column, or a
        # value the schema does not know, reads as `available` rather than raising.
        status: version_status_for(release),
        compatibility: compatibility_for(release),
        rollout: rollout_for(release),
      }
    end

    PUBLISHED_VERSION_STATUSES = %w[available halted pulled].freeze
    private_constant :PUBLISHED_VERSION_STATUSES

    def version_status_for(release)
      status = release.respond_to?(:status) ? release.status.to_s : 'available'
      PUBLISHED_VERSION_STATUSES.include?(status) ? status : 'available'
    end

    # Task 32a: staged rollout, Play-Console-parity. `respond_to?` keeps this
    # duck-typed like the rest of the class -- a fixture/Struct without the
    # new columns gets the fully-rolled-out default (percentage: 100,
    # status: 'complete'), same "honest current behavior" fallback the
    # compatibility block above uses, rather than raising. The device-bucket
    # decision itself (`Release#rollout_includes_device?`) is deliberately
    # NOT made here -- this index is signed and cached (same "read from
    # storage/downloads, never live" rule Section 3 of the D-store handover
    # documents on the consumer side), so it has to describe the rollout,
    # not evaluate it for one specific device. Whichever layer knows the
    # requesting device (D-store's update-check path, not this
    # once-per-publish serialization) is what calls that method.
    def rollout_for(release)
      percentage = release.respond_to?(:rollout_percentage) ? release.rollout_percentage : 100
      status = release.respond_to?(:rollout_status) ? release.rollout_status : 'complete'
      { percentage: percentage, status: status }
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
      # Task 40e: a CI-built release is installed from its signed universal APK, so that file's hash is the
      # one a reader can check. The bundle's hash would be rejected by every reader that verifies it.
      return release.universal_apk_sha256 if universal_apk_served?(release)
      return release.file_sha256 if release.respond_to?(:file_sha256) && release.file_sha256.present?

      path = local_file_path(release)
      return nil unless path && File.exist?(path)

      Digest::SHA256.file(path).hexdigest
    end

    # Task 40e: the universal APK's size for a CI-built release (the `original_size` column holds the size
    # of the old split set, not of what gets downloaded), else the earlier answer.
    def size_bytes_for(release)
      return release.universal_apk_size if universal_apk_served?(release)

      release.original_size || local_file_size(release)
    end

    # Duck-typed: a fixture without the CI columns is never a CI-built release.
    def universal_apk_served?(release)
      release.respond_to?(:serves_universal_apk?) && release.serves_universal_apk?
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
