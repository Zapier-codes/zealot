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
| `SIGN_UPLOADED_APKS` (storage repo) | **off** (not in `gh variable list`); must stay off, 40n-c and 40k delete its step | `gh variable list` |
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
   `live` (40n-h; a flag already `true` is skipped). It stops before changing anything if a gate is BLOCKED. Then, if wanted, `SIGN_UPLOADED_APKS=true` in the storage repo (re-signs plain APKs
   with the org key; apps already installed from another key then cannot update, see the 40l result).
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
| variable | `SIGN_UPLOADED_APKS` | `true` only when re-signing APKs is wanted |
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
- **Render deploy failed or the app will not boot:** save the deploy log from the Render dashboard (or with
  D-Store's `scripts/fetch-ci-log.sh`) to `~/storage/downloads` and upload it. The 2026-10-03 boot crash
  (`Unknown validator: 'MessageValidator'`) was found this way.
- **An upload ends `uploaded` with no release:** `RELEASE_UPLOAD_SESSIONS_ENABLED` is on but stage 1/2
  never reported; check the run in the storage repo, then the 40g-2 sweeper fails it after 90 minutes.
- **A finished release shows `signed: false`:** `CI_COMPILE_EXPECT_CERT_SHA256` unset or different from the
  certificate CI reported, or no `AndroidSigningKey` row (40l-b). Releases made before 40l-b are not backfilled.
- **Certificate refused (422):** the reported `cert_sha256` differs from `CI_COMPILE_EXPECT_CERT_SHA256`;
  compare against section 2.

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
bundletool build-apks --bundle="$FILE" --output=/tmp/check.apks --mode=universal
unzip -p /tmp/check.apks universal.apk > /tmp/universal.apk
aapt2 dump xmltree /tmp/universal.apk --file AndroidManifest.xml | head -40
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
