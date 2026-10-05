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
| Storage-repo variables `ZEALOT_URL`, `R2_STAGING_ENDPOINT`, `R2_STAGING_BUCKET` | set, equal to Render | `close-gaps.sh` output ("ok" lines) |
| Storage-repo variable `RELEASE_CERT_SHA256` | set by `close-gaps.sh --apply` | output |
| Render `CI_COMPILE_EXPECT_CERT_SHA256` | set by `close-gaps.sh --apply` (Render may have redeployed) | output |
| Storage-repo secrets `RELEASE_KEYSTORE_BASE64`, `RELEASE_KEYSTORE_PASSWORD`, `RELEASE_KEY_ALIAS` | set by `close-gaps.sh --apply`; the operator then re-set `RELEASE_KEYSTORE_PASSWORD` by hand with `gh secret set` | output |
| Storage-repo secrets `CI_COMPILE_CALLBACK_TOKEN`, `R2_STAGING_CI_ACCESS_KEY_ID`, `R2_STAGING_CI_SECRET_ACCESS_KEY` | exist (values cannot be compared) | output |
| Render latest deploy | `live` (2026-10-05 05:57 UTC); whether it came after the certificate variable change was **not** established (look for an "Environment updated" event) | deploy list |
| `read-upload.yml` in the storage repo | was the 40j version (`d01cb1e7`); replaced with `0f115f4c` (40l-b) through the contents API, hashes then equal (commit `d4ccdab3` in the storage repo) | `gh api ... --jq .sha` vs `git hash-object` |
| Render `R2_STAGING_BUCKET/ENDPOINT/ACCESS_KEY_ID/SECRET_ACCESS_KEY/REGION`, `CI_OIDC_AUDIENCE`, `CI_COMPILE_REPO`, `CI_COMPILE_DISPATCH_TOKEN`, `CI_COMPILE_CALLBACK_TOKEN`, `CI_COMPILE_EXPECT_CERT_SHA256`, `RELEASE_STORAGE_ADAPTER=github` | **set** (secrets by fingerprint only) | `check-render-env.sh` output, 2026-10-05 |
| Render `GITHUB_STORAGE_REPO`, `GITHUB_STORAGE_TOKEN` | **not yet checked** (the first check version did not list them) | |
| Render `CI_COMPILE_ENABLED`, `RELEASE_UPLOAD_SESSIONS_ENABLED`, `ADC_AUTO_REGISTER` | **unset** (off), as intended | same output |
| `SIGN_UPLOADED_APKS`, `CI_COMPILE_ENABLED`, `RELEASE_UPLOAD_SESSIONS_ENABLED` | **off** (nothing said they were turned on) | |
| 40m (Storeapp tenant signing) | **blocked**, four options in the Task 40 entry, unanswered | |

## 4. Order to turn the pipeline on (do not reorder)

1. Storage repo: `read-upload.yml` copied to `.github/workflows/read-upload.yml` on `main`
   (and `compile-aab.yml` if the bundle-compile path is wanted).
2. Storage repo secrets and variables complete (section 5, `close-gaps.sh` reports "No blockers").
3. Render variables complete (section 6, `check-render-env.sh` reports none MISSING) and the deploy is `live`.
4. Turn on, one at a time, **last**: `CI_COMPILE_ENABLED=true`, then `RELEASE_UPLOAD_SESSIONS_ENABLED=true`
   (both on Render). Then, if wanted, `SIGN_UPLOADED_APKS=true` in the storage repo (re-signs plain APKs
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
wrongly listed the `R2_*` trio as required; it is fixed. Optional: `R2_STAGING_REGION`, `CI_COMPILE_REPO`,
`ADC_AUTO_REGISTER` (off today by design), `CI_READ_UPLOAD_WORKFLOW`.

Google ADC variables (separate from Task 40): `~/sync-adc.sh --apply` compares `ADC_REFRESH_TOKEN`,
`CLIENT_ID`, `CLIENT_SECRET` between the phone and Render and sets what is missing.

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

## 9. Still open after this session

1. 40m: the operator's answer (see the Task 40 entry): `1a, 2b, 3 none installed` or `keep tenant
   signing, drop 40m`. Treat "unsure whether any tenant APK is installed" as "some installed".
2. Check `GITHUB_STORAGE_REPO` / `GITHUB_STORAGE_TOKEN` on Render (`check-render-env.sh`, fixed version) and
   that the live deploy is not older than the certificate variable change.
3. Back up the keystore off the phone (not confirmed done).
4. Turn the flags on in the order of section 4, then one real upload, then 40k.
