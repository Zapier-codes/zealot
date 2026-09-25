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
        "description": null,
        "icon": { "url": null, "sha256": null },
        "screenshots": [],
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
      "summary": null,                     // short one-liner, distinct from listing.description
      "category": null,                    // one of CATEGORIES below, or null if not yet categorized
      "license": null,
      "links": { "site": null, "source": null, "tracker": null, "donate": null },
      "available_regions": null,           // null = all regions; else an array of ISO 3166-1 alpha-2 codes
      "created_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-09-01T00:00:00Z",
      "editorial": { "featured": false, "editors_pick": false },  // NEW, reserved for 31a -- Zealot-authored, D-store reads only
      "sponsored_slots": [],               // NEW, reserved for 31a. Shape once used: [{ "starts_at": "...", "ends_at": "..." }]
      "collections": [],                   // NEW, reserved for 31a -- array of collection slugs

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
          "status": "available",           // NEW -- "available" | "halted" | "pulled" (27f owns transitions; 29b just reads whatever the column says once 27f adds it)
          "compatibility": {                // NEW, reserved for 29c -- APK extraction is separate work
            "min_sdk": null,
            "target_sdk": null,
            "abis": [],
            "screen_densities": [],
            "required_features": [],
            "permissions": []
          }
        }
      ]
    }
  ]
}
```

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

Fixed list, matching D-store's current categories exactly (not a Zealot-owned
free-text field mapped by D-store — see the open ❓ below for why this isn't
settled yet):

`system`, `multimedia`, `games`, `internet`, `navigation`,
`science-education`, `theming`, `time`, `reading`, `writing`, `development`,
`finance`

`null` is valid (an app not yet categorized) but any non-null value MUST be
one of the above — the JSON Schema enforces this with an `enum`, not free
text.

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
lands): `App#slug`, `App#summary`, `App#category`, `App#license`,
`App#links` (or a small value object), `App#available_regions`,
`App#created_at`/`updated_at` (already exist as AR timestamps — just not
serialized in v1), publisher bio/profile_url/joined_at, the `data_safety`/
`content_rating`/`contains_ads`/`has_in_app_purchases` listing declarations,
`editorial`/`sponsored_slots`/`collections` (31a), and per-release
`changelog` (rendered as a plain string via `Release#text_changelog`, not
the raw jsonb column — fixed by 29b/29d after cross-repo review found
D-store's reader already committed to a plain string), `released_at`
(`Release#created_at` — already exists), `status` (27f), and
`compatibility` (29c).

## ❓ Open decisions (not resolved by this slice)

Recorded in `handover.md`'s Task 29 section, repeated here for visibility:
1. **Category vocabulary**: fixed list (as written above) vs. Zealot-owned
   free text that D-store maps to its own categories. This doc assumes the
   fixed list because that's what ships today with zero mapping code on
   either side — if the operator wants free text instead, this section and
   the schema's `category` enum both need to change together.
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
