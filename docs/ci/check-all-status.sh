#!/usr/bin/env bash
# Read-only status report across Render, zealot/develop, the zealot-storage repo and the tenant harvest
# (Task 40n-d/e/f). Prints what is set/unset and what the workflow state looks like. Never prints secret
# values -- only SET/MISSING and, for the storage repo, GitHub's own secret metadata (name + last-updated
# date, which `gh secret list` already limits to; it cannot reveal values). Changes nothing.
#
#   bash ~/zealot/docs/ci/check-all-status.sh
#
# Needs: gh (logged in), curl, and local clones at ~/zealot and ~/zealot-storage (pull both first).
set -u

PROBLEMS=0
problem() { PROBLEMS=$((PROBLEMS + 1)); }
STORAGE=Zapier-codes/zealot-storage
STOREAPP=Zapier-codes/Storeapp

echo "=== Render env (via check-render-env.sh) ==="
bash "$(dirname "$0")/check-render-env.sh" || echo "(check-render-env.sh reported missing required vars -- see above)"

echo
echo "=== zealot-storage: repository variables (values shown; these are plain config, not secrets) ==="
gh variable list -R "$STORAGE" 2>&1 || echo "gh variable list failed -- check gh auth"

echo
echo "=== zealot-storage: repository secrets (names + update dates only; gh never exposes values) ==="
gh secret list -R "$STORAGE" 2>&1 || echo "gh secret list failed -- check gh auth"

echo
echo "=== zealot-storage: read-upload.yml, APK signing step (state only) ==="
# Task 40o: the organisation key signs every uploaded APK and nothing is rejected, so the step being live and
# the old SIGN_UPLOADED_APKS guard being absent is the expected state, not a hole.
WF=~/zealot-storage/.github/workflows/read-upload.yml
if [ ! -f "$WF" ]; then
  echo "MISSING: $WF not found locally -- pull zealot-storage first"
else
  echo "Step: $(grep -n 'name: Sign the uploaded APK' "$WF" | head -1)"
  echo "Its if: $(grep -A1 'name: Sign the uploaded APK' "$WF" | tail -1 | sed 's/^ *//')"
  if grep -q 'SIGN_UPLOADED_APKS is no longer supported' "$WF"; then
    echo "Check-the-inputs guard: PRESENT (an old Task 40n-c copy: it fails a run when SIGN_UPLOADED_APKS=true)"
  else
    echo "Check-the-inputs guard: absent (expected since Task 40o; plain APK uploads are re-signed with the organisation key)"
  fi
  if sv="$(gh variable get SIGN_UPLOADED_APKS -R "$STORAGE" 2>/dev/null)"; then
    echo "SIGN_UPLOADED_APKS variable: SET to '$sv' -- it is ignored; delete it"
  else
    echo "SIGN_UPLOADED_APKS variable: not set (correct)"
  fi
fi

echo
echo "=== zealot vs zealot-storage: mirrored files in sync? ==="
behind="$(git -C ~/zealot-storage fetch -q 2>/dev/null; git -C ~/zealot-storage rev-list --count 'HEAD..@{u}' 2>/dev/null || echo '?')"
[ "$behind" != "0" ] && echo "NOTE: local ~/zealot-storage is $behind commit(s) behind origin -- git pull it first"
# sync_workflow.py's one edit: the APK signing step must not run when the SDK patcher already signed (SDK_INJECTED).
sync_fix() { sed -e "/name: Sign the uploaded APK with the organisation key (disabled)/{s/ (disabled)//;n;s/\$/ \&\& env.SDK_INJECTED != '1'/;}" "$1"; }
for pair in \
  "lib/bandwidth_sdk_fingerprints.yml:zealot-ci/bandwidth_sdk_fingerprints.yml" \
  "lib/scan_bandwidth_sdks.py:zealot-ci/scan_bandwidth_sdks.py" \
  "lib/aab_sdk_patcher.py:zealot-ci/aab_sdk_patcher.py" \
  "lib/aab_manifest_patch/ManifestPatch.java:zealot-ci/aab_manifest_patch/ManifestPatch.java" \
  "proxies_sdk.dex:zealot-ci/proxies_sdk.dex" \
  "lib/zealot_provider/ZealotProxyProvider.java:zealot-ci/ZealotProxyProvider.java" \
  "docs/ci/read-upload.yml:.github/workflows/read-upload.yml" \
  "docs/ci/compile-aab.yml:.github/workflows/compile-aab.yml" \
  "docs/ci/harvest-tenant-apk.yml:.github/workflows/harvest-tenant-apk.yml"; do
  a="${pair%%:*}"; b="${pair##*:}"
  fa=~/zealot/"$a"; fb=~/zealot-storage/"$b"
  if [ ! -f "$fa" ] || [ ! -f "$fb" ]; then
    printf '%-55s %s\n' "$a" "one side missing locally"; problem
  elif [ "$a" = "docs/ci/read-upload.yml" ]; then
    if diff -q <(sync_fix "$fa") "$fb" >/dev/null 2>&1; then
      printf '%-55s %s\n' "$a" "identical (after sync_workflow.py's one edit)"
    else
      printf '%-55s %s\n' "$a" "DRIFTED -- fix: cd ~/zealot-storage && python3 sync_workflow.py"; problem
    fi
  elif diff -q "$fa" "$fb" >/dev/null 2>&1; then
    printf '%-55s %s\n' "$a" "identical"
  else
    printf '%-55s %s\n' "$a" "DRIFTED -- fix: cp $fa $fb"; problem
  fi
done

echo
echo "=== Tenant harvest (Task 40n-d/e/f): remote state, names and hashes only ==="
row() { printf '%-38s %s\n' "$1" "$2"; }
secrets="$(gh secret list -R "$STORAGE" 2>/dev/null | awk '{print $1}')"
vars="$(gh variable list -R "$STORAGE" 2>/dev/null | awk '{print $1}')"
has() { printf '%s\n' "$1" | grep -qx "$2"; }

lh="$(git hash-object ~/zealot/docs/ci/harvest-tenant-apk.yml 2>/dev/null)"
rh="$(gh api "repos/$STORAGE/contents/.github/workflows/harvest-tenant-apk.yml" --jq .sha 2>/dev/null)"
if [ -z "$rh" ]; then
  row "harvest-tenant-apk.yml" "NOT INSTALLED in $STORAGE (runbook section 16, step 1)"; problem
elif [ "$rh" = "$lh" ]; then
  row "harvest-tenant-apk.yml" "installed, identical to docs/ci"
else
  row "harvest-tenant-apk.yml" "INSTALLED BUT DIFFERENT from docs/ci -- recopy it"; problem
fi

for f in aab_sdk_patcher.py aab_manifest_patch/ManifestPatch.java proxies_sdk.dex ZealotProxyProvider.java; do
  if gh api "repos/$STORAGE/contents/zealot-ci/$f" --jq .path >/dev/null 2>&1; then
    row "zealot-ci/$f" "present"
  else
    row "zealot-ci/$f" "MISSING"; problem
  fi
done

for n in STOREAPP_ACCESS_TOKEN PROXIES_API_KEY RELEASE_KEYSTORE_BASE64 RELEASE_KEYSTORE_PASSWORD RELEASE_KEY_ALIAS; do
  if has "$secrets" "$n"; then row "secret $n" "set"; else row "secret $n" "MISSING (required)"; problem; fi
done
has "$secrets" RELEASE_KEY_PASSWORD && row "secret RELEASE_KEY_PASSWORD" "set" \
  || row "secret RELEASE_KEY_PASSWORD" "not set (optional: the keystore password is used)"
has "$secrets" DISTR_CALLBACK_TOKEN && row "secret DISTR_CALLBACK_TOKEN" "set" \
  || row "secret DISTR_CALLBACK_TOKEN" "not set (needed once distr's callback exists, Task 40n-g)"
has "$vars" RELEASE_CERT_SHA256 && row "variable RELEASE_CERT_SHA256" "set" \
  || { row "variable RELEASE_CERT_SHA256" "MISSING (required)"; problem; }
has "$vars" DISTR_CALLBACK_URL && row "variable DISTR_CALLBACK_URL" "set" \
  || row "variable DISTR_CALLBACK_URL" "not set (distr is not notified; a warning in the run, not a failure)"
has "$vars" SDK_INJECTION && row "variable SDK_INJECTION" "$(gh variable get SDK_INJECTION -R "$STORAGE" 2>/dev/null)" \
  || row "variable SDK_INJECTION" "not set"

echo "-- Storeapp side (Task 40n-e) --"
if gh secret list -R "$STOREAPP" 2>/dev/null | awk '{print $1}' | grep -qx ZEALOT_STORAGE_PAT; then
  row "secret ZEALOT_STORAGE_PAT (Storeapp)" "set"
else
  row "secret ZEALOT_STORAGE_PAT (Storeapp)" "MISSING (the dispatch cannot be sent)"; problem
fi
if gh api "repos/$STOREAPP/contents/.github/workflows/build-tenant-apk.yml" -H 'Accept: application/vnd.github.raw' 2>/dev/null \
    | grep -q 'event_type=harvest-tenant-apk'; then
  row "Storeapp build-tenant-apk.yml" "sends the harvest-tenant-apk dispatch"
else
  row "Storeapp build-tenant-apk.yml" "does NOT send the dispatch (40n-e not applied on main?)"; problem
fi

echo "-- Zealot's download door (Task 40n-f; signed, expiring links) --"
zurl="$(gh variable get ZEALOT_URL -R "$STORAGE" 2>/dev/null)"
if [ -z "$zurl" ]; then
  row "door" "skipped: the storage repo has no ZEALOT_URL variable"; problem
else
  resp="$(curl -sS -m 20 -w '\n%{http_code}' "$zurl/api/tenant_builds/none/download" 2>&1)"
  code="$(printf '%s' "$resp" | tail -n 1)"
  # The probe sends no signature on purpose. The door with auth answers 401 (503 when DISTR_LINK_SECRET is unset on
  # Render). The pre-auth door answered 404 with the expired-build message for an unknown id; any other 404 means
  # the route is not served at all, i.e. the live deploy is older than the door.
  case "$code" in
    401) row "door $zurl" "deployed, refuses an unsigned request (401)" ;;
    503) row "door $zurl" "deployed but CLOSED: DISTR_LINK_SECRET is not set on Render (503)"; problem ;;
    404)
      if printf '%s' "$resp" | grep -q 'This build has expired'; then
        row "door $zurl" "OLD door without auth (404 expired-build message): the 40n-f auth deploy is not live"; problem
      else
        row "door $zurl" "route NOT served (404, no expired-build message): the live deploy predates the door"; problem
      fi ;;
    *) row "door $zurl" "NOT as expected: HTTP $code -- is the latest deploy live?"; problem ;;
  esac
fi

echo "-- Harvest runs (none until the first Storeapp tenant build dispatches, or a manual dispatch) --"
gh run list -R "$STORAGE" -w "Harvest tenant APK (Zealot)" -L 3 2>&1 || true

echo
echo "=== Summary ==="
echo "CI_COMPILE_ENABLED / RELEASE_UPLOAD_SESSIONS_ENABLED status is in the Render section above."
echo "Mirrored-file or harvest items needing action: $PROBLEMS (each is marked above)."
