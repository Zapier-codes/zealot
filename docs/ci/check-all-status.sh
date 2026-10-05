#!/usr/bin/env bash
# Read-only status report across Render, zealot/develop, and the zealot-storage repo.
# Prints what is set/unset and what the workflow guard looks like. Never prints secret
# values -- only SET/MISSING and, for the storage repo, GitHub's own secret metadata
# (name + last-updated date, which `gh secret list` already limits to; it cannot reveal
# values). Changes nothing.
set -u

echo "=== Render env (via check-render-env.sh) ==="
bash "$(dirname "$0")/check-render-env.sh" || echo "(check-render-env.sh reported missing required vars -- see above)"

echo
echo "=== zealot-storage: repository variables (values shown; these are plain config, not secrets) ==="
gh variable list -R Zapier-codes/zealot-storage 2>&1 || echo "gh variable list failed -- check gh auth"

echo
echo "=== zealot-storage: repository secrets (names + update dates only; gh never exposes values) ==="
gh secret list -R Zapier-codes/zealot-storage 2>&1 || echo "gh secret list failed -- check gh auth"

echo
echo "=== zealot-storage: read-upload.yml guard state ==="
WF=~/zealot-storage/.github/workflows/read-upload.yml
if [ ! -f "$WF" ]; then
  echo "MISSING: $WF not found locally -- pull zealot-storage first"
else
  sign_line=$(grep -n "name: Sign the uploaded APK" "$WF")
  if_line=$(grep -A1 "name: Sign the uploaded APK" "$WF" | tail -1)
  guard=$(grep -c "fail \"SIGN_UPLOADED_APKS is no longer supported" "$WF")
  echo "Step name/line: $sign_line"
  echo "Its if: condition: $(echo "$if_line" | sed 's/^ *//')"
  if [ "$guard" -ge 1 ]; then
    echo "Check-the-inputs guard (fails the run if SIGN_UPLOADED_APKS=true): PRESENT"
  else
    echo "Check-the-inputs guard: MISSING -- this is the hole from before, re-check"
  fi
fi

echo
echo "=== zealot vs zealot-storage: mirrored files in sync? ==="
for pair in \
  "lib/bandwidth_sdk_fingerprints.yml:zealot-ci/bandwidth_sdk_fingerprints.yml" \
  "lib/scan_bandwidth_sdks.py:zealot-ci/scan_bandwidth_sdks.py" \
  "docs/ci/read-upload.yml:.github/workflows/read-upload.yml" \
  "docs/ci/compile-aab.yml:.github/workflows/compile-aab.yml" \
  "lib/zealot_provider/ZealotProxyProvider.java:zealot-ci/ZealotProxyProvider.java"; do
  a="${pair%%:*}"; b="${pair##*:}"
  fa=~/zealot/"$a"; fb=~/zealot-storage/"$b"
  if [ ! -f "$fa" ] || [ ! -f "$fb" ]; then
    printf '%-55s %s\n' "$a" "one side missing locally"
  elif diff -q "$fa" "$fb" >/dev/null 2>&1; then
    printf '%-55s %s\n' "$a" "identical"
  else
    printf '%-55s %s\n' "$a" "DRIFTED -- diff -u $fa $fb"
  fi
done

echo
echo "=== Summary: the two kill-switch flags ==="
echo "CI_COMPILE_ENABLED / RELEASE_UPLOAD_SESSIONS_ENABLED status is in the Render section above."
echo "SIGN_UPLOADED_APKS (storage repo variable) status is in the repository-variables section above."
