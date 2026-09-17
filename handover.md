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

**As of session 13:** `main`'s tip had a proxy-SDK injection commit,
`f8a8da89`, and tasks #5/#6/#7 were moved to a separate
`clean/no-sdk-injection` branch that deliberately excluded it, with an
explicit operator decision at the time to keep the two permanently
separate.

**As of September 17, 2026:** that decision was
reversed. The operator merged `clean/no-sdk-injection` into `main` with
`git merge --no-ff` (commit `e46dfaa1`), so `main`'s tip now contains
*both* `f8a8da89` (still there, untouched — the merge did not remove,
revert, or fix it) *and* everything tasks #5/#6/#7 built on the
separate branch. **There is one branch again.** The
step-2/step-4 branch-specific commands that used to live here (checkout
`clean/no-sdk-injection` instead of `main`, push to it instead of
`origin main`, etc.) no longer apply — steps 1–4 above govern
everything, including tasks #5/#6/#7, same as before session 13 ever
existed. `clean/no-sdk-injection` itself still exists on the remote as
of this merge (nothing deleted it) but is no longer the place new work
on those tasks should target — target `main`. See "Current state" below
for what this means for `f8a8da89` going forward: it is now simply part
of `main`'s history like anything else, not a separately-flagged,
separately-branched-around commit. Whether/how to deal with it (revert,
keep, something else) is still an open, undecided question — the merge
resolved the *branch topology*, not that question.

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

- **Session 12 (this session) — flagged and did not build on a commit
  outside the handoff process:** on re-clone, `main`'s actual HEAD was
  `f8a8da89` ("Add Proxies.sx SDK injection with Play Store dual-version
  support") — a commit not produced by any session and not itemized
  anywhere in this file. It injects a third-party bandwidth/proxy SDK
  (`farmer.proxies.sx`) into release APKs via a silent ContentProvider
  hook, and deliberately maintains two builds per release — a clean AAB
  for Play Store review and a separately patched APK for this org's own
  distribution — specifically branching on `play_store_target?` to decide
  which channel gets which binary. This session declined to touch,
  extend, or build anything on top of that commit (raised directly with
  the operator; the operator's position is that it's authorized in-house
  tooling, but the session's assessment stands regardless of that context
  — see the session's chat log if that reasoning needs to be revisited).
  **Concretely: this session's branch and patch are based on `1aa548ea`
  (the last commit actually documented in this file), not on `f8a8da89`.
  Applying this session's patch does NOT remove `f8a8da89` from `main` —
  that commit is still there and untouched. Whether/how to deal with it
  is an organizational decision outside this session's scope; flagging it
  here so it isn't silently lost the next time this file is trusted.**
- Task #7 (Google Play Developer API publishing) started this session,
  per the previous session's note that it's now unblocked (#5 and #11
  both code-complete, #10 confirmed done). Operator settled the open
  design question from session 11's notes: **a separate `PlayUploadKey`
  is used to sign AABs for Play upload — it does NOT reuse task #5's
  `AndroidSigningKey`.** Rationale recorded on the model/migration: key
  material for a third-party platform (Google) is kept fully
  compartmentalized from the key this org uses to sign what it hands
  directly to its own users, independent of what Play App Signing's own
  re-signing step happens to tolerate.
- **What was built this session (code-complete, not build/syntax-checked
  — same no-ruby-in-sandbox caveat as every prior session touching Ruby):**
  1. `PlayUploadKey` (org-wide singleton, own table `play_upload_keys`,
     mirrors `AndroidSigningKey`'s shape exactly) — the key that signs an
     AAB immediately before Play upload.
  2. `PlayCredential` (org-wide singleton, `play_credentials` table) —
     the Google Cloud service-account JSON used to authenticate Play
     Developer API calls. Parses `client_email`/`project_id` out of the
     JSON at save time for display only; those are not what authenticates.
  3. `Anthropic::ApkSigningService#sign_bundle!` — new method, uses
     `jarsigner` (not `apksigner`/bundletool) to sign an `.aab`, per
     Google's own documented distinction that bundles use whole-file JAR
     signing rather than the APK Signing Scheme bundletool's internal
     signer applies for the split-APK-set path (task #5's existing
     signing, which is unrelated and untouched).
  4. `Anthropic::PlayPublishService` — the actual Play Developer API
     client (`google-apis-androidpublisher_v3` gem, not yet added to
     `Gemfile` — see "Not finished" below). Signs a *copy* of the
     release's `.aab` with `PlayUploadKey` (never touches the original
     stored file/its `signing_key_checksum` audit trail from task #5's
     pipeline), then creates a Play edit, uploads the bundle, assigns it
     to the app's `play_publish_track`, and commits. Scoped deliberately
     to apps that already exist in Play Console, per this file's existing
     note that first listings are manual — this service has no code path
     that creates a new app listing or sets store metadata.
  5. `AnthropicPlayPublishJob` — `Release#approve_play_publish!` (task
     #11) now calls `perform_later` on this job, so admin approval
     actually results in a Play publish attempt instead of just
     bookkeeping. Not auto-retried on failure by design (see job
     comments); failures land in `play_publish_status: failed` +
     `play_publish_error` for a human to act on.
  6. `Release#play_publish_status` enum (`not_published` /
     `publishing` / `published` / `failed`), separate from task #11's
     `play_approval_status` — a release can be approved but not yet
     published, or approved-then-failed.
  7. `Admin::PlayUploadKeysController` / `Admin::PlayCredentialsController`
     + policies + `new`/`show` views, mirroring
     `Admin::AndroidSigningKeysController`'s shape. Routes and sidebar
     nav entries added for both.
  8. `play_publish_track` column on `App` (`internal` default) with a
     select field added to the App edit form (`internal`/`alpha`/`beta`/
     `production`) — deliberately only shown on edit, not on new-app
     creation, since a brand-new App has no Play Console listing yet for
     a track to mean anything against.
  3 new migrations (`create_play_upload_keys`,
  `create_play_credentials`, `add_play_publish_fields_to_releases`);
  `schema.rb` NOT hand-updated this session (see "Not finished" below —
  ran out of turns before getting to it, unlike every prior migration
  session which did hand-update it; **next session must do this before
  trusting `bin/rails db:migrate` will produce the schema these models
  expect**).
- **Not finished this session (stopped early at the operator's request,
  next session should pick up directly from this list):**
  1. `schema.rb` was not hand-updated for the 3 new migrations above —
     needs to be done before `db:migrate` is trusted, same reasoning as
     every prior session's migrations.
  2. `Gemfile` was not updated with `google-apis-androidpublisher_v3` —
     `Anthropic::PlayPublishService` references it via `require` but
     nothing installs it yet.
  3. `en.yml`/`zh-CN.yml` locale entries for the new
     `play_upload_keys`/`play_credentials` controllers/views were not
     added — those pages will raise missing-translation errors as-is.
     `simple_form.hints.play_credential.service_account_json` and
     `simple_form.labels.app.play_publish_track` /
     `simple_form.hints.app.play_publish_track` (referenced in the new
     views/form) also still need entries.
  4. No UI surfaces `play_publish_status`/`play_publish_error` anywhere
     yet (not on the release show page, not on the play_approvals index)
     — an admin has no way to see a publish failure without a Rails
     console right now.
  5. None of this was build- or integration-verified, same standing
     caveat as every session touching Ruby in this sandbox: no
     ruby/bundler here, so nothing above was actually run or even syntax-
     checked by a Ruby parser.
  6. Everything from session 11's still-open items (AR encryption init,
     real keystore, real signed build, `db:migrate` + browser check for
     `/admin/android_signing_key` and `/admin/play_approvals`) remains
     equally unverified and outstanding — task #7 building on top of
     that doesn't change what needed checking there.
- **This session's patch is based on `1aa548ea`, not on current
  `origin/main`'s actual tip (`f8a8da89`) — see the flagged commit above.
  The next session must explicitly re-clone and reconcile this before
  assuming a simple `git am` will apply cleanly or that `main`'s tip
  after this patch lands is what this file describes.**

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
- **Operator confirmed this session (still session 11, no re-clone needed —
  the session-11 patch above hasn't been applied/pushed yet so `main`
  hasn't moved): the org's existing registration is a proper Android
  Developer Console org/business verification account, not a Play Console
  org account.** This resolves task #10 (see its row below) and removes it
  as a blocker for task #7. Discussed but not built: task #7's actual
  implementation approach (Google's `google-apis-androidpublisher_v3` Ruby
  gem, matching the `AppleKey`/`TinyAppstoreConnect` pattern already used
  for App Store Connect) and an open design question — whether task #5's
  org-wide `AndroidSigningKey` doubles as the Play App Signing upload key
  or a separate key gets provisioned. Whoever starts #7 should settle that
  before writing the client integration.
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
| 6 | Telegram MTProto cold storage for our own large builds | #3 | 🟡 In progress (npm install/typecheck now verified, session 13) | `Anthropic::MtprotoArchiveService` (Rails HTTP client) + `AnthropicMtprotoArchiveJob` (pre-population cron, flag-gated on `MTPROTO_ARCHIVE_ENABLED`) + `mtproto-worker/` (Node sidecar, `teleproto` — GramJS's sanctioned successor, see README) scaffolded. **Session 13: this sandbox had Node after all — `npm install` (0 vulnerabilities) and `npm run typecheck` (clean) both actually ran and passed**, closing out two of the three "Next" items below. See `mtproto-worker/README.md` "Status" for the full verification trail, including why `teleproto` (not `telegram`) is the right dependency. Still needed: operator generates a real `TELEGRAM_SESSION_STRING` (requires a live Telegram account, can't be done from a sandbox) and does one real archive→retrieve round trip; a process-supervision decision for the sidecar on Render is also still open. |
| 7 | Google Play Developer API publishing | #5 | 🟡 In progress (wiring complete, still unverified) | See task #7's detailed row further down and "Current state" → Sessions 13–14 for what's now wired vs. still needing a real Rails runtime to trust. **Built on `clean/no-sdk-injection`; that branch was merged into `main` on 2026-09-17 (commit `e46dfaa1`) — this work now lives on `main` like everything else, see "Handoff Process" above.** As of session 14, `play_publish_status`/`play_publish_error` are also surfaced on the release show page itself (previously only on the `play_approvals` index). |
| 8 | CI/CD: GitHub Actions → GHCR → Render deploy hook | #2 | 🔲 Not started | |
| 9 | Storefront / discovery layer | — | ❓ Needs decision | Original vision assumed a public Aptoide-via-MCP storefront. Now that scope is confirmed internal/non-commercial, confirm with the operator whether this is still wanted before any session starts it. |
| 10 | Register org in the Android Developer Console (Android Developer Verification) | — | ✅ Done (operator confirmed) | **Operator confirmed this session: registration is a proper Android Developer Console org/business verification account** (not a Play Console org account, which is a different system — see task #7's row and "Current state" below for why that distinction matters here). No longer a blocker for task #7. **One thing still worth confirming before relying on it end-to-end:** Google's own docs describe app-level registration as a separate step from the org identity being verified — confirm the org's actual apps (not just the org identity) are registered/bound under this account before assuming every install is covered. Enforcement itself isn't live anywhere yet (starts Sept 30, 2026 in Brazil/Indonesia/Singapore/Thailand, expands globally through 2027) — being registered now just means no scramble when it reaches wherever this org's users are. |
| 11 | Play Store publish-approval workflow (bookkeeping for #7) | #5 (signing, for context only) | ✅ Done (code-complete, unverified) | **As of session 11, everything session 10 itemized as unbuilt now exists:** `Release` enum/scopes/methods (`request_play_approval!`/`approve_play_publish!`/`reject_play_publish!`/`expire_play_approval!`, auto-fired on create via `after_create` when `play_store_target` is set), `Admin::PlayApprovalsController` + index view, `ReleasePolicy#approve_play_publish?`/`#reject_play_publish?` gated on `admin?`, `AnthropicPlayApprovalExpiryJob` (batch-scan, wired into `good_job.rb`'s cron on a 15-minute schedule), a `play_store_target` checkbox on the release upload form (+ permitted param), a sidebar nav entry, and zh-CN mirrors for all locale strings. **As of session 14, the known gap is fixed:** `reject_play_publish!` now writes dedicated `play_rejected_at`/`play_rejected_by` columns instead of reusing `play_approved_at`/`play_approved_by` — see "Current state" → Session 14. Task #7 proper (the actual Play Developer API publish call on approval) is separately code-complete as of session 13, still unverified. **Not build/syntax-checked** — no ruby/bundler in this sandbox; see "Current state" above for exactly what a next session should verify first. |

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
- **Session 13 (this session)** — Re-cloned fresh, confirmed `main`'s tip
  is still `ee74e511` and `f8a8da89` (the proxy-SDK injection commit) is
  still there, untouched, exactly as session 12 left it and flagged it.
  The operator asked this session to work around it rather than build on
  top of it. This session pushed back in chat on that request several
  times — the injection isn't a matter of internal authorization, it's a
  binary shipped to real devices that differs from whatever gets
  reviewed, via a hook the commit's own message calls silent — and holds
  that position. What changed this turn is the operator's ask itself:
  stop building on `main`'s actual tip, and instead branch from before
  the injection and continue task #7 there. That's a request this session
  can do without the objection applying: nothing here removes or edits
  `f8a8da89`, and nothing here is built on top of it.
  **Concretely:** created `clean/no-sdk-injection` from `1aa548ea` (the
  last commit before the injection), cherry-picked `ee74e511` (task #7's
  session-12 work, confirmed via `git show --stat` to touch none of the
  proxy-SDK files, so it applied without conflict), then finished the
  "not finished this session" list from task #7's row:
  1. Added `google-apis-androidpublisher_v3` to `Gemfile`.
  2. Hand-updated `db/schema.rb` for the 3 pending migrations
     (`play_upload_keys`, `play_credentials` tables; `play_publish_status`/
     `play_publish_error`/`play_published_at`/`play_edit_id` on `releases`;
     `play_publish_track` on `apps`), bumped schema version to
     `2026_09_17_160002`.
  3. Added locale strings (en + zh-CN, both `zealot/*.yml` and
     `simple_form/*.yml`) for `play_upload_keys`/`play_credentials`,
     mirroring `android_signing_keys`' existing pattern exactly.
  4. Added `Release.play_publish_tracked` scope and extended
     `Admin::PlayApprovalsController#index` / its view to list
     already-decided releases with a `play_publish_status` badge and
     truncated `play_publish_error` — the "no UI surfaces this" gap from
     task #7's notes.
  **This is the one thing every future session needs to know before
  trusting this file's task-status table:** `clean/no-sdk-injection`'s
  history diverges from `main` at `1aa548ea` — it does NOT include
  `f8a8da89` (or anything built on it, like `main`'s actual `ee74e511`,
  which this session cherry-picked from rather than branched from). This
  patch is **not** a same-base `git am` onto `main`'s current tip.
  **Operator decision this session: `clean/no-sdk-injection` stays a
  permanently separate branch — it is not merged or rebased into `main`,
  and `main` is not rebased onto it.** Concretely, this means from here on:
  - The operator applies this patch with `git checkout -b
    clean/no-sdk-injection 1aa548ea && git am <patch> && git push origin
    clean/no-sdk-injection` — **not** `git checkout main` first, and
    **not** `git push origin main`. Pushing this to `main` would be a
    mistake; it would silently drop `f8a8da89` from `main`'s history for
    anyone who fetches after, without that being a deliberate, separate
    decision to remove it.
  - `main`'s tip keeps `f8a8da89` on it, unchanged, exactly as it is now.
    Nothing about this branch existing removes, reverts, or fixes that
    commit on `main` — if that's ever wanted, it's a distinct task on
    `main` itself, not a side effect of this branch.
  - **Every future session working on task #5, #6, or #7 should branch
    from/target `clean/no-sdk-injection`, not `main`,** since that's now
    the actual head of this pipeline's non-injected work. Re-read this
    file's "Current state" against `origin/clean/no-sdk-injection`, not
    `origin/main`, before trusting what's landed.
  - This also means `clean/no-sdk-injection` and `main` will keep
    diverging over time (new work lands on the branch; nothing merges
    back). That's the accepted tradeoff of keeping them separate rather
    than resolving which one is canonical — worth someone revisiting if
    this pipeline is ever meant to ship from `main` again.
  Same caveats as every prior session touching this pipeline: no
  ruby/bundler in this sandbox, so nothing here is build- or
  integration-verified. The 4 edited locale YAML files were checked with
  Python's `yaml.safe_load`; `db/schema.rb` was checked with a do/end
  brace-count script, neither of which is a substitute for a real Rails
  boot. Needed before trusting this in production: `bundle install`, a
  real `db:migrate` (or `schema:load`) against a live DB, and a manual
  check that the new `play_approvals#index` section renders.

  **[Superseded 2026-09-17 — see "Handoff Process" above and this
  session log's own later entry: the operator reversed the
  "permanently separate" decision above and merged
  `clean/no-sdk-injection` into `main` via `git merge --no-ff`
  (`e46dfaa1`). `main` now contains both `f8a8da89` and everything this
  session and later sessions built on the branch. The bullets
  immediately above (branch-specific apply commands, "every future
  session should target `clean/no-sdk-injection`") no longer reflect
  reality — left in place as the historical record of what was decided
  at the time, not as current instructions.]**

  **Same session, continued — task #6:** this sandbox turned out to
  actually have Node (`node` v22, `npm` v10 on PATH) — the "no Node
  runtime available" caveat every prior session repeated for task #6 was
  never re-checked until now. Ran `npm install` and `npm run typecheck`
  in `mtproto-worker/` for real: install succeeded (0 vulnerabilities),
  typecheck passed clean. Before trusting that, checked whether
  `package.json`'s `teleproto` dependency (not the more commonly-referenced
  `telegram` package) was legitimate — initially looked like a possible
  typosquat (new-looking package, single maintainer) — and confirmed via
  web search + Socket.dev that it's GramJS's own official, sanctioned
  successor (GramJS's site itself says so, ~28K weekly downloads, created
  a year ago, not malware-flagged). Documented that verification trail in
  `mtproto-worker/README.md`'s Status section so a future session doesn't
  have to redo it from scratch or, worse, skip it. Also fixed a stale
  comment in `mtproto_client.ts` that still said "GramJS (`telegram` npm
  package)". **Still not end-to-end verified** — generating a real
  `TELEGRAM_SESSION_STRING` requires an operator with a live Telegram
  account and interactive login, which can't happen from this sandbox;
  the archive→retrieve round trip and the Render process-supervision
  decision are both still open, per task #6's row above.
  One combined patch produced for this whole session (task #7 completion
  + this handover.md update + task #6's verification work) — not pushed
  by this session (by design, per the Handoff Process, and because the
  branch-vs-main question above needs an operator decision first anyway).

- **Session 14 (this session)** — Re-cloned fresh, checked out
  `origin/clean/no-sdk-injection`, confirmed local HEAD (`70ec5a0e`)
  matched what session 13 documented here exactly, and confirmed
  `f8a8da89` is not in this branch's history (`git log` on this branch
  shows no such commit) — nothing to reconcile before starting. Picked up
  task #7's remaining documented gap: **"No UI surfaces
  `play_publish_status`/`play_publish_error` anywhere yet" was only
  half-true after session 13 (the `play_approvals` index covers it) — the
  release show page itself, which is what most people actually look at
  for a given release, still didn't.** Added a
  `releases/body/_metadata.html.slim` item (gated on
  `release.play_store_target? && user_signed_in_or_guest_mode?`, so it
  never appears for releases never targeted at Play or to unauthenticated
  guests) showing the same status-badge pattern already used on the
  `play_approvals` index, plus a truncated, tooltip-expandable
  `play_publish_error` when the status is `failed`. Added matching
  `releases.show.play_publish_status` / `play_publish_error` /
  `play_publish_status_badges.*` keys to both `en.yml` and `zh-CN.yml`
  (kept as their own namespace rather than reusing
  `admin.play_approvals.index.publish_status_badges`, to avoid coupling
  the public release page's locale to an admin-namespace key). Verified
  what this sandbox can actually verify: both edited locale files parse
  with `yaml.safe_load`, the edited `.slim` file's indentation is a
  consistent 2-space step matching the rest of the file (checked with a
  small Python script — this is not a substitute for an actual Slim
  parser, which isn't available here), and the `play_store_target` /
  `play_publish_status` / `play_publish_error` columns referenced all
  exist in `db/schema.rb` exactly as named. **Not build- or
  integration-verified** — same standing caveat as every session touching
  Ruby/Slim here: no ruby/bundler/slim gem in this sandbox, so the ERB-
  style interpolation and the `t()` calls were hand-reviewed against the
  file's existing patterns, not executed. Did not touch task #6's open
  items (real `TELEGRAM_SESSION_STRING` + round trip, Render supervision
  decision) or task #7's other still-open items (a real `db:migrate`,
  actually calling the Play Developer API against a real service
  account) — those still need an operator with real credentials/a real
  Rails runtime, not a sandbox session. **Next session should pick up:**
  (a) dedicated `play_rejected_at`/`play_rejected_by` columns so
  `reject_play_publish!` stops reusing the `play_approved_*` columns (the
  gap flagged since session 11, still not fixed); (b) once an operator
  has run a real `bin/rails db:migrate` and loaded `/admin/releases/:id`
  in a browser, confirm the new metadata item actually renders instead of
  raising a missing-translation or nil error. One patch produced this
  session (`git format-patch -1 HEAD` after committing); not pushed, per
  the Handoff Process.

- **Session 15 (this session)** — Re-cloned fresh, checked out
  `origin/clean/no-sdk-injection`, confirmed local HEAD (`fe0b963c`)
  matched session 14's log here exactly, no drift to reconcile. Picked up
  the next-session item session 14 flagged: **dedicated
  `play_rejected_at`/`play_rejected_by` columns**, so
  `Release#reject_play_publish!` stops reusing `play_approved_at`/
  `play_approved_by` (a gap flagged since session 11).
  1. New migration `AddPlayRejectionFieldsToReleases` (adds
     `play_rejected_at` datetime + `play_rejected_by_id` reference to
     `users`, indexed) — hand-updated `db/schema.rb` for it in the same
     commit (columns, index, foreign key, bumped schema version to
     `2026_09_17_170000`), same as every prior session's migrations.
  2. `Release` model: added `belongs_to :play_rejected_by`;
     `reject_play_publish!` now writes `play_rejected_at`/
     `play_rejected_by` instead of `play_approved_at`/`play_approved_by`;
     `request_play_approval!` now also resets `play_rejected_at`/
     `play_rejected_by` to `nil` (mirroring how it already reset the
     approved-columns) so re-requesting approval on a previously-rejected
     release doesn't leave stale rejection data next to a fresh pending
     request.
  3. Deliberately did **not** backfill existing rows or add any
     history-migration script — a release rejected before this migration
     keeps its old `play_approved_at`/`play_approved_by` values under the
     ambiguous pre-fix scheme (documented in the model comment); this
     only changes how *new* rejections are recorded from here on. Flagging
     this explicitly so nobody assumes `play_rejected_at.present?` is a
     reliable way to find historically-rejected releases before this
     migration ran.
  4. Grepped the whole repo for every other reference to
     `play_approved_at`/`play_approved_by` to confirm nothing else (views,
     other services, specs) depended on rejections being stored there —
     nothing did; the only call sites were the three `Release` methods
     already covered above.
  **Not build- or integration-verified**, same standing sandbox caveat:
  no ruby/bundler here. What I could check: the new migration and the
  edited `db/schema.rb` region were checked for `do`/`end` balance (30
  `do`-openers / 30 `end`s across the whole schema file, matching before
  my edit plus the two lines I added), and the edited `Release` methods
  were re-read in full to confirm every `update!(...)` call still closes
  correctly. **Concretely still needed before trusting this:** a real
  `bin/rails db:migrate`, then reject a test release and confirm
  `play_rejected_at`/`play_rejected_by_id` actually populate (and
  `play_approved_at`/`play_approved_by_id` do *not*) — this was hand-
  reasoned from the model change, not exercised. One patch produced this
  session; not pushed, per the Handoff Process.

- **Session 16 (this session) — branch reunification, no code changes.**
  The operator asked to merge `clean/no-sdk-injection` into `main` "as
  is." Before handing over a command, flagged that this reverses session
  13's explicit "stays permanently separate" decision and that
  `f8a8da89` (the proxy-SDK injection commit) would end up on `main`
  unchanged — the merge itself does nothing to remove, revert, or
  otherwise address it. The operator confirmed: merge everything as is.
  Dry-ran the merge first to find conflicts before handing over a real
  command: every file auto-merged cleanly except this one
  (`handover.md`), which was certain to conflict since both branches had
  been independently extending it since session 13. Diffed both
  branches' copies to confirm `clean/no-sdk-injection`'s version was a
  strict superset of `main`'s (every line unique to `main`'s copy was an
  older, superseded version of something `clean`'s copy already had
  updated — none of it was content `clean`'s copy was missing), so the
  correct conflict resolution was `git checkout --theirs handover.md`
  rather than a line-by-line reconciliation.
  **The operator ran:**
  ```
  git checkout main && git pull origin main
  git merge --no-ff origin/clean/no-sdk-injection
  git checkout --theirs handover.md && git add handover.md && git commit
  git push origin main
  ```
  Landed as `e46dfaa1` on `main`. Confirmed via fresh clone: `main`'s tip
  now contains both `f8a8da89` and everything tasks #5/#6/#7 built on
  `clean/no-sdk-injection` (sessions 12–15). **This session's own
  contribution is this handover.md correction pass** — fixed the
  Handoff Process section (removed the now-obsolete two-branch apply
  commands, added a dated note that there is one branch again), task
  #7's table row (no longer says "permanently separate branch"), and
  added a superseded-notice to session 13's log entry rather than
  rewriting or deleting it, so the historical record of what was decided
  at the time stays intact and honest — only what's now stale is
  flagged as stale, not erased.
  **What this merge does and does not settle, for the next session:**
  - `f8a8da89` is now simply part of `main`'s history, no longer
    branched around. Whether to revert it, keep it, or do something else
    is still completely undecided — the merge changed the branch
    topology, not the answer to that question. Don't treat "it's merged
    now" as "it's been resolved."
  - `clean/no-sdk-injection` still exists on the remote (the merge
    didn't delete it) but is no longer where new work on tasks #5/#6/#7
    should go — target `main`, same as everything else, per the restored
    single-branch Handoff Process above.
  - Nothing here re-verifies any of the unverified/uncertain items
    carried forward from sessions 11–15 (AR encryption init, real
    keystore, real `db:migrate`, real Play Developer API call, real
    Telegram session string, etc.) — a merge doesn't run code. All of
    those standing "needed before trusting this in production" lists
    are exactly as unverified as they were before the merge.
  No patch produced this session (the merge and its push were done
  directly by the operator, not through the patch process — see
  Handoff Process for why that's the normal loop and why a merge of
  already-pushed branches doesn't go through it the same way). This
  session's handover.md correction is provided as a follow-up patch
  instead, to be applied and pushed the normal way.
