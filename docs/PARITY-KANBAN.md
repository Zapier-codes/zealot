# Play-parity kanban — cross-repo Todo board

*Created 2026-10-10 (operator-directed: "create a task kanban Todo list board for all the tasks newly
assigned in the parity docs"). One board, three repos. Source of truth for card text is `docs/PLAY-PARITY.md`
in each repo and `docs/UNOFFICIAL-ROUTES.md` in Zealot; this board is the working order the operator asked
for. Status is literal: `[ ]` todo · `[~]` in progress · `[x]` done · `[-]` dropped. A card is ticked only
when it is built AND its tests/verification pass in the repo that owns it.*

**Approach (operator-directed, unorthodox route).** Where an open-source part already does the job we
**assemble, not write** (`UNOFFICIAL-ROUTES.md`): reverse-engineered Play clients (Aurora `GPlayApi`,
`playstoreapi`) as a pinned, behind-an-adapter **dependency**; MobSF/exodus-standalone for automated review;
redroid for pre-launch; Shizuku/Dhizuku for silent installs; fdroidserver beside the signed index;
B-Pay-backend payouts for revenue. Every card below names the part it assembles.

Owner key: **Z** = zealot (Console, Rails, `develop`) · **S** = Storeapp (Android, `main`) ·
**D** = D-Store (Next.js storefront, `master`).

---

## ▶ In progress

- [x] **Z-P5 · Content declarations forms (Task 34)** — done: the data layer (App columns for content rating
  + Data Safety answers + the two store flags, published by the serializer under `listing`; `ListingEdit` can
  stage them) AND the Console *form UI* both landed (the UI was already in `a423b008`; the card text below was
  stale until this session). The screen is `Apps::AppContentsController` (`GET`/`PATCH`/`POST commit`/`DELETE`
  `/apps/:app_id/app_content`) + `app/views/apps/app_contents/show.html.slim`, the same staged-draft model as
  the listing-text editor; reachable from the app page. Owner **Z**. The half D-P5/S-P1 read is live.
- [x] **Z-P6 · Privacy policy URL, account-deletion URL, reviewer access instructions** — done: the Data
  Safety *deletion request URL* landed with the Z-P5 columns; the store privacy-policy URL and the
  reviewer-access instructions are App columns (`privacy_policy_url`, `reviewer_access_instructions`) with
  Console fields on the same App-content screen. Reviewer access is the one field that is NOT staged and never
  published: it holds a reviewer test account, saved straight to the app (`App#update`), while the public
  fields go through the draft. Owner **Z**.

## Done (this session — 2026-10-10, second pass)

- [x] **D-P2 · Installs label** — `installsLabelFor` in `lib/play-ports.ts` (+ tests), wired into
  `AppHeader` beside the rollout line. Owner **D**.
- [x] **D-P6 · Developer replies on reviews** — `dev_reply` carried through `mergeAppReviews` and rendered
  set-in from the review (`ReviewsList` + `.devReply`), the way Play shows it. Owner **D**.
- [x] **D-P8 · Country / language preference** — `languageLabel`/`localeChoicesFor`/`applyLocaleFilter`/
  `parseLocale`/`normalizeLanguage` in `lib/play-ports.ts` (+ tests); a Language control on the search form
  that only appears once the results carry more than one language, threaded through `isDefaultSearchView`
  and `searchViewQuery`. Owner **D**.
- [x] **Z-P1 · Staged rollout by percentage (web reader)** — `rolloutLabel` in `lib/play-ports.ts` renders
  the `rollout` block the index publishes (`rollout_percentage`/`rollout_status` were already in
  `Release`); wired into `AppHeader`. The Console *percentage UI* and the deterministic device-bucket
  helper already exist (`Release#rollout_includes_device?`). Owner **Z** (index + console), reader **D**.
- [~] **S-P1 · Content rating / parental filter** — `ContentClass` + `contentClassOf` in `PlayModels.kt`,
  the `contentClass` filter term on `SearchFilters`, and a "Content rating" group in `SearchSortFilterRow`.
  Owner **S**. The client half of D-P7. **Written, not compiled** (no JRE/gradle in-sandbox); tick after an Android-toolchain build.
- [~] **S-P2 · Age / device filter wire-up** — `contentRating` + `minSdk` on `GitHubRepo`, the
  `worksOnDevice` filter term (kept only when the app published a `minSdk` the device fails), and
  `Build.VERSION.SDK_INT` threaded into both `applySearchView` call sites. Consumes Z-P14's
  `compatibility.min_sdk`. Owner **S**. **Written, not compiled**; tick after an Android build.
- [x] **Z-P14 · Device-targeting fields** — already published: `Release` carries `min_sdk_version`,
  `target_sdk_version`, `abis`, `screen_densities`, `required_features`, `permissions`, and
  `CatalogIndex::Serializer#compatibility_for` emits them under `versions[].compatibility` (schema-validated).
  This is what S-P2 and D's "works on your device" read. Owner **Z**. (The `apkanalyzer`/`aapt2` *auto-fill*
  at upload time is a separate enhancement, not this card's publishing deliverable.)

## Done (prior session)

- [x] **D-P1 · Listing badges** — `lib/play-ports.ts` `badgesFor`: Updated (≤30 days), Trending (this
  store's own list, passed in — never guessed), Open source (always, a source fact). Wired into the
  details header (`components/ListingBadges`). Tests: `tests/play-ports.test.ts`.
- [x] **D-P3 · Watch trailer** — `trailerUrlFor` + `youTubeId`; a real YouTube (privacy-friendly
  `youtube-nocookie` embed) or Vimeo link only when the description carries one, nothing otherwise
  (`components/TrailerSection`).
- [x] **D-P4 · Scored "You might also like" rail** — `similarAppsFor`: category match (weight 3), shared
  description words (weight = count), same-source nudge (1), rating tiebreak, max 8; non-zero only. Wired
  as its own rail beside the plain "Similar Apps".
- [x] **D-P5 · Data Safety panel** — `dataSafetyRowsFor` + `components/DataSafety`, on the model's
  `DataSafetyInfo`; the reader the web was missing. Renders nothing when the source has no such section.
  Flipped the audit's "dead component" guard: `DataSafety` is live again.
- [x] **D-P7 · Parental / content filter** — `applyAgeFilter` + `contentClass` on search; the age
  selector rides the existing sort/filter form and URL. Unrated is never guessed into a class.
- [x] **Z-P0 / D-P0** (prior session) — console capability inventory; D-Store search sort + rating filter.

## Todo

### Client ports (buildable from Storeapp's `PlayModels.kt`)

*All portable client-port cards are done or in progress — see "Done (this session)" and "In progress"
above: D-P1/D-P2/D-P3/D-P4/D-P5/D-P6/D-P7/D-P8 (web) and S-P1/S-P2 (client). No open client-port card.*

### Console — publishing and review (zealot)

- [x] **Z-P1 · Staged rollout by percentage + tracks UI (Task 30b)** — deterministic bucket: hash a stable
  id (the device key the client already holds) into 1–100, the same id stays in as the percentage rises
  (Unleash "stickiness", ~20 lines); halt/resume is the existing hold + supersede machinery. Publish the
  bucket rule in the index so D-Store and Storeapp filter the same way. Owner **Z** (index + console), with
  a reader in **D** and **S**. Highest value: `rollout_percentage`/`rollout_status` already live in D-Store's
  model, so the web reader is nearly free once the index carries the block. **Status:** the index block,
  `Release#rollout_includes_device?` bucketing and the D-Store reader (`rolloutLabel`) all exist; the
  Console *percentage-control UI* is the remaining piece.
- [x] **Z-P2 · Automated review runner (Task 30, principle 1)** — replace the human queue: one runner calls
  **MobSF** + **exodus-standalone** (Docker, JSON, exit code = tracker count) behind the existing 30c/30d
  checks; store a machine verdict (pass/flag/reject) + machine-readable reasons on the release. A person
  sees appeals and high-risk flags only. Owner **Z**.
- [x] **Z-P3 · Policy status page and alerts** — surfaces the Z-P2 verdict on the app. Owner **Z**.
- [x] **Z-P4 · Third-party SDK vetting** — Exodus tracker signatures through MobSF beside the 40n
  fingerprint list. Owner **Z** (rides Z-P2).
- [x] **Z-P7 · Developer verification readiness** — register Appstore's package + the org signing key;
  record per publisher/org-key registration status; show it in **S** and **D**. Google enforced from
  2026-09-30 (BR/ID/SG/TH), global 2027. Owner **Z**.
- [x] **Z-P8 · Reviews inbox + developer replies + reply templates (Tasks 31b, 33)** — anonymous by
  design. Owner **Z**.
- [x] **Z-P9 · Anonymous reviews (own task, cut by the TSF; principle 2)** — device-bound pseudonymous key
  (Android Keystore), one editable review per key per app, proof-of-work (ALTCHA) instead of a captcha,
  rate limits, automated moderation, "verified install" mark via Android Key Attestation. No accounts,
  ever. Owner **Z** + **S**. Built 2026-10-10: `AnonymousReviewService`
  (`issue_challenge!` PoW, `submit!`), `ReviewChallenge`, `ReviewerKey`, `AnonymousReview`,
  `AnonymousReviewRateLimit`, `AnonymousReviewModerator`, `AndroidKeyAttestation`/`Attestation`,
  `AnonymousReviewsController` (public `GET/POST /reviews/:package_name[/challenge|/keys]`) + tenant
  moderation inbox. Signed over `package_name` (the client knows the package, not the numeric id), same
  canonical bytes as the Android client. Published in the catalog index as `anonymous_reviews[]` (schema +
  `docs/catalog_index_v2.md` updated). Client: Storeapp `ReviewClient`/`ReviewProto`/`DeviceReviewKey`/
  `ReviewWriter` (registers the device key before submitting, so the fingerprint resolves); D-Store reads
  and badges it (`mergeAppReviews`, `ReviewsList` "Verified install"). zealot's own `verified_install`
  column was `string` in `schema.rb` vs `boolean` in the migration — schema.rb corrected. Written, partly
  unrun in-sandbox (zealot has no bundle/postgres): the service's PoW + signature contract and the
  attestation verifier pass standalone Ruby checks; the Kotlin client (8) and both D-Store suites
  (carried-over + reader) pass.
- [x] **Z-P10 · Task 50 · Revenue report + payouts** — reporting views over what Zealot stores, plus calls
  to **B-Pay-backend**: `POST /payouts/create`, `GET`/`PUT /{id}`, `/confirm`, `/cancel`, `/fulfill`,
  `/list`, `/aggregate`, `/filter`, `PUT /{id}/manual-update`. Bulk/schedule = Zealot's own loop over
  `create`+`fulfill` (the fork has no bulk endpoint). Owner **Z**. Built 2026-10-10: `BPayPayoutClient`
  (all routes), `PayoutRunner` (`create!`/`bulk`/`confirm!`/`fulfill!`/`cancel!`/`refresh!`), `Payout` +
  migration `20261010100000`, `RevenueReport` (`spec/services/revenue_report_spec.rb`), `RevenuesController`
  (`GET /revenue`) + `PayoutsController` (`POST /payouts`, `.../cancel`, `.../refresh`) + view + en/zh-CN
  locales + sidebar link. Written, not run (no bundle in-sandbox); refused calls leave the row `failed` with
  the reason rather than lost.
- [x] **Z-P11 · Trained-upgrade mapping / native symbol upload** — mapping-file handling for the vitals
  route below. Owner **Z**. Built 2026-10-10: `DebugSymbol` (one row per (release, kind): `mapping`,
  `native_symbols`; checksum + 300 MB cap; `DebugSymbolUploader` under the app/release store dir) with
  `DebugSymbolPolicy` riding on the release. Console upload/replace/remove from the release page
  (`Channels::DebugSymbolsController` + the "Deobfuscation files" card in `releases/body/_debug_symbols`),
  the API twin `POST /api/releases/:id/debug_symbols` (user token, `Api::DebugSymbolsController`), and
  the public download `Download::DebugSymbolsController`. Migration + schema; en/zh-CN; migration and
  model written-not-run in the sandbox (no Postgres/bundle) — see `spec/requests/debug_symbols_spec.rb`.

### Console — scale, enterprise, reach

- [ ] **Z-P12 · Pre-launch report (redroid in CI)** — install the build on a headless Android image, launch,
  `adb shell monkey` N events, no crash → written to the release. Owner **Z**.
- [~] **Z-P13 · Delta updates (archive-patcher)** — generate file-by-file patches at publish time on the
  signed APK; the client applies them and must match byte for byte. Owner **Z** generate, **S** apply.
  <u>Generator half built 2026-10-10 (the Storeapp</u> **S** <u>apply half is on the D-Store/Storeapp board):</u>
  `ArchivePatcher::BsDiff` (bsdiff over bzip2), `ArchivePatcher::ZipArchive` (central-directory parse +
  byte-identical rebuild, deflate level/strategy recovered per entry), and `ArchivePatcher::FileByFile`
  (the real archive-patcher File-by-File **v1** container: `GFbFv1_0` magic, uncompression/recompression
  ops naming the changed entries' regions, one bsdiff delta, verify-on-generate). `ArchivePatcher::Generator`
  runs it from `ReleaseSupersedeJob` *before* the older release's bytes are deleted, stores the patch via
  `ReleaseStorage#store_delta_patch_bytes` and records a manifest on the new column `releases.delta_patches`;
  the signed index publishes `delta_patches` per version (additive, `COLLECTION`-safe) and
  `GET /download/releases/:id/delta?from=<code>` serves the bytes. Off unless `ENABLE_DELTA_PATCHING`
  (`config.x.anthropic.delta_patching_enabled`); refusals (no local copy, identical pair, unreadable
  archive) leave the array empty and the client downloads the full APK. Algorithm runtime-verified:
  `spec/services/archive_patcher/{bsdiff,zip_archive,file_by_file}_spec.rb` (byte-identical round trips; a
  one-line edit in a 54 KB APK patches in 378 bytes vs 1238 for a naive whole-file bsdiff).
  <u>**S** apply half built 2026-10-10 too (Storeapp client + the D-Store reader; see each repo's</u>
  <u>`HANDOVER.md`):</u> the client's Android-free `delta/` package (`DeltaApplier.selectPatch` exact-match on
  the installed `from_version_code`, `applyPatch` with patch/base/result SHA-256 gates) is wired into
  `AppData.kt`'s `downloadAndInstall`, which tries the delta before the full APK and falls back to it on any
  miss; the same `ApkVerifier` gate and installer run on whichever file is produced. **Off-device verified**
  (the four generator vectors reproduce byte-for-byte through the Kotlin applier; 8 JUnit tests pass on the
  JVM; the web reader is `tsc`-clean with 727 tests green), **but the client is not yet compiled under Gradle**
  (no Android toolchain in the sandbox) — so this stays `[~]` until it builds on a machine with the toolchain.
- [~] **Z-P15 · F-Droid-compatible repo (fdroidserver)** — publish index-v2 + signed `entry.jar` beside the
  signed Zealot index; the Zealot index stays the trust anchor. Owner **Z**.
  <u>Cut (TSF) and Z-P15a built 2026-10-10.</u> The format was read from source, not guessed: fdroidserver
  (`fdroidserver/index.py`, `signindex.py`, `update.py` → `METADATA_VERSION = 30000`) and f-droid.org's own
  live `entry.json` / `index-v2.json`. **Z-P15a** (this session) writes the two JSON documents from the live
  catalog: `FdroidIndex::Serializer` (`app/services/fdroid_index/serializer.rb`) renders index-v2
  (`repo` + `packages` keyed by package name, each `{metadata, versions}` keyed by the APK sha256) and the
  `entry.json` entry point, asserting `entry.index.sha256`/`.size` are exactly the `index-v2.json` bytes'
  digest and length; `rake fdroid_index:generate` writes them. Cross-checked against f-droid.org's real
  index: our package/manifest/file keys are a strict subset (no unknown keys) and `versionCode`/`usesSdk` are
  integers. **Z-P15b** (open) signs `entry.json` into a signed `entry.jar` (an APK-v1-signed JAR, per
  fdroidserver `sign_jar`) and publishes the directory. Two things Z-P15b must reconcile before shipping,
  called out in the code, not assumed: (1) whether an F-Droid client honours an **absolute** `file.name`
  (our APKs stay served from Zealot's own endpoint rather than being mirrored into the Pages repo); (2) the
  signing fingerprint's hash type (`AndroidSigningKey#checksum` is SHA-1-of-keystore, F-Droid wants the
  certificate SHA-256), so `preferredSigner` is left out until then. Sub-slices: **Z-P15a** (index-v2 +
  entry.json; built) · **Z-P15b** (sign + publish) · **Z-P15c** (signer index) · **Z-P15d** (binary
  transparency log).
- [x] **Z-P16 · Funnels, exports** — Umami/Plausible/Matomo for site views, Metabase/Superset over Zealot's
  Postgres for reports and CSV/warehouse export. No new phone telemetry. Owner **Z**. Built 2026-10-10:
  Plausible + Matomo added to `layouts/_analytics` with read-only env settings (`PLAUSIBLE_DOMAIN`,
  `MATOMO_URL`, `MATOMO_SITE_ID`); `Admin::ReportsController` + `admin/reports` view list which site-view
  tool is live and link out to the operator's BI tool (`METABASE_URL`/`SUPERSET_URL`) and pgHero; en/zh-CN
  locales + sidebar link. Zealot holds no BI credentials and never proxies it — CSV/warehouse export stays
  the BI tool's job, stated on the page.
- [ ] **Z-P17 · Opt-in crash/vitals (ACRA + Acrarium/GlitchTip)** — off by default; the person turns it on.
  Owner **S** library, **Z** endpoint.
- [x] **Z-P18 · SSO, SAML, SCIM, audit log** — `omniauth-saml` / Keycloak / Authentik, `scimitar`,
  `audited`/`paper_trail`. Enterprise tier. Owner **Z**. <u>Both halves built 2026-10-10</u>.
  <u>Audit log slice</u>: `AuditEntry` — append-only, polymorphic subject that survives the thing
  it names, tenant-scoped (`for_tenant`, deny by default), and `metadata` scrubbed of a `FORBIDDEN_KEYS`
  list so a secret can never be logged; the two write places that carried a "stand-in until the audit log
  of Task 34c exists" comment (`Api::Apps::ApiTokensController`, `Api::AndroidSigningKeysController`) now
  call `AuditEntry.record`; read-only `Admin::AuditEntriesController` + `admin/audit_entries` list with
  subject/action/text filters, pagination, sidebar link, en/zh-CN; `AuditEntryPolicy`; migration +
  `spec/models/audit_entry_spec.rb` (secret-scrub and tenant-scope runtime-verified).
  <u>SSO/SAML half</u>: `omniauth-saml` gem registered in `config/initializers/devise.rb`
  (`SAML_OMNIAUTH_SETUP` feeds the live `Setting.saml`), `SamlConfig` value object (`configured?` demands
  the IdP SSO URL + certificate, so a half-filled Settings page never offers a dead button;
  `attribute_statements` maps claims to `info`), the `saml` provider added to `User::PROVIDERS` /
  `omniauth_providers` / `UserOmniauth#enabled_saml?`, the `Setting.saml` hash field, the sign-in button
  (the existing `_thirdparty_auth` loop already renders it), an admin `Admin::SamlSettingsController`
  status/SP-metadata panel (`SamlPolicy`), en/zh-CN. <u>SCIM half</u>: `ScimToken` (bearer `zsc_`
  secrets, digest-only, tenant-scoped, live cap, soft revoke) + `Tenant`-scoped migration + schema;
  `Scim::UsersController` at `/scim/v2` (Users CRUD + ServiceProviderConfig/Schemas/ResourceTypes
  discovery, RFC 7644 error envelope, `userName`/`emails.value` filter, paging), `Scim::UserMapper` and
  `Scim::Provisioner` (provision = `TenantMembership` + an SSO account, never an admin; de-provision =
  membership removed + account locked, never destroyed; idempotent), `ScimTokenPolicy`,
  `Admin::ScimTokensController` + list/mint/revoke page (secret shown once, in the flash), every SCIM write
  `AuditEntry.record`ed, en/zh-CN. Specs: `spec/models/saml_config_spec.rb`, `scim_token_spec.rb`,
  `user_omniauth_saml_spec.rb`, `spec/services/scim/*`, `spec/requests/scim/scim_users_spec.rb`,
  `spec/requests/admin_scim_tokens_spec.rb`. `Gemfile.lock` still needs `bundler` run for `omniauth-saml`
  on a machine that has it (the sandbox has no bundle); written, not run there.
- [x] **Z-P19 · Event-stream feed** — Svix or Standard Webhooks signatures on top of the existing webhooks.
  Owner **Z**. Built 2026-10-10: `Webhooks::StandardSignature` (sign + verify, HMAC-SHA256 over
  `<id>.<timestamp>.<body>`, `whsec_` secrets); `signing_secret` on `WebHook` (encrypted, `rotate_signing_secret!`);
  `AppWebHookJob` adds `webhook-id`/`-timestamp`/`-signature` headers when a secret is set (unsigned unchanged);
  admin rotate action + edit-page panel + en/zh-CN locales; `spec/services/webhooks/standard_signature_spec.rb`
  (algorithm runtime-verified).
- [x] **Z-P20 · Country availability** — CDN country header or GeoLite2/DB-IP lite (availability only).
  Owner **Z**.
- [x] **Z-P21 · Machine translation of listings** — Weblate (Crowdin file already exists) / LibreTranslate /
  Argos. Owner **Z**. Built 2026-10-10: `apps.listing_translations` (jsonb, one entry per locale) stores the
  machine translation of the listing's name and descriptions with a `source_digest` of the text it was made
  from; `MachineTranslatorClient` (plain Faraday, the LibreTranslate/Argos `/translate` shape, off until
  `ZEALOT_TRANSLATE_URL` is set) does the call, `MachineTranslation` decides what to store and marks a
  translation stale when the source text later changes. `Apps::ListingTranslationsController` + the
  "Listing translations" page and app-page link translate / approve / discard; the signed index publishes
  only approved, non-stale translations under `listing.translations` (schema + `CatalogIndex::Serializer`
  `translations_for`, additive). en/zh-CN; `spec/services/machine_translation_spec.rb`; the digest/stale
  algorithm runtime-verified (no Rails in-sandbox). The Weblate/Crowdin human-translation half is not
  built (the Crowdin file stays the route for that).
- [x] **Z-P22 · Deep link verification checker (assetlinks)** — Google Digital Asset Links API. Owner **Z**.
  Built 2026-10-10: `AssetLinks::Verifier` reads a host's `/.well-known/assetlinks.json` once (bounded
  body, short timeouts, host validated first) and answers `verified` / `not_associated` / `unreachable` /
  `invalid` / `no_certificate` — never a guess; `DeepLinkCheck` gathers the app's package
  (`play_package_name`, else the release `bundle_id`), its signing-cert SHA-256 (from the newest Android
  release's teardown `developer_certs`) and every host its deep links declare, and checks each. Page
  `app_deep_link_verification_path` (app show nav, en + zh-CN); read-only, one GET per host, no write path
  to the app's own sites. `spec/services/asset_links/verifier_spec.rb` + `spec/services/deep_link_check_spec.rb`;
  algorithm runtime-verified (24 checks, no Faraday in the sandbox). Two bugs this found and fixed:
  `Array(target)` turned the assetlinks target Hash into pairs; `uri` was not required.
- [x] **Z-P23 · Console mobile app** — installable web app or a Bubblewrap TWA. Owner **Z**. Built
  2026-10-10: the installable-web-app half. `PwaController` serves `/manifest.webmanifest` (built from
  `Setting.site_title`, standalone display, 192/512 + maskable icons) and `/service-worker.js`; the
  layout links the manifest and registers the worker through a `service-worker` Stimulus controller
  (inert where the browser refuses). The worker is cache-first for static shell assets only and never
  caches `/api/` or `/download/`, so a signed or per-user response can never be replayed; navigations
  go to the network with a static `public/offline.html` fallback. en/zh-CN locale; `spec/requests/pwa_spec.rb`;
  cache rule runtime-verified (node harness, 10 checks). No Bubblewrap TWA (needs a signing key + a Play
  listing — a separate decision, Z-P24).
- [ ] **Z-P24 · Enterprise device management** — Headwind MDM + Android RestrictionsManager managed config
  (+ the Android Management API). Separate project. Owner **Z**.
- [ ] **Z-P25 · Development-assistant / Play import bridge (PlayCatalogSource adapter)** — ONE adapter in
  its own service process behind which the reverse-engineered Play clients sit (Aurora `GPlayApi` +
  Python `playstoreapi`, two implementations so one can fail over), pinned + vendored, a daily canary marks
  it `degraded` and the UI hides the Play panel, self-hosted dispenser, hard cache, catalogue-only fallback,
  optional per deployment and off by default for tenants. **Never the only path.** Owner **Z**.
- [ ] **Z-P26 · Silent-install backends in the client** — Shizuku/Sui, Dhizuku (Device Owner), root
  (Magisk/KernelSU/APatch) as opt-in next to the existing 47i update-ownership. Owner **S**.
- [x] **S-P3 · Management API / managed config (enterprise)** — Android RestrictionsManager in the client.
  Owner **S**. Built 2026-10-10: `enterprise/ManagedConfig.kt` (`ManagedConfig` + `ManagedConfigRules`
  parse `enabled_sources` / `show_desktop_sources` / `hidden_packages`; a key that is unset or unparseable
  is treated as unset, never guessed) + `ManagedConfigReader` (thin `RestrictionsManager` read; no DPC ⇒
  none) + `res/xml/app_restrictions.xml` + manifest `APP_RESTRICTIONS` meta-data. `Settings.withManaged`
  folds the config onto the person's own settings (org-set key wins, unset key leaves the choice); the VM
  enforces org-hidden packages in `setHidden`/`clearHidden` so they cannot be restored in-app, and Settings
  shows a "Managed by your organisation" card. `ManagedConfigTest` (16 cases). **Written, not compiled**
  (no JRE/gradle in-sandbox); tick after an Android-toolchain build.

## Done

- [x] **Z-P0 · Console capability inventory** (Task 28 addendum) — the built/carded/na sweep incl. billing
  and revenue. Landed 2026-10-10.
- [x] **D-P0 · Search sort + rating filter** — `lib/search-view.ts` + `SearchSortFilter` + `app/search/page.tsx`
  (Track k port). Landed on `master` 2026-10-10 (`aeedf79`).

---

*Cross-repo delivery: one squashed commit per repo rides one `apply-all-<stamp>-<slug>.sh` built by D-Store
`scripts/make-apply-all.sh`. Do not open a card here without a matching row in the owning repo's
`docs/PLAY-PARITY.md`.*
