# Zealot — Session Handover

This file tracks only the current in-progress task. A prior `handover.md`
existed in this repo's history but was removed (commit `4996098`, "Remove
handover.md") and is not carried forward here — this is a clean start
scoped to the task below.

## Handoff process (unchanged repo convention)

1. Session does the work on a branch, never pushes directly to `develop`/`main`.
2. Session runs `git format-patch -1 HEAD` (or `-N` for N commits) to produce
   a `.patch` file and hands it off — no push from the session.
3. Operator applies it themselves. **Exact command for this session's patch**
   (adjust the filename below to match whatever your download actually
   saved it as, if it differs):
   ```
   cd ~/zealot
   git am ~/storage/downloads/zealot-landing-page-auth-glassmorphism.patch
   git push
   ```
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
