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
4. Set `MTPROTO_WORKER_SHARED_SECRET` to a random token, and configure the
   same value as `MTPROTO_WORKER_SHARED_SECRET` on the Rails side.

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
- A decision on process supervision (a second Render service? forked from
  the same Dockerfile with a different entrypoint?) — not yet made.
