#!/usr/bin/env bash
# Task 40: gate checks, then turn the two pipeline flags on, in the runbook's order.
#   bash ~/zealot/docs/ci/enable-pipeline.sh            # dry run: runs every gate, changes nothing
#   bash ~/zealot/docs/ci/enable-pipeline.sh --apply    # gates pass -> sets CI_COMPILE_ENABLED=true,
#                                                       # waits for the deploy to be live, then sets
#                                                       # RELEASE_UPLOAD_SESSIONS_ENABLED=true
# Needs: curl, jq, gh (logged in), git, sha256sum. Uses RENDER_API_KEY or RENDER_TOKEN (already set).
# Never prints a secret value. ADC_AUTO_REGISTER and SIGN_UPLOADED_APKS are NOT touched (off by design;
# see docs/ci/operator-runbook.md section 4).
set -u
for f in "$HOME/.zealot.env" "$HOME/.render.env"; do [ -f "$f" ] && . "$f"; done
RENDER_API_KEY="${RENDER_API_KEY:-${RENDER_TOKEN:-}}"
: "${RENDER_API_KEY:?no Render key: set RENDER_API_KEY or RENDER_TOKEN}"
SVC="${RENDER_SERVICE_ID:-srv-dalsvf942hec73dk2vg0}"
STORAGE="${STORAGE_REPO:-Zapier-codes/zealot-storage}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
API="https://api.render.com/v1"
auth=(-H "Authorization: Bearer $RENDER_API_KEY")

fail=0
ok()  { printf '  ok      %s\n' "$1"; }
bad() { printf '  BLOCKED %s\n' "$1"; fail=$((fail+1)); }
norm() { printf %s "$1" | sed 's:/*$::'; }

# ---- read Render env (same paging as check-render-env.sh)
vars="{}"; cursor=""
while :; do
  page=$(curl -fsS "${auth[@]}" "$API/services/$SVC/env-vars?limit=100${cursor:+&cursor=$cursor}") \
    || { echo "Render API call failed"; exit 2; }
  [ "$(echo "$page" | jq length)" -eq 0 ] && break
  vars=$(jq -s '.[0] + (.[1] | map({(.envVar.key): .envVar.value}) | add)' <(echo "$vars") <(echo "$page"))
  cursor=$(echo "$page" | jq -r '.[-1].cursor')
  [ "$(echo "$page" | jq length)" -lt 100 ] && break
done
rv() { echo "$vars" | jq -r --arg k "$1" '.[$k] // empty'; }

echo "Gate 1: Render variables"
adapter=$(rv RELEASE_STORAGE_ADAPTER)
req="R2_STAGING_BUCKET R2_STAGING_ENDPOINT R2_STAGING_ACCESS_KEY_ID R2_STAGING_SECRET_ACCESS_KEY CI_OIDC_AUDIENCE CI_COMPILE_DISPATCH_TOKEN CI_COMPILE_CALLBACK_TOKEN CI_COMPILE_EXPECT_CERT_SHA256 RELEASE_STORAGE_ADAPTER"
case "$adapter" in
  github) req="$req GITHUB_STORAGE_REPO GITHUB_STORAGE_TOKEN" ;;
  r2)     req="$req R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY" ;;
  *)      bad "RELEASE_STORAGE_ADAPTER is '$adapter' (expected github or r2)" ;;
esac
for k in $req; do [ -n "$(rv "$k")" ] && ok "$k set" || bad "$k MISSING on Render"; done

echo "Gate 2: storage repo $STORAGE matches Render"
sv() { gh variable get "$1" -R "$STORAGE" 2>/dev/null; }
zu=$(sv ZEALOT_URL); aud=$(rv CI_OIDC_AUDIENCE)
if [ -n "$zu" ] && [ "$(norm "$zu")" = "$(norm "$aud")" ]; then ok "ZEALOT_URL = CI_OIDC_AUDIENCE"; else bad "ZEALOT_URL ('$zu') differs from CI_OIDC_AUDIENCE ('$aud')"; fi
for k in R2_STAGING_ENDPOINT R2_STAGING_BUCKET; do
  a=$(sv "$k"); b=$(rv "$k")
  if [ -n "$a" ] && [ "$(norm "$a")" = "$(norm "$b")" ]; then ok "$k equal"; else bad "$k differs (storage repo '$a', Render '$b')"; fi
done
cert=$(sv RELEASE_CERT_SHA256); rcert=$(rv CI_COMPILE_EXPECT_CERT_SHA256)
if [ -n "$cert" ] && [ "$cert" = "$rcert" ]; then ok "RELEASE_CERT_SHA256 = CI_COMPILE_EXPECT_CERT_SHA256"; else bad "certificate variables differ or are unset"; fi
names=$(gh secret list -R "$STORAGE" 2>/dev/null | awk '{print $1}')
for s in RELEASE_KEYSTORE_BASE64 RELEASE_KEYSTORE_PASSWORD RELEASE_KEY_ALIAS CI_COMPILE_CALLBACK_TOKEN R2_STAGING_CI_ACCESS_KEY_ID R2_STAGING_CI_SECRET_ACCESS_KEY; do
  echo "$names" | grep -qx "$s" && ok "secret $s exists" || bad "secret $s MISSING in storage repo"
done
remote=$(gh api "repos/$STORAGE/contents/.github/workflows/read-upload.yml" --jq .sha 2>/dev/null)
local_=$(git -C "$HERE" hash-object "$HERE/read-upload.yml")
if [ -n "$remote" ] && [ "$remote" = "$local_" ]; then ok "read-upload.yml is current ($remote)"; else bad "read-upload.yml in storage repo ('$remote') is not this repo's ('$local_')"; fi

echo "Gate 3: Render deploy"
latest_status() { curl -fsS "${auth[@]}" "$API/services/$SVC/deploys?limit=1" | jq -r '.[0].deploy.status // empty'; }
st=$(latest_status)
[ "$st" = live ] && ok "latest deploy is live" || bad "latest deploy status is '$st' (need live)"

echo
if [ "$fail" -gt 0 ]; then echo "$fail gate(s) BLOCKED. Fix them, run again. Nothing was changed."; exit 1; fi
echo "All gates pass."
if [ "$APPLY" -ne 1 ]; then echo "Dry run: nothing changed. Re-run with --apply to turn the flags on."; exit 0; fi

setvar() {
  curl -fsS -X PUT "${auth[@]}" -H "Content-Type: application/json" -d "{\"value\":\"$2\"}" \
    "$API/services/$SVC/env-vars/$1" >/dev/null || { echo "failed to set $1"; exit 2; }
  echo "set $1=$2"
}
wait_live() {
  sleep 8   # give Render time to start the deploy the env change triggers
  for _ in $(seq 1 60); do
    s=$(latest_status); echo "  deploy: $s"
    [ "$s" = live ] && return 0
    case "$s" in build_failed|update_failed|canceled|pre_deploy_failed) echo "deploy ended '$s'; stop here"; exit 3 ;; esac
    sleep 10
  done
  echo "deploy not live after 10 minutes; stop here"; exit 3
}

echo "Turning on, one at a time, last:"
setvar CI_COMPILE_ENABLED true;               wait_live
setvar RELEASE_UPLOAD_SESSIONS_ENABLED true;  wait_live
echo "Done. Next: one real end-to-end upload (docs/direct_upload.md), then 40k."
echo "Check:  bash $HERE/check-render-env.sh"
