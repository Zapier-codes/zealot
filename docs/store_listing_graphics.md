# Store-listing graphics: the standard Zealot follows (Task 27d-d/e)

Zealot is the Play Console for our own store; D-store is the Play Store app.
This file records what Google Play's console accepts for a listing's graphics,
what Zealot copies from it, and where Zealot deliberately differs. **Docs only:
nothing here is built yet.** The build is the slice table in `handover.md`
(27d-d1 to 27d-e2).

## Sources and how they were cross-checked

- **Primary:** Google, "Add preview assets to showcase your app" (Play Console
  Help, `support.google.com/googleplay/android-developer/answer/9866151`),
  fetched and read in full on 2026-09-28. Every number below marked *(Play)* is
  from that page.
- **Cross-check:** third-party ASO guides (SplitMetrics, AppScreens, AppLaunchFlow,
  AppRadar) agree with the primary source on the feature graphic (1024 x 500,
  JPEG or 24-bit PNG, no alpha) and on the video rules. One guide claims a
  feature graphic is only *displayed* when a promo video exists; the primary
  page says it is *required to publish* and is used as the video's cover, so the
  primary page wins.
- **Not checked:** Apple App Store Connect, Huawei and Samsung asset limits were
  not re-read for this file. The 27 card's earlier notes on them stand as written.
- Google revises these rules; re-read the page above before building 27d-d1.

## What Play's console accepts *(Play)*

| Asset | Required to publish | Format | Size | Count |
|---|---|---|---|---|
| App icon | yes | 32-bit PNG (alpha allowed) | 512 x 512, max 1024 KB | 1 |
| Feature graphic | yes | JPEG or 24-bit PNG, **no alpha** | 1024 x 500 | 1 |
| Screenshots | yes, at least 2 across device types | JPEG or 24-bit PNG, **no alpha** | each side 320 to 3840 px; the long side at most 2x the short side | up to 8 per device type |
| Preview video | no | a **YouTube URL**, not an upload | n/a | 1 |
| Short description | yes | text | 80 characters | 1 |

Rules that sit behind the table *(Play)*:

- **No GIFs and no uploaded video.** Image slots take JPEG or 24-bit PNG only;
  the video slot takes a YouTube link only. Play hosts no video files and
  accepts no animated images. (The absence of GIF is read from the format list,
  not from a sentence saying "GIF is refused".)
- **Video link:** a plain video URL (no playlist, channel or timecode
  parameters). The video must be public or unlisted (not private), not
  age-restricted, embeddable, and with ads turned off.
- **Video advice (not enforced):** show the real app within the first 10
  seconds, aim for at least 80% real product footage, keep it short because only
  the first 30 seconds autoplay (muted), use captions, no fingers on the device.
- **Recommendations for store promotion eligibility:** at least 4 screenshots
  at 1080 px or more, 16:9 landscape (1920 x 1080 minimum) or 9:16 portrait
  (1080 x 1920 minimum); real in-app UI first; a tagline, if any, covers at most
  20% of the image; no ranking, award, price or call-to-action wording ("Best",
  "#1", "Free", "Download now"); no device frames; no other store's badge; a
  clean status bar (full battery, wifi and signal, no notifications).
- **Feature graphic layout:** focal point in the centre, key elements away from
  the edge cut-off zones, leave room for the play button when a video exists,
  no fine detail, avoid pure white, black or dark grey.
- **Alt text:** every graphic should carry alt text of 140 characters or fewer,
  without "image of" or "photo of".
- **Other device types** (tablets, Chromebook, Wear OS, Android TV, Automotive,
  XR) have their own screenshot rules and their own counts. Zealot starts with
  phones only.
- **Ownership:** all of these belong to the **app's store listing**, not to a
  release. Editing them does not need a new APK.

## What Zealot copies, and where it differs

| Topic | Decision | Why |
|---|---|---|
| Owner of the assets | The **app**, not the release | Play attaches them to the store listing. (The icon is the one exception today, see below.) |
| Formats | Screenshots and the feature graphic: **JPEG or PNG without alpha**. **GIF, WebP, APNG and animated anything are refused**, with a message that names the allowed types | Matches Play; keeps the index and D-store's rendering simple; an animated file is a video in disguise |
| Screenshots | **Phone only for now, 2 to 8 per app**; each side 320 to 3840 px, long side at most 2x the short side; **8 MB cap per file** | Counts and pixels are Play's. The 8 MB cap is **our choice** (Play states no cap for phone screenshots on the page read; 8 MB is the figure Play gives for XR screenshots) |
| "Store-ready" | Not a publish gate. An app can go live with fewer than 2 screenshots; the console shows a checklist with the Play recommendations (4 or more at 1080 px or more, 16:9 or 9:16) | Play blocks publishing on 2; our listing states already gate on payment and review, and a hard block here would strand apps |
| Feature graphic | Optional at first, exactly 1024 x 500, no alpha | Play requires it; D-store has no surface that uses it yet, so requiring it now would block owners for nothing |
| Video | **One YouTube video ID per app; no upload, no hosting, no hashing.** The console accepts a pasted URL and stores only the 11-character ID (rejects playlists, channels, and other hosts) | Same as Play. Zealot cannot verify public/unlisted/embeddable/ads-off, so it says so in the UI and does not claim to |
| Demo motion | Owners who want motion use the video slot | The way Play handles it; a GIF slot would be an invention |
| Integrity | Every image is stored through `ReleaseStorage`, hashed with SHA-256, and referenced in the signed index with its hash (F-Droid's rule, already used for icons in 27d-a to 27d-c) | The video is the one asset outside this: an external link, listed without a hash |
| Alt text | Stored per image, max 140 characters, emitted in the index | Play recommends it |
| Order | `position` per app; the first image is shown first | Play shows screenshots in order |
| Copy rules | The console **warns** (does not block) on Play's forbidden wording in short text | Recommendations, not requirements, in Play |

### The icon is different today

Play's icon is a listing asset (512 x 512, 32-bit PNG) separate from the
launcher icon inside the APK. Zealot's icon is per release, taken from the
uploaded build (`Release#icon`, `AppIconUploader`), and 27d-a to 27d-c already
mirror, hash and publish it. That stays as it is. A real per-app listing icon
(512 x 512, max 1024 KB) is a later card, **27d-f**, so that owners can update
the store icon without a new release. It is not part of 27d-d/e.

## The index fields

`listing.screenshots[]` already exists in `catalog_index_v2.schema.json` as
`{url, sha256}` with `additionalProperties: false`. The proposal, which needs
D-store's reader to tolerate new keys before it is built:

```json
"listing": {
  "screenshots": [ { "url": "...", "sha256": "...", "alt": "...", "width": 1080, "height": 1920 } ],
  "feature_graphic": { "url": "...", "sha256": "...", "alt": "..." },
  "video": { "youtube_id": "dQw4w9WgXcQ" }
}
```

`alt`, `width` and `height` are additive and optional for readers;
`feature_graphic` and `video` are new keys defaulting to `null`. This changes
the JSON Schema (the `additionalProperties: false` on the screenshot item and
the `listing` object), so it is a **v2 additive change that D-store must accept
before Zealot publishes it**: the schema version is not bumped, but the
cross-repo check the earlier 27 cards used (D-store's `5.g.i.zo` sign-off) applies.

## Not covered

Localised graphics, custom store listings per audience, other device types,
Play's promotional "Play Shorts", and the asset-review workflow are Play
features with no Zealot card. They are left out on purpose, not forgotten.
