# Task 40 operator runbook: setup, checks, commands and debugging

Written 2026-10-05 from a live operator session. Everything here was either run by the operator and
reported back, or read from the code; each item says which. **Nothing in Task 40 has run end to end
yet** (see `handover.md`, Task 40). Read this before asking the operator to rediscover any of it.

## 1. The cast: where everything lives

| Thing | Where | Notes |
|---|---|---|
| Operator's shell | Termux on a phone | repos in `~/zealot`, files in `~/storage/downloads`; no Ruby in the Claude sandbox |
| Zealot (this repo) | `github.com/Zapier-codes/zealot`, branch `develop` | deploys through `Anthropic - Build & Deploy develop` only (see handover) |
| Zealot on Render | service `zealot-web`, id `srv-dalsvf942hec73dk2vg0` | URL `https://zealot-deploy-latest.onrender.com`, Free instance, kept awake by UptimeRobot |
| Storage repo (CI) | `github.com/Zapier-codes/zealot-storage` | holds the workflows (`read-upload.yml`, `compile-aab.yml`), the CI secrets and variables |
| R2 staging bucket | bucket `zealot-staging`, endpoint `https://3a46f47127565b4cd6c0c937dd15d2e4.r2.cloudflarestorage.com` | direct-upload staging (40h-a); two tokens: Render's (`R2_STAGING_*`) and CI's (`R2_STAGING_CI_*`) |
| Org signing key | file `appstore-production.jks`, alias `appstore_production` | Zealot holds an encrypted copy in its database (`AndroidSigningKey`); never exported |

Operator helpers on the phone (not in any repo except where noted): `~/.zealot.env` (Zealot URL and admin
login), `zealot-token` (prints the admin API token), `~/sync-adc.sh` (copies the Google ADC variables to
Render), `~/close-gaps.sh` (**now `docs/ci/close-gaps.sh` in this repo**, copy it back with
`cp ~/zealot/docs/ci/close-gaps.sh ~/close-gaps.sh`).

## 2. Facts established this session (public values only, no secrets)

- Org key file SHA-1 `32f5e77c79f208be49d25108867a8860a342b28b` equals the `checksum` Zealot reports for
  its key (checked 2026-10-05), so the file on the phone **is** the key Zealot signs with.
- Org certificate SHA-256: `2412373ae44a839f58bed85796707f120b96420bee9365143ce47767b64ea1e5`.
  Set as storage-repo variable `RELEASE_CERT_SHA256` and Render `CI_COMPILE_EXPECT_CERT_SHA256`.
- The key password equals the keystore password (`keytool -certreq` opened the key with only the keystore
  password and asked for nothing more), so **no `RELEASE_KEY_PASSWORD` secret is needed**. If the keystore
  is ever replaced, repeat that test.
- Render needs **no** keystore password variable: nothing in `app/`, `lib/` or `config/` reads one. Zealot's
  own copy is in its database; CI's copy is the storage-repo secrets.
- The only copy of the keystore file outside Zealot/GitHub was the phone. GitHub secrets cannot be read
  back and Zealot never exports the key, so **a backup off the phone is the operator's job** (encrypted
  copy plus the passwords in a password manager). Whether it was done is not recorded.
- R2 staging bucket lifecycle, read back by the operator 2026-10-06 (the account id is the first part of the
  endpoint; `CF_API_TOKEN` is a Cloudflare API token with R2 access, not the `R2_STAGING_*` storage keys, which
  cannot read bucket settings). The rule is what removes abandoned staged files and half-sent multipart uploads,
  so it backs the multipart window of Task 40s (6 hours, well under the 1-day abort):
  ```
  A=3a46f47127565b4cd6c0c937dd15d2e4
  curl -sS "https://api.cloudflare.com/client/v4/accounts/$A/r2/buckets/zealot-staging/lifecycle" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    | jq -r 'if .success then (.result.rules[] | "\(.id)  enabled=\(.enabled)  prefix=\(.conditions.prefix)  delete_after_s=\(.deleteObjectsTransition.condition.maxAge)  abort_multipart_after_s=\(.abortMultipartUploadsTransition.condition.maxAge)") else .errors end'
  ```
  Result: `expire-staging  enabled=true  prefix=staging/  delete_after_s=172800  abort_multipart_after_s=86400`.
  If the rule is ever missing, re-apply step 3 of "R2 staging bucket: terminal commands" in `handover.md` (Task 40).
- R2 multipart behaviour of the same bucket, checked by the operator 2026-10-06 with presigned `UploadPart` URLs:
  they work; every part but the last must have the same length (`InvalidPart` otherwise); a 1 MiB non-last part is
  refused (`EntityTooSmall`); 6, 6 and 1 MiB complete. Details in the Task 40s-a session entry in `handover.md`.

## 3. State of the setup (as last reported by the operator, 2026-10-05)

| Item | State | How known |
|---|---|---|
| Render `ADC_REFRESH_TOKEN`, `CLIENT_ID`, `CLIENT_SECRET` | set and verified | `~/sync-adc.sh --apply` output |
| Storage-repo variables `ZEALOT_URL`, `R2_STAGING_ENDPOINT`, `R2_STAGING_BUCKET`, `RELEASE_CERT_SHA256` | set, equal to Render, **full values read back 2026-10-05 ~10:15 UTC** (section 3a) | `gh variable list --json name,value` |
| Storage-repo variable `RELEASE_CERT_SHA256` | set by `close-gaps.sh --apply` | output |
| Render `CI_COMPILE_EXPECT_CERT_SHA256` | set by `close-gaps.sh --apply` (Render may have redeployed) | output |
| Storage-repo secrets `RELEASE_KEYSTORE_BASE64`, `RELEASE_KEYSTORE_PASSWORD`, `RELEASE_KEY_ALIAS` | set by `close-gaps.sh --apply`; the operator then re-set `RELEASE_KEYSTORE_PASSWORD` by hand with `gh secret set` | output |
| Storage-repo secrets `CI_COMPILE_CALLBACK_TOKEN`, `R2_STAGING_CI_ACCESS_KEY_ID`, `R2_STAGING_CI_SECRET_ACCESS_KEY` | exist (values cannot be compared) | output |
| Render latest deploy | `live`, created 2026-10-05 07:01:07 UTC, newer than the flag change and the manual POST at 07:00:53 (**superseded, see section 3a**) | deploy list, 2026-10-05 ~10:08 UTC |
| `read-upload.yml` in the storage repo | was the 40j version (`d01cb1e7`); replaced with `0f115f4c` (40l-b) through the contents API, hashes then equal (commit `d4ccdab3` in the storage repo) | `gh api ... --jq .sha` vs `git hash-object` |
| Render `R2_STAGING_BUCKET/ENDPOINT/ACCESS_KEY_ID/SECRET_ACCESS_KEY/REGION`, `CI_OIDC_AUDIENCE`, `CI_COMPILE_REPO`, `CI_COMPILE_DISPATCH_TOKEN`, `CI_COMPILE_CALLBACK_TOKEN`, `CI_COMPILE_EXPECT_CERT_SHA256`, `RELEASE_STORAGE_ADAPTER=github` | **set** (secrets by fingerprint only) | `check-render-env.sh` output, 2026-10-05 |
| Render `GITHUB_STORAGE_REPO`, `GITHUB_STORAGE_TOKEN` | **set** (`Zapier-codes/zealot-storage`; token fingerprint `0a3471110c`) | `check-render-env.sh`, 2026-10-05 ~10:08 UTC |
| Render `CI_COMPILE_ENABLED`, `RELEASE_UPLOAD_SESSIONS_ENABLED` | **`true`** (turned on by `enable-pipeline.sh --apply`; read back 2026-10-05 ~10:08 UTC). `ADC_AUTO_REGISTER` is **not set** (off, by design) | `check-render-env.sh` |
| `SIGN_UPLOADED_APKS` (storage repo) | **off** (not in `gh variable list`); must stay unset: since 40n-c the workflow **fails the run** if it is `true` (its step is disabled; 40k deletes it) | `gh variable list` |
| Render `REQUIRE_ORG_SIGNED_APKS` | **not set** (off). Turn on to accept only APKs signed with the organisation key (40n-c, section 4) | `check-render-env.sh` |
| 40m (Storeapp tenant signing) | **blocked**, four options in the Task 40 entry, unanswered | |

## 3a. Where things stand now: 40n-0 part 1 PASSED (read back by the operator, 2026-10-05 ~10:05 to 10:15 UTC)

Every line below was pasted back from the operator's phone, so a session should **not** re-ask for any of it.
Re-check only if something changed since (a new deploy, a variable edit).

**Render (`zealot-web`)**
- Deploy list (`?limit=3`): `live` created `07:01:07`, then `deactivated` `07:00:53` and `deactivated` `06:52:49`. The
  commit message shows `null` for all three (API-started deploys carry none; that is normal, not a problem). The live
  deploy is newer than both the flag change and the manual POST, so the flags are in the running app.
- `check-render-env.sh` ended "All required variables are set." Set: `R2_STAGING_BUCKET=zealot-staging`,
  `R2_STAGING_ENDPOINT` (the `3a46f471...` endpoint), `R2_STAGING_ACCESS_KEY_ID` (fingerprint `0303e6930d`),
  `R2_STAGING_SECRET_ACCESS_KEY` (`3db03143bd`), `R2_STAGING_REGION=auto`, `CI_OIDC_AUDIENCE=https://zealot-deploy-latest.onrender.com`,
  `CI_COMPILE_REPO=Zapier-codes/zealot-storage`, `CI_COMPILE_DISPATCH_TOKEN` (`9c1bcf8b7a`), `CI_COMPILE_CALLBACK_TOKEN` (`b21a1962f3`),
  `CI_COMPILE_EXPECT_CERT_SHA256=2412373a...a1e5`, **`CI_COMPILE_ENABLED=true`**, **`RELEASE_UPLOAD_SESSIONS_ENABLED=true`**,
  `RELEASE_STORAGE_ADAPTER=github`, `GITHUB_STORAGE_REPO=Zapier-codes/zealot-storage`, `GITHUB_STORAGE_TOKEN` (`0a3471110c`).
- The adapter-side `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` exist and carry the same endpoint and fingerprints
  as the `R2_STAGING_*` ones (from `add-r2-adapter-vars.sh`). Nothing reads them while the adapter is `github`.
- `ADC_AUTO_REGISTER` is **not set**: a finished release does not queue Google registration. Intended; turn it on only on purpose.
- `curl -sI https://zealot-deploy-latest.onrender.com` answers `HTTP/2 200`.

**Storage repo (`Zapier-codes/zealot-storage`)**
- Variables (full values read with `--json name,value`): `R2_STAGING_BUCKET=zealot-staging`, `R2_STAGING_ENDPOINT=https://3a46f47127565b4cd6c0c937dd15d2e4.r2.cloudflarestorage.com`,
  `RELEASE_CERT_SHA256=2412373ae44a839f58bed85796707f120b96420bee9365143ce47767b64ea1e5`, `ZEALOT_URL=https://zealot-deploy-latest.onrender.com`.
  All four equal Render's. `SIGN_UPLOADED_APKS` is not set.
- Secrets (names only): `CI_COMPILE_CALLBACK_TOKEN`, `R2_STAGING_CI_ACCESS_KEY_ID`, `R2_STAGING_CI_SECRET_ACCESS_KEY`,
  `RELEASE_KEYSTORE_BASE64`, `RELEASE_KEYSTORE_PASSWORD`, `RELEASE_KEY_ALIAS`. `RELEASE_KEY_PASSWORD` is not needed (section 2).
  Values cannot be compared; `CI_COMPILE_CALLBACK_TOKEN` is assumed equal to Render's (never proven; a mismatch would show as a callback 401/403).
- Workflows: `Read upload (Zealot)` id `374946022` and `Compile AAB (Zealot)` id `374946049`, both `active`.
- `read-upload.yml` blob hash is `0f115f4c6a621b29e0e33299ba206abea8a95644` in the storage repo **and** in `docs/ci/read-upload.yml`
  here (at the time of writing): the 40l-b version is the one deployed. If a later slice edits that file, recopy it and compare again.

**Not yet done (40n-0 part 2):** one real end-to-end upload. Nothing in Task 40 has run against a real Zealot, Render or bucket
until that passes (section 10).

**Termux gotchas seen in this session (do not trip on them again)**
- The phone truncates wide `gh variable list` / `gh secret list` tables (`https://3a46f...`, `RELEASE_CERT_SH...`). Never compare
  from the table; use `gh variable list -R <repo> --json name,value --jq '.[] | "\(.name)=\(.value)"'`.
- Several commands pasted at once run together and their output runs together on one line. Read the names, not the layout.
- `~/distr` is the shell's working directory, not a Zealot checkout. Zealot is `~/zealot`; always use `~/zealot/...` paths.

## 4. Order to turn the pipeline on (do not reorder)

1. Storage repo: `read-upload.yml` copied to `.github/workflows/read-upload.yml` on `main`
   (and `compile-aab.yml` if the bundle-compile path is wanted).
2. Storage repo secrets and variables complete (section 5, `close-gaps.sh` reports "No blockers").
3. Render variables complete (section 6, `check-render-env.sh` reports none MISSING) and the deploy is `live`.
4. Turn on, one at a time, **last**: `CI_COMPILE_ENABLED=true`, then `RELEASE_UPLOAD_SESSIONS_ENABLED=true`
   (both on Render). `bash docs/ci/enable-pipeline.sh` (dry run) runs every gate of steps 1 to 3 and the by-hand
   comparisons of section 5/6; `--apply` then sets the two flags in this order, waiting after each for a **new** deploy to be
   `live` (40n-h; a flag already `true` is skipped). It stops before changing anything if a gate is BLOCKED. Then, if wanted, `REQUIRE_ORG_SIGNED_APKS=true` on Render (40n-c): an uploaded APK is then
   accepted only if it is signed with the organisation key (nothing is ever re-signed); every other APK is rejected with
   "not built by distr" and its release stays held. It applies to **every** APK upload (the operator's wording, see the
   scope question in the handover), so a developer's own-key APK is turned away and they upload an `.aab` instead.
   Needs `CI_COMPILE_EXPECT_CERT_SHA256` set. Recopy `docs/ci/read-upload.yml` into the storage repo first, or every APK is
   rejected as unverifiable. `SIGN_UPLOADED_APKS` must not be set (the workflow fails if it is `true`).
5. One real end-to-end upload (operator), then 40k. Upload how-to: `docs/direct_upload.md`.

## 5. The storage repo: checks and fixes

```
# every variable and its value (secrets are never shown)
gh variable list -R Zapier-codes/zealot-storage
# secret NAMES only
gh secret list -R Zapier-codes/zealot-storage
# is the workflow there, and is it the current one (the two hashes must match)
gh workflow list -R Zapier-codes/zealot-storage
gh api repos/Zapier-codes/zealot-storage/contents/.github/workflows/read-upload.yml --jq .sha
git -C ~/zealot hash-object docs/ci/read-upload.yml
```

Required in the storage repo:

| Kind | Name | Must be |
|---|---|---|
| variable | `ZEALOT_URL` | equal to Render's `CI_OIDC_AUDIENCE` (or `https://$ZEALOT_DOMAIN`), trailing slash ignored |
| variable | `R2_STAGING_ENDPOINT`, `R2_STAGING_BUCKET` | equal to Render's |
| variable | `RELEASE_CERT_SHA256` | the org certificate SHA-256 (64 hex, lower case, no colons) |
| variable | `SIGN_UPLOADED_APKS` | **not set** (40n-c: Zealot never re-signs an APK; the run fails if it is `true`) |
| secret | `RELEASE_KEYSTORE_BASE64` | `base64 -w0 appstore-production.jks` |
| secret | `RELEASE_KEYSTORE_PASSWORD`, `RELEASE_KEY_ALIAS` | the keystore password; `appstore_production` |
| secret | `RELEASE_KEY_PASSWORD` | only if the key password differs (it does not today) |
| secret | `R2_STAGING_CI_ACCESS_KEY_ID`, `R2_STAGING_CI_SECRET_ACCESS_KEY` | a second Cloudflare R2 token, Object Read and Write on the staging bucket |
| secret | `CI_COMPILE_CALLBACK_TOKEN` | same value as on Render |

### `docs/ci/close-gaps.sh`

Checks the storage repo against Render and, with `--apply`, fixes what can be derived. Default run changes
nothing. Needs `gh` (logged in with admin on the storage repo), `jq`, `curl`; `keytool` (`pkg install
openjdk-17`) only to read the certificate from a keystore. Asks for the Render API key if
`RENDER_API_KEY` is not set (also reads `~/.zealot.env` and `~/.render.env`).

```
~/close-gaps.sh                       # check only
~/close-gaps.sh --apply               # copy ZEALOT_URL / R2_STAGING_* from Render, set the cert variable
KEYSTORE=~/storage/downloads/appstore-production.jks KEYSTORE_ALIAS=appstore_production \
  ~/close-gaps.sh --apply             # also sets the keystore secrets and reads the certificate
CERT=<64 hex> ~/close-gaps.sh --apply # when the certificate is known and no keystore is at hand
```

It prompts (hidden) for the keystore password and, unless `KEYSTORE_KEY_PASSWORD` is set, the key password
(Enter = same). It cannot create the `R2_STAGING_CI_*` secrets (they need a Cloudflare token) and cannot
compare secret values.

**Gotchas found while building it (do not repeat them):**
- `gh api` prints GitHub's 404 JSON **on stdout** with exit 1. A helper that only discards stderr will read
  the error body as a value ("a certificate value is not 64 hex characters: {\"message\"..."). `gv()` now
  returns a value only when `gh api` succeeds.
- The first draft of the operator's own script called an undefined helper `gv` (Termux:
  `gv: command not found`), which made every "differs from Render" line meaningless. If a line mentions
  `command not found`, the comparison is not trustworthy.
- `keytool -certreq -alias <a> -keystore <f> -file /dev/null` is the non-destructive test that the key
  password equals the keystore password: empty output and exit 0 means it does.
- Setting a Render variable through the API may start a redeploy; look at the Events tab afterwards.

## 6. Render: checks and fixes

`docs/ci/check-render-env.sh` lists each Task 40 variable as `set` / `MISSING` (plain values for
non-secrets, a 10-character SHA-256 fingerprint for secrets) and changes nothing.

```
# the operator's Render key is already set globally (RENDER_API_KEY or RENDER_TOKEN): do NOT ask for it again
KEY="${RENDER_API_KEY:-$RENDER_TOKEN}"
bash ~/zealot/docs/ci/check-render-env.sh
# the last two deploys (status, time, commit message)
curl -s -H "Authorization: Bearer $KEY" \
  "https://api.render.com/v1/services/srv-dalsvf942hec73dk2vg0/deploys?limit=2" \
  | jq -r '.[].deploy | "\(.status)  \(.createdAt)  \(.commit.message // "" | split("\n")[0])"'
```

Render API used (from the scripts, verified only against the stubs in the sandbox): list
`GET /v1/services/{id}/env-vars?limit=100[&cursor=...]` (each row `{envVar:{key,value},cursor}`), set one
`PUT /v1/services/{id}/env-vars/{key}` with `{"value": "..."}`.

Required on `zealot-web` for the direct-upload + CI release path: `R2_STAGING_BUCKET`,
`R2_STAGING_ENDPOINT`, `R2_STAGING_ACCESS_KEY_ID`, `R2_STAGING_SECRET_ACCESS_KEY`, `CI_OIDC_AUDIENCE` (equal
to the storage repo's `ZEALOT_URL`), `CI_COMPILE_DISPATCH_TOKEN` (fine-grained, Actions read and write on
the storage repo), `CI_COMPILE_CALLBACK_TOKEN`, `CI_COMPILE_EXPECT_CERT_SHA256` (without it 40l-b marks
nothing signed), the two flags, and the storage adapter set, which depends on `RELEASE_STORAGE_ADAPTER`: with `github` (today's
value) `GITHUB_STORAGE_REPO` and `GITHUB_STORAGE_TOKEN`; the adapter's own `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY` (not the `R2_STAGING_*` ones) are needed only with `r2`. An earlier draft of the check
wrongly listed the `R2_*` trio as required; it is fixed. The operator chose to have them present anyway (R2 stays
staging-only, the adapter stays `github`, credentials only added): `bash docs/ci/add-r2-adapter-vars.sh --apply` copies
`R2_STAGING_BUCKET/ENDPOINT/ACCESS_KEY_ID/SECRET_ACCESS_KEY` into `R2_BUCKET/ENDPOINT/ACCESS_KEY_ID/SECRET_ACCESS_KEY`
(never overwrites, refuses unless the adapter is `github`). Nothing reads them until someone sets the adapter to `r2`, and
then they would point at the staging bucket, so give `r2` its own bucket and token first. Run it BEFORE `enable-pipeline.sh`.
Since 40n-h it waits for a NEW deploy to be `live` itself (see "Deploy waiting" below). Optional: `R2_STAGING_REGION`, `CI_COMPILE_REPO`,
`ADC_AUTO_REGISTER` (off today by design), `CI_READ_UPLOAD_WORKFLOW`.

Google ADC variables (separate from Task 40): `~/sync-adc.sh --apply` compares `ADC_REFRESH_TOKEN`,
`CLIENT_ID`, `CLIENT_SECRET` between the phone and Render and sets what is missing.

### Deploy waiting (Task 40n-h; built, tested against a stub only)

`enable-pipeline.sh` and `add-r2-adapter-vars.sh` used to read "the latest deploy" right after a variable change, which was still
the old `live` one, and reported success before any new deploy existed (2026-10-05: nothing newer than the old deploy appeared
until the operator POSTed one by hand). Both now source `docs/ci/lib-render-deploy.sh`:

1. snapshot the newest deploy ids **before** the change (it compares ids, never clocks);
2. wait `DEPLOY_GRACE` (60 s) for a deploy that is not in the snapshot; if none appears, start one with
   `POST /v1/services/$SVC/deploys` (body `{"clearCache":"do_not_clear"}`) and wait for that;
3. wait until the newest deploy is `live`, wait `DEPLOY_SETTLE` (20 s), and check it is still the newest (a second change can queue a
   deploy right behind the first);
4. stop (exit 3) on `build_failed`, `update_failed`, `canceled`, `pre_deploy_failed` or after `DEPLOY_MAX` (900 s); exit 2 when the
   deploy list cannot be read.

`enable-pipeline.sh` also skips a flag that is already `true`, so running it twice is safe. Tunables are environment variables
(`DEPLOY_GRACE`, `DEPLOY_POLL`, `DEPLOY_SETTLE`, `DEPLOY_MAX`). `RENDER_API_URL` points a script at a stub.

**What was and was not checked.** `bash docs/ci/test/test-render-deploy.sh` runs both scripts against `docs/ci/test/mock_render.py`
(auto-deploy, silent, failing, never-starting and late-second-deploy cases, plus dry runs): 10 of 10 pass, and the previous
`enable-pipeline.sh` was run against the "silent" stub to confirm it reproduced the bug (two changes, no deploy, `deploy: live`
read from the old one). **Not checked:** the real Render API. In particular the POST body `{"clearCache":"do_not_clear"}` is from
memory of Render's API, not from a run; the operator's by-hand POST on 2026-10-05 worked, but its body was not recorded. If the
script's own POST answers 4xx on the first real use, send the output to the session.

## 7. Zealot's own API, for checks from the phone

```
. ~/.zealot.env
curl -s -H "Authorization: Bearer $(zealot-token)" \
  https://zealot-deploy-latest.onrender.com/api/android_signing_key
# -> {"id":..,"filename":"appstore-production.jks","key_alias":"appstore_production","checksum":"<sha1>",..}
sha1sum ~/storage/downloads/appstore-production.jks   # must equal "checksum"
```

Same route family: `POST /api/play_credential` (Play service account), `bin/bootstrap-publishing`
(signing key and app creation, see Task 34d). The signing-key route wants the user token in an
`Authorization: Bearer` header only.

## 8. Debugging recipes

- **A push to `develop` did not deploy / which run is the deploy:** handover, "Which workflow is the deploy
  pipeline?". Pushes that touch only `**.md` do not deploy; a push that adds a `.sh` or workflow file does.
- **A CI run in the storage repo failed** (save the log where the session can read it):
  ```
  gh run list -R Zapier-codes/zealot-storage -L 5
  gh run view <run id> -R Zapier-codes/zealot-storage --log > ~/storage/downloads/run-<id>.log
  ```
  then upload the file. The stage-1/2 workflow is `read-upload.yml`; its report to Zealot is the callback
  (`/stage1`, `/stage2`), verified by GitHub OIDC (audience = `ZEALOT_URL`).
- **A compile run failed in the storage repo (name, step and fix):** section 15 reads one from start to finish, with the commands that fetch the latest run's id and its failing step.
- **Render deploy failed or the app will not boot:** save the deploy log from the Render dashboard (or with
  D-Store's `scripts/fetch-ci-log.sh`) to `~/storage/downloads` and upload it.
  Exact command (Termux; it saves one `render-deploy-<id>.log` per failed deploy, secrets stripped):
  ```
  export RENDER_API_KEY="${RENDER_API_KEY:-$RENDER_TOKEN}"
  for d in $(curl -s -m 30 -H "Authorization: Bearer $RENDER_API_KEY" "https://api.render.com/v1/services/srv-dalsvf942hec73dk2vg0/deploys?limit=5" | jq -r '.[].deploy | select(.status|test("failed")) | .id'); do
    bash ~/D-Store/scripts/fetch-ci-log.sh render srv-dalsvf942hec73dk2vg0 "$d"; done
  ```
  The boot error is the line starting `! Unable to load application`; the `from /app/app/...` lines under it name the file.
- **Boot crash `Before process_action callback :verify_authenticity_token has not been defined`:** a controller under
  `ApplicationController` has its own `skip_before_action :verify_authenticity_token`. `ApplicationController` already skips
  it, so delete the line (or write `raise: false`). Found on 2026-10-06 in `Api::TenantBuildsController` (Task 40n-f); three
  deploys failed on it. The 2026-10-03 boot crash
  (`Unknown validator: 'MessageValidator'`) was found this way.
- **An upload ends `uploaded` with no release:** `RELEASE_UPLOAD_SESSIONS_ENABLED` is on but stage 1/2
  never reported; check the run in the storage repo, then the 40g-2 sweeper fails it after 90 minutes.
- **A finished release shows `signed: false`:** `CI_COMPILE_EXPECT_CERT_SHA256` unset or different from the
  certificate CI reported, or no `AndroidSigningKey` row (40l-b). Releases made before 40l-b are not backfilled.
- **Certificate refused (422):** the reported `cert_sha256` differs from `CI_COMPILE_EXPECT_CERT_SHA256`;
  compare against section 2.
- **An APK upload ends `failed` with "not built by distr" or "could not be verified" (40n-c):**
  `REQUIRE_ORG_SIGNED_APKS` is `true` and the APK is not signed with the organisation key, is unsigned, has more than
  one signer, or the workflow copy in the storage repo is older than 40n-c (it reports no signature, so every APK is
  refused). The run's step `Read the uploaded APK's signature` shows whether `apksigner` ran. "no organisation
  certificate configured" means `CI_COMPILE_EXPECT_CERT_SHA256` is unset on Render. The held release has no file; delete it.
- **A run fails at `Check the inputs` with "SIGN_UPLOADED_APKS is no longer supported":** delete that storage-repo variable.

## 11. 40n-0 part 2 and 40n-a: run together on the operator's own machine (2026-10-05)

**Why combined.** The sandbox that writes these patches has no Maven/Google network access and no Android build tools,
so it cannot run the real upload test (section 10) or prove an AAB manifest patch (40n-a needs `bundletool`/`aapt2`, whose
`Resources.proto` schema the sandbox cannot fetch). Both need the operator's own machine. The operator chose to skip the
throwaway-app test and go straight to this, so **this is now the first real exercise of the whole pipeline**: treat any
failure as pipeline-wide, not as one small thing, and read section 8 (debugging recipes) if anything breaks.

**Prerequisites (operator's machine, not Termux-only):** `bundletool` (the `.jar`, or `brew install bundletool`), a JDK
(`keytool` already confirmed present, section 7), `aapt2` (from Android SDK build-tools, or `pip install aapt2` wheel),
and one real signed `.aab` of an app already in Zealot (its channel's `bundle_id` must match).

```bash
# 1. the real upload (section 10's block), against a REAL app/channel this time, not a throwaway one.
. ~/.zealot.env
Z=https://zealot-deploy-latest.onrender.com
FILE=<path to a real .aab>
CHANNEL_KEY=<its channel key, from: curl -sG "$Z/api/apps" -d token="$(zealot-token)" | jq -r '.. | objects | select(has("key") and has("bundle_id")) | "\(.name) \(.bundle_id) \(.key)"'>
bash ~/upload-test.sh "$FILE" "$CHANNEL_KEY"   # the script from the session that asked for this; recreate it from section 10 if deleted

# 2. in parallel (or after), the AAB manifest proof 40n-a needs, on the SAME file, independent of Zealot:
W=$(mktemp -d)   # uses $TMPDIR, which Termux sets (it has no /tmp)
bundletool build-apks --bundle="$FILE" --output=$W/check.apks --mode=universal
unzip -p $W/check.apks universal.apk > $W/universal.apk
aapt2 dump xmltree $W/universal.apk --file AndroidManifest.xml | head -40
# confirms bundletool can round-trip this bundle at all, before any patcher touches its manifest
```

**Report back:** the full output of step 1 (session JSON, PUT status, finalize JSON, every polled state, and the
`gh run list` line), and whether step 2's `aapt2 dump` ran without error. If step 1 fails, save the storage-repo run log
(section 8). If `bundletool`/`aapt2` are not installable on the operator's machine either, say so — 40n-a then has nowhere
to be proven, and 40j's existing universal-APK patch (already written) is the fallback per the Task 40 board.

## 9. Still open after this session (updated 2026-10-05, after 40n-0 part 1)

1. **40n-0 part 2: the one real upload** (section 10). Nothing in 40n-a to 40n-g starts before it passes.
2. ~~40n-h~~ **built** (`docs/ci/lib-render-deploy.sh`): both scripts now wait for a deploy **newer than the change**. Tested only
   against a stub (`docs/ci/test/test-render-deploy.sh`, 10 checks pass); **never run against the real Render API**. The first real
   use is the next time a Render variable is changed by either script; read its output, do not assume.
3. Back up the keystore off the phone (not confirmed done).
4. Three operator answers still owed (revamp section of `handover.md`): scope of the APK rule (every APK upload or tenant accounts only),
   the file behind the email button (30-day retention is a proposal), the dispatch path for 40n-d.
5. Done and no longer open: 40m (answered, superseded by 40n), `GITHUB_STORAGE_*` on Render (set), live deploy newer than the
   certificate and flag changes (yes), flags turned on (yes).

## 10. 40n-0 part 2: the one real end-to-end upload (commands checked against the code, NOT run)

Why: this is the first run of the whole direct-upload and CI path (40a to 40l-b). The routes and parameters below were read from
`config/routes.rb` and `app/controllers/api/apps/upload_sessions_controller.rb`; the shell block itself has never been executed.

Needs: a throwaway app **with an existing channel** in the Zealot console (a session never creates an app, scheme or channel; the
first upload of an app still uses the multipart endpoint), a small test `.aab` or `.apk` whose package name matches that app, and a
versionCode not used before. Use `hold=true` so nothing reaches a store.

```
. ~/.zealot.env
Z=https://zealot-deploy-latest.onrender.com
TOKEN=$(zealot-token)
FILE=~/storage/downloads/test.aab          # the test file
CHANNEL_KEY=<channel key of the throwaway app>

SIZE=$(wc -c < "$FILE")
S=$(curl -sS -X POST "$Z/api/apps/upload_sessions" \
  -d token="$TOKEN" -d channel_key="$CHANNEL_KEY" \
  -d filename="$(basename "$FILE")" -d size="$SIZE" -d hold=true)
echo "$S" | jq .
ID=$(echo "$S" | jq -r .id); URL=$(echo "$S" | jq -r .upload_url)

# send every header the session lists (a listed Content-Type must be sent exactly, or R2 answers 403 SignatureDoesNotMatch)
curl -sS -X PUT "$URL" --data-binary "@$FILE" \
  $(echo "$S" | jq -r '.headers | to_entries[] | "-H \(.key):\(.value)"')

curl -sS -X POST "$Z/api/apps/upload_sessions/$ID/finalize" -d token="$TOKEN" | jq .

# poll the outcome every ~30 s until state is "done" or "failed"
curl -sS -G "$Z/api/apps/upload_sessions/$ID" -d token="$TOKEN" | jq .
gh run list -R Zapier-codes/zealot-storage -L 3
```

**Pass:** the session goes `awaiting_bytes`, `uploaded`, then `done`; `release_id`, `release_version` and `release_url` appear and the
release is `held` in the console. For a bundle the served file is its universal APK and, because `CI_COMPILE_EXPECT_CERT_SHA256` is
set, the release should show `signed: true` (40l-b). Report the final `show` JSON.

**Reading the failures**
- `404` on `upload_sessions`: the flag is off in the running deploy (check the deploy is newer than the flag change).
- `401`/`403`: wrong credential for the route (`token` is the user token; a per-app token goes only in `Authorization: Bearer zpa_...`, never both).
- `422` on finalize: R2 holds nothing yet, or the size differs (the row becomes `failed` and the object is deleted). Redo the PUT.
- `503`: R2 unreachable or not configured; the row is unchanged, retry. Check `R2_STAGING_*` on Render.
- Stuck in `uploaded` with no run in the storage repo: dispatch failed; check `CI_COMPILE_DISPATCH_TOKEN` (needs Actions read and write on the storage repo) and `CI_COMPILE_REPO`.
- A run exists and fails: save its log (section 8) and upload it to the session. Callback 401/403 from the run points at the OIDC audience
  (`ZEALOT_URL` vs `CI_OIDC_AUDIENCE`) or `CI_COMPILE_CALLBACK_TOKEN`; 422 with a certificate message points at `CI_COMPILE_EXPECT_CERT_SHA256` vs `RELEASE_CERT_SHA256`.
- Stuck with a green run: the 40g-2 sweeper fails the upload after 90 minutes; do not wait, read the run and the `show` JSON now.

## 12. Render Free has no one-off jobs and no console: re-sending a release to CI (Task 40q, 2026-10-06)

**Found, do not retry.** `POST https://api.render.com/v1/services/$SVC/jobs` (the Jobs API, for `bin/rails runner ...`) answers
`400 {"message":"new paid services not allowed: srv-dalsvf942hec73dk2vg0"}`. One-off jobs need a paid Render plan; this service is
on the free tier. It is a plan limit, not a request mistake: no change of body, header or key will make it work. The same limit
rules out a `rails console` from the API. The only other way to run `rails runner` is the dashboard's web Shell (browser).

**Other ways considered and why they were not taken**
- Bump the app version and re-run the Storeapp workflow: the plan job's `version_exist` check runs regardless of `force`, so an unchanged
  app is blocked before upload. Only works with an artificial version bump.
- Render web Shell: works, but it is the browser path the operator wants to avoid.

**What replaced it: `POST /api/releases/:id/retry_compile`** (Task 40q). Platform admin only, user token only (a `zpa_` per-app token
is refused). **The user token goes in the `token` parameter, NOT in an `Authorization: Bearer` header** (`Api::BaseController#validate_user_token` reads `params[:token]` only; the Bearer form answered "未授权用户 token" on 2026-10-06 and the example here used to show it). It calls `CiCompileDispatchJob.enqueue_for(release)` and nothing else, so the 40b rules still decide:

| Answer | Meaning |
|---|---|
| `202` `{"id":3,"ci_compile_state":"queued"}` | queued; the job dispatches the storage-repo workflow |
| `422` with `ci_compile_state` / `ci_compile_error` | refused and nothing changed: `CI_COMPILE_ENABLED` is not `true`, the release is not an AAB, or its state is not empty/`failed` (already `queued`, `dispatched` or `done`) |
| `401` / `403` / `404` | no or wrong token / not an admin / no such release |

```
. ~/.zealot.env
Z=https://zealot-deploy-latest.onrender.com
curl -sS -X POST "$Z/api/releases/3/retry_compile" -d token="$(zealot-token)" | jq .
# then read what CI did (outcome is NOT readable from the API yet, see below):
gh run list -R Zapier-codes/zealot-storage -L 3
```

**Do not use `retry_compile` to poll.** On a `failed` release every call re-queues it. Read the outcome from the storage-repo run and the
release page in the console. A read-only `ci_compile_state` field on the release API is an open follow-up (40q-b), not built.

**Not verified:** the action, route, policy predicate and spec were written without a Ruby runtime or database (`ruby -c` not run
either: no Ruby in this sandbox). The endpoint exists only after this patch is pushed and the Render deploy is `live`
(it touches `.rb`, so the push does start `Anthropic - Build & Deploy develop`).

## 13. R2 staging as the only door for Android files (Task 40r, 2026-10-06)

**What it is.** Two changes, both in this patch:
1. **A session can open the first upload of an app** (no `channel_key`). The app, scheme and channel are created at stage 1
   from the file's package name, owned by the uploader (`ReleaseUploadAppResolver`). Details: `docs/direct_upload.md`.
2. **`REQUIRE_DIRECT_UPLOAD`** (Render variable, ships **unset = off**): when `true` and sessions are usable, an `.apk`/`.aab`
   posted as multipart to `POST /api/apps/upload` answers `426`, and the console form's plain post is redirected back. Other
   formats keep those doors.

**One storage-repo change is required before the first new-app upload.** The stage-2 job compared the app id in the staging
key with the app id in the storage tag; a first upload is staged under `a0` (no app yet), so the comparison would fail.
`docs/ci/read-upload.yml` now skips it for `a0` only. Replace the copy in the storage repo and check the hashes:

```
cd ~/zealot
gh api repos/Zapier-codes/zealot-storage/contents/.github/workflows/read-upload.yml --jq .sha
git hash-object docs/ci/read-upload.yml
# if they differ, replace it (same method as 2026-10-05: the contents API), then compare again:
SHA=$(gh api repos/Zapier-codes/zealot-storage/contents/.github/workflows/read-upload.yml --jq .sha)
gh api -X PUT repos/Zapier-codes/zealot-storage/contents/.github/workflows/read-upload.yml \
  -f message="task 40r: skip the staged-app comparison for a0 (first upload of an app)" \
  -f content="$(base64 -w0 docs/ci/read-upload.yml)" -f sha="$SHA"
gh api repos/Zapier-codes/zealot-storage/contents/.github/workflows/read-upload.yml --jq .sha   # must equal git hash-object
```

Uploads to an existing channel are not affected by this edit (their key still carries the real app id and is still compared),
so the workflow can be replaced before or after the Render deploy.

**Order to turn it on (do not reorder).**
1. Push the patch, wait for the Render deploy to be `live` (it runs the migration `20261006120000`).
2. Replace `read-upload.yml` in the storage repo (above).
3. Prove a **first upload through a session** with a throwaway package (commands in section 10, but **without** `channel_key`,
   optionally `-d name="Throwaway"`); the final session JSON must show `state: done` and an `app_id`. A throwaway app then
   exists in the console; delete it.
4. Prove an upload to the new app's channel (section 10 as written).
5. Only then set `REQUIRE_DIRECT_UPLOAD=true` on Render (a variable change starts a deploy; wait for it to be `live`).

**Revert.** Unset `REQUIRE_DIRECT_UPLOAD` (instant after the deploy), or `git revert` the commit (the migration only relaxed a
NOT NULL; leave it applied).

**Reading the failures.** A first upload that ends `failed` with "may not create" / "already exists and you may not upload to
it" / "is archived" is the resolver refusing (the reason is in the session's `error`). `403` on the session itself: a plain
member account, a per-app token, or a tenant host. A stage-2 run failing at "the storage tag belongs to another app" means
the old `read-upload.yml` is still in the storage repo.

**Not verified:** everything. No Rails, Postgres, R2 or runner in the sandbox that wrote it (`ruby -c`, the YAML parse and
`bash -n` on every `run:` block of `read-upload.yml` passed; the changed shell condition was run against sample values).

## 14. Large files in parts: turn-on order, variables and the real-file test (Task 40s, 2026-10-06)

**What it is.** A file at or over a threshold goes to R2 in parts (resumable) instead of one PUT, on both doors. Built in
40s-a to 40s-d, ships **off**. API loop and the full flow: `docs/direct_upload.md`, "Large files in parts".

**The three Render variables** (a change starts a deploy; wait for it to be `live`; `docs/ci/check-render-env.sh` lists them):

| Variable | Default | Notes |
|---|---|---|
| `RELEASE_UPLOAD_MULTIPART_ENABLED` | off | `true` is the switch |
| `RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB` | 100 | at or over this goes in parts; editable any time (affects uploads opened afterwards) |
| `RELEASE_UPLOAD_PART_SIZE_MIB` | 16 | floor 5; a 2 GiB file at 16 MiB is 128 parts |

**Before turning it on, check these (read-only):**
1. `check-render-env.sh` shows the staging and sessions variables set, and the bucket's lifecycle rule (1-day abort of unfinished
   multipart uploads) was read back on 2026-10-06 (`handover.md`, Task 40s-a entry). The 6-hour row window is inside it.
2. **The bucket's CORS rule allows `PUT` from the console origin with any request header.** The 40h-a commands set it; the
   40s-d session never read it back. Read it back (the same method as the lifecycle rule) before the first browser test.
3. **Storeapp:** its `release-aab.yml` direct-upload path (`ZEALOT_DIRECT_UPLOAD`) does a single PUT and fails on a bundle at
   or over the threshold. Leave `ZEALOT_DIRECT_UPLOAD` off there, or set the threshold above its largest bundle, until the
   workflow runs the parts loop (a separate Storeapp patch, not yet cut).

**Order to turn it on (do not reorder).**
1. The 40s-a migration (`part_size`) is live (it ran on the deploy after 40s-a).
2. Set `RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB` first if the default does not suit; leave the other two at their defaults.
3. Set `RELEASE_UPLOAD_MULTIPART_ENABLED=true`; wait for `live`. Files under the threshold behave exactly as before.
4. **Console test:** from a channel's upload page choose a file over the threshold. The bar climbs; close the tab at about half;
   reopen the page, choose the same file, press the button: the message says it is resuming and only the rest is sent.
5. **API test** with the loop in `docs/direct_upload.md` (section 10's commands for the same file, then follow `GET
   /api/apps/upload_sessions/:id` until `done` or `failed`). Try `RESUME_ID=<id>` after interrupting it with Ctrl-C.
6. The real-file test, section 13 (first upload of an app) and 40n-0 part 2, now with a big file. These were waiting on this.

**Reading the failures.**
- Console message `send_failed` on every part: almost always the CORS rule (check 2 above); the browser's network tab shows the
  blocked `PUT` to the R2 host.
- `409` on `.../parts` or finalize: the 6-hour window closed, or R2 dropped the upload; start again (the sweeper cleans the old one).
- `422 parts_incomplete` that repeats after resending: R2 holds a part at the wrong size; `GET .../parts` lists it under `missing`.
- `422` on `POST .../parts`: bad numbers, more than 10, or the upload was opened as a single PUT (the flag changed between open and sign).
- A large upload with no `upload_url` in the answer, from a client that does not know parts: the flag is on and that client needs
  the loop (Storeapp, see above). Turn the flag off to restore the single PUT for everyone at once.

**Revert.** Unset `RELEASE_UPLOAD_MULTIPART_ENABLED` (effective after the deploy). Uploads already open in parts can still be
resumed and finalized until their window closes; new ones are single PUTs.

**Not verified:** everything against a real R2, browser or Render. The loop was run against a local stand-in only.

## 15. A compile run failed: read it, fix it, put the fix in the storage repo (Task 40t, 2026-10-06)

**Found.** Release 3 (Storeapp, app 2) was re-sent with `retry_compile` and run `37427410330` of `Compile release 3` failed after 36 s.
The log (saved with section 8's command) shows every step before the failure passing: inputs, bundletool, the download of
`app-default-release.aab` (30 MB) from the storage release `a2-r3`, the signing key, and `bundletool build-apks` producing the signed
universal APK. It failed at **`Read the signing certificate`** with "could not read the signing certificate's SHA-256".

**Why.** The step prefers `apksigner` and falls back to reading the certificate from the keystore with `keytool -list -v | sed`. The
fallback ran (the `::notice::apksigner not found or unreadable` line is in the log) and found nothing: `keytool` indents its fingerprint
line with a **TAB then a space** (`\t SHA256: ...`) and the `sed` expected only spaces. Reproduced with a real `keytool` (JDK 17).
Why `apksigner` itself gave nothing on the runner is **not known**: its error output was thrown away.

**The fix** (`docs/ci/compile-aab.yml` and the same step in `docs/ci/read-upload.yml`, which would have failed the same way at stage 2):
the fallback now hashes the exported certificate (`keytool -exportcert | sha256sum`), so no text is parsed; and `apksigner`'s own output is
kept, so the next failure says why (`::notice::apksigner printed no certificate: ...`). The step script, extracted from the workflow, was
run against a real keystore: a match with no `apksigner` (the failing case), the expected value written with colons and capitals, a
mismatch (fails with "nothing was uploaded"), and an `apksigner` that prints only an error (reason logged, fallback still passes).

**Get a failed run (the same four commands every time):**

```
RID=$(gh run list -R Zapier-codes/zealot-storage -L 1 --json databaseId --jq '.[0].databaseId')
gh run list -R Zapier-codes/zealot-storage -L 3 --json databaseId,workflowName,conclusion,displayTitle
gh run view $RID -R Zapier-codes/zealot-storage --log > ~/storage/downloads/run-$RID.log
gh run view $RID -R Zapier-codes/zealot-storage --log-failed | tail -40
```

**Put the fix in the storage repo.** Run this right after `git am` (so the fix is `HEAD`). It applies the commit's own change to each
storage copy as a patch instead of overwriting the file, because the storage repo's `read-upload.yml` already differs from this repo's
(APK org-signing, 40o); a `patch` that does not apply cleanly stops that file and changes nothing.

```
cd ~/zealot
for F in compile-aab read-upload; do
  W=$(mktemp -d)   # uses $TMPDIR, which Termux sets (it has no /tmp)
  git diff HEAD~1 HEAD -- docs/ci/$F.yml > $W/$F.diff
  gh api repos/Zapier-codes/zealot-storage/contents/.github/workflows/$F.yml --jq .content | base64 -d > $W/$F.storage.yml
  patch $W/$F.storage.yml < $W/$F.diff || { echo "$F: did not apply, stop and report"; continue; }
  SHA=$(gh api repos/Zapier-codes/zealot-storage/contents/.github/workflows/$F.yml --jq .sha)
  gh api -X PUT repos/Zapier-codes/zealot-storage/contents/.github/workflows/$F.yml \
    -f message="task 40t: read the signing certificate by hashing the exported cert" \
    -f content="$(base64 -w0 $W/$F.storage.yml)" -f sha="$SHA" --jq .commit.sha
done
```

Then re-send the release (it is `failed`, so it is sendable) and read the new run:

```
. ~/.zealot.env; Z=https://zealot-deploy-latest.onrender.com
curl -sS -X POST "$Z/api/releases/3/retry_compile" -d token="$(zealot-token)" | jq .
sleep 45; gh run list -R Zapier-codes/zealot-storage -L 2
```

**Pass:** the run is green, the release page shows the compile `done`, and `zealot-storage` release `a2-r3` gains
`pipeline__universal.apk` and `pipeline__release.apks.br` next to the AAB (those names are what Task 41 replaces).
If it fails again, run the four commands above and upload the log.

**Not verified:** the patched workflows on a real runner. The step script was run locally; the YAML parses and every `run:` block passes `bash -n`.


## 16. The tenant harvest workflow (Task 40n-d, 2026-10-06; written, NOT run)

Storeapp's tenant build (`build-tenant-apk.yml`, 40n-e) uploads an unsigned bundle as the artifact `tenant-bundle`
(file `unsigned.aab`) and sends a `repository_dispatch` of type `harvest-tenant-apk` to the storage repo with
`build_id`, `storeapp_run_id` and `bundle_sha256`. `docs/ci/harvest-tenant-apk.yml` does the rest and creates no `Release` row.

**Install in the storage repo** (`Zapier-codes/zealot-storage`):

```
# 1. the workflow
cp docs/ci/harvest-tenant-apk.yml <storage-clone>/.github/workflows/harvest-tenant-apk.yml
# 2. zealot-ci/ must already hold the 40n-b files: aab_sdk_patcher.py, aab_manifest_patch/ManifestPatch.java,
#    proxies_sdk.dex, ZealotProxyProvider.java (see the header of docs/ci/read-upload.yml)
# 3. secrets and variables
gh secret   set STOREAPP_ACCESS_TOKEN -R Zapier-codes/zealot-storage   # read-only on Storeapp: Actions + Contents read
gh secret   set DISTR_CALLBACK_TOKEN  -R Zapier-codes/zealot-storage
gh variable set DISTR_CALLBACK_URL    -R Zapier-codes/zealot-storage --body "<distr callback url>"
# already present from stage 2, reused: PROXIES_API_KEY, RELEASE_KEYSTORE_BASE64, RELEASE_KEYSTORE_PASSWORD,
# RELEASE_KEY_ALIAS, RELEASE_KEY_PASSWORD, and the variable RELEASE_CERT_SHA256
```

On the Storeapp side the dispatch token (`ZEALOT_STORAGE_PAT`) is a fine-grained token on the storage repo. Repository
dispatch needs **Contents: write** on that repo; if the dispatch answers 403/404, check that permission first.
Record both tokens' expiry dates here when minted: `STOREAPP_ACCESS_TOKEN` ____, `ZEALOT_STORAGE_PAT` ____.

**Try it** (after a Storeapp tenant build has finished green, take its run id and the bundle hash from its log):

```
gh workflow run harvest-tenant-apk.yml -R Zapier-codes/zealot-storage \
  -f build_id=test1 -f storeapp_run_id=<run id> -f bundle_sha256=<64 hex>
sleep 45; gh run list -R Zapier-codes/zealot-storage -w "Harvest tenant APK (Zealot)" -L 2
```

**Pass:** the run is green and the storage repo has a prerelease `tenant-test1` with one asset `tenant-test1.apk`.
**The run refuses on purpose** when the run is not Storeapp's, is not `build-tenant-apk.yml`, was not on `main`, did not
succeed, or the artifact hash differs from `bundle_sha256`; the message says which. Delete a test release with
`gh release delete tenant-test1 -R Zapier-codes/zealot-storage --cleanup-tag -y`.

**Timing (40n-d3).** Storeapp dispatches from the last step of its own run, so the run is still `in_progress` when the
harvest starts. The harvest now waits for it (checks every 10 seconds, up to 10 minutes) and then requires `completed` and
`success`. A run that is the wrong repo, workflow or branch is refused at once without waiting.

**Public or private storage repo.** Both work. The harvest uploads with the job's own token either way. The Zealot download
door asks GitHub's asset API for the file and redirects to the short-lived signed link it returns, so it does not depend on
`browser_download_url`. `GITHUB_STORAGE_TOKEN` is required on Render only if the storage repo is private (set it anyway; it
is harmless for a public one). If you switch the repo between public and private, nothing needs to change.

**Door auth: signed, expiring links (40n-f).** The download door refuses any request that does not carry a link signed by
distr (a browser clicking an email button cannot send an `Authorization` header, so the proof is inside the link). One
shared secret, `DISTR_LINK_SECRET`, set on Render (`zealot-web`) and in distr; generate it once with `openssl rand -hex 32`.
`check-render-env.sh` lists it as required. Without it the door answers 503 (closed), never open.

The link is `https://<zealot host>/api/tenant_builds/<build_id>/download?expires=<unix seconds>&signature=<hex>` where
`signature` is the lowercase hex HMAC-SHA256, keyed with the secret, of three lines joined by newlines:
`tenant-build-download`, the build id, the expiry. Any HMAC library works; to make one by hand:

```
B=b123; E=$(( $(date +%s) + 600 ))
S=$(printf 'tenant-build-download\n%s\n%s' "$B" "$E" | openssl dgst -sha256 -hmac "$DISTR_LINK_SECRET" | awk '{print $NF}')
curl -sI "https://<zealot host>/api/tenant_builds/$B/download?expires=$E&signature=$S"   # 302 to GitHub, or 404 if no such build
```

A wrong, missing, altered or other-build signature is 401; an expired link is 401 saying so; an expiry more than 7 days out
is 401 even if signed. distr picks the lifetime (10 minutes to a few days; the email button should point at a distr page that
mints a fresh link when pressed, so the email never carries a long-lived one). Rotating the secret: set the new value in both
places at once; links signed with the old one stop working, which is the intent.

**Not verified:** a real runner. The YAML parse, `bash -n` of every `run:` block, and a mocked-`gh` test of the new wait
loop (wait then pass, refuse on failure, refuse on wrong branch, time out, retry after an API error) were the only checks.
The Ruby spec was updated but not run (no Ruby in the sandbox).

### Check everything at once (added with the 2026-10-06 audit)

```
cd ~/zealot && git pull origin develop && bash docs/ci/check-all-status.sh
```

It is read-only. Besides Render, the storage repo and the mirrored files, it now covers the harvest: the installed workflow against `docs/ci`, the `zealot-ci` files, the secrets and variables by name, Storeapp's `ZEALOT_STORAGE_PAT` and dispatch step, whether the download door is deployed, and the last three harvest runs. The last line counts the items that need action.

## 17. Making an app show as Featured in D-Store (Task 42a, 2026-10-06; written, NOT run)

Featured is store-owned data on the `App` row, not something the owner sets. Who owns the app does not matter to it:
`/admin/apps` lists every app on the default host and an admin may toggle any of them. D-Store reads the flag only from
Zealot's signed catalog index, and it features first-party (Zealot) apps only; the home hero is the first featured app.
Do these in order (the app is Storeapp, owned by the developer account `claudeone7492@gmail.com`):

1. **Owner.** Open the app's page, then its owner page (`/apps/<id>/new_owner`; admin or the current owner) and pick the
   developer account. Check the owner shown on the app page afterwards.
2. **Default tenant.** The app must belong to no tenant (the default catalog). D-Store's default index never includes an app
   of another tenant. If the developer account was made on a tenant's host, the app is in that tenant's index instead.
3. **Listing live.** Signed in as the developer account: the app's Store listing page, request listing (needs a publisher
   profile). Then, as admin, the same page's mark-paid button (or the B-PAY checkout). Only `listing_status = live` apps are in the index.
4. **A published release.** The release must be in an available (published) status; re-send `a2-r6` first if it predates Task 41 (section 12).
5. **Featured.** Admin: `/admin/apps`, toggle Featured on the app. Since 42a this republishes the index by itself;
   before 42a it did not, and any listing edit was needed to force it.
6. **Check.** The Pages index carries `"featured": true` for the app, and D-Store's home shows it in the hero after its cache refreshes.

## 18. distr on its own Render account: the commands that worked (2026-10-07)

Full state and the order of next steps are in `handover.md`, newest entry. Termux, operator device. Keys live in `~/.render-distr.env`
(`RENDER_API_KEY_DISTR`, `RENDER_SERVICE_ID_DISTR`); never put the distr key into `~/.render.env` or name it `RENDER_API_KEY` there.

- **Check the key and find the service:** `curl -s -H "Authorization: Bearer $RENDER_API_KEY_DISTR" "https://api.render.com/v1/services?limit=20" | jq -r '.[].service | "\(.id)  \(.name)  \(.type)  \(.suspended)"'`. A `404` on a service call means a wrong service id (a placeholder); a bad key is `401`.
- **A distr CI run failed:** `bash ~/D-Store/scripts/fetch-ci-log.sh gh Zapier-codes/distr [run id]` grabs the latest *failed run of any workflow*; the first one it picked was `Release Please`, not the build. Find the build run with `gh run list -R Zapier-codes/distr -w "Publish to GHCR" -L 5`.
- **Green build, nothing deployed:** `gh run view <id> -R Zapier-codes/distr --log | grep "hook answered" | grep -v 'code}'` must show `Render deploy hook answered 200`. A `RENDER_DEPLOY_HOOK_URL is not set` notice means the image was published and Render was never told. Set it silently: `read -rsp "hook: " H; echo; printf %s "$H" | gh secret set RENDER_DEPLOY_HOOK_URL -R Zapier-codes/distr; unset H`. The log of a run that is still going is empty; wait for the `✓`.
- **A distr deploy is `update_failed`:** `RENDER_API_KEY="$RENDER_API_KEY_DISTR" bash ~/D-Store/scripts/fetch-ci-log.sh render srv-db2n44jncjis73bn1hvg`, then `unset RENDER_API_KEY`. The first two failed with `panic: missing required environment variable: DATABASE_URL` (exit 2): the service was created without the variables in `render.yaml`. Required to boot: `DATABASE_URL`, `DATABASE_ENCRYPTION_KEY`, `JWT_SECRET`, `DISTR_HOST`, `PORT=8080`, `LOKI_URL`, `REGISTRY_ENABLED=false`.
- **Set an env var on a service without opening the dashboard:** `curl -s -X PUT -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d "{\"value\":$(printf %s "$VALUE" | jq -Rs .)}" "https://api.render.com/v1/services/<srv id>/env-vars/<NAME>" | jq -r .key` prints the name back on success. Then start a deploy: `curl -s -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d '{}' "https://api.render.com/v1/services/<srv id>/deploys"`.
- **Database:** Supabase **Session pooler** (port 5432), not the transaction pooler (6543); distr migrates on boot and takes advisory locks. Free Supabase projects pause when idle.


## 19. Putting an app in D-Store over the API (Task 42e, 2026-10-07; RAN for real on app 2 the same day, see section 22; the pay/checkout parts were not run)

Everything section 17 did by clicking can now be done with `curl`. All routes take the **user token in the `token`
parameter** (never a Bearer header, never a per-app token) and change nothing on a refusal. The console pages stay;
both paths call the same model methods and policies.

| Step | Call | Who |
|---|---|---|
| Read what keeps an app out of the index | `GET /api/apps/:id/store_listing` | owner or admin |
| Request listing (draft -> awaiting_payment) | `POST /api/apps/:id/store_listing` | the **owner**, who needs a publisher profile |
| **Pay** the listing fee (starts the B-PAY payment) | `POST /api/apps/:id/store_listing/pay` (optional `return_url=`) | the **owner** |
| Read the payments and their status | `GET /api/apps/:id/store_listing/payment` | owner or admin |
| Mark paid by hand (awaiting_payment or suspended -> live), the admin stand-in | `PATCH /api/apps/:id/store_listing/mark_paid` | platform admin |
| Change the owner | `PUT /api/apps/:id/owner` with `user_id=` or `email=` | owner or admin |
| Featured / Editors' Pick | `PUT /api/apps/:id/editorial` with `featured=true\|false` and/or `editors_pick=true\|false` | platform admin |
| Publish a held release | `POST /api/releases/:id/release` (Task 34a-6, already there) | owner or admin |
| Re-send a release to CI | `POST /api/releases/:id/retry_compile` (section 12) | platform admin |

`:id` is the numeric app id (the number in the console URL `/apps/<id>`). Every answer from the first five is the same
readiness report: `owner`, `tenant`, `listing_status`, `featured`, `latest_release`, `available_release`, `blockers`
(plain sentences) and `eligible_for_catalog_index`. An empty `blockers` list means nothing Zealot knows of keeps the app
out of the index; the published file is still the proof (`gh api repos/Zapier-codes/dstore-catalog/contents/index.json
-H "Accept: application/vnd.github.raw"`). The tenant is not changeable here: an app that shows a tenant stays out of the
default index until it is moved by hand.

```
. ~/.zealot.env; Z=https://zealot-deploy-latest.onrender.com; A=<app id>
T=$(zealot-token)                                  # the ADMIN's token
curl -sS -G "$Z/api/apps/$A/store_listing" -d token="$T" | jq '{listing_status, owner, tenant, blockers}'
# hand the app to the developer account (by email)
curl -sS -X PUT "$Z/api/apps/$A/owner" -d token="$T" --data-urlencode email=claudeone7492@gmail.com | jq '{changed, owner}'
# the OWNER (not the admin) asks for the listing; use the developer account's own token
curl -sS -X POST "$Z/api/apps/$A/store_listing" -d token="<developer token>" | jq '{listing_status, code, error}'
# the admin marks it paid, which makes it live and republishes the index
curl -sS -X PATCH "$Z/api/apps/$A/store_listing/mark_paid" -d token="$T" | jq '{listing_status, blockers}'
curl -sS -X PUT "$Z/api/apps/$A/editorial" -d token="$T" -d featured=true | jq '{featured, blockers}'
```

**Paying over the API (Task 42f; written, NOT run).** `POST .../store_listing/pay` runs the same code as the console's pay
page (`StoreListingPayment`): a `pending` Payment of 1499 cents (`usd`) and a B-PAY payment with a mandate for the later
maintenance charges. It answers `201` with `payment_id`, `status`, `amount_cents`, `currency`, `client_secret`,
`publishable_key` and `sdk_url`. **That starts the payment; it does not take the card.** Zealot never handles card data, so
the card step is B-PAY's own checkout (its web SDK, or its client-side confirm call with the publishable key, the client
secret and the card details), which the caller's own app or page makes. The app goes live only when B-PAY's signed webhook
reports success (`/hooks/hyperswitch`); poll `GET .../store_listing/payment` until `status` is `succeeded`, or watch the
report's `listing_status` turn `live`. The client secret is shown once and cannot be read back; do not log it. Each `pay` call
makes a new pending Payment, so do not put it in a retry loop. `503 payment_not_configured`: `HYPERSWITCH_API_KEY` is unset
on Render. `502 payment_start_failed`: B-PAY refused; the Payment row is kept as `failed`.

```
curl -sS -X POST "$Z/api/apps/$A/store_listing/pay" -d token="<developer token>" -d return_url=https://example.com/done \
  | jq '{payment_id, status, amount_cents, currency, publishable_key, sdk_url}'   # leave client_secret out of logs
curl -sS -G "$Z/api/apps/$A/store_listing/payment" -d token="<developer token>" | jq '.payments[0] | {status, paid_at}'
```

**Reading refusals.** `422 publisher_profile_required`: the owner has no publisher profile (create it over the API, section 21). `422 listing_not_available`: the app is not in the state the step needs (asking again after a
success lands here; read `listing_status`). `422 app_archived`. `403`: wrong role for that step (only the owner may
request, only an admin may mark paid or set the flags). `404`: no such app, or an app of another tenant. `422` with no body
about a token: a missing or wrong `token` on this legacy door.

**Not verified:** nothing ran under Rails or against Render (see the 42e entry in `handover.md`). The spec is
`spec/requests/api_app_store_listing_spec.rb`; read the `CI - RSpec` run for this commit first.

## 20. Paying the listing fee from a terminal or any client (Task 42i, 2026-10-07; written, NOT run)

`POST /api/apps/:id/store_listing/pay` (owner's user token) now also answers `checkout_url` and
`checkout_expires_at` (one hour). Open `checkout_url` in any browser: it is a hosted page, no login, that shows
`$25.00` struck through next to `$14.99` and B-PAY's card form. The card goes from that page to B-PAY; Zealot
never sees it. The app goes live when B-PAY's signed webhook arrives, so poll
`GET /api/apps/:id/store_listing/payment` until `status` is `succeeded`.

From a terminal (needs `curl` and `jq`):

```
ZEALOT_URL=https://<zealot host> ZEALOT_TOKEN=<owner's user token> bin/pay-store-listing <app_id>
```

It starts the payment, then asks for the name on the card, the card number (hidden), the expiry (MM/YY) and the
security code (hidden), checks them (card number checksum, expiry shape, code length), shows `Pay $14.99 with the
card ending 4242 ...` and waits for Enter. On Enter it sends the card **directly to B-PAY** (`confirm_url`, with the
publishable key and the one-time client secret from the `pay` answer); Zealot never receives it. Then it waits up
to 10 minutes for `succeeded` or `failed`. If the bank wants 3-D Secure it prints a link to finish that in a
browser. `bin/pay-store-listing --link <app_id>` prints the hosted page's link instead.

Needs `HYPERSWITCH_API_KEY`, `HYPERSWITCH_PUBLISHABLE_KEY` and `HYPERSWITCH_SDK_URL` on the server. **Not verified
against real B-PAY:** that its confirm call accepts a card from a non-browser caller with these fields (the
`customer_acceptance` block and the lack of `browser_info` are the likeliest to need adjusting); test with a B-PAY
test card first. Anyone holding the hosted link can pay that one invoice and nothing else; an expired link needs a
new `pay` call.

**An app made live by `mark_paid` is outside every payment rule (Task 42h).** `mark_paid` creates no Payment and no
`app_maintenance_billings` row. The $14.99 listing fee and the $2/month maintenance charge, the charge job and the
lapse suspension only ever act on an app that has a billing row, and a row is made only when a listing-fee payment
succeeds through B-PAY. So an app already published and put in D-Store by hand (the section 19 commands above) is never
charged, never suspended for non-payment, and its releases are shown for as long as it stays `live`.

## 21. Everything over the API: any account's token and the publisher profile (Task 42j, 2026-10-07; RAN for real the same day, see section 22)

A platform admin can now do, with the admin's token alone, what used to need the console or the developer's own login.

| Step | Call | Who |
|---|---|---|
| Find an account | `GET /api/users/search?email=<address>` | platform admin |
| Read that account's API token | `GET /api/users/:id/token` -> `{user_id, email, token}` | platform admin only (a 403 for anyone else, even for their own id) |
| Read your own publisher profile | `GET /api/publisher_profile` (404 `publisher_profile_missing` if none) | the token's user |
| Create or change your own | `PUT /api/publisher_profile` with `kind`, `display_name`, `legal_name`, `country`, `contact_email` (201 created, 200 changed, 422 `publisher_profile_invalid` with `errors`) | the token's user |
| Read, create or change any account's | `GET` / `PUT /api/users/:id/publisher_profile` (same fields) | platform admin only |

The token is in no other answer; the user record never carries it. Each read is logged as "admin X read the API token
of user Y" (never the token). It is the same power the console's Admin > Users > Edit page already gives; treat the
token like a password and do not log it. Listing an app end to end with the admin token only:

```
. ~/.zealot.env; Z=https://zealot-deploy-latest.onrender.com; T=$(zealot-token); A=2
U=$(curl -sS -G "$Z/api/users/search" -d token="$T" --data-urlencode email=claudeone7492@gmail.com | jq -r .id)
read -rs DEV < <(curl -sS -G "$Z/api/users/$U/token" -d token="$T" | jq -r .token)   # the owner's token, not printed
curl -sS -X PUT "$Z/api/users/$U/publisher_profile" -d token="$T" -d kind=individual -d display_name="<name>" \
  -d legal_name="<legal name>" -d country="<country>" -d contact_email=<email> | jq .
curl -sS -X POST "$Z/api/apps/$A/store_listing" -d token="$DEV" | jq '{listing_status, code, error}'      # draft -> awaiting_payment
curl -sS -X POST "$Z/api/releases/<release id>/release" -d token="$T" | jq '{id, status}'                  # held -> available
curl -sS -X PATCH "$Z/api/apps/$A/store_listing/mark_paid" -d token="$T" | jq '{listing_status, blockers}' # live, no payment
```

## 22. Storeapp (app 2) live and featured in D-Store, no payment: what ran, and what to check (2026-10-07)

Everything below was run from Termux against `https://zealot-deploy-latest.onrender.com` and the outputs were read back
by the operator. Sections 19 and 21 therefore work on the deployed build, except the pay and checkout paths (42f, 42i),
which were not run.

**Helpers now on the phone (no secrets in this repo).**
- `~/.zealot.env` now also exports `Z` (the Zealot URL) and `ZA=2` (the Storeapp app id). Start any session with
  `. ~/.zealot.env; T=$(zealot-token); DEV=$(zealot-dev-token); A=$ZA`.
- `zealot-dev-token [email]` (in `$PREFIX/bin`): prints the developer account's API token, default
  `claudeone7492@gmail.com`, by calling `GET /api/users/search` and `GET /api/users/:id/token` with the admin token.
  Nothing is cached on disk, so a rotated token is never stale. Each read is logged by the server (id, never the token).
- `VERCEL_TOKEN` is exported from `~/.bashrc`.

**State read back.** App 2 (Storeapp): owner user 3 (`claudeone7492@gmail.com`), `tenant: null`. Release 6, version 1.1.4,
build 218: `status: available`, `ci_compile_state: done`, `signed: true`. Publisher profile id 1 for user 3, `kind:
individual`, created over the API with `PUT /api/users/3/publisher_profile` (`kind` locks once the account has a live app).

**What ran, in order.**
1. `GET .../store_listing` (admin): `draft`, blocker "listing_status is draft; only live apps are indexed".
2. `POST .../store_listing` (owner token) first answered `422 publisher_profile_required`; after the profile was created it
   answered `awaiting_payment`.
3. `POST /api/releases/6/release` was refused: the release was **already `available`**, so this step is not needed for it.
   The refusal text comes in Chinese on this deployment (the locale), which is why a `jq` filter on `{id, status}` printed
   nulls. Read such answers raw.
4. `PATCH .../store_listing/mark_paid` (admin): `live`, `blockers: []`. No Payment, no billing row, so the 42h job never
   charges or suspends it.
5. `GET .../store_listing` again: `available_release` is release 6, `eligible_for_catalog_index: true`.
6. The published index (`dstore-catalog/contents/index.json`) carries version 1.1.4, code 218, commit 517394f, and it is the
   app's `suggested_version_code`.
7. `PUT .../editorial -d featured=true` (admin): `featured: true`, `blockers: []`. After it the index had exactly one app with
   `featured: true`.

**Anomaly, not explained.** The block above was run twice. On the second run `POST .../store_listing` answered
`awaiting_payment` (no `code`) for an app that was already `live`, and `mark_paid` put it back to `live`. The repo's own
code (`App#request_store_listing!` returns false unless `listing_draft?`, so a repeat should be `422 listing_not_available`)
says it should have been refused, so either the deployed build differs from `develop` or something else changed the status
in between. The end state was correct, but D-Store may have dropped the app until the next republish. Do not repeat the
request step on a live app; to find the cause, compare the deployed commit with `develop` and read `listing_status` between calls.

**D-Store (Vercel, not Render).** The Render account holds only `zealot-web`. D-Store is the Vercel project `d-store`
(repo `D-Store`), domains `d-store-edges2.vercel.app` and `d-store-git-master-edges2.vercel.app`. Its home hero is the first
featured first-party app in the index (`lib/catalog.ts` `getFeaturedApps`, `app/page.tsx` hero rule), so with Storeapp the
only featured app it is the top card once D-Store's cache refreshes. Listing the Vercel projects:
```
curl -s -H "Authorization: Bearer $VERCEL_TOKEN" "https://api.vercel.com/v9/projects?limit=50" \
  | jq -r '.projects[] | [.name, (.targets.production.alias // [] | join(",")), (.link.repo // "")] | @tsv'
```

**CI.** The latest run of `zealot-storage` on `main` is green. Three earlier runs failed (two `read-upload`-type runs and one
compile run of 36 s; the runbook's section 15 records run `37427410330`, `Compile release 3`, failing after 36 s). Their logs
were not saved, and the Claude sandbox has no `gh`, so nothing was read from them. Save a failed run's log with section 8's
command; `gh run view <id> -R ... --log` needs the real run id (the `<id>` is a placeholder, not literal text).

**Not verified.** The live D-Store home page in a browser (the Claude sandbox cannot reach `*.vercel.app`); that the hero
actually shows Storeapp; the cause of the anomaly above; anything under Rails or RSpec.
