# Unofficial routes, reverse-engineered projects and workarounds for the Play parity gaps

*Revised 2026-10-10 (operator decision: "we will use them as dependencies since they have not broken yet till date"): the reverse-engineered Play clients in section 1 are now **dependencies behind a boundary**, not references; see 1.1.*

*Written 2026-10-10 (operator-directed: "all the repos, unofficial routes, reverse engineering repos and unorthodox ways we can use ... most of the missing areas do not need code written from scratch"). Docs only; nothing here is adopted, built or run. Companion to `docs/PLAY-PARITY.md` (the gaps) and its reuse map (the sanctioned parts).*

**Marks.** **✓** = the project's own page or a result about it was read in a search on 2026-10-10. **◇** = from the author's knowledge, not checked: confirm licence, maintenance and current behaviour before adopting. **Risk** = what breaks or what rule is crossed. **Safe to adopt?** = Yes, Yes with care, Only as a reference, or No.

**Payments service.** Everything about money in this file means **`Zapier-codes/B-Pay-backend`**, the program's own service, read from its source. It is not upstream Hyperswitch (see section 8 for what the fork does and does not carry).

**Scope of "anonymous reviews".** The anonymous, account-free reviews in the operating principles are reviews **inside Appstore, D-Store and Zealot**. No route in this file posts reviews to Google Play or Apple, and none is proposed (see section 10).

## 1. Reverse-engineered Google Play clients (read side)

| Project | What it is | Mark | Risk | Safe to adopt? |
|---|---|---|---|---|
| **Aurora OSS `GPlayApi`** (GitLab `AuroraOSS/gplayapi`; Maven Central `com.aurora:gplayapi`) | Kotlin wrapper over Play's protobuf interface: search, details, similar apps, download. Describes itself as "an unofficial FOSS implementation". GPL-3.0-or-later | ✓ | Interface is reverse engineered and changes without notice; needs an AAS token (a real or dispenser-issued login); GPL cannot be folded into differently licensed code; outside Google's terms | **Dependency, behind the boundary in 1.1** (own service process in Zealot; may link into Storeapp, see licences) |
| **`marzzzello/playstoreapi`** (PyPI `playstoreapi`) and **`AbhiTheModder/playstoreapi`** | Python fork of `googleplay-api` with anonymous login through a token dispenser, search, `streamDetails` for related apps, paging | ✓ | Dispenser availability is not guaranteed; the one on the PyPI page is a third party's host; same terms problem. Licence not checked ◇ | **Dependency, behind the boundary in 1.1** (second implementation, so one can stand in for the other) |
| `egirault/googleplay-api`, `alessandrodd/googleplay_api`, `Akdeniz/google-play-crawler` | The original PoCs the forks descend from. The first is archived "not maintained" | ✓ | Old protocol, will not work as is | No |
| `inmanjeffrey89-cell/play-reviews-cli` | Reads a public app's reviews from the store's internal reviews endpoint, no key | ✓ | Very small project, unknown author, undocumented endpoint, scraping terms | No (read the technique only) |
| `oxylabs/google-play-scraper` and the Apify "Google Play reviews" actors | Commercial scraping wrappers | ✓ | Paid third party sees every query | No |

**What these are for:** Play's public rating, "similar apps" and listing data beside a listing, and, where the operator wants it, a download for an app a tenant already publishes. Zealot and Appstore keep deriving their own rating line and similar-apps rail from their own catalogue; Play's data is shown as a separate, labelled source and never replaces it.

### 1.1 Operator decision and how to hold it *(decision on record, overrule any)*

**Decision:** use the Aurora `GPlayApi` and the `playstoreapi` forks as dependencies, because they have not broken to date. **Said plainly, not to argue it:** "has not broken yet" is true until Google changes the interface, which it does without notice; the projects' own pages say so. So the dependency is held in a way that a break is a degraded panel, not an outage:

1. **One adapter, one interface.** A single `PlayCatalogSource` (details, search, similar, optional download) in its own service process. Nothing else in Zealot, Appstore or D-Store imports either library. Two implementations behind it (Aurora's Kotlin library and the Python `playstoreapi`), so a break in one fails over to the other.
2. **Pinned versions, vendored copies.** Pin an exact version of each (Maven Central `com.aurora:gplayapi`, PyPI `playstoreapi`) and keep a copy in our own registry or repo, so a yanked release or a deleted project cannot stop a build.
3. **A daily canary.** One fixed read (a stable public app) run each day with the result stored. When it fails, the adapter marks the source `degraded` and the UI hides the Play panel. That turns "has not broken yet" into a measured fact and tells us the day it does.
4. **Self-host the token dispenser** if the login path needs one (Aurora's dispenser is open source ◇), instead of depending on a third party's host such as the one named in the `playstoreapi` PyPI page. Keep the dispenser, and any Google login it uses, in a separate credential set with no access to publishing keys.
5. **Cache hard.** Store every read with a timestamp, refresh slowly and with a delay between requests (the forks support one), so the load is small and a break shows stale data, not an error.
6. **Never the only path** (principle 5). Every feature that uses it has a catalogue-only fallback, and the Play panel is optional per deployment (a switch, off by default for tenants).
7. **Licences (not legal advice).** Aurora `GPlayApi` is GPL-3.0-or-later ✓. **Zealot and D-Store are MIT:** run it as a separate program and talk to it over HTTP, do not link it into the Rails process. **Storeapp is AGPL-3.0:** GPL-3.0-or-later code can be combined with AGPL-3.0 code, so it may be linked into the client, but on a phone the client would then reach Play directly from each device's IP with its own login, which is a different risk from one server. The default is server-side only. The `playstoreapi` licence was not checked ◇.
8. **Terms.** These clients are outside Google's terms of service. The consequence to expect is the account or token being blocked or the interface changing, not a code defect. Use read-only calls, a modest rate, and never the publishing keys or any tenant account.

## 2. Play Console without the browser (official API, plug-and-play CLIs)

These are not reverse engineered: they wrap Google's own Publisher API with a service account. They matter because they are finished, scriptable references for **an "Import from Play" bridge** (a publisher gives Zealot a service account; Zealot pulls listing text, tracks, reviews, vitals and reports).

| Project | Coverage | Mark | Risk | Safe to adopt? |
|---|---|---|---|---|
| **`tamtom/play-console-cli`** (`gplay`, Go) | Claims 98% of the Play Developer API v3 (134 of 137 endpoints) plus Reporting (vitals), Checks, Managed Google Play and Cloud Storage reports; review read and reply; subscriptions and in-app products; release gates for CI | ✓ | Third-party author; claim of coverage is the project's own | Yes with care (study or shell out to it) |
| **`AndroidPoet/playconsole-cli`** (`gpc`, Go, MIT) | Upload, tracks, promote with rollout percent, review list and reply, device stats, internal app sharing | ✓ | Small (166 stars at the time of the page) | Yes with care |
| **fastlane `supply`** | Upload, listing and metadata sync | ◇ | No reviews or vitals | Yes |

**Fit with the gaps:** reviews inbox and replies (Tasks 31b, 33) for publishers who also ship on Play; vitals and report export (enterprise); staged-rollout semantics to copy (see `PLAY-PARITY.md`, deterministic bucket).

## 3. Automated review: the human queue replaced (principle 1)

| Project | What it gives the verdict | Mark | Risk | Safe to adopt? |
|---|---|---|---|---|
| **MobSF** (`MobSF/Mobile-Security-Framework-MobSF`) | Static and dynamic analysis of APK and AAB; manifest, code and certificate checks; **APKiD**; behaviour analysis using ported Quark rules (v4.3.0); hardcoded secrets; domain malware check; malware lookups by hash against VirusTotal, Triage, Hybrid Analysis and MetaDefender; REST API for CI | ✓ | Heavy (Docker plus decompilers); dynamic analysis needs an emulator; false positives need a rule for "flag, not reject" | Yes |
| **exodus-standalone** (Exodus Privacy) | Tracker signatures, JSON report, usable as a CI gate | ✓ (earlier session) | Signature list needs refreshing | Yes |
| **Quark-Engine**, **Pithus**, **Androguard**, **APKiD** | Malware scoring, open-source APK analyzer, parsing library, packer and obfuscator identification | ✓ (named in a security tool list and in MobSF's own notes) | Pithus is also run as a hosted service ◇: self-host it or use it only on non-confidential builds | Yes (Androguard, APKiD, Quark are libraries) |
| **Koodous**, **ANY.RUN**, **AMAaaS** | Hosted analysis against shared YARA rules or sandboxes | ✓ | The file is uploaded to a third party | No for tenants' unreleased builds |
| YARA, ClamAV | Pattern and signature scans | ◇ | | Yes |

**Reading of the principle:** verdict (pass, flag, reject) plus machine-readable reasons stored on the release; a person only sees appeals and high-risk flags. Nothing here needs new analysis code, only a runner and a verdict mapping.

## 4. Pre-launch report and device targeting

| Project | Role | Mark | Risk | Safe to adopt? |
|---|---|---|---|---|
| **redroid** (Android in Docker; images for Android 11 through 16) | Headless Android in CI: install the build, launch, drive it with `adb` | ✓ | Needs a privileged container and kernel support for Android's binder; no Google Play services; graphics-heavy apps may not run | Yes |
| **Zebrunner Device Farm** (redroid agents) | A ready-made farm that uses redroid as its device pool | ✓ | Product with a hosted tier; the open parts are what matter | Yes with care |
| `mcp-android-emulator` | An MCP server over `adb` for an emulator, redroid or a device | ✓ | Third-party MCP | Only as a reference |
| Maestro, Appium, `adb shell monkey`, scrcpy, DeviceFarmer (OpenSTF) | Scripted taps, random events, screen mirror, a self-hosted real-device lab | ◇ | | Yes |
| `apkanalyzer`, `aapt2` | Read minSdk, ABIs and required features for the "works on your device" filter | ◇ | | Yes |

**Cost note:** a pre-launch run is a CI minute budget decision for the operator, not a code gap.

## 5. Other stores and repositories to join, mirror or interoperate with

| Project | Role for Zealot and Appstore | Mark | Risk | Safe to adopt? |
|---|---|---|---|---|
| **fdroidserver** | Publish an F-Droid-format repo (index-v2, signed `entry.jar`) beside the signed Zealot index; instant reach into every F-Droid-style client | ✓ (earlier session) | Two indexes to keep consistent; Zealot's stays the trust anchor | Yes |
| **IzzyOnDroid** | An F-Droid-style repository run by its own maintainer; a place a publisher can also be listed | ✓ | A third party's policy, not ours | Yes |
| **Droid-ify**, **Neo Store** | Clients that read F-Droid-style repos: they would read the fdroidserver repo above | ✓ | | Yes |
| **Obtainium** | Installs and updates from a project's release page; could track Zealot release pages with no extra work | ✓ | Client-side only | Yes |
| **Accrescent** | A security-focused store; registered itself under Google's developer verification and still takes unregistered submissions | ✓ | Different packaging and review rules | Only as a reference |
| **GitHub Store / Komi Store** (`OpenHub-Store`) | Discovers and installs from GitHub Releases; supports silent installs through Shizuku, Sui, Dhizuku and root; checks the signing fingerprint before an update | ✓ | Kotlin Multiplatform app, its own conventions | Only as a reference |
| Aptoide (the existing MCP) | The sanctioned third-party catalogue | recorded | | Yes |

## 6. Unorthodox install and update paths (what Play does that a normal sideloaded store cannot)

| Route | What it does | Mark | Risk | Safe to adopt? |
|---|---|---|---|---|
| **Shizuku** and **Sui** | A privileged helper started once over wireless debugging (or by root) that lets a store install and update silently, with no per-app prompt | ✓ | The person must set it up; it stops at reboot unless started again; not for people who will not use ADB | Yes as an opt-in |
| **Dhizuku** (Device Owner delegate) | Silent install on devices whose maker adds extra install prompts, with neither root nor ADB | ✓ | Device Owner can only be set on a fresh or reset device; on Android 14 and later it can fall back to the system prompt when the installer of record differs (projects fix this by retrying without attribution) | Yes as an opt-in |
| **Root backends** (Magisk, KernelSU, APatch) | Silent install on rooted phones | ✓ | Small audience | Yes as an opt-in |
| **Update ownership** (`setRequestUpdateOwnership`, Android 14) | The store becomes the owner so its updates need no confirmation | recorded (Task 47i) | First install only | Already done (47i) |
| **Android Management API / Headwind MDM** | Managed distribution and managed configuration for fleets | ✓ (Headwind, earlier session) | Enterprise project of its own | Yes (enterprise tier) |
| **Installer-source spoofing** (a store or installer records itself as "Play Store") | Makes apps that check where they came from run | ✓ (it exists in two installers) | **Deceives the app and conflicts with Task 47i's update ownership; it is also what a policy reviewer would call evasion** | **No** |

## 7. Anonymous reviews: parts to assemble (principle 2)

| Part | Project | Mark | Note | Safe to adopt? |
|---|---|---|---|---|
| Hardware-backed device key, verified on the server | **`android/keyattestation`** (Kotlin; also in AOSP) and **`google/android-key-attestation`** (Java server sample) | ✓ | Validate the certificate chain on the server, not on the device (rooted devices can lie); the revoked-serial list is published by Google. Check the chain, keep only the public key and a pass or fail, drop the rest | Yes |
| Proof of work in place of a captcha | **ALTCHA** (MIT), **Cap** (Apache-2.0), **mCAPTCHA** (AGPL-3.0), Anubis | ✓ (earlier session) | Self-hosted, no tracking | Yes |
| Rate-limited anonymous tokens | **Privacy Pass** (IETF) | ◇ | One token per person per period without learning who | Yes with care |
| Moderation first pass | Detoxify, StopForumSpam, Akismet | ◇ | Automated first pass; reports and takedown stay as today | Yes |
| "Verified install" mark | Appstore client signs a challenge with the device key and the server checks it against the install record it already holds | recorded design | The mark proves the install, not who the person is | Yes |

## 8. B-Pay-backend (the program's payments service): what it has, and what it does not

Read from `Zapier-codes/B-Pay-backend` on 2026-10-10.

- **Payouts are built into the image.** `payouts` and `payout_retry` are in the crate's feature set, and the Dockerfile builds with `v1`, which pulls in `common_default`.
- **Routes:** `POST /payouts/create`, `GET` and `PUT /payouts/{id}`, `POST /payouts/{id}/confirm`, `/cancel`, `/fulfill`, list and filter endpoints, `GET /payouts/aggregate`, `PUT /payouts/{id}/manual-update`.
- **Connectors with payout code** (files that handle a payout flow; confirm each before relying on it): Adyen, Adyen Platform, Stripe (Connect), PayPal, Wise, Paystack, Flutterwave, Korapay, Nuvei, Payone, Worldpay, Cybersource, Ebanx, Envoy, Gigadat, Gotyme Sanlam, Juicyway, Loonio, Nomupay, TrueLayer, Trustly.
- **Not found:** a bulk-payout endpoint, scheduled payouts, a payout analytics module. Upstream Hyperswitch's own docs list some of these; this fork does not carry them, so the earlier line in `PLAY-PARITY.md` that cited them was wrong and has been corrected. Bulk and schedule would be Zealot's own loop over `create` and `fulfill`, or a port from upstream (B-Pay-backend's own handover already tracks an upstream-port backlog).
- **Also present:** `/subscriptions` (create, estimate, items, list, confirm) for a publisher's recurring plan. This is not in-app billing for end users, and `PLAY-PARITY.md` still marks that as not applicable by design.
- **Revenue reports (Task 50):** SQL views over Zealot's own records plus the routes above. Lago for invoices ◇.

## 9. Assembly order if the operator wants the least new code

1. fdroidserver repo beside the Zealot index (reach into the F-Droid ecosystem, nothing to write but a job).
2. MobSF plus exodus-standalone behind the existing release checks: the automated verdict (replaces the review queue).
3. redroid in CI for the pre-launch report; `apkanalyzer` fields for device targeting.
4. Shizuku, Sui and Dhizuku as opt-in silent-update backends in Appstore, next to 47i.
5. Key attestation plus ALTCHA plus Privacy Pass for anonymous reviews (the one piece that still needs a design task).
6. The Play panel through the `PlayCatalogSource` adapter in 1.1 (dependency by the operator's decision), and `gplay` or `gpc` as the reference for an "Import from Play" bridge.
7. Task 50 over B-Pay-backend's payout routes.

## 10. Said plainly: what this file does not recommend

- **Posting reviews, ratings or installs to Google Play or Apple.** No route here does it and none should: it would be fake engagement on someone else's store, it is outside their terms and it is the thing their automated systems exist to remove. "Anonymous reviews" means anonymous inside our own stores.
- **Using the section 1 clients without the 1.1 boundary** (one adapter, pinned and vendored versions, daily canary, self-hosted dispenser, cache, fallback). The clients are a dependency by the operator's decision; the boundary is what keeps a break from becoming an outage. Also: a Google account or token that is shared with publishing or tenant credentials.
- **Spoofing the installer source** (section 6).
- **Copying GPL code** into a differently licensed component (Aurora is GPL-3.0-or-later ✓; check the licences of Droid-ify and Neo Store ◇). Study it, or link to it as a separate program.
- **Anything marked ◇ used without checking** its licence and last release first.
