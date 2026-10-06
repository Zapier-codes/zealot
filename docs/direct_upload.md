# Direct upload (Task 40, slices 40h-b, 40h-c and 40s)

Status: **written, not run, switched off.** The doors answer 404 until `RELEASE_UPLOAD_SESSIONS_ENABLED=true` and the four
`R2_STAGING_*` variables are set. Do not switch it on before slice 40i-a (the CI stage that reads the uploaded file)
exists: until then a finalized upload waits in state `uploaded` and no release is created from it.

Why: the file goes from the client straight to a Cloudflare R2 staging bucket through a presigned URL, so Render never
receives, buffers or parses the bytes. Zealot only handles three small JSON requests.

## The flow (the console and the API do the same three steps)

1. **Open a session.** Zealot checks who you are and that you may upload to the channel, writes a `release_uploads` row
   (`awaiting_bytes`) and answers `201` with a presigned URL.
2. **PUT the file** to `upload_url`, sending every header in `headers` (if the answer lists a `Content-Type`, send exactly
   that one: it is part of the signature, and R2 answers 403 `SignatureDoesNotMatch` otherwise). The URL is good for two
   hours (`expires_at`).
3. **Finalize.** Zealot asks R2 what it holds and compares the size with the one you declared. `200` means the row is now
   `uploaded`; repeating a finished finalize also answers `200` and changes nothing.

Nothing in these steps creates a `Release`. That happens only when CI has read the file and called Zealot back (40i-b).

## API (for a developer's own CI)

Credentials are the same two as `POST /api/apps/upload`, never both and never a fallback: a per-app token
(`Authorization: Bearer zpa_...`, header only, confined to its own app) or the user token (`token` parameter).
`channel_key` names an **existing** channel. **Task 40r:** leave it out for the **first upload of an app**: nothing is
created when the session opens; once CI has read the package name, Zealot creates the app (named by `name` if you sent
one, else the file's label, else its package name), an `Adhoc` scheme and an Android channel, with you as owner, then the
release as usual. It needs the same right as the multipart door's first upload (an admin or developer account), it is
refused for a per-app token (a token is for one existing app) and it is only available on the default host. Extra
optional fields for a new app: `name`, `slug`, `git_url`, `download_filename_type` (the channel `password` is not
accepted; set it in the console afterwards). If the app already exists and you may change it, the upload goes to its
Android channel; if you may not, the upload ends `failed` with the reason.

| Request | Body (JSON or form) | Answer |
|---|---|---|
| `POST /api/apps/upload_sessions` | `channel_key`, `filename`, `size` (bytes, 1 up to 2 GiB minus 1); optional `content_type`, `hold`, `play_store_target`, `changelog`, `branch`, `git_commit`, `ci_url`, `release_type` | `201 { id, state, upload_url, method, headers, expires_at, size }` |
| `PUT <upload_url>` | the raw file | `200` from R2 |
| `POST /api/apps/upload_sessions/:id/finalize` | none | `200 { id, state }` or `4xx/503 { error }` |

Finalize answers: `422` when R2 holds nothing yet (retry after the PUT) or the size differs from the declared size (the
row becomes `failed` and the staged object is deleted); `409` when the upload expired or is no longer open; `503` when
R2 cannot be reached (the row is unchanged, retry). Only the user who opened an upload can finalize it.

The optional fields are kept on the upload record and are **not trusted** until the release exists; CI's stage 1 and
Zealot's callback re-run every check (package name, version code, version uniqueness) before a release is created.

Sketch of a CI step (not run; adapt names):

```sh
set -eu
FILE=app-release.aab
SIZE=$(wc -c < "$FILE")
SESSION=$(curl -sS -X POST "$ZEALOT_URL/api/apps/upload_sessions" \
  -H "Authorization: Bearer $ZEALOT_APP_TOKEN" \
  -d "channel_key=$CHANNEL_KEY" -d "filename=$(basename "$FILE")" -d "size=$SIZE")
ID=$(echo "$SESSION" | jq -r .id)
URL=$(echo "$SESSION" | jq -r .upload_url)
# send every header the session lists (usually none, or one Content-Type)
curl -sS -X PUT "$URL" --data-binary "@$FILE" $(echo "$SESSION" | jq -r '.headers | to_entries[] | "-H \(.key):\(.value)"')
curl -sS -X POST "$ZEALOT_URL/api/apps/upload_sessions/$ID/finalize" -H "Authorization: Bearer $ZEALOT_APP_TOKEN"
```

## Large files in parts (Task 40s)

Status: **built, switched off.** With `RELEASE_UPLOAD_MULTIPART_ENABLED=true`, a file of at least
`RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB` (default 100) is sent to R2 in parts instead of one PUT: a dropped connection
costs one part, not the whole file, and an upload can be resumed. Smaller files, and everything while the flag is off,
use the single PUT above, unchanged. Both doors (console and API) behave the same.

| Variable (Render) | Default | Meaning |
|---|---|---|
| `RELEASE_UPLOAD_MULTIPART_ENABLED` | off | `true` turns parts on |
| `RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB` | 100 | files of at least this many MiB go in parts (never below the part size) |
| `RELEASE_UPLOAD_PART_SIZE_MIB` | 16 | size of every part but the last (floor 5; R2 needs equal-sized parts but the last) |

A change only affects uploads opened after it: the part size of an open upload is stored on its row.

**The flow.**

1. **Open.** `POST /api/apps/upload_sessions` as before. For a large file the answer has `multipart: true`, `part_size`,
   `part_count`, `expires_at` (6 hours) and **no `upload_url`**.
2. **Sign.** `POST /api/apps/upload_sessions/:id/parts` with `parts=1,2,3,4` (a JSON array also works; 1 to 10 distinct
   numbers inside `1..part_count`) answers `{ parts: [{ part_number, url, method, headers, size, expires_at }] }`.
3. **PUT each part.** Part *n* is bytes `(n-1) x part_size` up to `part_size` long; the last part is what is left. Send it
   to its `url` with the headers listed (none today): the URL signs no content type, so send none. A part that fails
   (network, an expired URL) is signed again and sent again. The response's `ETag` is not needed.
4. **Resume.** `GET .../parts` answers `{ part_size, part_count, uploaded: [...], missing: [...] }` from R2's own list (a
   part of the wrong size counts as missing). Send only `missing`.
5. **Finalize.** `POST .../finalize` as before. If parts are missing it answers `422 { code: "parts_incomplete",
   missing: [...] }` and the upload stays open: send those parts and finalize again.

Answers on the two part calls: `422` bad part numbers or an upload not opened in parts, `409` the upload is not open,
its 6-hour window has closed, or R2 no longer knows it (it may have been completed: try finalize, else start again),
`503` R2 cannot be reached (retry). The 2 GiB cap and every check after finalize are unchanged. An unfinished upload is
aborted in R2 by the sweeper after the window closes.

**The console** (`direct_upload_controller.js`) does all of this itself: 3 parts at once, 4 signed per request, each part
tried up to 5 times with a new signature, and a refresh resumes (the session id is kept in `localStorage`, keyed by the
console URL, the file's name, size and last-modified time, and the form options; choose the same file again and press
the button).

**An API client or CI step** needs the same loop. The script below does it with `bash`, `curl`, `jq` and `dd` (no part is
held in memory; each is cut from the file into a temp file). It was run against a local stand-in for both Zealot and R2
(a single PUT with a listed `Content-Type`; 22 MB in 5 parts; a part failing twice then passing; a part failing every
time; a finalize answering `parts_incomplete` once; a resume with parts 1 to 3 already held, sending only 4 and 5). It was **not**
run against a real Zealot or R2.

```bash
#!/usr/bin/env bash
# Uploads one file through a Zealot upload session. Small files: one PUT. Large files (the session answers
# "multipart": true): parts, resumable. Needs bash 4+, curl, jq, dd.
#   ZEALOT_URL=https://zealot.example ZEALOT_APP_TOKEN=zpa_... CHANNEL_KEY=abc ./upload.sh app-release.aab
#   RESUME_ID=123 ... ./upload.sh app-release.aab     # carry on an upload that stopped half way
set -eu
FILE=$1
SIZE=$(wc -c < "$FILE")
API="$ZEALOT_URL/api/apps/upload_sessions"
AUTH="Authorization: Bearer $ZEALOT_APP_TOKEN"
PART=$(mktemp); OUT=$(mktemp); trap 'rm -f "$PART" "$OUT"' EXIT

# PUT file $2 to the signed object $1 (a session answer has "upload_url", a part has "url"); the headers it
# lists (none for a part) are sent exactly. `-T` sends the bytes with a Content-Length and no Content-Type of its own.
put_signed() {
  local H=(); mapfile -t H < <(echo "$1" | jq -r '(.headers // {}) | to_entries[] | "-H", "\(.key): \(.value)"')
  curl -fsS -T "$2" "$(echo "$1" | jq -r '.upload_url // .url')" -o /dev/null ${H[@]+"${H[@]}"}
}
sign() { curl -fsS -X POST "$API/$ID/parts" -H "$AUTH" -d "parts=$1"; }   # "1,2,3,4": at most 10 numbers

send_part() {   # $1 part number, $2 its signed JSON; cuts the part out of the file, retries with a fresh signature
  local n=$1 signed=$2 attempt=1
  dd if="$FILE" of="$PART" bs="$PART_SIZE" skip=$((n - 1)) count=1 iflag=fullblock 2>/dev/null
  until put_signed "$signed" "$PART"; do
    [ "$attempt" -lt 5 ] || { echo "part $n failed after 5 attempts" >&2; return 1; }
    sleep "$attempt"; attempt=$((attempt + 1))
    signed=$(sign "$n" | jq -c '.parts[0]')
  done
}

if [ -n "${RESUME_ID:-}" ]; then
  ID=$RESUME_ID
  LIST=$(curl -fsS "$API/$ID/parts" -H "$AUTH")            # R2's own word on what it holds
  PART_SIZE=$(echo "$LIST" | jq -r .part_size)
  MISSING=$(echo "$LIST" | jq -r '.missing | join(" ")')
else
  SESSION=$(curl -fsS -X POST "$API" -H "$AUTH" -d "channel_key=$CHANNEL_KEY" \
    -d "filename=$(basename "$FILE")" -d "size=$SIZE")
  ID=$(echo "$SESSION" | jq -r .id)
  echo "upload id $ID (RESUME_ID=$ID to carry on if this stops)" >&2
  if [ "$(echo "$SESSION" | jq -r '.multipart // false')" != true ]; then
    put_signed "$SESSION" "$FILE"                          # single PUT: the answer has url, headers
    MISSING=""
  else
    PART_SIZE=$(echo "$SESSION" | jq -r .part_size)
    MISSING=$(seq 1 "$(echo "$SESSION" | jq -r .part_count)" | tr '\n' ' ')
  fi
fi

for round in 1 2 3; do
  set -- $MISSING
  while [ $# -gt 0 ]; do                                   # 4 parts per signing request, sent one by one
    NUMS=""; k=0
    while [ $# -gt 0 ] && [ "$k" -lt 4 ]; do NUMS="$NUMS,$1"; shift; k=$((k + 1)); done
    NUMS=${NUMS#,}; SIGNED=$(sign "$NUMS")
    for n in ${NUMS//,/ }; do
      send_part "$n" "$(echo "$SIGNED" | jq -c --argjson n "$n" '.parts[] | select(.part_number == $n)')"
    done
  done
  CODE=$(curl -sS -o "$OUT" -w '%{http_code}' -X POST "$API/$ID/finalize" -H "$AUTH")
  [ "$CODE" = 200 ] && { cat "$OUT"; echo; exit 0; }
  # 422 parts_incomplete names the parts R2 does not hold: send those again, then finalize again
  [ "$CODE" = 422 ] && [ "$(jq -r .code "$OUT")" = parts_incomplete ] || { cat "$OUT" >&2; exit 1; }
  MISSING=$(jq -r '.missing | join(" ")' "$OUT")
done
echo "still incomplete after 3 rounds; RESUME_ID=$ID to try again" >&2; exit 1
```

**Storeapp.** `release-aab.yml`'s direct-upload path (`ZEALOT_DIRECT_UPLOAD`, 40h-c-2) PUTs once to `upload_url`; with
multipart on, a bundle at or over the threshold gets no `upload_url` and that step fails. Until that workflow runs the loop
above, leave `ZEALOT_DIRECT_UPLOAD` off there, or set `RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB` above the largest bundle
Storeapp builds. Turn-on order and checks: runbook section 14.

## Console

`POST /channels/:channel/release_uploads` and `POST /channels/:channel/release_uploads/:id/finalize`, JSON only, signed-in
user who passes the same rule as the upload form. When the flag is on, the upload form (`releases/_form`) loads the
`direct-upload` Stimulus controller: it takes the chosen file, runs the three steps above (with a progress bar for the
PUT) and shows a message with a link back to the channel. With no file chosen it does nothing and the normal form submit
runs. With the flag off the form is the plain multipart form and nothing changes.

The direct path forwards only the fields Zealot accepts for an upload (`release_type`, `branch`, `git_commit`, `ci_url`,
`changelog`, `play_store_target`). `release_version` and `build_version` are not forwarded: the file's own manifest is the
source of truth once CI has read it.

## Operator setup

The R2 staging bucket, its CORS rule (the console origin may `PUT` and `HEAD`, and read `ETag`), the lifecycle rule and
the token are in the Task 40 entry of `handover.md` ("R2 staging bucket: terminal commands"). The browser PUT goes
cross-origin to R2, so the CORS rule is required for the console form; CI is not affected by CORS.

## Task 40r: R2 staging as the only door for Android files

With `REQUIRE_DIRECT_UPLOAD=true` (and sessions usable) an `.apk` or `.aab` can no longer be sent as a multipart body:

- `POST /api/apps/upload` answers `426` with `{ "error": "Android files must be uploaded through POST /api/apps/upload_sessions ..." }`;
- the console's plain form post redirects back to the channel with the same advice (the form's own script already sends
  the file to R2, so this only catches the no-script and hand-made-request cases).

Other formats (for example `.ipa`) keep both doors. Nothing is rejected as an *upload*: the same file goes through a
session and CI signs it and injects the SDK exactly as before; only the transport changes. The flag ships **off**; turn
it on only after the order in the runbook, section 13, and only after one real session
upload, first-app case included, has finished `done`.

The staged-file name for a first upload is `staging/a0/u<id>/<32 hex>/<file>`: `a0` because the app does not exist
yet. The stage-2 workflow skips its "storage tag belongs to the staged app" comparison for `a0` only
(`docs/ci/read-upload.yml`; the copy in the storage repo must be replaced, runbook section 13).
