# Catalog update check, v1 (Task 47d)

`GET /catalog/updates/<package_name>` on Zealot's host. The check the injected `ZealotUpdater` library
(Task 47a) makes for its own package. Public, no login, no cookie, no device id.

## Answer (200, `application/json`)

```json
{
  "package_name": "com.example.app",
  "release_id": 7,
  "version_code": "12",
  "version_name": "1.2.0",
  "download_url": "https://<zealot host>/download/releases/7",
  "sha256": "<64 hex characters of the universal APK>",
  "size_bytes": 31238330,
  "signing_fingerprint": "AB:CD:...",
  "min_sdk": "26",
  "changelog": "- Faster start",
  "released_at": "2026-10-09T01:00:00Z"
}
```

`changelog` is `null` when there is none. `min_supported_version_code` (Task 47 design point 2) is **not**
sent yet: nothing stores it. It will be added with the publisher switch, never invented.

## 404 (empty body)

Unknown package, app not live in the default tenant's catalog, app archived, or no installable release.
A library treats every 404 as "no update".

## Which release is offered

Same set the signed index lists (`App#catalog_releases`: production channels, never held), narrowed to a release
that is `available` and has a recorded compiled universal APK (`Release#serves_universal_apk?`). The newest is
the highest `build_version` compared as a version ("100" beats "99"), not the latest upload. A halted or pulled
release is never offered.

## What the library must still do

Compare `version_code` with its own installed one; require HTTPS, the byte count `size_bytes`, the SHA-256
`sha256`, and a signing certificate equal to its own before it installs anything (Task 47 point 3). The request
carries only the package name; the query string is not read, so one cached answer serves every caller
(`Cache-Control: public, max-age=300`, `ETag`).

Default tenant only, like `/catalog/index.json`. Code: `CatalogController#latest`, `CatalogUpdateLookup`.
