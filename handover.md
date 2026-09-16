# Anthropic — Project Handover

This file is the single source of truth for what's done, what's in progress, and
what each future Claude session should pick up. Update it at the end of every
session before generating that session's patch.

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
| Cold storage | Telegram MTProto archive of our own large builds | Not started |
| Publishing | Google Play Developer API, verified org account | Not started |
| Database | Supabase Postgres, Session Pooler | Unchanged from upstream Zealot |
| Deployment | Render (image-backed), GitHub Actions → GHCR | Not started |
| Auth | Existing Zealot OAuth providers | Unchanged from upstream Zealot |

## Current state of `main` (verified by fresh clone, this session)

- HEAD: `a295c6a6` "Add Play Asset Delivery, Brotli compression, and delta patching", on top of `de2cbd44`.
- Present: `app/services/anthropic/{bundletool,brotli,delta,asset_pack}_service.rb`,
  `app/jobs/anthropic_asset_delivery_job.rb`, migration + schema columns on
  `releases`, download-controller Brotli negotiation + `/delta` endpoint,
  Dockerfile changes (Java, bundletool, brotli, bsdiff on Alpine).
- **Not yet build-verified.** No session has had real Docker access. Two
  specific known risks, not yet resolved:
  1. `bsdiff` may not exist as a native Alpine `apk` package (could not
     confirm via public package index search — may need to build from source).
  2. The Alpine `community` repo (where `openjdk17-jre-headless` and `brotli`
     live) may not be enabled by default in `ruby:3.4.7-alpine` — needs an
     explicit `sed`/echo into `/etc/apk/repositories` to be safe.
- `main` has moved upstream between sessions before (5 unrelated upstream
  commits appeared, then were gone by the time of this session's re-clone —
  origin drift is possible between sessions). **Every session should
  re-clone fresh and diff against what it expects before assuming a prior
  patch's context still matches `main` exactly.**

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
| 5 | Signing pipeline for our own AABs | — | 🔲 Not started | Signs builds produced by our own employees only. No submission-from-outside-parties flow. |
| 6 | Telegram MTProto cold storage for our own large builds | #3 | 🔲 Not started | R2 ⇄ MTProto streaming worker, pre-population cron. Scope: our own release artifacts only. `ReleaseStorage` is now in place to build on. |
| 7 | Google Play Developer API publishing | #5 | 🔲 Not started | First listing is manual per Play's own constraints; automate only subsequent releases. |
| 8 | CI/CD: GitHub Actions → GHCR → Render deploy hook | #2 | 🔲 Not started | |
| 9 | Storefront / discovery layer | — | ❓ Needs decision | Original vision assumed a public Aptoide-via-MCP storefront. Now that scope is confirmed internal/non-commercial, confirm with the operator whether this is still wanted before any session starts it. |

## Open questions for the operator (don't guess — ask)

- Is task #9 (public storefront) still in scope now that the console itself
  is internal-only? If there's no public store, Aptoide/MCP discovery may
  not be needed at all.
- Does #2 (Dockerfile verification) get unblocked by giving a session actual
  Docker access, or should the operator run the build themselves and paste
  back the failure output for a session to fix blind?

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
