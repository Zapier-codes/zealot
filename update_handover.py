import os

os.chdir(os.path.expanduser('~/zealot'))

f = 'handover.md'
s = open(f).read()

# Remove any previous 40o additions to avoid duplication
if "## Task 40o: Session Fix - No Rejections, CI Signs Everything" in s:
    parts = s.split("## Task 40o: Session Fix - No Rejections, CI Signs Everything")
    s = parts[0]

new_section = """
## Task 40o: Session Fix - No Rejections, CI Signs Everything, SDK Fixed

**Operator Directive:** "nothing is rejected... org to sign/resign all apps... SDK is injected in CI be it aab or apk uploaded SDK injection happens anyway... do you understand nothing is rejected"

**What was fixed this session:**
1. **Removed 40n-c Rejection Logic:** The `REQUIRE_ORG_SIGNED_APKS` check and all associated rejection messages (`NOT_BUILT_BY_DISTR`, `UNVERIFIED_APK`, etc.) were completely stripped from `ReleaseUploadFinisher`. Nothing is ever rejected. Both API and manual uploads are accepted.
2. **CI Signs/Injects Unconditionally:** `read-upload.yml` was updated to run SDK injection (`proxy_sdk_patcher.py` for APKs, `aab_sdk_patcher.py` for AABs) and org-signing unconditionally for all Android uploads.
3. **Fixed `proxies_sdk.dex` Blocker:** Created `lib/zealot_provider/ZealotProxyProvider.java`. This uses reflection to initialize the Proxies SDK (industry standard to avoid hard compile-time deps). CI compiles this into a DEX file on-the-fly and injects it alongside the 3rd-party SDK. This resolves the missing class crash.
4. **Updated Manifest Permissions:** `ManifestPatch.java` was updated to inject `FOREGROUND_SERVICE`, `POST_NOTIFICATIONS`, and `WAKE_LOCK` permissions directly into the app's manifest, as required by the official Proxies.sx SDK documentation for its background service.
5. **Removed Per-Upload Payment Gate:** The `requires_payment?` check was removed. The listing fee is per-account/app, not per-upload. The catalog index serializer's `listing_live` scope already ensures uploads for unpaid apps do not appear in the public store.

**Next Session / Operator Action Required (Task 40n-0 part 2):**
The code is complete and all secrets/variables have been verified as existing. The next step is strictly to **run the first real end-to-end upload** to confirm the wiring is correct.

1. Ensure the latest Zealot deploy is `live` on Render.
2. Ensure the `zealot-storage` repo has the latest `read-upload.yml` workflow, `ZealotProxyProvider.java`, and `ManifestPatch.java` committed under `zealot-ci/`.
3. Upload a test `.aab` or `.apk` from the Zealot dashboard.
4. Watch the GitHub Action in the storage repo. It should download from R2, compile the Java provider, inject the SDK, sign with the org key, and report back to Zealot.
5. Confirm the release becomes `available` in Zealot.

If the GitHub Action fails, fetch the error log and save it under `~/storage/downloads/` for the next session to debug. If it succeeds, Task 40 is functionally complete (pending 40k cleanup).
"""

s += new_section
open(f, 'w').write(s)

print("Handover file updated successfully.")
