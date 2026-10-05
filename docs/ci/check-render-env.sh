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
ADC_AUTO_REGISTER F O
RELEASE_STORAGE_ADAPTER P R
R2_ENDPOINT P R
R2_ACCESS_KEY_ID S R
R2_SECRET_ACCESS_KEY S R'

printf '%-34s %-9s %s\n' NAME RESULT VALUE/FINGERPRINT
miss=0
while read -r name kind need; do
  val=$(echo "$vars" | jq -r --arg k "$name" '.[$k] // empty')
  if [ -z "$val" ]; then
    if [ "$need" = R ]; then r="MISSING"; miss=$((miss+1)); else r="not set"; fi
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
[ "$miss" -gt 0 ] && { echo "$miss required variable(s) MISSING"; exit 1; }
echo "All required variables are set."
