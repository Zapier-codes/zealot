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
produces it from an app's current state. **What it is not:** publishing (27b-iii; signing is 27b-ii, below), regeneration on
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
`file` (nil or an object responding to `path`), and optionally `file_sha256`
(a persisted hash, preferred over hashing `file` live when present -- see
"The `sha256` gap" below). A fixture without `file_sha256` still works; the
serializer falls back to the old live-hash path.

## Which apps go in

The serializer itself doesn't filter -- `Serializer.call(anything)` will
happily serialize a draft app if you hand it one. `Serializer.for_live_apps`
scopes to `App.listing_live`, and **production generation (27c) is expected
to only ever call that** -- a public catalog for D-Store has no reason to
mention a draft or suspended app. `listing_status` still rides along in the
output for debugging/completeness, not as a filter contract.

## The `sha256` gap (Task 27b-i closed it going forward)

There is currently **no SHA-256 of any release binary anywhere in this
codebase** -- `Release#signing_key_checksum` is a SHA-1 of the *signing
keystore*, not a hash of the APK/AAB itself. v1's serializer originally
computed it lazily from the release's local file (`Release#file`) when
that file still existed on disk, and returned `null` when it didn't --
which, per Task 19's mirror-then-wipe behavior, was the common case for
anything old enough to have been mirrored to `ReleaseStorage` and cleaned
up locally.

**Task 27b-i (this session) closes the gap going forward:**
`ReleaseFileMirrorJob` now hashes the primary file and persists it to
`Release#file_sha256` at mirror time -- while the local file is
guaranteed to still be there, before anything else in the pipeline gets a
chance to wipe it. `CatalogIndex::Serializer#sha256_for` prefers this
persisted value and only falls back to hashing the local file live (the
original, gap-prone path) when it's blank.

**Releases created before this migration still show `sha256: null`** until
`ReleaseFileMirrorJob.backfill` (or a natural re-run) catches them up --
that rake-style task walks every release without a stored mirror key, which
in practice is nearly every release old enough to matter, so running it
once after deploying 27b-i is expected, not automatic. F-Droid's index
leans on exactly this hash for every referenced file, so treat a `null`
here as "not backfilled yet," not as "broken."

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

## Signing (Task 27b-ii)

Zealot publishes **two files** and, once, a public key:

| File | What it is |
|---|---|
| `index.json` | The index, byte for byte what `CatalogIndex::Signer` produced (`JSON.pretty_generate` + a trailing newline). Never re-serialised. |
| `index.json.sig` | Base64 of the **Ed25519 signature over those exact bytes** (detached, standard Ed25519 / RFC 8032, no pre-hash). |
| public key | Base64 of the **raw 32-byte** Ed25519 public key. Published once, and **pinned** by D-store. Non-secret. |

`key_id` = first 16 hex characters of the SHA-256 of the raw public key: a label
to tell keys apart, not a security feature.

The signing key is **separate from `AndroidSigningKey`** (which signs APKs): a leaked
index key must not be able to sign an app, and the other way round.

### What a reader (D-store) must do

1. Fetch `index.json` and `index.json.sig`; verify the signature over the **raw bytes
   as fetched** with the pinned public key. Any failure → **discard, keep showing the
   last good index**. Do not parse first and re-serialise.
2. Only then parse. Reject the index unless `schema_version` is one it understands.
3. **Rollback protection:** remember the newest `generated_at` accepted so far; reject
   any index whose `generated_at` is **not strictly greater**. Zealot guarantees it
   never issues a `generated_at` that is earlier than or equal to a previous one (it
   persists the last value under a row lock and, if the clock went backwards, issues
   the previous value + 1 second). A replayed old index is therefore detectable.
4. Node example (raw key → SPKI → verify), verified against Zealot's output:

```js
const spki = Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), rawPublicKey]);
const key = crypto.createPublicKey({ key: spki, format: 'der', type: 'spki' });
const ok = crypto.verify(null, indexBytes, key, Buffer.from(sigB64, 'base64'));
// or WebCrypto: subtle.importKey('raw', rawPublicKey, { name: 'Ed25519' }, false, ['verify'])
//               then subtle.verify('Ed25519', key, sigBytes, indexBytes)
```

### Which apps are signed into the index

`CatalogIndex::Signer.default_apps` = `App.listing_live` **and not archived**. (The
serializer itself filters nothing; `Serializer.for_live_apps` uses `App.listing_live`
without the archived check, so the signer does not use it — an archived app must not
stay in a public catalog.)

### Operating it

`rake catalog_index:generate_key` creates the one key (refuses if one exists) and prints
the key id and the public key; the private key is never printed and is stored encrypted
(Active Record Encryption). `rake catalog_index:public_key` prints them again.
**Key rotation is not designed yet** (Task 27 ❓3): replacing the key means every reader
must re-trust a new public key, so it needs its own procedure before it is ever done.

## Publishing (Task 27b-iii)

`CatalogIndex::Publish` signs the current catalog and writes it to a small **public
Pages repository** as **one git commit** (GitHub Git Data API: blob → tree → commit →
fast-forward ref update), then pings D-store's deploy hook. The commit contains:

| Path | Content |
|---|---|
| `index.json` | the signed index bytes |
| `index.json.sig` | base64 Ed25519 signature + newline |
| `signing_key.pub` | base64 raw public key + newline (unchanged most of the time; a reader can always find the key that goes with the signature — pin it, don't trust it blindly) |
| `.nojekyll` | empty, so Pages serves the files untouched |

Because it is one commit, a reader never sees a new index next to an old signature or
key. The branch update is fast-forward only and never forced; if the branch moved in
between, the publish starts over from the new tip (3 tries) and then fails loudly.

**Serialized.** Signing and committing run under one Postgres advisory lock, so two
publishes can never interleave and the order they are signed in is the order they land
in. (The lock is per DB session, so it also covers separate processes and is released
if a process dies.)

**Deploy hook.** `DSTORE_DEPLOY_HOOK_URL` (optional; a secret, never logged) is POSTed
after a commit actually landed. A failing hook never fails the publish — the index is
already public — and D-store's own cache rule refreshes it anyway.

### Configuration (environment)

| Variable | Meaning |
|---|---|
| `CATALOG_PAGES_REPO` | `owner/name` of the **public** Pages repo (not the code repo, not the private build-storage repo) |
| `CATALOG_PAGES_TOKEN` | fine-grained token scoped to **only that repo**, "Contents: read and write". **Not** `GITHUB_STORAGE_TOKEN`: that one can write to private build storage and must not be reachable from code that publishes to a public repo |
| `CATALOG_PAGES_BRANCH` | branch Pages serves from; default `gh-pages`. Must already exist with Pages enabled for it |
| `DSTORE_DEPLOY_HOOK_URL` | optional Vercel deploy hook |
| `GITHUB_API_URL` | optional, defaults to `https://api.github.com` |

### Running it

`rake catalog_index:publish` (once now, by hand) or `CatalogIndexPublishJob`. The job
does nothing, and says so in the log, until the repo, token and signing key exist.
Nothing enqueues it automatically yet: that is 27c (on `go_live!`, suspension, listing
edits, new releases).

