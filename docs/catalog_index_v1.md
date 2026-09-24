# Catalog index v1 (Task 27a)

Zealot is the "Play Console"; [D-Store](https://github.com/Zapier-codes/D-store)
is the "Play Store app" -- front-facing only, never accepting developer input
(see `handover.md`'s Task 26 correction and Task 27's mapping table). Instead
of Zealot writing fields directly into D-Store's Supabase, Zealot publishes a
**signed catalog index** and D-Store reads it -- the F-Droid model, not the
"shared database" one.

This document, `catalog_index_v1.schema.json` (machine-checkable), and
`app/services/catalog_index/serializer.rb` (the actual code) are kept in sync
by hand. If you change one, change the other two.

**What this slice (27a) is:** the shape of the index and the serializer that
produces it from an app's current state. **What it is not:** signing,
atomic/strictly-increasing publishing (27b), regeneration on
`go_live!`/suspend/listing-edit/new-release (27c), or the icon/screenshot
pipeline and store-listing editor (27d/27e). Fields those slices own are
present in v1's shape already (so the schema doesn't need a v2 bump later)
but always come back `null`/empty for now.

## Shape

```jsonc
{
  "schema_version": 1,
  "generated_at": "2026-09-24T12:00:00Z", // UTC ISO-8601
  "apps": [
    {
      "id": 123,                 // App#id -- stable, key off this
      "package_name": "com.example.app", // App#play_package_name, or null
      "listing_status": "live",  // draft | awaiting_payment | live | suspended
      "publisher": {
        "name": "Ada Labs",      // App#publisher_display_name
        "verified": false        // always false in v1 -- no KYB yet
      },
      "listing": {
        "title": "Example App",  // App#name
        "description": null,     // reserved for 27e
        "icon": { "url": null, "sha256": null },  // reserved for 27d
        "screenshots": []        // reserved for 27d
      },
      "latest_version": {        // null if the app has no releases
        "release_id": 456,
        "version_name": "1.2.3", // Release#release_version
        "version_code": "42",    // Release#build_version ("versionCode" in Play's terms)
        "download_url": "https://zealot.example.com/download/releases/456",
        "sha256": null,          // see "The sha256 gap" below
        "size_bytes": 15728640,
        "signing_fingerprint": "d41d8cd9..." // AndroidSigningKey's checksum, or null
      }
    }
  ]
}
```

## Inputs the serializer needs from an "app" object

Duck-typed on purpose (see the class comment) -- anything that responds to
these works, real `App`/`Release` or a fixture:

`id`, `play_package_name`, `listing_status`, `publisher_display_name`, `name`,
`recently_release` -> an object responding to `id`, `release_version`,
`build_version`, `download_url`, `original_size`, `signing_key_checksum`,
`file` (nil or an object responding to `path`).

## Which apps go in

The serializer itself doesn't filter -- `Serializer.call(anything)` will
happily serialize a draft app if you hand it one. `Serializer.for_live_apps`
scopes to `App.listing_live`, and **production generation (27c) is expected
to only ever call that** -- a public catalog for D-Store has no reason to
mention a draft or suspended app. `listing_status` still rides along in the
output for debugging/completeness, not as a filter contract.

## The `sha256` gap (read before assuming this is done)

There is currently **no SHA-256 of any release binary anywhere in this
codebase** -- `Release#signing_key_checksum` is a SHA-1 of the *signing
keystore*, not a hash of the APK/AAB itself. v1's serializer computes it
lazily from the release's local file (`Release#file`) when that file still
exists on disk, and returns `null` when it doesn't -- which, per Task 19's
mirror-then-wipe behavior, is the common case for anything old enough to have
been mirrored to `ReleaseStorage` and cleaned up locally.

**This means v1's `sha256` will be `null` for most releases in production
today.** That's an honest gap, not a bug: computing it requires either (a)
re-downloading the mirrored file to hash it (expensive, and wrong to do on
every index regeneration) or (b) persisting the hash once, likely at mirror
time (`ReleaseFileMirrorJob`, Task 19c) so it survives the wipe. Either is a
real design decision for **27b** (which owns index *generation*, including
deciding when/how expensive per-release work like this happens), not
something to guess at here. F-Droid's index leans on exactly this hash for
every referenced file, so 27b should treat closing this gap as part of "the
index is trustworthy," not an optional nice-to-have.

## What's deliberately out of scope for v1

- **iOS.** `package_name` maps to `App#play_package_name` only; there's no
  bundle-id field yet. The whole Task 27 plan is framed around the Play
  Console model (see the mapping table), so this wasn't an oversight, but a
  future session should decide whether/how iOS apps appear in the index at
  all before D-Store expects them to.
- **Release selection.** "`latest_version`" is `App#recently_release` --
  whatever the app's most recent release is across every channel, the same
  method already used elsewhere for "the app's latest build." There's no
  concept yet of "the release that's actually the public store version"
  (e.g. only a Play-published one, or an explicit pin an owner sets). 27c/27e
  are the natural place to make that deliberate.
- **Verification.** `publisher.verified` is hardcoded `false`. Nothing
  computes it because company verification (KYB) doesn't exist yet -- see
  Task 27's decision list (❓1 area).

## Verifying this slice

No Rails boot is available in this sandbox (no rubygems access -- only
`ruby`/`rspec` via `apt`, no `bundle install`), same limitation every other
"code-complete, not run" item on this board carries. What *was* actually run
here, the same way `release_storage_cleanup_callback_spec.rb`'s standalone
harness was:

1. A throwaway plain-Ruby harness (not committed) that `require`s this file
   directly with Struct-based fake app/release fixtures (no ActiveRecord) and
   runs the real `RSpec` gem installed via `apt` against it.
2. The harness's JSON output was validated against
   `catalog_index_v1.schema.json` with `ajv` (Node, already available in this
   sandbox) for both a fully-populated app and a released-with-no-local-file
   app (the common `sha256: null` case) -- both passed.

`spec/services/catalog_index/serializer_spec.rb` is the real spec that lives
in the repo (`require 'rails_helper'`, real `App`/`Release` records) -- it
exercises the same code path but wasn't itself runnable here.
