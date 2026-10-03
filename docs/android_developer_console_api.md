# Android Developer Console API: what is known, what was tested, what is not

**Status: the code in section 9 now calls this API, written and NOT run, and automatic registration is OFF until `ADC_AUTO_REGISTER=true`.** Written in the Task 36
discovery session and extended in the Task 36b build session. It records (a) the shape of Google's API, read from Google's own
machine-readable definition with the operator's key, (b) the few live calls that were made with
the operator's credentials, (c) how the operator's credentials are set up, and (d) what is still
unknown. The build plan is the Task 36 section of `handover.md`; this file is the facts it rests on.

Nothing here contains a secret. Environment variable names are given, never values.

How to read the tags: **[read]** = read from Google's definition or a Google page this session;
**[called]** = a real request was made with the operator's credentials and the answer was seen;
**[reported]** = something the operator, or an earlier session, said, not re-checked; **[unknown]**
= not established. Anything without a tag is a deduction, and says so.

## 1. What the API is for

Google's "Android developer verification" ties a verified developer identity to Android package
names and the signing certificates used for them. The Android Developer Console API lets a tool
(an alternative app store, a CI pipeline) register package names and keys by program instead of
by hand in the console. **[read]** Google's guide says it supports "OAuth delegation" so a store can
act for a developer. A separate, much smaller API, the Android Developer ID Status API, only answers
"is this package name registered?".

Scope of Google's enforcement (Google's guide, read this session): the protections go live on
**30 September 2026 in Brazil, Indonesia, Singapore and Thailand**, and Google plans mandatory
verification worldwide in **2027**. **[read]** The guide says apps "can still be sideloaded".

**Re-check needed (changes an earlier reading).** Task 27h parked this work because Google's pages,
read in an earlier session, limited enforcement to seven named stores (none of them Zealot). The
Google page read in this session says the verification capability "will soon be expanded to all
third-party Android app stores" and that Android requires apps to be registered by verified
developers to install on certified devices. Those two readings differ. Neither was verified against
a device. Task 36 treats registration as wanted anyway (operator direction), so this only affects
how urgent it is.

## 2. The operator's setup (as found; no values)

- **Developer account.** `developerAccounts.list` **[called]** returned exactly one account: display
  name **EDGES ENTERPRISE LTD**, `verificationState` **VERIFIED**. A session must not hard-code its
  numeric id; read it with `developerAccounts.list` (and refuse to act if more than one is returned).
- **Registered packages.** `androidPackages.list` **[called]** returned one package, `com.antropic`,
  state `REGISTERED`. Who owns that app and which key it is registered with were **not** checked
  (`keys.list` was not called). The package this repo cares about, `com.vythera.vyxelapps`, was **not**
  in the list.
- **Org signing key.** `AndroidSigningKey` is one org-wide row. An earlier session reported its
  SHA-256 certificate fingerprint as
  `24:12:37:3A:E4:4A:83:9F:58:BE:D8:57:96:70:7F:12:0B:96:42:0B:EE:93:65:14:3C:E4:77:67:B6:4E:A1:E5`
  **[reported, not re-verified]**. Google's API wants the fingerprint as a raw hex string without
  colons (definition text, `AndroidPackageKey.certificateFingerprintSha256`). A slice must compute
  the fingerprint from the stored keystore, not trust this line.
- **Credential type.** A Google Cloud OAuth client of type **Desktop app**, in the operator's Cloud
  project. The Android Developer Console API is **enabled** in that project (it was disabled until
  this session; the first call failed with `SERVICE_DISABLED` and worked after enabling).
- **Environment variables (names only):**

| Name | Holds | Where it exists |
|---|---|---|
| `CLIENT_ID`, `CLIENT_SECRET` | the Desktop OAuth client | Termux `~/.bashrc`; Render service `zealot-web` |
| `ADC_REFRESH_TOKEN` | refresh token with scope `androiddeveloperconsole`, granted by the account that owns the developer account | Termux `~/.bashrc`; Render service `zealot-web` (put there this session through Render's API; a Render env change redeploys the service) |
| `ADC_API_KEY` | an API key restricted to the two Android APIs | **Termux only. Not in Render.** Needed only for the definition document and the Status API |

- **API key.** The first key the operator made by hand arrived damaged (33 characters; Google rejected
  it as invalid). A replacement was **created by program** (Service Usage API to enable the API Keys
  API, then API Keys API `projects/{n}/locations/global/keys`, restricted to
  `androiddeveloperconsole.googleapis.com` and `androiddeveloperidstatus.googleapis.com`) and it is
  39 characters and works for the definition document **[called]**. Any older key in the console is
  unused and should be deleted by the operator.

## 3. Authentication, exactly

**[read]** The API accepts **OAuth 2.0 only**. Service accounts, Workload Identity Federation and
API keys are refused for the API itself, because developer-account data belongs to a Google Account,
not to a Cloud project. The one scope is
`https://www.googleapis.com/auth/androiddeveloperconsole`. Google recommends the web-server flow
with `access_type=offline`: a person consents once, the app stores the refresh token, and later
calls trade it for short-lived access tokens with no login.

**The Play service account does not work here [read].** The credential Task 7 stores for the Play
Developer API is a different thing. Do not try to reuse it.

How the refresh token was obtained **[called]**: authorization-code flow with
`redirect_uri=http://127.0.0.1:<port>` (allowed for Desktop clients without registering anything),
`access_type=offline`, `prompt=consent`. A small listener in Termux caught the code; the exchange at
`https://oauth2.googleapis.com/token` returned the refresh token and confirmed the granted scope.
Refreshing it (`grant_type=refresh_token`) returned an access token with the right scope
(`oauth2.googleapis.com/tokeninfo` shows it). Access tokens last about an hour.

**Refresh-token lifetime [unknown for this project].** Google's general rule is that a refresh token
for an OAuth consent screen left in "Testing" mode expires after 7 days. The consent screen's
publishing status was not checked. If registration ever starts failing with `invalid_grant` after a
week, that is the first thing to look at (set the screen to "In production" and consent again).

Operator-side lessons (not Zealot code): Termux has no `/tmp`; Opera Mini cannot reach
`127.0.0.1` while its data-saving modes are on (the listener works with savings off, and a paste of
the address-bar URL is the fallback); long multi-line pastes into Termux are fragile, so scripts are
written to a file first.

## 4. The API surface (read from Google's definition, base `https://androiddeveloperconsole.googleapis.com`, version `v1`)

**How the definition was fetched [called].** `GET /$discovery/rest?version=v1&key=<api key>` returned
200 and about 29 KB. The same address **without** a key, or with only the OAuth token, answers 403
"unregistered callers". `https://www.googleapis.com/discovery/v1/apis/androiddeveloperconsole/v1/rest`
answers 404. A session that needs to re-read the definition therefore needs `ADC_API_KEY`.

### Methods

| Method id (short) | HTTP | Path | Body -> response | Note |
|---|---|---|---|---|
| `developerAccounts.list` | GET | `v1/developerAccounts` | - -> `ListDeveloperAccountsResponse` | "Never throws." **[called]** |
| `developerAccounts.get` | GET | `v1/{name}` | - -> `DeveloperAccount` | 404 if missing, 403 if no access |
| `androidPackages.list` | GET | `v1/{parent}/androidPackages` | - -> `ListAndroidPackagesResponse` | `pageSize`, `pageToken` **[called]** |
| `androidPackages.create` | POST | `v1/{parent}/androidPackages?androidPackageId=<pkg>` | `AndroidPackage` -> `AndroidPackage` | package name goes in the **query** `androidPackageId` |
| `androidPackages.get` | GET | `v1/{name}` | - -> `AndroidPackage` | 404 if it does not exist |
| `androidPackages.getRegistrationPolicy` | GET | `v1/{name}` | - -> `AndroidPackageRegistrationPolicy` | `name` is `.../androidPackages/{pkg}/registrationPolicy` |
| `androidPackages.keys.list` | GET | `v1/{parent}/keys` | - -> `ListAndroidPackageKeysResponse` | `pageSize`, `pageToken` |
| `androidPackages.keys.create` | POST | `v1/{parent}/keys` | `AndroidPackageKey` -> `AndroidPackageKey` | `parent` is the package resource name |
| `androidPackages.keys.get` | GET | `v1/{name}` | - -> `AndroidPackageKey` | |
| `...keys.justifyAndroidPackageKeyRegistration` | POST | `v1/{name}:justifyAndroidPackageKeyRegistration` | `{justification}` -> `AndroidPackageKey` | needed when a known key is `REQUIRED` |
| `media.upload` (the ownership check) | POST | `v1/{name}:verify`; upload path `/upload/v1/{name}:verify` (simple and multipart), resumable `/resumable/upload/v1/{name}:verify` | `VerifyAndroidPackageKeyOwnershipRequest` (no fields) -> `AndroidPackageKey` | accepts any media type; the **signed APK is the upload** |

`{parent}` and `{name}` are full resource names: `developerAccounts/{account}`,
`developerAccounts/{account}/androidPackages/{package}`,
`developerAccounts/{account}/androidPackages/{package}/keys/{key}`.

### Messages (field names exactly as the definition lists them)

- `DeveloperAccount`: `name`, `displayName`, `verificationState`.
- `AndroidPackage`: `name`, `packageName` (output only), `state` (output only), `registeredAppStore`
  (boolean, output only: "whether this package is an active RAS". **Meaning not established.**)
- `AndroidPackageKey`: `name`, `certificateFingerprintSha256` (required, immutable; "raw hex string"),
  `state` (output only), `registrationJustificationRequired` (output only), `verificationToken`
  (output only; "proves key ownership").
- `AndroidPackageRegistrationPolicy`: `name`, `keySelectionStrategy` (output only), `knownKeys[]`.
- `KnownKey`: `certificateFingerprintSha256`, `justificationRequirement`.
- `List...Response`: `androidPackages` / `androidPackageKeys`, `nextPageToken`.

### Enumerations

- `verificationState`: `VERIFICATION_STATE_UNSPECIFIED`, `VERIFIED`, `NOT_VERIFIED`.
- package `state`: `STATE_UNSPECIFIED`, `DRAFT`, `IN_REVIEW`, `REGISTERED`, `PENDING_TRANSFER`.
- key `state`: `STATE_UNSPECIFIED`, `DRAFT`, `OWNERSHIP_VERIFIED`, `IN_REVIEW`, `REGISTERED`, `BLOCKED`,
  `PENDING_TRANSFER`. (Google's prose guide says `REGISTERED_ACTIVE` for a key; the definition says
  `REGISTERED`. **Trust the definition; match both defensively.**)
- `keySelectionStrategy`: `KEY_SELECTION_STRATEGY_UNSPECIFIED`, `SELECT_KEY_FROM_LIST`, `USE_ANY_KEY`.
- `justificationRequirement`: `JUSTIFICATION_REQUIREMENT_UNSPECIFIED`, `REQUIRED`, `NOT_REQUIRED`.

## 5. The registration flow (Google's guide, mapped onto the methods)

1. **Create the package**: `androidPackages.create` under the verified account.
2. **Read the policy**: `getRegistrationPolicy`.
   - `USE_ANY_KEY` (a package name never seen on Android): add the key with `keys.create` carrying the
     SHA-256 fingerprint. **No ownership proof is needed.**
   - `SELECT_KEY_FROM_LIST` (a package name already in use somewhere): the key must be one of
     `knownKeys`, and ownership must be **proved**.
3. **Prove ownership** (only for `SELECT_KEY_FROM_LIST`): `keys.create` returns a `verificationToken`.
   The token goes into a file named `adi-registration.properties` inside the app's `assets/`, the APK
   is signed with the private key being registered, and that APK is uploaded to `:verify`.
   Google's guide says a store that manages the developer's key "must" do this itself, automatically.
4. **Justify** (only if the chosen known key has `justificationRequirement` `REQUIRED`): free-text
   business reason through `justifyAndroidPackageKeyRegistration`; Google reviews it, up to 24 hours.
5. The package and key states move through `DRAFT` / `OWNERSHIP_VERIFIED` / `IN_REVIEW` to `REGISTERED`.
   Google's page says an email is sent on registration.

Who may register a package name that already exists (Google's rules, read): the key with more than 50 %
of known installs has priority; with no majority, every key with 50 or more installs may register
directly; with none above 50, first come first served; everyone else must justify. After one developer
registers, others have to ask permission.

## 6. The Status API (separate service)

`GET https://androiddeveloperidstatus.googleapis.com/v1/packages/{package}/packageRegistrationStatus:check`
with the header `X-Goog-Api-Key`. Returns `REGISTERED` or `NOT_REGISTERED` (any verified developer).
A variant takes a certificate fingerprint to check a package-and-key pair. **[read]** Not yet answered
with a good key: the one attempt this session used the damaged key and got `API_KEY_INVALID`. The
replacement key has not been tried against it. **[unknown until tried]**

## 7. What is proved, what is not

**Proved by a real call:** the refresh token works; the scope is right; the API is enabled; the
account is VERIFIED; the package list can be read; the definition can be fetched with the key.

**Never called, so every field-level detail below is read, not seen:** `androidPackages.create`,
`getRegistrationPolicy`, `keys.list`, `keys.create`, `:verify`, `justify...`, and the Status API.

**Known trouble reported by others [read, a public forum thread]:** with the same OAuth approach,
`androidPackages.list` returned 403 `PERMISSION_DENIED` and `androidPackages.create` returned 400
`INVALID_ARGUMENT` ("Request contains an invalid argument", no field detail) for an empty body, even
though the same identity could register by hand in the Play Console. Here the list worked (200), so the
403 is not universal; the 400 on create is **untested** and may recur. A first implementation must log
Google's full response body on every non-2xx and must be able to run without writing (read-only mode).

**Unknown, needing a decision or a test:**
1. Whether `create` needs anything in the body besides the query parameter.
2. What `registeredAppStore` means and whether it changes anything for a store like Zealot.
3. How to put `adi-registration.properties` into the right place. The token must be inside the APK's
   `assets/` and the APK signed with the org key. Zealot turns an AAB into an APK set with bundletool;
   whether the file can be added to an already-built release without changing what users install is not
   settled. This only matters for package names Google already knows (`SELECT_KEY_FROM_LIST`).
4. Whether the verified account may register packages that belong to other companies' apps
   (a policy and contract question, not a technical one).

## 8. Facts about this repo that the plan depends on (read from `develop` @ `d77650b9`)

- `AndroidSigningKey` is one org-wide row (`only_one_record`, `.current`). **Signing does not depend
  on the tenant.** The only place it signs is `AnthropicAssetDeliveryJob#process_release`, and only for
  `.aab` uploads; it then sets `releases.signed` and `releases.signing_key_checksum`.
- A directly uploaded `.apk` is not re-signed; it keeps whatever signature its uploader used. Registering
  such a package under the org key would claim a key the app is not signed with.
- `TenantSigningKey` (Task 37b-ii) has a database constraint allowing only the purpose `catalog_index`.
  Tenant keys sign the **index**, never an APK.
- `apps.tenant_id` is nullable (NULL = default catalog). `App.for_tenant` and the console policy scopes
  hide other tenants' apps. A background job that registers packages must **not** read through those
  scopes; it must see every tenant's apps.
- `apps.play_package_name` (unique where not null) and `releases.bundle_id` both hold a package name.
  Which one is reliable for a given app was not checked.
- Existing HTTP-client pattern: `HyperswitchClient` (plain Faraday, typed `TemporaryError` /
  `PermanentError`, tests stub `Faraday.new` with `Faraday::Adapter::Test::Stubs`). The new client
  should copy it; no new gem.
- `AndroidSigningKey#with_keystore_files` already yields decrypted keystore and password files for the
  block's duration only; a fingerprint or a proof-APK signature must go through it.

## 9. How Zealot uses it (Task 36b, written and NOT run)

| Piece | Where |
|---|---|
| Client (OAuth refresh, all methods in section 4, error mapping, paging) | `app/services/google_adc/client.rb` |
| Namespace, errors, the two switches, name formats | `app/services/google_adc.rb` |
| Read-only inventory and Status API client | `google_adc/inventory.rb`, `google_adc/status_client.rb`, `bin/rails google_adc:inventory` |
| Registration of one package name | `google_adc/registrar.rb`, `bin/rails "google_adc:register[com.example.app]"` |
| Automatic trigger after a release is signed | `app/jobs/google_adc_register_job.rb`, enqueued from `AnthropicAssetDeliveryJob` |
| Record per package | table `android_package_registrations`, model `AndroidPackageRegistration` |
| Organisation key fingerprint | `AndroidSigningKey#certificate_sha256` (`keytool -exportcert -rfc`, SHA-256 of the DER) |
| Status badge | `app/views/apps/_google_registration.html.slim` |

Switches (environment, read at call time): `ADC_AUTO_REGISTER=true` lets a newly signed release enqueue a
registration (unset = off); `ADC_DRY_RUN=true` makes the Registrar read, log what it would send, send nothing
and save nothing. Credentials: `CLIENT_ID`, `CLIENT_SECRET`, `ADC_REFRESH_TOKEN` (section 2). Optional:
`ADC_API_KEY` for the Status API.

What the Registrar does and does not do is in its file header and in handover.md, "Task 36b". In one line:
it registers a new package name with the organisation key by itself, and for a name Google already knows it
records `needs_review` and stops, because that case needs a proof of key ownership (section 5) that is not
automated (36b-8 and 36b-9 are not built).
