# mtproto-worker

One-shot batch script that wraps [GramJS](https://gram.js.org/)'s successor
(`teleproto`) to archive our own release-pipeline artifacts using Telegram as
free cold storage. This is task #6 from `../handover.md`, moved off an
always-on Rails-container sidecar and onto scheduled GitHub Actions runs in
task #19f (see "Architecture (task 19f)" below — this superseded the
"Deployment"/"Setup" sections as they read before that slice; kept below,
marked, for history).

Approach still mirrors `github.com/ShivaReddyVanja/aetheroll`
(`docs/CACHING_AND_DATA_FETCHING_ARCHITECTURE.md`) for the Telegram side:
one MTProto connection per run, chunked upload via GramJS's built-in
`uploadFile`, 512KB-part semantics handled internally.

## Scope

Archives only our own artifacts that already live in our own release
storage (`ReleaseStorage` — GitHub Releases in a private repo as of task
#19, see `../handover.md`), into a private Telegram chat/channel we
control. Not a general-purpose Telegram proxy — see the "Scope, stated
plainly" section of `../handover.md`.

## Architecture (task 19f)

As of this slice, this is a **one-shot script** (`src/archive_batch.ts`),
not an HTTP server. It is invoked once per run by
`../.github/workflows/mtproto_archive.yml` on a `schedule` (03:30 daily,
matching the old cron time) and on manual `workflow_dispatch`, does one
batch, and exits. It does not run inside the Rails container, is not
supervised by s6, and Rails never makes an HTTP request to it (the reverse
of the old design).

Flow, each run:

1. `GET {ZEALOT_URL}/api/mtproto_archive/candidates?token=...` — Rails
   (`Api::MtprotoArchiveController`, admin-token-authed) returns releases
   old/large enough to archive, each with a short-lived signed download URL
   from `ReleaseStorage#url_for`.
2. Download each candidate straight from that signed URL — this script
   never holds Rails' storage credentials, only whatever the signed URL
   already exposes.
3. Archive it into Telegram via `MtprotoClient` (`src/mtproto_client.ts`,
   unchanged from the sidecar era).
4. `POST {ZEALOT_URL}/api/mtproto_archive/{release_id}/complete` with the
   encoded location, so Rails records `mtproto_archived_location`/`_at`.

Best-effort per candidate (one failure is logged, the run continues); the
process exits non-zero if any candidate failed or if a fatal, run-wide
error occurs (can't reach Rails, missing env vars) — see
`src/archive_batch.ts`'s header comment for the exact contract.

**Why this over the sidecar:** the sidecar existed to keep a warm MTProto
connection alive for low-latency archive/retrieve calls Rails might make at
any time. In practice only one nightly cron job ever called it
(`AnthropicMtprotoArchiveJob`, itself now removed — see `../handover.md`
Task 19f), so there was never request-path traffic to justify a persistent
process. Running it as a scheduled batch instead removes an entire class of
Render-container failure modes this worker caused (see "Deployment
(superseded)" below — the OOM-at-boot issue, the s6 crash-loop-when-
unconfigured guard) for free, since the container no longer runs it at all.

**What changed in `render.yaml` / the Dockerfile / the image:** all of
`MTPROTO_WORKER_URL`, `MTPROTO_WORKER_SHARED_SECRET`, and the four
`TELEGRAM_*` vars are gone from `render.yaml` — Rails no longer needs them.
The Dockerfile no longer builds this package into the image, and
`docker/rootfs/etc/services.d/mtproto-worker/` (the s6 run script) is
removed. `MTPROTO_ARCHIVE_ENABLED` **stays** on Render — it's now the
Rails-side kill switch for whether `Api::MtprotoArchiveController#candidates`
returns anything at all, independent of whether the GitHub Actions schedule
itself is enabled.

## Setup (task 19f — operator action required)

1. Register an app at <https://my.telegram.org> to get `TELEGRAM_API_ID` /
   `TELEGRAM_API_HASH` (skip if already done from the sidecar era — these
   don't change).
2. Generate a `TELEGRAM_SESSION_STRING` **once, offline**, by logging in
   interactively with GramJS/teleproto's `StringSession` flow on a trusted
   machine — this script never performs interactive login itself. Reuse the
   existing one if already generated; it's not tied to how the worker runs.
3. Create (or reuse) the private archive chat/channel and note its ID as
   `TELEGRAM_ARCHIVE_CHAT_ID`.
4. **Move these four secrets from Render to GitHub Actions** (Settings →
   Secrets and variables → Actions, on the `Zapier-codes/zealot` repo):
   `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `TELEGRAM_SESSION_STRING`,
   `TELEGRAM_ARCHIVE_CHAT_ID`. They should no longer be set on Render at all
   once this is deployed.
5. Add two more repo secrets/vars for the Rails side of the contract:
   `ZEALOT_ADMIN_TOKEN` (an admin user's API token — Zealot user profile →
   API token, or `rails runner 'puts User.find_by(admin: true).token'`) as
   a **secret**, and `ZEALOT_URL` (e.g. `https://zealot.example.com`) as a
   **variable** (not sensitive, but keeps the workflow file portable).
6. On Render, set `MTPROTO_ARCHIVE_ENABLED=true` once ready to go live (the
   candidates endpoint returns an empty list otherwise). No other Render
   env var is needed for this feature anymore.
7. Do one real archive → retrieve round trip against a test release before
   trusting this in production — see "Status" below; still not done as of
   this slice, and retrieval itself (`MtprotoClient#retrieve`) has no
   caller anywhere yet, same open question `../handover.md` has carried
   since task #6.

## Run

Locally, against a real Zealot instance (mostly for testing the script
itself — a real run happens via the GitHub Actions workflow):

```bash
npm install
ZEALOT_URL=https://your-zealot-instance \
ZEALOT_ADMIN_TOKEN=... \
TELEGRAM_API_ID=... TELEGRAM_API_HASH=... \
TELEGRAM_SESSION_STRING=... TELEGRAM_ARCHIVE_CHAT_ID=... \
npm run archive:dev
```

`npm run build && npm run archive` runs the compiled version, which is what
the GitHub Actions workflow does.

## Status

**Task 19f (this slice):** replaced `src/index.ts` (Express HTTP server)
with `src/archive_batch.ts` (one-shot script); `mtproto_client.ts` is
unchanged. Removed the `express`/`@types/express` dependencies — nothing
here listens on a port anymore. `npm install` (fresh lockfile), `npm run
typecheck`, and `npm run build` all ran clean in-sandbox (0 vulnerabilities,
no type errors). The HTTP contract with Rails (`GET .../candidates` →
download from the signed URL → `POST .../complete`) was exercised end-to-
end against a throwaway local stand-in server standing in for
`Api::MtprotoArchiveController`, with the real `encodeLocation` from the
compiled `dist/mtproto_client.js` and only the actual Telegram upload
(`MtprotoClient#archive`) stubbed out — this sandbox has no real
`TELEGRAM_*` credentials and no network path to Telegram's servers to
verify that part. **Not verified:** a real Telegram upload/download; the
real `Api::MtprotoArchiveController` (no Ruby/Rails app boot available
either — see `../handover.md` Task 19f for what was and wasn't verified on
that side); the GitHub Actions workflow actually running (no way to trigger
Actions from this sandbox).

**Session 13:** `npm install` + `npm run typecheck` first ran in a sandbox
with Node — both passed clean. Confirmed `teleproto` resolves the exact
import paths `mtproto_client.ts` uses.

One thing worth recording here since it came up that session and could
reasonably come up again: `package.json` depends on `teleproto`, not the
`telegram` package most GramJS docs/tutorials still reference. `teleproto`
was initially flagged as a possible typosquat (single maintainer,
unfamiliar name) before checking further — it turned out to be GramJS's
own sanctioned successor: GramJS's official site (gram.js.org) itself says
the original is archived and points to `teleproto`; it has real, active
adoption (~28K weekly downloads, created about a year ago, third-party
forks of its own); and it's tracked (not malware-flagged) on Socket.dev's
supply-chain scanner. If a future session or dependency bump raises this
question again, that's the verification trail — don't just take a
deprecation notice at face value, but don't dismiss `teleproto` as
suspicious without redoing this check either.

**Session 22:** (superseded by task 19f above) process supervision was
decided and built as a fourth s6 service in the Rails image. Not verified
end-to-end then either — no Docker build available in that sandbox.

## Deployment (superseded by task 19f — kept for history)

Prior to task #19f, this worker ran as a peer process **inside the same
container** as the Rails app, supervised by s6 alongside
`caddy`/`job`/`zealot`, rather than as a separate Render service or a
scheduled job. Reasoning at the time: Render's Free plan doesn't offer
private services/background workers (Starter $7/mo+ only), and a
same-container sidecar reachable only on `127.0.0.1` needed no paid
resource. The tradeoff — coupling this worker's lifecycle (and crash
behavior) to the web container's — plus a real production incident (a
connect-at-boot attempt once OOM-killed the whole Free-tier container, see
`../handover.md` Task 6's 502 investigation note) motivated moving it off
the container entirely in task #19f, rather than only deferring the
connection further.
