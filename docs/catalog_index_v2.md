# Catalog index v2 (Task 29a)

Supersedes [`catalog_index_v1.md`](catalog_index_v1.md) as the schema Zealot
actually publishes going forward. v1 is kept for history, not deleted — it
was never published anywhere (27b only shipped once v2 existed... actually:
if 27b already shipped v1 in production before this slice landed, v1 is
still the live schema until 29b ships v2's serializer. Check
`app/services/catalog_index/serializer.rb`'s current `SCHEMA_VERSION`
before assuming which one a running index is actually using).

This slice (29a) is **schema only** — the written doc plus the
machine-checkable `catalog_index_v2.schema.json`, and the naming rules for
`slug`/`category`. It does not touch the serializer (29b), extract APK
compatibility metadata (29c), or get D-store's formal sign-off (29d) — those
are separate slices for a reason: nothing consumes v1 in production yet
(confirm this is still true before treating v2 as risk-free to define), so
revising the shape now costs nothing, but the code that fills these new
fields doesn't exist yet and several of them will legitimately come back
empty for a while.

## Why v2 exists

Compared against D-store's own `App` type (`lib/mock-data.ts` in that repo)
during Task 28's planning: v1 doesn't carry enough for D-store to render its
actual UI (category browsing, compatibility filtering, version history,
editorial placements) or for a future on-device Updater (Task 32) to make
install/update decisions safely. See `handover.md`'s Task 29 section for the
full rationale and the phase this sits in (Phase 1, trust core).

## Shape

```jsonc
{
  "schema_version": 2,
  "generated_at": "2026-09-24T12:00:00Z",  // UTC ISO-8601, as v1
  "sequence": 42,                          // NEW: strictly increasing per publish; lets a reader detect a rollback attempt (27b/29b wires this up)
  "expires_at": "2026-09-25T12:00:00Z",    // NEW: freshness bound; a reader should refuse an index past this
  "apps": [
    {
      // --- v1 fields, unchanged ---
      "id": 123,
      "package_name": "com.example.app",
      "listing_status": "live",
      "publisher": {
        "name": "Ada Labs",
        "verified": false,
        // --- v2 additions to publisher ---
        "bio": null,                       // NEW, reserved -- no developer-profile UI yet
        "profile_url": null,               // NEW, reserved
        "joined_at": null                  // NEW, reserved (App/User's created_at once wired up)
      },
      "listing": {
        "title": "Example App",
        "description": null,               // 27e-a: plain text, <= 4000 characters, paragraphs split by a blank line; null when the owner wrote none
        "icon": { "url": null, "sha256": null },  // 27d-c: /download/releases/:id/icon + hash of the newest release that has an icon
        "screenshots": [],                 // 27d-e1: [{ "url", "sha256", "alt", "width", "height" }] in position order (phone only); url is /download/graphics/:id
        "feature_graphic": null,           // 27d-e1: { "url", "sha256", "alt" } (1024 x 500) or null
        "video": null,                     // 27d-e1: { "youtube_id": "<11 chars>" } or null; an external link, so no hash
        // --- v2 additions to listing ---
        "content_rating": null,            // NEW, reserved -- e.g. "everyone", "teen"; vocabulary not decided yet
        "data_safety": {                   // NEW, reserved -- all null/false until a real declaration flow exists
          "collects_data": null,
          "data_types": [],
          "shared_with_third_parties": null,
          "encrypted_in_transit": null,
          "deletion_request_url": null
        },
        "contains_ads": null,              // NEW, reserved
        "has_in_app_purchases": null        // NEW, reserved
      },
      // --- v2: NEW top-level per-app fields ---
      "slug": "example-app",               // immutable once listing_status first reaches "live" -- see "The slug rule" below
      "summary": null,                     // 27e-b: the short description, one line, <= 80 characters, distinct from listing.description; null when the owner wrote none
      "category": null,                    // one of CATEGORIES below, or null if not yet categorized
      "license": null,
      "links": { "site": null, "source": null, "tracker": null, "donate": null },
      "available_regions": null,           // null = all regions; else an array of ISO 3166-1 alpha-2 codes
      "created_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-09-01T00:00:00Z",
      "editorial": { "featured": false, "editors_pick": false },  // Task 31a -- Zealot-authored, D-store reads only. Real `apps.featured`/`apps.editors_pick` columns; false is the default until an admin opts an app in, not a placeholder
      "base_stats": null,  // Task 45a -- `null`, or { "downloads": <n>, "rating": null | { "average": 4.3, "count": <n> } }: downloads and ratings the app earned before it was listed here (real history entered by an admin, source kept in Zealot). Task 45e: `downloads` is that carried-over figure PLUS the download count GitHub keeps for each release's installable file (read every 6 hours, never falls). A reader shows one total, formatted like Play Store (5.8M), and adds no counter of its own for these apps.
      "reviews": [],  // Task 45d -- comments the app earned before it was listed here, oldest first, each { "author_name", "rating" (1-5), "body": null|string, "commented_on": <date-time>, "helpful_count" }. Published so a reader shows them as ordinary reviews with no label; `source_note` and who entered each row stay in Zealot's `migrated_comments` table and are never published. A reader merges these with its own reviews by date and does not count them twice. `[]` when the app has none. Additive: no schema_version bump.
      "anonymous_reviews": [],  // Z-P9 -- live anonymous reviews, newest first, each { "rating" (1-5), "body": null|string, "verified_install": bool, "version_code": null|string, "helpful_count": <n>, "created_at": <date-time> }. Only `published` rows appear; `pending` waits for an owner and `rejected` never publishes. No reviewer identity is published (there is none to publish). `verified_install` is earned, never assumed: the review carried a device-bound key that passed Android Key Attestation and named a real release of this app. A reader shows these as ordinary reviews beside the carried-over `reviews`, each badged only when the mark is true. `[]` when the app has none. Additive: no schema_version bump.
      "sponsored_slots": [],               // Task 31a -- real `SponsoredSlot` rows, current-or-upcoming only, soonest first. Shape: [{ "starts_at": "...", "ends_at": "..." }]
      "collections": [],                   // Task 31a -- real `Collection` membership via `CollectionApp`. Array of collection slugs, resolving against the top-level `collections` registry below
      "suggested_version_code": "42",      // Task 27f-c -- the version_code a client should offer: the highest version_code among `versions[]` whose `status` is "available", compared as versions (so "100" beats "99"), or null when none is. Halting or pulling the newest release moves it to the previous available one (a Play-style rollback, no new data). Additive: no schema_version bump; a reader that does not know the key ignores it. It ignores the rollout ramp: whether one device is offered it is still the reader's call, from `rollout`.

      // --- v2: `latest_version` replaced by `versions[]` ---
      "versions": [
        {
          "release_id": 456,
          "version_name": "1.2.3",
          "version_code": "42",
          "download_url": "https://zealot.example.com/download/releases/456",
          "sha256": null,
          "size_bytes": 15728640,
          "signing_fingerprint": "d41d8cd9...",
          "changelog": "- Fixed login crash\n- Improved battery usage",  // NEW -- a plain string via Release#text_changelog(default_template: false), not the raw jsonb column; "" (not null) for a release with no entries
          "released_at": "2026-09-01T00:00:00Z",  // NEW -- the release's created_at
          "status": "available",           // NEW -- "available" | "halted" | "pulled". Read from `releases.status` (Task 27f-a). A `held` release is not published at all: it is left out of `versions[]` until it is released. Task 46b-index: a release that goes through the CI compile is also left out until the compile is done and its universal APK is fully recorded, so `download_url` never serves a bundle a phone cannot install.
          "compatibility": {                // NEW, 29c -- extracted from the APK at upload time for Android releases (see app/models/concerns/release_parser.rb#extract_compatibility). abis/screen_densities are read off the APK's own zip entry paths, not AppInfo::APK's public API, which doesn't expose either directly; both are a lower bound (no native code or no density-qualified resources correctly yields [], not a parsing failure). Still all-null/empty for a non-Android release, or any release uploaded before this slice shipped -- "empty, not invented" per 29a/29b's original rule.
            "min_sdk": 24,
            "target_sdk": 34,
            "abis": [ "arm64-v8a", "armeabi-v7a" ],
            "screen_densities": [ "xhdpi", "xxhdpi" ],
            "required_features": [ "android.hardware.camera" ],
            "permissions": [ "android.permission.INTERNET", "android.permission.CAMERA" ]
          },
          "rollout": {                      // NEW, 32a -- staged rollout, Play-Console parity. percentage 0-100 (100 = fully available, the default). status is the admin-controlled ramp state ("active" | "halted" | "complete"), distinct from the sibling "status" field above (which is the release's overall lifecycle, not the rollout ramp).
            "percentage": 100,
            "status": "complete"
          }
        }
      ]
    }
  ],
  // --- v2: NEW top-level registry, added 31a ---
  // The registry the per-app `collections[]` array (above) resolves
  // against. A collection with no apps in it yet is still a valid entry
  // here (nothing requires membership to publish the registry row).
  "collections": [
    {
      "slug": "editors-picks",
      "name": "Editor's Picks",
      "description": "Hand-picked by the Zealot team."
    }
  ]
}
```

## Listing graphics: an additive change to v2 (Task 27d-e1)

`listing.screenshots[]` items gained `alt`, `width` and `height`, and `listing` gained two keys,
`feature_graphic` and `video`, both `null` when the app has none. **`schema_version` stays `2`.** The rule
that makes this safe is the usual one for a signed, versioned JSON document: a change that only *adds*
optional keys is not a new version, because a reader is expected to ignore keys it does not know; only a
change that removes, renames or re-types a key needs a new `schema_version`. D-store's reader
(`lib/sources/zealot.ts`, read on 2026-09-29) does exactly that: it verifies the signature over the raw
bytes, checks only `schema_version`, `expires_at` and the anti-rollback counter, and picks fields by name
with no runtime schema check, so the new keys pass through unread until D-store chooses to consume them.

- Only a graphic that is **stored and hashed** is listed, so every listed `url` serves bytes a reader can
  check against `sha256`. A row whose ingest has not finished, or that predates it, is left out.
- `screenshots[]` is the app's phone screenshots in `position` order. `feature_graphic` is at most one.
- `video` is one YouTube ID (11 characters, checked when it was saved). It is an external link, so it has
  no hash and Zealot does not claim the video is public, embeddable or ad-free.
- The `url` is Zealot's stable `GET /download/graphics/:id`, never a signed storage URL.
- Adding, changing, reordering or removing a graphic, or changing the promo video, republishes the owning
  tenant's index (only for a live app: a draft is not in the index).
- The JSON Schema keeps `additionalProperties: false`, and now requires `feature_graphic` and `video` to be
  present (they are always emitted). It is the contract for what Zealot *writes*; readers should not copy
  that strictness.

## The slug rule

`slug` is generated once, the first time an app's `listing_status` reaches
`live`, and never changes after that — D-store and any external links
(including a future Updater) may treat it as a permanent identifier, unlike
`title` which an owner can freely edit. Two consequences a future slice must
respect:
- Uniqueness is enforced at generation time, not just at the database level
  (a rename must never produce a collision with an existing slug).
- Nothing regenerates `slug` on a listing edit, even though nothing in the
  serializer (a read-only view) can enforce that — the write side (Task 30's
  listing-edit machinery) is what actually needs to honor this.

This document does not implement generation (that's a `29b`/model concern);
it only fixes the contract so 29b doesn't have to guess and D-store can rely
on it not changing later.

## Category vocabulary

**❓1 resolved (this slice):** the operator chose full Play parity over the
small D-store-matching list this section used to carry. The vocabulary is
now the same category (and, for games, sub-category) list Play Console
itself offers a developer —
[Play Console Help: choose a category and tags](https://support.google.com/googleplay/android-developer/answer/9859673)
— fixed, not Zealot-owned free text. `App::APP_CATEGORIES`/
`App::GAME_CATEGORIES` are the source of truth; this list and the schema's
`category` enum are kept in sync with them by hand, same convention as the
rest of this file. `game_*` values mirror Play's own `GAME_*` category enum
naming so a game category can't collide with an app category of the same
name (Play has both an app "Sports" and a game "Sports").

Apps (32): `art_and_design`, `auto_and_vehicles`, `beauty`,
`books_and_reference`, `business`, `comics`, `communications`, `dating`,
`education`, `entertainment`, `events`, `finance`, `food_and_drink`,
`health_and_fitness`, `house_and_home`, `libraries_and_demo`, `lifestyle`,
`maps_and_navigation`, `medical`, `music_and_audio`, `news_and_magazines`,
`parenting`, `personalization`, `photography`, `productivity`, `shopping`,
`social`, `sports`, `tools`, `travel_and_local`,
`video_players_and_editors`, `weather`.

Games (17): `game_action`, `game_adventure`, `game_arcade`, `game_board`,
`game_card`, `game_casino`, `game_casual`, `game_educational`,
`game_music`, `game_puzzle`, `game_racing`, `game_role_playing`,
`game_simulation`, `game_sports`, `game_strategy`, `game_trivia`,
`game_word`.

`null` is valid (an app not yet categorized — Play Console has no
"uncategorized" option at publish time, but nothing here forces a choice at
draft time either) but any non-null value MUST be one of the above — the
JSON Schema enforces this with an `enum`, not free text.

**Cross-repo follow-up, not done by this slice:** D-store's own category
list/mapping (if it has one) still reflects the old 12-item vocabulary this
section used to document. Nothing in this repo can fix that from here —
flagged so the next session touching D-store's side knows the vocabulary
changed and free-text/legacy values need a mapping or a one-time
migration, not silent drift.

## What's intentionally excluded

Per Task 29's own writeup: **install/view counts, average rating, and rating
count are not in the index, by design.** Those are store-owned data (D-store
computes and owns them from its own traffic/review data) — putting them in
a Zealot-signed index would make Zealot the source of truth for numbers it
has no way to actually measure. The JSON Schema's `additionalProperties:
false` enforces this structurally: adding one of these fields to a real
document makes it invalid, not just against convention.

## Inputs the v2 serializer will need (for 29b, not built by this slice)

Everything v1's serializer already reads, plus (all currently nonexistent on
the models and expected to come back `null`/empty until their owning slice
lands): `App#slug`, `App#summary`, `App#category` (real column as of the
category slice above — see the serializer's `#category_for`), `App#license`,
`App#links` (or a small value object), `App#available_regions`,
`App#created_at`/`updated_at` (already exist as AR timestamps — just not
serialized in v1), publisher bio/profile_url/joined_at, the `data_safety`/
`content_rating`/`contains_ads`/`has_in_app_purchases` listing declarations,
`editorial`/`sponsored_slots`/`collections` (31a), and per-release
`changelog` (rendered as a plain string via `Release#text_changelog`, not
the raw jsonb column — fixed by 29b/29d after cross-repo review found
D-store's reader already committed to a plain string), `released_at`
(`Release#created_at` — already exists), `status` (27f), and
`compatibility` (29c — real as of that slice for Android releases going
forward; still empty for anything uploaded earlier or on another platform,
same "empty, not invented" rule as every other field on this list until its
owning slice lands).

**32a, added later:** `versions[].rollout` — real as of this slice
(`Release#rollout_percentage`/`#rollout_status`, `AddStagedRolloutToReleases`),
not reserved. Every release defaults to `{percentage: 100, status:
"complete"}`, so nothing published before this slice changes shape. The
device-bucket decision (`Release#rollout_includes_device?`) is intentionally
not part of this serializer — the signed index describes the rollout for
every device alike; whichever layer knows the requesting device's stable ID
evaluates the bucket per request.

## ❓ Open decisions (not resolved by this slice)

Recorded in `handover.md`'s Task 29 section, repeated here for visibility:
1. ~~**Category vocabulary**~~ — resolved this slice (see "Category
   vocabulary" above): full Play parity, `App::APP_CATEGORIES`/
   `App::GAME_CATEGORIES` as the source of truth.
2. **Who authors `available_regions`**: per-app in the (future) listing
   editor, or an org-wide default that individual apps can override. Schema
   allows either (`null` = all regions, an array = a restriction) without
   needing to know the answer yet.

## Verifying this slice

Same constraint as 27a: no Rails boot available in this sandbox. What was
actually run: `catalog_index_v2.schema.json` was validated with `ajv`/
`ajv-formats` (Node, already available) against a fully-populated fixture
document and a bare-minimum one (an app with every "reserved" field at its
default null/empty/false value, and one with no versions at all) — both
passed — and against deliberately malformed documents (a `category` outside
the fixed vocabulary, a `sequence` as a string instead of an integer, an
extra unrecognized top-level field, a `versions[].status` outside the three
allowed values) — all four were correctly rejected. Neither `ajv` nor
`ajv-formats` are dependencies of this repo; they were only used locally to
check this schema.
