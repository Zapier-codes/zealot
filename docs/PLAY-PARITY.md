# Play Store / Play Console parity: Zealot (Console) half

*Written 2026-10-10 (operator-directed: "cross-check everything Play Store and Play Console have that Zealot and Appstore do not, hidden and public, consumer and enterprise"). Docs only; nothing here is built or run.*

This is the Console half of a three-repo cross-check. The client half is `docs/PLAY-PARITY.md` in Storeapp (section 4, Play Store against Appstore) and its web mirror is `docs/PLAY-PARITY.md` in D-Store (section 4). The older Task 28 "Console capability inventory" in `handover.md` is the shorter first pass; this file extends it with the embedded platform tools and the consumer / enterprise tags, and nothing here overrides a recorded decision.

## Operating principles for closing every gap *(operator directive, 2026-10-10)*

1. **Human steps are automated.** Anywhere Play puts a person in the loop (app review, policy decisions, content-rating questionnaires, appeals triage, support routing), this program builds an automated decision instead: a machine verdict with machine-readable reasons (pass, flag, reject), recorded on the release. A person is only the exception path (an appeal, or a verdict the automation marks as high risk), never a queue that publishing waits on. Existing rules stand: an update to an app that already has a previous version is never held (Zealot Task 48/49).
2. **Reviews are anonymous. No accounts, ever.** The intended design (not built; its own task, cut by the TSF before code): a device-bound pseudonymous key made on the phone (Android Keystore), one editable review per key per app, a proof-of-work challenge instead of a captcha service, rate limits per key and per network, automated moderation, and a visible "verified install" mark when the review came from the Appstore client with proof that the reviewed version was installed. The website accepts the same review with the proof-of-work token and no install mark. Developer replies are public. There is no sign-in, no email and no profile anywhere in this path.
3. **Everything else follows the industry-standard approach**, as the earlier decision records (D43-n, 47h and the rest) already do, and keeps this program's own intended approaches where a handover has recorded one (additive-only sources, signed catalog index, org signing key, CI signs everything, no telemetry by default).
4. **Reuse before writing.** Most missing areas already exist as open-source parts that can be assembled. The reuse map below lists them with a mark: **✓** = the project's own page was read in a search on 2026-10-10; **◇** = from the author's knowledge, not checked, so check licence and maintenance before adopting. Nothing in the map is adopted yet.
5. **Unofficial routes carry a stated risk.** A route that depends on a reverse-engineered or unpublished interface is listed with that risk, and is never the only path to a feature.


## Play Console against Zealot

Key: ✅ have · ◐ partial · ❌ missing · ➖ not applicable by design · ❓ not confirmed in any handover. **C** = consumer / indie publisher, **E** = enterprise / organization.

| Feature, including embedded platform tools | Tag | Play | Zealot |
|---|---|---|---|
| Developer accounts and publisher profiles | C | ✅ | ✅ |
| Collaborators, ownership transfer | E | ✅ | ✅ |
| Fine-grained per-app roles and permissions | E | ✅ | ◐ |
| Organization identity verification (legal entity) | E | ✅ | ❌ |
| Android developer verification registration (package names and signing keys) | C/E | ✅ | ❌ |
| Audit or activity log | E | ✅ | ❓ |
| SSO, SAML, SCIM | E | ✅ | ❓ |
| Multi-tenant white-label with per-tenant signing key | E | ➖ | ✅ (beyond Play) |
| Upload AAB or APK, release notes | C | ✅ | ✅ |
| Testing tracks (internal, closed, open) with tester lists | C/E | ✅ | ❌ (Task 30b) |
| Staged rollout by percentage, halt and resume | C/E | ✅ | ❌ |
| Managed publishing (hold, then release) | C | ✅ | ◐ |
| Supersede older releases automatically | C | ✅ | ✅ |
| Target countries for a release | E | ✅ | ❌ |
| Device targeting and exclusion (device catalog) | E | ✅ | ❌ |
| Pre-launch report (automated run on devices) | C/E | ✅ | ❌ |
| App bundle explorer (size per device) | E | ✅ | ❌ |
| Bundle compile, asset packs | C | ✅ | ✅ |
| Upload key vs distribution key, key rotation | C/E | ✅ | ✅ |
| Deobfuscation mapping and native symbol upload | C/E | ✅ | ❌ |
| Target API level enforcement and warnings | C/E | ✅ | ❓ |
| Listing text, graphics, localization | C | ✅ | ✅ |
| Transactional listing edits (draft, validate, commit) | C | ✅ | ✅ |
| Custom store listings (per country or campaign) | E | ✅ | ❌ |
| Machine translation of listings | C | ✅ | ❌ |
| Listing experiments (A/B) | C | ✅ | ➖ |
| Automated policy checks (permission diff, signing continuity, integrity) | C/E | ✅ | ◐ |
| Third-party SDK vetting (Google SDK Index equivalent) | E | ✅ | ◐ (fingerprint list, vendors still unverified) |
| Review queue, rejection and appeal flow | C/E | ✅ | ❌ (Task 30; to be automated, principle 1) |
| Policy status page and alerts | C/E | ✅ | ❌ |
| Content declarations: Data safety, content rating, audience, ads, news | C/E | ✅ | ◐ (forms are Task 34; to be automated, principle 1) |
| Privacy policy URL, account-deletion URL, reviewer access instructions | C/E | ✅ | ❌ |
| Takedown, DMCA, moderation | C/E | ✅ | ✅ |
| Reviews inbox, developer replies, reply templates | C | ✅ | ❌ (Tasks 31b, 33; anonymous, principle 2) |
| Reviews API | E | ✅ | ❌ |
| Install and download analytics | C | ✅ | ◐ |
| Acquisition, retention and conversion funnels | E | ✅ | ❌ |
| Report export, BigQuery-style export | E | ✅ | ❌ |
| Android vitals (crashes, ANRs, battery) | C/E | ✅ | ➖ (no telemetry by default; an opt-in route is in the reuse map) |
| Publisher pays for a paid store listing (Hyperswitch) | C/E | ➖ | ✅ (beyond Play) |
| Revenue and financial reports, payouts | E | ✅ | ❌ (candidate Task 50) |
| Per-country pricing | E | ✅ | ❌ |
| Subscriptions, in-app products, promo codes, voided purchases | C | ✅ | ➖ |
| Publishing API (edits), API tokens, GraphQL, per-app tokens | C/E | ✅ | ✅ |
| Real-time developer notifications (Pub/Sub) | E | ✅ | ◐ (webhooks, no event-stream feed) |
| Linked cloud project and service accounts | E | ✅ | ◐ |
| CI and Gradle or Fastlane integration | C/E | ✅ | ◐ (workflow templates) |
| Deep link verification (assetlinks) checker | C/E | ✅ | ❌ |
| Notifications and email preferences | C | ✅ | ✅ |
| Console mobile app | C | ✅ | ❌ |


**Facts behind the newest row.** Google's Android developer verification started user-facing protections on 2026-09-30 in Brazil, Indonesia, Singapore and Thailand and is planned to go global in 2027 (reported by Android Authority, 2026-06-18, and by 9to5Google). It ties an installed app to a registered developer, including apps installed outside Play. It does not apply any content review. Zealot re-signs bundles with the org key in CI, so the org key and the package names it signs are what need registering.

## Reuse map: Console side (assemble, do not write from scratch)

**✓** = the project's own page was read in a search on 2026-10-10. **◇** = from the author's knowledge, not checked: check licence and maintenance first. Nothing here is adopted yet; each adoption is its own task, cut by the TSF before code.

| Gap | Route | Mark | Note |
|---|---|---|---|
| Staged rollout, tracks | Deterministic bucket: hash a stable id into 1 to 100; the same id stays in as the percentage rises (Unleash's documented "stickiness"). Implement in Zealot (about 20 lines), or run Unleash or GrowthBook | ✓ docs.getunleash.io/concepts/stickiness; GrowthBook ◇ | The stable id is the device key the client already holds (no account). Halting a rollout is the existing hold and supersede machinery |
| Automated review (replaces the human queue) | **MobSF** (static and dynamic analysis, tracker list from Exodus, APKiD, hardcoded secrets); **exodus-standalone** (Docker image, JSON report, exit code can be the tracker count, so it can gate CI) | ✓ github.com/Exodus-Privacy/exodus-standalone; MobSF ✓ | Verdict and reasons are stored on the release; a person only sees appeals and high-risk flags. Also: Androguard, APKiD, Quark-Engine, Pithus, YARA, ClamAV, VirusTotal API (check its terms) ◇ |
| Third-party SDK vetting | Exodus tracker signatures through MobSF or exodus-standalone, beside the existing fingerprint list (Task 40n) | ✓ | Replaces "vendors still unverified" with a maintained signature set |
| Pre-launch report | Emulator in CI plus `adb shell monkey` and Maestro | ◇ | Install, launch, no crash in N events; written to the release. Firebase Test Lab is the official option but needs a Google account |
| Content declarations (rating, audience, ads) | Derive honestly from the manifest and the scan (permissions, ad and tracker SDKs found), as Storeapp already derives badges; IARC is the industry system but a store has to be a participant | ◇ (IARC participation not checked) | Automated, with the publisher able to correct and the correction logged |
| Delta updates | **archive-patcher** (Google, open source): file-by-file patches; Google reports updates about 65% smaller on average. The result must match the new APK byte for byte, so the patch is made at publish time on the signed file | ✓ android-developers.googleblog.com/2016/12/saving-data-reducing-the-size-of-app-updates-by-65-percent.html | Zealot generates; the client applies |
| Developer verification (Google, enforced from 2026-09-30 in Brazil, Indonesia, Singapore, Thailand; global 2027) | Register Appstore's package name and key; record per publisher and per org key whether their packages are registered; the Android Developer Console is the official route | ✓ Accrescent registered itself and still accepts unregistered submissions: blog.accrescent.app/posts/android-developer-verification/ | Zealot's CI re-signs with the org key, so the org key is what must be registered for those packages (the key-identity mismatch F-Droid describes). A limited-distribution account for up to 20 devices exists for hobbyists, not for tenants |
| F-Droid-compatible repo (instant reach into F-Droid, Droid-ify, Neo Store, Obtainium style clients) | **fdroidserver**: index-v2, `entry.jar`, signer index, binary transparency log of the index | ✓ f-droid.org/docs/All_our_APIs/ | Publish beside the signed Zealot index; the Zealot index stays the trust anchor |
| Anonymous review spam control | **ALTCHA** (MIT, proof of work, self-hosted, no tracking); **Cap** (Apache-2.0); mCAPTCHA (AGPL-3.0); Anubis | ✓ altcha.org/open-source-captcha/; capjs.js.org/guide/best-captcha-alternatives.html | Principle 2. Also Android Key Attestation for the device key and Privacy Pass (IETF) for rate-limited anonymous tokens ◇ |
| Review moderation | Detoxify, StopForumSpam, Akismet | ◇ | Automated first pass; reports and takedown stay as today |
| Crash and vitals, opt-in only | **ACRA** library with **Acrarium** server, or a Sentry-compatible endpoint (GlitchTip) | ✓ github.com/ACRA; Sentry or GlitchTip DSN ✓ | Off by default (no telemetry by design); the person turns it on. R8 retrace for mapping files ◇ |
| Funnels, exports | Umami, Plausible or Matomo for site and listing views; Metabase or Apache Superset over Zealot's Postgres for reports and CSV or warehouse export | ◇ | No new data collection on phones |
| Revenue reports and payouts (Task 50) | **Hyperswitch payouts**: `/payouts/create`, bulk and scheduled payouts, smart retries, payout analytics and a manual update API. B-Pay-backend is the program's Hyperswitch fork, so the connectors it already wraps are the route | ✓ docs.hyperswitch.io/other-features/connectors/payouts | Task 50 is reporting views plus payout calls over what is stored. Lago for invoices and usage billing ◇ |
| SSO, SCIM, audit log | `omniauth-saml`, Keycloak or Authentik, the `scimitar` gem, the `audited` or `paper_trail` gems | ◇ | Enterprise tier |
| Event-stream feed | Svix or the Standard Webhooks signing spec on top of the existing webhooks | ◇ | |
| Country availability | Country header from the CDN, or MaxMind GeoLite2 / DB-IP lite | ◇ | Availability only; per-country pricing is not planned |
| Device targeting | Read minSdk, ABIs and required features from the manifest with `apkanalyzer` or `aapt2` and publish them in the index; the client filters on the phone | ◇ | The same fields feed Appstore's "works on your device" |
| Machine translation of listings | Weblate (Zealot already has a Crowdin file), LibreTranslate, Argos Translate | ◇ | |
| Deep link checker | Google's Digital Asset Links API | ◇ | |
| Console mobile app | Installable web app, or a Trusted Web Activity built with Bubblewrap | ◇ | |
| Enterprise device management | **Headwind MDM** (open source; deploys apps and remotely configures third-party apps); the standard **Android RestrictionsManager** managed-configuration API; Android Management API (Google) | ✓ h-mdm.com; RestrictionsManager ✓; Android Management API ◇ | Since 2026 Google limits provisioning with custom builds of Headwind's launcher; a custom build must change its package name and be signed with its own key |

**Unofficial routes that exist, and why they are not the plan.** Aurora Store (GPL-3.0) and gplaydl log in to Google Play anonymously through a token dispenser and download from it. Their own pages say the interface is reverse engineered, may break when Google changes it, and the dispenser is not reliable. That is outside Google's terms and GPL-3.0 code cannot simply be folded into a differently licensed app. It is recorded here so nobody re-discovers it as a shortcut; the sanctioned third-party source stays Aptoide through its MCP.

## Suggested order *(not a decision; the operator picks)*

1. Developer verification readiness (register Appstore and the org key; record each publisher's registration status; show it in Appstore and D-Store).
2. Tracks and staged rollout (Task 30b) on the deterministic-bucket rule above, then automated review and policy status (MobSF and exodus-standalone behind the existing 30c/30d checks).
3. Content declarations and device-targeting fields (Task 34), the privacy and deletion URLs, then the Appstore age and device filters that wait on them.
4. Anonymous reviews (principle 2) as one task cut by the TSF, then the reviews inbox and developer replies (Tasks 31b, 33).
5. Enterprise tier: audit log, roles, report export, SSO and SCIM; Headwind MDM and managed configuration as a separate project.
6. Task 50 (revenue reporting and payouts) over Hyperswitch payouts, if the operator confirms.
