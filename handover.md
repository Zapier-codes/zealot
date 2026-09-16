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

- HEAD: `c0470e01` "Task 5: org-wide signing key; task 11: start Play
  approval workflow", on top of `5d54c81e`. Confirmed landed on
  `origin/main` by fresh fetch before starting this session (per the
  Handoff Process above) — local clone matched `origin/main` exactly, no
  drift this time.
- **This session (session 11) finished what session 10 left itemized as
  not-built for #5 and #11:**
  1. Task #5: wrote the missing `app/views/admin/android_signing_keys/
     {new,show}.html.slim` (+ a `_form` partial) — the controller/policy
     from session 10 would 500 without these; they now exist and mirror
     `AppleKey`'s upload/show shape. Added `simple_form` labels/hints for
     the five keystore form fields (`en.yml`/`zh-CN.yml`).
  2. Task #11: built everything session 10 left unbuilt except the actual
     Play Developer API call (that remains task #7 proper):
     - `Release` model: `play_approval_status` enum (`not_requested` /
       `pending` / `approved` / `rejected` / `expired`, prefixed
       `play_approval_`), `play_store_targeted` / `awaiting_play_approval`
       / `play_approval_overdue` scopes, and
       `request_play_approval!` / `approve_play_publish!` /
       `reject_play_publish!` / `expire_play_approval!` methods. An
       `after_create :request_play_approval_if_targeted` callback starts
       the 48h clock automatically when a release is uploaded with
       `play_store_target` set.
     - `Admin::PlayApprovalsController` (`index`/`approve`/`reject`) —
       the routes session 10 added now resolve to something.
     - `app/views/admin/play_approvals/index.html.slim` — approval queue
       table using the locale strings session 10 already wrote.
     - `ReleasePolicy#approve_play_publish?` / `#reject_play_publish?`,
       gated on `admin?` specifically (not `any_manage?`), per session
       10's explicit note that this is an org-level decision, not an
       app-level one.
     - `AnthropicPlayApprovalExpiryJob`, following
       `AnthropicMtprotoArchiveJob`'s batch-scan pattern as instructed,
       wired into `good_job.rb`'s `CRON_JOBS_SETUP` on a 15-minute cron
       (always-on, no feature flag — unlike the MTProto job this isn't an
       external integration needing credentials, so there's nothing to
       gate on; the query is a no-op until releases actually get targeted
       at Play Store).
     - `play_store_target` checkbox added to `releases/_form.html.slim`;
       permitted in `ReleasesController#release_params`. This is the one
       piece not explicitly itemized by session 10 as "next" but was
       required for #11 to be usable end-to-end (nothing previously set
       the column).
  3. Also added, not itemized by session 10 but needed for reachability:
     sidebar links (`app/views/layouts/_main_sidebar.html.slim`) to both
     `admin_android_signing_key_path` and `admin_play_approvals_path` —
     neither had a nav entry, so both were previously URL-only.
  4. `zh-CN.yml`/`simple_form.zh-CN.yml` mirrors added for all of the
     above (session 10 had only added zh-CN entries for the two new
     *error*-attribute keys, not the view-level strings — this session
     filled in the rest).
  5. **Known gap, not fixed this session:** `Release#reject_play_publish!`
     reuses the `play_approved_at`/`play_approved_by` columns for
     rejections too, since session 10's migration only added "approved"
     columns, not separate `rejected_at`/`rejected_by` ones. Flagged
     in-code; a follow-up migration adding dedicated columns is worth
     doing if anyone ever needs to distinguish approval history from
     rejection history at a glance.
  Task #5 and #11 are now believed feature-complete for what was scoped
  (see "Not build- or integration-verified" below for what that claim does
  and doesn't cover).
- **Not build- or integration-verified** — same posture as every prior
  session touching Ruby: no `ruby`/`bundler` in this sandbox this session
  either, so none of the above was actually run or syntax-checked by a
  Ruby parser. What IS true this session: the four edited/added locale
  YAML files (`en.yml`, `zh-CN.yml`, `simple_form.en.yml`,
  `simple_form.zh-CN.yml`) were parsed with Python's `yaml.safe_load` and
  confirmed to be syntactically valid YAML — that catches indentation/
  quoting mistakes but says nothing about whether the Ruby files
  referencing those keys are correct, or whether the keys resolve where
  each `t('.foo')` call expects. Everything Ruby here (model, controller,
  policy, job, views' embedded Ruby) is hand-written/reviewed against the
  existing `AppleKey`/`AnthropicMtprotoArchiveJob`/`Admin::AppleKeysController`
  conventions, not run. Concretely still needed before trusting this in
  production, on top of session 10's carried-forward items (AR encryption
  init, real keystore, real signed build):
  1. `bin/rails db:migrate`, then actually load `/admin/android_signing_key`
     and `/admin/play_approvals` in a browser and confirm they render
     (these are exactly the views this session added to fix the 500).
  2. Upload one release with `play_store_target` checked and confirm the
     approval-request flow actually fires (`play_approval_status` flips to
     `pending`, `play_approval_expires_at` gets set ~48h out).
  3. Manually set a test release's `play_approval_expires_at` into the
     past and confirm `AnthropicPlayApprovalExpiryJob` actually flips it
     to `expired` on its next run (or run it manually via `rails runner`).
  4. Confirm `admin?`-only gating on approve/reject actually blocks a
     non-admin developer/collaborator (this was hand-reasoned from
     `ReleasePolicy`'s existing `any_manage?` pattern, not exercised).
- `main` has moved upstream between sessions before (5 unrelated upstream
  commits appeared, then were gone by the time of a later session's
  re-clone — origin drift is possible between sessions). **Every session
  should re-clone fresh and diff against what it expects before assuming a
  prior patch's context still matches `main` exactly.**
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
| 5 | Signing pipeline for our own AABs | — | 🟡 In progress (code-complete, unverified) | Org-wide singleton `AndroidSigningKey` (`AndroidSigningKey.current`), `Admin::AndroidSigningKeysController` + policy, and — **as of session 11** — the previously-missing `new`/`show` views (`app/views/admin/android_signing_keys/`) plus a sidebar nav entry, so `/admin/android_signing_key` no longer 500s and is reachable from the UI. Still needs, before trusted: `bin/rails db:encryption:init` run for real + `ANTHROPIC_AR_ENCRYPTION_*` env vars, a real keystore uploaded through the controller, one real signed build inspected with `apksigner verify` — none of that is possible in this sandbox. Reminder carried from earlier sessions: signing with the key does **not** make a sideloaded install show as "from a verified developer" (that's task #10, a separate system). |
| 6 | Telegram MTProto cold storage for our own large builds | #3 | 🟡 In progress | `Anthropic::MtprotoArchiveService` (Rails HTTP client) + `AnthropicMtprotoArchiveJob` (pre-population cron, flag-gated on `MTPROTO_ARCHIVE_ENABLED`) + `mtproto-worker/` (Node/GramJS sidecar) scaffolded. See `mtproto-worker/README.md` "Status" for what's unverified — not build- or integration-tested (no Node runtime or real Telegram credentials in sandbox). Next: operator generates `TELEGRAM_SESSION_STRING`, provisions the sidecar, runs `npm install && npm run typecheck`, and does one real archive→retrieve round trip before this is trusted. |
| 7 | Google Play Developer API publishing | #5 | 🔲 Not started (groundwork started) | First listing is manual per Play's own constraints; automate only subsequent releases. **This session added the publish-approval bookkeeping only** (operator decision: a release targeting Play Store needs explicit admin approval, auto-expiring after 48h to internal-distribution-only if nobody acts — see task #11 for the full breakdown of what's built vs. not). The actual Play Developer API publish call itself is still not started. |
| 8 | CI/CD: GitHub Actions → GHCR → Render deploy hook | #2 | 🔲 Not started | |
| 9 | Storefront / discovery layer | — | ❓ Needs decision | Original vision assumed a public Aptoide-via-MCP storefront. Now that scope is confirmed internal/non-commercial, confirm with the operator whether this is still wanted before any session starts it. |
| 10 | Register org in the Android Developer Console (Android Developer Verification) | — | 🔲 Operator action needed | **Not code — an account registration, done outside this repo.** Google is rolling out a requirement, separate from Play Store and separate from APK signing, that an app be registered to an identity-verified developer account to install/update normally on certified Android devices at all. Registration opened March 2026 for developers distributing outside Play Store (our exact case for Zealot's sideload distribution); enforcement started Sept 30 2026 in Brazil/Indonesia/Singapore/Thailand and expands globally through 2027, after which unregistered apps need an "advanced flow" (ADB or a deliberately-frictioned manual install) instead of a normal install. Having an existing Play Console org account does **not** cover this — it's a distinct system/registration. Low-effort to do now rather than waiting for global enforcement to bite. No code dependency on task #5 or #7, but worth doing before #7 (Play publishing) since both concern the same org's Google-facing identity. |
| 11 | Play Store publish-approval workflow (bookkeeping for #7) | #5 (signing, for context only) | ✅ Done (code-complete, unverified) | **As of session 11, everything session 10 itemized as unbuilt now exists:** `Release` enum/scopes/methods (`request_play_approval!`/`approve_play_publish!`/`reject_play_publish!`/`expire_play_approval!`, auto-fired on create via `after_create` when `play_store_target` is set), `Admin::PlayApprovalsController` + index view, `ReleasePolicy#approve_play_publish?`/`#reject_play_publish?` gated on `admin?`, `AnthropicPlayApprovalExpiryJob` (batch-scan, wired into `good_job.rb`'s cron on a 15-minute schedule), a `play_store_target` checkbox on the release upload form (+ permitted param), a sidebar nav entry, and zh-CN mirrors for all locale strings. One known gap: `reject_play_publish!` reuses the `play_approved_at`/`play_approved_by` columns rather than having dedicated rejection columns (see "Current state" above) — functions correctly, just semantically fuzzy in the DB. Task #7 proper (the actual Play Developer API publish call on approval) is still separately not started. **Not build/syntax-checked** — no ruby/bundler in this sandbox; see "Current state" above for exactly what a next session should verify first. |

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
- **Session 11 (this session)** — Re-cloned fresh; confirmed `main`
  matched `origin/main` exactly at `c0470e01` (no drift this time). Picked
  up directly from session 10's next-session list: wrote the missing
  `admin/android_signing_keys/{new,show}` views (task #5), then built out
  everything session 10 had left unbuilt for task #11 (`Release` model
  methods, `Admin::PlayApprovalsController`, its index view, `ReleasePolicy`
  gating, the 48h expiry cron job) plus two things not explicitly itemized
  but needed for either feature to actually be reachable/usable: a
  `play_store_target` checkbox on the release upload form (nothing
  previously set that column), and sidebar nav links for both new admin
  pages (neither had one). Filled in the zh-CN view-level locale strings
  session 10 had left only partially mirrored. See "Current state" and
  tasks #5/#11 above for the itemized list of what specifically landed and
  the known columns-reuse gap in `reject_play_publish!`. Not build- or
  integration-verified — no ruby/bundler in this sandbox; the four edited
  locale YAML files were parsed with Python's `yaml.safe_load` and
  confirmed syntactically valid, which is the only mechanical check this
  session could actually run. One combined patch produced; not pushed by
  this session (by design, per the Handoff Process).
