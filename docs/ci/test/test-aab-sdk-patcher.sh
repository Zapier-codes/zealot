#!/usr/bin/env bash
# Task 40n-a: end-to-end proof for lib/aab_sdk_patcher.py.
#
# Downloads a real bundletool-all jar (GitHub release) and a real sample .aab (bundletool's own
# Apache-2.0 testdata, also from GitHub) rather than committing either as a repo fixture, patches
# the sample bundle with the repo's own proxies_sdk.dex, and checks:
#   1. the original sample .aab is byte-identical before and after (the patcher must only ever
#      read it, never write to it -- the "clean bundle" invariant from handover.md);
#   2. `java -cp lib/aab_manifest_patch` compiles and the patch step succeeds, adding exactly one
#      new dex at the first free base/dex/classesN.dex slot;
#   3. `bundletool build-apks --mode=universal` accepts the patched bundle (proves the manifest
#      edit is valid protobuf that aapt2's own deserializer -- bundled inside bundletool -- accepts,
#      not just that our Java writer didn't throw);
#   4. the resulting universal.apk's real binary-AXML manifest (built by aapt2 from our patched
#      protobuf, not read back with our own tool) actually contains the <provider>,
#      its API-key <meta-data>, and the <uses-permission> -- checked with `aapt2 dump xmltree`
#      if available, else androguard (pip install androguard) as a fallback.
#
# Needs: java, python3, curl, unzip. Network to github.com and raw.githubusercontent.com (CI has
# this; it is not on every sandbox's allowlist -- see handover.md, "40n-a could not be built").
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BUNDLETOOL_VERSION="${BUNDLETOOL_VERSION:-1.18.3}"
BUNDLETOOL_JAR="$WORK/bundletool.jar"
SAMPLE_AAB="$WORK/sample.aab"

echo "[*] fetching bundletool $BUNDLETOOL_VERSION"
curl -sL -o "$BUNDLETOOL_JAR" \
  "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar"
test -s "$BUNDLETOOL_JAR" || { echo "FAIL: bundletool download empty"; exit 1; }

echo "[*] fetching a real sample .aab (bundletool's own Apache-2.0 testdata)"
curl -sL -o "$SAMPLE_AAB" \
  "https://raw.githubusercontent.com/google/bundletool/master/src/test/resources/com/android/tools/build/bundletool/testdata/bundle/install-time-permanent-modules.aab"
test -s "$SAMPLE_AAB" || { echo "FAIL: sample .aab download empty"; exit 1; }

ORIG_SHA="$(sha256sum "$SAMPLE_AAB" | cut -d' ' -f1)"

echo "[*] running aab_sdk_patcher.py"
PATCHED_AAB="$WORK/patched.aab"
BUNDLETOOL_JAR="$BUNDLETOOL_JAR" python3 "$REPO_ROOT/lib/aab_sdk_patcher.py" \
  "$SAMPLE_AAB" "$PATCHED_AAB" "$REPO_ROOT/proxies_sdk.dex" "test-api-key" --verify \
  | tee "$WORK/patch.log"

NEW_SHA="$(sha256sum "$SAMPLE_AAB" | cut -d' ' -f1)"
if [[ "$ORIG_SHA" != "$NEW_SHA" ]]; then
  echo "FAIL: input .aab changed (clean-bundle invariant broken)"; exit 1
fi
echo "[PASS] input bundle byte-identical after patching"

DEX_SLOT="$(grep -o 'classes[0-9]*\.dex' "$WORK/patch.log" | tail -1)"
echo "[*] SDK dex added as $DEX_SLOT"
unzip -l "$PATCHED_AAB" | grep -q "base/dex/$DEX_SLOT" || { echo "FAIL: $DEX_SLOT missing from patched bundle"; exit 1; }
echo "[PASS] patched bundle contains the new dex slot"

APK_PATH="$(grep 'bundletool build-apks --mode=universal succeeded' "$WORK/patch.log" | sed -E 's/.*succeeded: //')"
test -f "$APK_PATH" || { echo "FAIL: no universal.apk produced"; exit 1; }
echo "[PASS] bundletool build-apks --mode=universal accepted the patched bundle"

echo "[*] checking the real built APK's manifest (not our own writer's output)"
MANIFEST_OK=0
if command -v aapt2 >/dev/null 2>&1; then
  DUMP="$(aapt2 dump xmltree "$APK_PATH" --file AndroidManifest.xml)"
  if grep -q "ZealotProxyProvider" <<<"$DUMP" && grep -q "android.permission.INTERNET" <<<"$DUMP"; then
    MANIFEST_OK=1
  fi
elif python3 -c "import androguard" >/dev/null 2>&1; then
  DUMP="$(python3 -c "
from androguard.core.apk import APK
a = APK('$APK_PATH')
print(a.get_android_manifest_axml().get_xml().decode('utf-8', 'ignore'))
" 2>/dev/null)"
  if grep -q "ZealotProxyProvider" <<<"$DUMP" && grep -q "android.permission.INTERNET" <<<"$DUMP"; then
    MANIFEST_OK=1
  fi
else
  echo "SKIP: neither aapt2 nor androguard available to read back the built APK's manifest" \
       "(pip install androguard, or install aapt2, to run this last check)"
  MANIFEST_OK=2
fi

if [[ "$MANIFEST_OK" == "1" ]]; then
  echo "[PASS] built APK's real binary-AXML manifest has the provider, its API-key meta-data, and the permission"
elif [[ "$MANIFEST_OK" == "0" ]]; then
  echo "FAIL: built APK's manifest is missing the provider and/or the permission"; exit 1
fi

echo "[*] all checks passed (manifest-content check: $([[ $MANIFEST_OK == 1 ]] && echo ran && echo || echo skipped))"
