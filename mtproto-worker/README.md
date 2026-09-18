# mtproto-worker

Sidecar HTTP service that wraps [GramJS](https://gram.js.org/) to archive and
retrieve our own release-pipeline artifacts using Telegram as free cold
storage. This is task #6 from `../handover.md`. Called only by the Rails
app's `Anthropic::MtprotoArchiveService` — not exposed publicly.

Approach mirrors `github.com/ShivaReddyVanja/aetheroll`
(`docs/CACHING_AND_DATA_FETCHING_ARCHITECTURE.md`): one persistent, warm
MTProto connection reused across requests, chunked upload/download rather
than reconnect-per-call, and 512KB-part semantics handled internally by
GramJS's `uploadFile`/`downloadMedia`.

## Scope

Archives only our own artifacts that already live in our own R2 bucket
(`ReleaseStorage`), into a private Telegram chat/channel we control. Not a
general-purpose Telegram proxy — see the "Scope, stated plainly" section of
`../handover.md`.

## Deployment (decided session 22 — see handover.md task #6)

This worker runs as a peer process **inside the same container** as the
Rails app, supervised by s6 alongside `caddy`/`job`/`zealot`
(`docker/rootfs/etc/services.d/mtproto-worker/run`), rather than as a
separate Render service. Reasoning:

- Render's Free plan — what `render.yaml` uses for `zealot-web` — only
  covers web services, static sites, and cron jobs. A private service or
  background worker needs Starter ($7/mo) or above (confirmed against
  Render's current instance-type docs this session, since pricing/plan
  details are exactly the kind of thing that drifts and shouldn't be
  assumed from training data). A second Render service is therefore a real
  cost decision for the operator, not something a session should introduce
  as a side effect of finishing task #6.
- This worker's own scope requirement — "not exposed publicly... bind to a
  private network / internal Render service" — is satisfied for free by
  binding to `127.0.0.1` inside the one existing container. It never needs
  a public URL, and never needs Render's paid private-networking feature
  either, since there's no second service to network to.
- The existing image already proves this pattern works: `caddy`, `job`
  (good_job), and `zealot` (puma) all run as independent s6-supervised
  processes in one container today. `mtproto-worker` is a fourth.

The tradeoff: this couples the worker's lifecycle to the web container's —
it deploys, restarts, and (if crash-looping) gets logged alongside Rails,
rather than scaling or failing independently. Given this worker only serves
a nightly cron job (`AnthropicMtprotoArchiveJob`, 03:30) and on-demand
retrieval, not request-path traffic, that coupling was judged an acceptable
tradeoff against paying for a second service. **If retrieval latency or
archive volume ever becomes request-path-critical, revisit this** — that's
the point at which a dedicated, independently-scalable private service
would start to pay for itself.

The run script gates on `MTPROTO_ARCHIVE_ENABLED` and marks itself
intentionally down (`s6-svc -O -d`) rather than crash-looping when Telegram
credentials aren't configured yet — see that file's comments. So this
worker is safe to ship in the image now, before any of the Setup steps
below are done; it simply won't start until an operator flips
`MTPROTO_ARCHIVE_ENABLED` to `true` on Render after completing them.

## Setup (not yet done by any session — operator action required)

1. Register an app at <https://my.telegram.org> to get `TELEGRAM_API_ID` /
   `TELEGRAM_API_HASH`.
2. Generate a `TELEGRAM_SESSION_STRING` **once, offline**, by logging in
   interactively with GramJS's `StringSession` flow on a trusted machine —
   this worker never performs interactive login itself, and the resulting
   string is a long-lived credential that should be treated like any other
   production secret (stored in Render's env vars, not committed).
3. Create the private archive chat/channel and note its ID as
   `TELEGRAM_ARCHIVE_CHAT_ID`.
4. Set all five `TELEGRAM_*`/`MTPROTO_*` env vars from `render.yaml`'s new
   task-#6 block on the live Render service (`TELEGRAM_API_ID`,
   `TELEGRAM_API_HASH`, `TELEGRAM_SESSION_STRING`, `TELEGRAM_ARCHIVE_CHAT_ID`
   — all `sync: false`, so Render will prompt for them on the next
   Blueprint sync — plus flipping `MTPROTO_ARCHIVE_ENABLED` to `true` once
   the other four are in place). `MTPROTO_WORKER_URL` and
   `MTPROTO_WORKER_SHARED_SECRET` are already wired in `render.yaml` and
   need no manual action.

## Run

```bash
npm install
npm start
```

## Status

**Session 13:** `npm install` + `npm run typecheck` now actually run (this
sandbox has Node, unlike every prior session) — both pass clean, 0
vulnerabilities on install, no type errors. Confirmed the `teleproto`
dependency resolves the exact import paths `mtproto_client.ts` uses
(`teleproto`, `teleproto/sessions/index.js`).

One thing worth recording here since it came up this session and could
reasonably come up again: `package.json` depends on `teleproto`, not the
`telegram` package most GramJS docs/tutorials still reference.
`teleproto` was initially flagged as a possible typosquat (single
maintainer, unfamiliar name) before checking further — it turned out to
be GramJS's own sanctioned successor: GramJS's official site
(gram.js.org) itself says the original is archived and points to
`teleproto`; it has real, active adoption (~28K weekly downloads,
created about a year ago, third-party forks of its own); and it's
tracked (not malware-flagged) on Socket.dev's supply-chain scanner. If a
future session or dependency bump raises this question again, that's the
verification trail — don't just take a deprecation notice at face value,
but don't dismiss `teleproto` as suspicious without redoing this check
either.

Still not build- or integration-verified end-to-end — no real Telegram
credentials in this sandbox. Needs, before this is trusted in production:

- A real `TELEGRAM_SESSION_STRING` generated (per the Setup section
  above — this requires an operator with a live Telegram account and
  cannot be done from a sandbox) and one real archive → retrieve round
  trip against a test chat.

**Session 22:** process supervision is now decided and built (see
"Deployment" above) — the worker ships as a fourth s6 service in the
existing image (alongside `caddy`/`job`/`zealot`), gated off by default. Still not verified end-to-end in any
way that matters: no Docker build available in this sandbox, so the new
`npm ci && npm run build && npm prune --omit=dev` builder-stage step and
the `node dist/index.js` runtime invocation are unexercised — only checked
by hand-reading `package.json`'s `build` script and confirming `dist/`
would land at the path the new s6 run script and Dockerfile `COPY` both
reference. The next session with real `docker build` output (i.e. via the
GitHub Actions workflow from task #8, same as task #2) should confirm the
image actually builds and that `mtproto-worker`'s s6 log shows either the
clean "not starting" message (if `MTPROTO_ARCHIVE_ENABLED` is still unset)
or a real `connect()` attempt (once it's set) — not a crash loop.
