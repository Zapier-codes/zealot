# Anthropic — Project Handover

This file is the single source of truth for what's done, what's in progress, and
what each future Claude session should pick up. Update it at the end of every
session before generating that session's patch.

## Handoff Process (the actual rule — follow exactly, every session)

This repo has no CI-triggered auto-merge and no session ever pushes
directly. The loop is always:

1. **Session** re-clones fresh, does the task, updates this file (status
   column + "Current state" + a new dated Session log entry), then runs
   `git format-patch -1 HEAD` (or `-N` for N commits) to produce one
   `.patch` file. The session does **not** push.
2. **Operator** downloads the patch, applies and pushes it themselves:
   ```
   cd ~/zealot
   git am ~/storage/downloads/<name>.patch
   git push origin main
   ```
3. Builds are verified **only** via GitHub Actions on `main` after that
   push — no session verifies a build locally, and no session should claim
   a build passed without an Actions log to point to. If Actions fails, the
   operator pastes the failure output back into the next session, which
   debugs from that output (see task #2).
4. The **next session** starts by re-cloning `main` fresh and confirming
   this file's "Current state" section actually matches what's on GitHub,
   before trusting anything a prior session wrote here.

Do not deviate from this (no direct pushes from a session, no skipping the
patch step, no declaring a build verified without an Actions log).

## Scope, stated plainly

This console is **internal tooling**, used only by this organization's own
employees, to build and publish **apps this organization produces**. It is not
a public submission platform. Nothing in this pipeline re-signs or republishes
third-party developers' apps under our verified identity, and nothing in the
storage layers is for archiving commercial titles we don't have distribution
rights to. Every task below should be read with that scope in mind — if a task
ever drifts outside it, stop and flag it rather than building it.

## Architecture (see prior architectural-vision doc for full detail)

| Layer | Component | Status |
|---|---|---|
| Control plane | Zealot fork (Rails) | In progress |
| Pipeline | bundletool / Brotli / delta patching | Landed on `main` |
| Storage | `ReleaseStorage` (Local + R2 adapters) | Not started |
| Cold storage | Telegram MTProto archive of our own large builds | In progress |
| Publishing | Google Play Developer API, verified org account | Not started |
| Database | Supabase Postgres, Session Pooler | Unchanged from upstream Zealot |
| Deployment | Render (image-backed), GitHub Actions → GHCR | Not started |
| Auth | Existing Zealot OAuth providers | Unchanged from upstream Zealot |

## Current state of `main` (verified by fresh clone, this session)

- HEAD: `ab603383` "Document Handoff Process in handover.md; scaffold task 6
  (MTProto cold storage)", on top of `4575a31e`. Confirmed landed on
  `origin/main` by fresh fetch before starting this session (per the
  Handoff Process above).
- This session adds (not yet pushed — see this session's patch):
  `app/models/android_signing_key.rb` (encrypted keystore, one per App),
  `app/services/anthropic/apk_signing_service.rb` (keytool-based keystore
  verification), signing wired into `BundletoolService#build_apk_set` and
  `AssetPackService#process`, `AnthropicAssetDeliveryJob` now looks up
  `release.app.android_signing_key` and signs automatically when present,
  `config/initializers/active_record_encryption.rb` (ENV-driven, not
  `credentials.yml.enc`), two migrations + hand-updated `schema.rb`
  (`android_signing_keys` table; `releases.signed` /
  `releases.signing_key_checksum`).
- **Not build- or integration-verified** — same posture as every prior
  session touching Ruby: no `ruby`/`bundler` in this sandbox at all this
  time (not even for a syntax check), so this was written and reviewed by
  hand against the existing `AppleKey`/`ReleaseStorage` conventions rather
  than run. What IS true: this session did have Node, and used it to
  actually `npm install` + `npx tsc --noEmit` the session-6 sidecar
  worker's real dependency types, catching and fixing one genuine type
  error against the library's `.d.ts` files rather than guessing — that
  was Ruby-unrelated work already landed, noted here only so "not verified"
  isn't read as "nothing here has ever been verified by any means."
- `main` has moved upstream between sessions before (5 unrelated upstream
  commits appeared, then were gone by the time of this session's re-clone —
  origin drift is possible between sessions). **Every session should
  re-clone fresh and diff against what it expects before assuming a prior
  patch's context still matches `main` exactly.**
- Task #2 (Dockerfile build verification) remains blocked; carried-forward
  known risks, still unresolved:
  1. `bsdiff` may not exist as a native Alpine `apk` package (could not
     confirm via public package index search — may need to build from source).
  2. The Alpine `community` repo (where `openjdk17-jre-headless` and `brotli`
     live) may not be enabled by default in `ruby:3.4.7-alpine` — needs an
     explicit `sed`/echo into `/etc/apk/repositories` to be safe.
  Per the operator's answer above, this is now verified via GitHub Actions
  only — the operator runs it and pastes back any failure.

## Task list

Each task below is meant to be handed to one session. A session should:
1. Re-clone fresh, verify `main`'s actual state against this file (not just
   trust this file — confirm on GitHub).
2. Do the task.
3. Update this file's status column and "Current state" section.
4. Produce one `.patch` via `git format-patch`, do not push.

| # | Task | Depends on | Status | Notes |
|---|---|---|---|---|
| 1 | PAD / Brotli / delta patching services | — | ✅ Done | Landed `a295c6a6` |
| 2 | Dockerfile build verification & fix | #1 | 🔲 Blocked on Docker access | Needs a sandbox with real `docker build` capability, or the operator running it and reporting exact failures back. Do not declare success without an actual build log. |
| 3 | `ReleaseStorage` service (Local + R2 adapters) | — | ✅ Done | Landed on top of `1a3773c5`. `RELEASE_STORAGE_ADAPTER=local\|r2`. See "Current state" below for what's untested. |
| 4 | Wire pipeline (#1) onto `ReleaseStorage` (#3) once both exist | #1, #3 | ✅ Done (folded into #3) | `AnthropicAssetDeliveryJob` now always uses `ReleaseStorage`; download controller redirects to a presigned R2 URL when available, else fetches-and-streams. |
| 5 | Signing pipeline for our own AABs | — | 🟡 In progress | `AndroidSigningKey` model (encrypted keystore, one per App) + wired into `BundletoolService#build_apk_set` via `--ks`/`--ks-pass file:`/`--key-pass file:` (passwords never hit process argv). Signs automatically in `AnthropicAssetDeliveryJob` when an app has a key configured; `Release#signed`/`signing_key_checksum` record the outcome. Needs, before trusted: `bin/rails db:encryption:init` run for real + the 3 resulting values set as `ANTHROPIC_AR_ENCRYPTION_*` env vars (see `config/initializers/active_record_encryption.rb`), a real keystore uploaded and `AndroidSigningKey#verify!`'d, and one real signed build inspected with `apksigner verify` or equivalent. No UI/controller for uploading a keystore yet — only the model + pipeline wiring. |
| 6 | Telegram MTProto cold storage for our own large builds | #3 | 🟡 In progress | `Anthropic::MtprotoArchiveService` (Rails HTTP client) + `AnthropicMtprotoArchiveJob` (pre-population cron, flag-gated on `MTPROTO_ARCHIVE_ENABLED`) + `mtproto-worker/` (Node/GramJS sidecar) scaffolded. See `mtproto-worker/README.md` "Status" for what's unverified — not build- or integration-tested (no Node runtime or real Telegram credentials in sandbox). Next: operator generates `TELEGRAM_SESSION_STRING`, provisions the sidecar, runs `npm install && npm run typecheck`, and does one real archive→retrieve round trip before this is trusted. |
| 7 | Google Play Developer API publishing | #5 | 🔲 Not started | First listing is manual per Play's own constraints; automate only subsequent releases. |
| 8 | CI/CD: GitHub Actions → GHCR → Render deploy hook | #2 | 🔲 Not started | |
| 9 | Storefront / discovery layer | — | ❓ Needs decision | Original vision assumed a public Aptoide-via-MCP storefront. Now that scope is confirmed internal/non-commercial, confirm with the operator whether this is still wanted before any session starts it. |

## Open questions for the operator (don't guess — ask)

- ~~Is task #9 (public storefront) still in scope~~ **Answered:** decision on
  #9 is deferred until the console has been successfully hosted. Do not start
  #9 before then.
- ~~Does #2 get unblocked by Docker access or operator-run builds?~~
  **Answered:** GitHub Actions is the sole source of truth for builds. No
  session should attempt local/sandbox Docker verification. The operator
  will run the Actions build and paste back failure output for a session to
  debug.

## Session log

- **Session 1** — Built PAD/Brotli/delta services, wired pipeline, Dockerfile
  changes (unverified), produced `anthropic-pad-brotli.patch`. Not pushed by
  that session (by design).
- **Session 2** — Attempted Dockerfile build verification. No Docker access
  in sandbox (no binary, no socket, registry hosts blocked at network layer).
  Did not fabricate build output. Cross-checked `bsdiff`/`openjdk17-jre-headless`
  against public Alpine package index via web search instead: `bsdiff`
  package existence unconfirmed, `openjdk17-jre-headless` confirmed but in
  `community` repo. No patch produced this session (no changes made).
- **Session 3 (architecture discussion)** — Clarified scope: console is
  internal-only, our own employees, our own apps. Ruled out third-party
  re-signing/publishing and unlicensed game archival as out of scope.
- **Session 4 (this session)** — Verified `anthropic-pad-brotli.patch` landed
  on `main` (`a295c6a6`, confirmed via independent fresh clone). Created this
  handover file.

## Session log (continued)

- **Session 5** — Built `ReleaseStorage` (Local + R2 adapters), wired the
  PAD pipeline job and the download controller onto it, added
  `compressed_apks_storage_key` column. `Gemfile.lock` was NOT regenerated
  (no rubygems/bundler network access in this sandbox) — run
  `bundle install` after applying. R2 path is logic-reviewed but not
  integration-tested against a real R2 bucket.
- **Session 6** — Confirmed `ReleaseStorage` landed on `main`
  (`f0ee5e25`). Operator answered both open questions (see above: #2 is
  GitHub-Actions-verified only, #9 deferred until successful hosting).
  Surveyed `github.com/ShivaReddyVanja/aetheroll` (cloned read-only, not
  merged/vendored) as the architectural reference for task #6: it uses
  GramJS for MTProto, a 4-tier cache (Edge → Durable Object RAM → R2 →
  MTProto), 512KB chunked `upload.getFile` reads, and a persistent
  warm MTProto connection pool to avoid re-handshaking. Relevant docs there:
  `docs/CACHING_AND_DATA_FETCHING_ARCHITECTURE.md` (fetch/cache tiers) and
  `docs/BYO_R2_TURBO_CACHE_PLAN.md` (R2 integration). No code was ported
  into this repo this session — task #6 is still 🔲 not started; this is
  groundwork only.
- **Session 7 (this session)** — Added the "Handoff Process" section above
  (the operator asked for this to be documented explicitly, since it had
  only existed as implicit convention across sessions 1–6). Started task #6:
  `Anthropic::MtprotoArchiveService` (Rails-side HTTP client),
  `AnthropicMtprotoArchiveJob` (cron pre-population, flag-gated), cron
  wiring, a migration + hand-updated schema for
  `mtproto_archived_location`/`mtproto_archived_at` on `releases`, and
  `mtproto-worker/` (Node + GramJS sidecar implementing the actual MTProto
  archive/retrieve calls, following the persistent-connection + chunked
  transfer pattern from `aetheroll`). Rails talks to the sidecar over HTTP
  with a shared-secret bearer token; the sidecar — not Rails — holds
  `TELEGRAM_API_ID`/`TELEGRAM_API_HASH`/`TELEGRAM_SESSION_STRING`. Nothing
  in this session was build- or integration-verified: no Node/npm in this
  sandbox, no real Telegram credentials, no live DB to run the migration
  against. Concretely still needed before trusting this in production —
  all operator/next-session actions, not guesses:
  1. `bundle install` / `bin/rails db:migrate` for real (schema.rb was
     hand-edited, same caveat as session 5's `ReleaseStorage` migration).
  2. In `mtproto-worker/`: `npm install`, `npm run typecheck`, then
     generate a real `TELEGRAM_SESSION_STRING` per the README and do one
     live archive→retrieve round trip against a test chat before pointing
     `AnthropicMtprotoArchiveJob` at real release data.
  3. Decide how the sidecar is actually deployed/supervised alongside the
     Rails app on Render (separate service vs. same image, different
     entrypoint) — not decided this session.
  One combined patch produced for this session (handoff-process doc +
  task #6 scaffold together, per operator's request).
- **Session 8 (this session)** — Confirmed session 7's patch landed on
  `main` (`ab603383`). Operator decided credentials (Telegram + AR
  Encryption) will all be set together once the instance is hosted, so
  this session picked the other unblocked, credential-independent task:
  #5, signing pipeline for our own AABs. Built `AndroidSigningKey`
  (encrypted keystore/passwords via Active Record Encryption, one per
  App), wired it into the existing PAD pipeline
  (`BundletoolService`/`AssetPackService`/`AnthropicAssetDeliveryJob`) so
  a release signs automatically when its app has a key configured, and
  added `ApkSigningService` for pre-flight keystore verification via
  `keytool`. Deliberately used bundletool's `--ks-pass file:...` /
  `--key-pass file:...` (and keytool's `-storepass:file` /
  `-keypass:file`) rather than the simpler `pass:...` forms, so signing
  passwords never appear in `ps`/process-argv on a shared host — worth a
  future session double-checking if this ever gets reviewed by someone
  with real JDK/bundletool access, since it wasn't runnable here.
  No `ruby` available in this sandbox this session (not even for a
  syntax check) — all Ruby here is hand-written/reviewed against existing
  patterns, not executed. Still needed before trusting this: real
  `db:encryption:init` + env vars, a real keystore + `verify!` call, one
  real signed build inspected with `apksigner verify`. No
  controller/UI for uploading a keystore yet — that's the natural next
  slice of #5 if it's not already covered by what's wanted from #7
  (Play publishing) needing something similar for API credentials.
