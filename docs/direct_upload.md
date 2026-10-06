# Direct upload (Task 40, slices 40h-b and 40h-c)

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
