# Zealot — Session Handover

This file tracks the task board for this repo. A prior `handover.md`
existed in this repo's history but was removed (commit `4996098`, "Remove
handover.md") and is not carried forward here — task statuses below for
Tasks 6, 7 and 9 are as reported by the operator, not re-derived from that
removed file or independently re-verified against the code.

## Handoff process (unchanged repo convention)

1. Session does the work on a branch, never pushes directly to `develop`/`main`.
2. Session runs `git format-patch -1 HEAD` (or `-N` for N commits) to produce
   a `.patch` file and hands it off — no push from the session.
3. Operator applies it themselves. **Outstanding patches, apply in this
   order** (adjust filenames below to match whatever your download
   actually saved them as, if different):
   ```
   cd ~/zealot
   git am ~/storage/downloads/zealot-landing-page-auth-glassmorphism.patch
   git am ~/storage/downloads/zealot-handover-task-board-update.patch
   git push
   ```
   The second patch (task-board doc update) is commit-stacked directly on
   top of the first in this session's branch — apply them in that order,
   not the reverse. Both are single commits, so each `git am` call applies
   exactly one.
   This session's patch is a single commit on top of `develop` (branch
   `feat/landing-page-and-auth-glassmorphism`), so `git am` applies
   directly to whatever branch you're currently on — check `git status`
   first and `git checkout develop` if you're not already there. `git am`
   fails loudly (not silently) if the tree has diverged since this patch
   was generated; if that happens, don't force it — pull first, rebase the
   patch, or flag it back to the next session rather than resolving
   conflicts blind.
4. Build/behavior is verified after that push (CI, or a manual smoke test),
   not claimed as verified by the session itself — nothing in this session
   was run through Ruby/Node locally (no Ruby/Node runtime in the sandbox
   this was written in), so treat everything below as **code-complete,
   not syntax- or build-checked**.

## Task board

Status markers: 🟢 done and merged · ✅ code-complete, patch handed off,
awaiting operator apply/verify · 🟡 in progress, needs live config/creds ·
🆕 newly requested, not started · ❓ needs an operator decision before any
session should start building.

### 🟢 Landing page + auth glassmorphism — done, merged, live

Applied by the operator: commit `7624295` is on `develop` and has been
deployed (`deploy-7624295` in Render's deploy history). Three follow-up
fix commits landed on top of it since (`cef5e83`, `fb99d46`, `e2abc22`).
See "What was built this session" below (in the original session's
section, kept for history) for the full breakdown of what shipped.

**Bug found and fixed this session:** `HomeController#index` (added by
this task) called the bare method `site_title`, but that method only
exists in `ApplicationHelper` — never mixed into controllers, never
declared with `helper_method`. Every signed-out visit to `/` raised
`NameError: undefined local variable or method 'site_title'` and
returned a 500. Fixed by switching to `Setting.site_title` directly,
matching the existing convention in `device_attributes.rb` and
`user_mailer.rb`. Patch: `0001-Fix-NameError-on-landing-page-use-Setting.site_title.patch`,
branch `fix/home-controller-site-title-nameerror`, base `develop`. Not
yet applied as of this doc.

### 🟡→ Task 6: Telegram MTProto Cold Storage (operator reports fully wired)
Operator states all live credentials (`TELEGRAM_API_ID`, `TELEGRAM_API_HASH`,
`TELEGRAM_SESSION_STRING`, `TELEGRAM_ARCHIVE_CHAT_ID`) are now set on Render
and `MTPROTO_ARCHIVE_ENABLED` is intended to be `true`. Not independently
re-verified against the code this session (no Node runtime in this sandbox).

**Note from this session's 502 debugging:** `MTPROTO_ARCHIVE_ENABLED` was
temporarily flipped to `false` on Render to rule the worker out as the
cause of a 502 the operator was seeing. It was ruled out — see the 502
investigation note below — but the flag was left `false` and needs to be
flipped back to `true` before Task 6 can be considered live again.

Remaining step: **do one real archive → retrieve round trip against a
test chat** to confirm the wiring actually works end-to-end — this has
not been verified, only configured.

### 502 investigation (this session)
Operator reported `zealot-web` returning 502. Root-caused via Render logs
and deploy history, not the mtproto sidecar:
- The container's `mtproto-worker` s6 service was briefly suspected (it
  crash-loops if Telegram creds are invalid, and starting it coincided
  with when the 502s began) — ruled out by disabling it and confirming
  the 502 persisted.
- Actual cause: `zealot-web` had **18 deploys in ~14 hours** that day
  (`deploy_hook`-triggered by pushes to `develop`, plus a few
  `service_updated`/`manual`/`api` ones). Each deploy replaces the
  free-tier instance's only container, so a request landing mid-rollover
  gets a 502. Not a crash loop, not an app bug — just very frequent
  redeploys during active development.
- `healthCheckPath` was empty on the service (`serviceDetails.healthCheckPath: ""`).
  This does **not** explain the 502s (Render only runs health-check-driven
  restarts when a path is configured), but it was still worth setting —
  now set to `/` so future zero-downtime deploys can actually tell when
  the new instance is ready before cutting traffic over. This depends on
  the `site_title` fix above being applied first, since `/` 500'd before
  that patch.

### 🟡 Task 7: Google Play Developer API Publishing (In Progress)
The code is complete, but it requires live configuration and verification on your Render server.
1. **Database Migration:** Run `bin/rails db:migrate` on Render to create the `play_upload_keys`, `play_credentials` tables, and the `play_rejection_fields` columns.
2. **Credentials:** Create a Google Cloud Service Account, link it to your Play Console, and upload the `service_account.json` via the Zealot Admin UI (`/admin/play_credential`).
3. **Upload Key:** Upload a `PlayUploadKey` (keystore) via the Zealot Admin UI (`/admin/play_upload_key`).
4. **Verification:** Test the end-to-end flow: upload a release, check the `play_store_target` box, approve it, and verify it actually publishes to the Google Play Store.

> Same caveat as Task 6 — status as reported, not re-verified this session.

### ❓ Task 9: Storefront / Discovery Layer (Needs Decision)
This was deferred until the console was successfully hosted. Now that Zealot is live on Render, the operator needs to decide:
- Do you want a public-facing Aptoide-style storefront?
- Or will you keep it strictly internal for your employees?
If you want it, a session needs to be started to build the public discovery layer UI.

### 🆕 Task 12: Automated Email Infrastructure (New — not started)

Four transactional/campaign emails, sent to platform users, triggered via
Supabase RPC triggers on the Postgres side:

1. **App deploy notification** — sent when a user deploys/publishes an app.
2. **Custom branding campaign** — a platform marketing/branding campaign
   email (broadcast-style, not per-event).
3. **Payment receipt/invoice** — sent when a user pays for publishing;
   needs to include the invoice and the receipt.
4. **Errors / maintenance / app notices** — sent on platform errors,
   scheduled maintenance, or notices about a specific user's app.

**Open design question before a session starts building this:** the app
already has `ActionMailer` configured over SMTP
(`config/environments/production.rb`), existing mailers
(`app/mailers/application_mailer.rb`, `user_mailer.rb`,
`devise_mailer.rb`), and `good_job` (Postgres-backed background jobs,
already in the `Gemfile`, already the queue for everything else in this
app). Routing these four emails through **Supabase RPC triggers** instead
means a second, parallel trigger/delivery path that lives outside Rails
entirely (e.g. Postgres Database Webhooks + `pg_net` calling out to a
Supabase Edge Function or an external mail API), rather than a Rails
`after_commit` callback enqueuing a `GoodJob`-backed mailer the normal way.
That's not necessarily wrong — it can make sense if the intent is for
emails to survive even if the Rails app itself is down, or if a separate
Supabase project already owns this — but it is a second delivery
mechanism next to one that already exists, so the operator should confirm
that's actually wanted before a session builds it, rather than a session
assuming and building the trigger-based path silently.

**Known gaps to resolve first, regardless of which path is chosen:**
- **No payment/invoice data model exists yet** — `db/schema.rb` has no
  `payments`, `invoices`, or `receipts` table (checked the full model
  list: no such model in `app/models/`). Email #3 needs that built (or an
  existing external payment provider's webhook as the trigger source)
  before it can fire on anything real.
- **"Deploy" event** likely maps to `Release` creation/status changes,
  which does already exist — email #1 is the most immediately buildable
  of the four.
- **Recipient/notification preferences** — none of the four should be
  unsubscribable-proof by default; check whether `User` needs an
  email-preferences column before this ships, so platform-wide
  maintenance/branding mail doesn't become unwanted noise with no opt-out.

### 🆕 Task 13: Dashboard / Console UI Revamp — 2026 Modernization (New — not started)

Operator wants a visual overhaul of the dashboard and all other in-app
console pages (everything past sign-in — not the public landing page,
which was already redone under the glassmorphism task above). Brief, as
given:

- **Look and feel:** "2026 modernization," described as cinematic and
  futuristic — explicitly **not** dull, but also explicitly **not**
  gamified. The operator was clear this should read as corporate/
  professional, not a consumer play-store or gaming aesthetic.
- **Usability bar:** the console should be *easier and more convenient to
  navigate than the Play Store* — i.e. the comparison is about
  discoverability/navigation ergonomics, not visual style (the visual
  style should stay corporate even though the usability bar references a
  consumer app).
- **Scope:** dashboard plus "all other pages" — this reads as every
  authenticated console view (app list, release management, org/team
  settings, admin pages, etc.), not just `dashboards#index`. A session
  starting this should inventory the actual view/controller list under
  `app/views/` and `app/controllers/` (excluding `home/` and `devise/`,
  already covered) before scoping the work, rather than guessing which
  pages count as "console."

**Open questions before a session starts building, so it doesn't have to
guess and redo work:**
- Is this a ground-up redesign (new component library / design tokens) or
  a restyle of the existing Slim views + `app/frontend/stylesheets`
  system used by the landing/auth work above? The existing stack has no
  component library beyond hand-rolled CSS + Stimulus controllers — worth
  confirming before introducing a new one.
- Any reference sites/apps the operator has in mind for "cinematic,
  futuristic, corporate" (concrete references reduce back-and-forth on
  subjective visual language)?
- Should this land as one large patch or be broken into page-by-page
  patches, given the scope ("dashboard and all other pages")?

No code has been written for this task yet — this entry only records the
request on the task board per the operator's ask.

## Task: professional sign-in/sign-up + landing page (glassmorphism, 2026 style)

**Branch:** `feat/landing-page-and-auth-glassmorphism`
**Status:** code-complete, not build-verified

### What was built this session

1. **Landing page** (didn't exist before — root previously went straight to
   `DashboardsController`, which bounced signed-out visitors to sign-in
   with nothing public to see):
   - `config/routes.rb`: `root` now points to `home#index`. Added a new
     named route `get 'dashboard', to: 'dashboards#index', as: :dashboard`
     since the dashboard previously had **no route helper of its own** —
     it was only reachable because it happened to sit at `root`. Existing
     internal links (`_sidebar.html.slim`, `_main_sidebar.html.slim`) still
     use `root_path`, which now round-trips through the landing controller's
     redirect for signed-in users — one extra redirect hop, functionally
     fine, but a future session could give those links `dashboard_path`
     directly to shave it off.
   - `app/controllers/home_controller.rb` (new): signed-in users are
     redirected straight to `dashboard_path`; everyone else gets the
     landing page. If `Setting.guest_mode` is on, a "Continue as guest"
     CTA links straight to the dashboard.
   - `app/views/home/index.html.slim` (new): hero with the ambient-glow
     brand name, animated stat counters, a "global reach" strip, and two
     opposite-direction marquees (partners scroll left, sponsors scroll
     right).
   - `app/frontend/stylesheets/components/landing.css` (new, imported from
     `application.tailwind.css`): hero glow blobs, the shine/"silver
     lining" sweep on the brand name, stat-card glass panels, flag-pill
     grid, and the two marquee animations (duplicated-list `translateX`
     loop, `prefers-reduced-motion` respected throughout).
   - `app/frontend/javascript/controllers/counter_controller.js` (new,
     registered in `controllers/index.js`): IntersectionObserver-triggered
     count-up, ease-out-cubic, jumps straight to the final value under
     reduced motion instead of animating.
   - `config/locales/zealot/en.yml`: added a `home:` block for all landing
     copy. Not yet mirrored into `zh-CN.yml` or the other locale — see
     "Not done" below.

2. **Stat numbers**: `App.count`, `Release.count`, `User.count` are real
   queries — not placeholders. The "uptime" figure (99.9%) is static brand
   copy, not derived from anything, since nothing in this schema tracks
   uptime.

3. **"Countries signaling global reach"**: `db/schema.rb` has no
   geo/country column anywhere (checked `devices`, `releases`) — there is
   no real install-geography data to show. Rather than fabricate a stat,
   `HomeController#landing_countries` returns a static list of country
   codes rendered as plain text badges (no flag-icon library — none was
   installed, and adding one wasn't worth an unverified new dependency for
   this). If the operator has real geography from an analytics tool
   elsewhere, swap that array out.

4. **Auth pages** (`devise/sessions/new`, `devise/registrations/new`,
   which already shared `auth-shell`/`auth-card` from a previous session):
   left the Slim templates untouched and upgraded
   `app/frontend/stylesheets/components/auth.css` only — heavier
   `backdrop-blur-2xl` + `backdrop-saturate-150`, a gradient sheen ring
   (`.auth-card::before`) and a top inner-edge highlight
   (`.auth-card::after`) for a more layered "liquid glass" look. No new
   markup, no new classes to wire up elsewhere.

### Not done / next session

- `home:` locale keys only exist in `en.yml`. `zh-CN.yml` (and any other
  locale file under `config/locales/zealot/`) needs the same block
  translated, or those users will silently fall back to English on the
  landing page only.
- The extra redirect hop on `root_path` for signed-in users (see routing
  note above) — cosmetic, not a bug, but easy to remove by pointing
  `_sidebar.html.slim` / `_main_sidebar.html.slim` at `dashboard_path`.
- No flag-icon library is installed; the global-reach section is
  text-badge only by design (see above), not a placeholder waiting on
  something — but flag it if a future session is tempted to add one, since
  it'd be a new npm dependency touching the Vite build.
- Nothing here was run — no `rails routes`, no asset build, no visual
  check in a browser. First thing the next session (or the operator, post
  build) should do is actually load `/` signed out and signed in and look
  at it.

## Session log

- **This session**: built the landing page, animated counters, dual-marquee
  partners/sponsors strip, and the auth-page glass upgrade described above.
  Patch generated from a single commit on
  `feat/landing-page-and-auth-glassmorphism`, base `develop`.
