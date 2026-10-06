#!/usr/bin/env bash
# Read-only check of the Render env for zealot-web: which Task 40 variables are set.
# Prints SET/MISSING; plain values for non-secret settings, a 10-char SHA-256
# fingerprint for secrets. Changes nothing. Needs: curl, jq, sha256sum.
#   ~/zealot/docs/ci/check-render-env.sh   (uses RENDER_API_KEY or RENDER_TOKEN, already set in the shell)
# Optional: RENDER_SERVICE_ID (default below), ~/.zealot.env is sourced if present.
set -u
for f in "$HOME/.zealot.env" "$HOME/.render.env"; do [ -f "$f" ] && . "$f"; done
RENDER_API_KEY="${RENDER_API_KEY:-${RENDER_TOKEN:-}}"
: "${RENDER_API_KEY:?no Render key: set RENDER_API_KEY or RENDER_TOKEN (Render dashboard > Account Settings > API Keys)}"
SVC="${RENDER_SERVICE_ID:-srv-dalsvf942hec73dk2vg0}"

vars="{}"; cursor=""
while :; do
  page=$(curl -fsS -H "Authorization: Bearer $RENDER_API_KEY" \
    "https://api.render.com/v1/services/$SVC/env-vars?limit=100${cursor:+&cursor=$cursor}") || { echo "Render API call failed"; exit 2; }
  [ "$(echo "$page" | jq length)" -eq 0 ] && break
  vars=$(jq -s '.[0] + (.[1] | map({(.envVar.key): .envVar.value}) | add)' <(echo "$vars") <(echo "$page"))
  cursor=$(echo "$page" | jq -r '.[-1].cursor')
  [ "$(echo "$page" | jq length)" -lt 100 ] && break
done

# kind: P = plain (show value), S = secret (fingerprint only), F = flag (show value)
# need: R = required for direct upload + CI release, O = optional
rows='R2_STAGING_BUCKET P R
R2_STAGING_ENDPOINT P R
R2_STAGING_ACCESS_KEY_ID S R
R2_STAGING_SECRET_ACCESS_KEY S R
R2_STAGING_REGION P O
CI_OIDC_AUDIENCE P R
CI_COMPILE_REPO P O
CI_COMPILE_DISPATCH_TOKEN S R
CI_COMPILE_CALLBACK_TOKEN S R
CI_COMPILE_EXPECT_CERT_SHA256 P R
CI_COMPILE_ENABLED F R
RELEASE_UPLOAD_SESSIONS_ENABLED F R
RELEASE_UPLOAD_MULTIPART_ENABLED F O
RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB P O
RELEASE_UPLOAD_PART_SIZE_MIB P O
ADC_AUTO_REGISTER F O
REQUIRE_ORG_SIGNED_APKS F O
RELEASE_STORAGE_ADAPTER P R
DISTR_LINK_SECRET S R
GITHUB_STORAGE_REPO P A:github
GITHUB_STORAGE_TOKEN S A:github
R2_ENDPOINT P A:r2
R2_ACCESS_KEY_ID S A:r2
R2_SECRET_ACCESS_KEY S A:r2'

adapter=$(echo "$vars" | jq -r '.RELEASE_STORAGE_ADAPTER // empty')
printf '%-34s %-9s %s\n' NAME RESULT VALUE/FINGERPRINT
miss=0
while read -r name kind need; do
  val=$(echo "$vars" | jq -r --arg k "$name" '.[$k] // empty')
  # A:<adapter> = required only for that RELEASE_STORAGE_ADAPTER (R2_* only with r2, GITHUB_STORAGE_* only with github)
  case "$need" in A:*) if [ "${need#A:}" = "$adapter" ]; then need=R; else need=N; fi ;; esac
  if [ -z "$val" ]; then
    if [ "$need" = R ]; then r="MISSING"; miss=$((miss+1)); elif [ "$need" = N ]; then r="n/a"; else r="not set"; fi
    printf '%-34s %-9s\n' "$name" "$r"
  elif [ "$kind" = S ]; then
    printf '%-34s %-9s %s\n' "$name" set "$(printf %s "$val" | sha256sum | cut -c1-10)"
  else
    printf '%-34s %-9s %s\n' "$name" set "$val"
  fi
done <<< "$rows"

aud=$(echo "$vars" | jq -r '.CI_OIDC_AUDIENCE // empty')
echo
echo "Compare by hand: the storage repo's ZEALOT_URL variable must equal CI_OIDC_AUDIENCE ($aud),"
echo "and its R2_STAGING_ENDPOINT / R2_STAGING_BUCKET must equal the two Render values above."
echo "Turn CI_COMPILE_ENABLED and RELEASE_UPLOAD_SESSIONS_ENABLED on LAST."
if [ "$(echo "$vars" | jq -r '.RELEASE_UPLOAD_MULTIPART_ENABLED // empty')" = true ]; then
  echo "Multipart uploads are ON: Storeapp's direct-upload path (ZEALOT_DIRECT_UPLOAD) must stay off, or the threshold"
  echo "above its largest bundle, until its workflow runs the parts loop (runbook section 14)."
fi
[ "$miss" -gt 0 ] && { echo "$miss required variable(s) MISSING"; exit 1; }
echo "All required variables are set."
