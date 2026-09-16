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
- **Correction to the above, made this session:** session 8's patch (task 5:
  `android_signing_key.rb`, `apk_signing_service.rb`, bundletool/job wiring,
  AR Encryption initializer, two migrations) was described above as "not yet
  pushed," but a fresh clone this session shows it **is** on `origin/main` as
  `5d54c81e`, on top of `ab603383`. This is exactly the origin-drift case the
  Handoff Process warns about — this file's "Current state" had gone stale
  relative to GitHub. Treat `5d54c81e` as the confirmed current HEAD of
  `main` going forward, not `ab603383`.
- **This session's changes (stopped partway through, by operator request —
  see task #11 above for the full itemization of what's unfinished):**
  1. Task #5: `AndroidSigningKey` converted from one-per-App to an org-wide
     singleton (migration `20260917150000_make_android_signing_keys_org_wide.rb`
     removes `app_id`; `App#android_signing_key` removed;
     `AndroidSigningKey.current` is the new accessor;
     `AnthropicAssetDeliveryJob` updated to use it). New
     `Admin::AndroidSigningKeysController` + `AndroidSigningKeyPolicy`
     (singular `admin/android_signing_key` route) for uploading/verifying/
     destroying the key — **views not written, will 500 until they exist.**
  2. Task #11 (new): Play Store publish-approval bookkeeping started —
     migration `20260917150001_add_play_approval_fields_to_releases.rb`
     adds the approval-status columns to `releases`; routes for
     `admin/play_approvals` added — **but the controller, `Release` model
     changes, policy methods, views, and the 48h expiry cron job are all
     still unbuilt.** Do not consider #11 usable yet.
  3. Locale strings added for both of the above in `en.yml`/`zh-CN.yml`.
  Nothing in this session was build- or integration-verified (no
  `ruby`/`bundler` in this sandbox, same as every prior session touching
  Ruby) — everything above is hand-written/reviewed against existing
  conventions (`AppleKey`, `AnthropicMtprotoArchiveJob`), not run.
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
| 5 | Signing pipeline for our own AABs | — | 🟡 In progress | **Changed this session by operator decision: `AndroidSigningKey` is now an org-wide singleton, not one-per-App** (every AAB through this pipeline comes from this one org, so one shared key signs all of it). `AndroidSigningKey.current` is the one place that resolves "the current key" — `AnthropicAssetDeliveryJob` now calls that instead of `release.app.android_signing_key`. `App#android_signing_key` association is gone. Model enforces singleton-ness at the app level (`only_one_record` validation on create), deliberately no DB-level constraint for it. Blast-radius tradeoff of one shared key (vs. one per App) was raised and the operator chose shared — worth remembering if this ever gets revisited. `Admin::AndroidSigningKeysController` + `AndroidSigningKeyPolicy` built this session (singular resource `admin/android_signing_key`, mirrors `AppleKey`'s upload/verify/destroy shape, calls `AndroidSigningKey#verify!` via keytool before saving). **Not done: the views** (`app/views/admin/android_signing_keys/{new,show}.html.slim` — locale strings for them exist under `admin.android_signing_keys.*` in both `en.yml`/`zh-CN.yml`, but no `.slim` templates were written, so `new`/`show` will 500 until they exist). Still also needs, before trusted: `bin/rails db:encryption:init` run for real + `ANTHROPIC_AR_ENCRYPTION_*` env vars, a real keystore uploaded through the new controller, one real signed build inspected with `apksigner verify`. Reminder carried from last session: signing with the key does **not** make a sideloaded install show as "from a verified developer" (that's task #10, a separate system). |
| 6 | Telegram MTProto cold storage for our own large builds | #3 | 🟡 In progress | `Anthropic::MtprotoArchiveService` (Rails HTTP client) + `AnthropicMtprotoArchiveJob` (pre-population cron, flag-gated on `MTPROTO_ARCHIVE_ENABLED`) + `mtproto-worker/` (Node/GramJS sidecar) scaffolded. See `mtproto-worker/README.md` "Status" for what's unverified — not build- or integration-tested (no Node runtime or real Telegram credentials in sandbox). Next: operator generates `TELEGRAM_SESSION_STRING`, provisions the sidecar, runs `npm install && npm run typecheck`, and does one real archive→retrieve round trip before this is trusted. |
| 7 | Google Play Developer API publishing | #5 | 🔲 Not started (groundwork started) | First listing is manual per Play's own constraints; automate only subsequent releases. **This session added the publish-approval bookkeeping only** (operator decision: a release targeting Play Store needs explicit admin approval, auto-expiring after 48h to internal-distribution-only if nobody acts — see task #11 for the full breakdown of what's built vs. not). The actual Play Developer API publish call itself is still not started. |
| 8 | CI/CD: GitHub Actions → GHCR → Render deploy hook | #2 | 🔲 Not started | |
| 9 | Storefront / discovery layer | — | ❓ Needs decision | Original vision assumed a public Aptoide-via-MCP storefront. Now that scope is confirmed internal/non-commercial, confirm with the operator whether this is still wanted before any session starts it. |
| 10 | Register org in the Android Developer Console (Android Developer Verification) | — | 🔲 Operator action needed | **Not code — an account registration, done outside this repo.** Google is rolling out a requirement, separate from Play Store and separate from APK signing, that an app be registered to an identity-verified developer account to install/update normally on certified Android devices at all. Registration opened March 2026 for developers distributing outside Play Store (our exact case for Zealot's sideload distribution); enforcement started Sept 30 2026 in Brazil/Indonesia/Singapore/Thailand and expands globally through 2027, after which unregistered apps need an "advanced flow" (ADB or a deliberately-frictioned manual install) instead of a normal install. Having an existing Play Console org account does **not** cover this — it's a distinct system/registration. Low-effort to do now rather than waiting for global enforcement to bite. No code dependency on task #5 or #7, but worth doing before #7 (Play publishing) since both concern the same org's Google-facing identity. |
| 11 | Play Store publish-approval workflow (bookkeeping for #7) | #5 (signing, for context only) | 🟡 Started, incomplete | Operator decision this session: a release with Play Store as a target doesn't auto-publish — it needs explicit admin approval, and if 48h pass with no action it expires and the release stays available only through our own internal distribution (nothing about this ever takes a release down from internal distribution). **Built this session:** migration + hand-updated `schema.rb` adding `play_store_target` (boolean), `play_approval_status` (string, default `not_requested`), `play_approval_requested_at`, `play_approval_expires_at`, `play_approved_at`, `play_approved_by_id` (FK `users`) to `releases`, with indexes; routes for `admin/play_approvals` (`index`, member `approve`/`reject`); locale strings (`admin.play_approvals.*`, both `en.yml`/`zh-CN.yml`). **Not built — this is most of the feature, next session should start here:** (1) `Release` model has no enum/scopes/methods yet for the new columns — no `play_approval_status` enum, no `request_play_approval!`/`approve_play_publish!`/`reject_play_publish!`, nothing computes `play_approval_expires_at` at request time; (2) `Admin::PlayApprovalsController` does not exist yet — the routes added this session point at a controller that isn't there; (3) no views for it either; (4) `ReleasePolicy` has no `approve_play_publish?`/`reject_play_publish?` (should almost certainly gate on `admin?` specifically, not the app-scoped `any_manage?` the rest of that policy uses, since this is an org-level publishing decision, not an app-level one); (5) no cron job for the 48h auto-expiry — should follow `AnthropicMtprotoArchiveJob`'s batch-scan pattern (`app/jobs/anthropic_mtproto_archive_job.rb`) rather than a per-release delayed job, and get wired into `config/initializers/good_job.rb`'s `CRON_JOBS_SETUP`; (6) nothing sets `play_store_target` anywhere — no UI on the release upload form, so as of this session the column exists but nothing ever flips it true; (7) the actual Play Developer API publish call on approval is task #7 proper and is separately not started. Not build/syntax-checked, same caveat as every session touching Ruby in this sandbox. |

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
- **Session 9 (this session)** — Re-cloned fresh per the Handoff Process and
  found this file's "Current state" had drifted from `main`: session 8's
  patch (task 5) was marked "not yet pushed" but is actually already landed
  as `5d54c81e` — corrected above. No code changes this session (operator
  brought a correction/new item, not a coding task): clarified in task #5's
  notes that a matching Play Store signing key does not make sideloaded
  installs show as "from a verified developer" (that's an install-source
  signal, not a signing-identity one); added task #10, registering the org
  in the new Android Developer Console for Android Developer Verification —
  a separate system from both Play Store distribution and APK signing, and
  not already covered by the existing Play Console org account. Operator
  should treat #10 as actionable now (registration is open, enforcement is
  already live in 4 countries and expanding through 2027) rather than
  waiting.
- **Session 10 (this session)** — Operator raised two things: (a) whether
  the signing key could be org-wide instead of per-App, since every AAB
  through this pipeline is this org's own — confirmed technically fine,
  flagged the blast-radius tradeoff, operator chose shared; (b) whether the
  existing Play Console org account already grants the "verified developer"
  badge this org wants for its own app store, plus a proposed workflow
  where non-Play-Store-bound releases go out immediately on our own store
  while Play-Store-bound releases wait on 48h-timeboxed admin approval.
  Corrected the premise: the Play Console org account is not the same
  system as Android Developer Verification (task #10) — neither the shared
  key nor the Play Console account confers a "verified" badge on sideloaded
  installs, and once #10 is registered it applies uniformly to all of the
  org's distributed apps rather than selectively by destination. The
  48h-approval-timeout idea itself is sound as a *publishing gate* (separate
  from device-level verification) and was scoped as task #11. Started
  building both (see task #5 and #11 above and "Current state" above for
  exactly what landed vs. didn't) but stopped partway through at the
  operator's request before task #11's controller/model/views/cron job were
  built — **next session should pick up directly from task #11's
  not-built list**, and should also write the missing
  `admin/android_signing_keys/{new,show}` views for task #5 before trying
  to use that controller. One combined patch produced for everything that
  *did* land this session; not pushed by this session (by design).
