#!/usr/bin/env bash
# close-gaps.sh (rewrite). Checks the storage repo against Render and, with --apply,
# fixes what it can derive. Default run changes nothing.
#   ~/close-gaps.sh            check only
#   ~/close-gaps.sh --apply    also set what can be copied or derived
# Optional inputs (env): CERT=<64 hex org cert SHA-256>
#   KEYSTORE=/path/release.jks  KEYSTORE_PASSWORD=...  KEYSTORE_ALIAS=...
#   STORAGE_REPO (default Zapier-codes/zealot-storage)  RENDER_SERVICE_ID  RENDER_API_KEY
set -u
REPO="${STORAGE_REPO:-Zapier-codes/zealot-storage}"
SVC="${RENDER_SERVICE_ID:-srv-dalsvf942hec73dk2vg0}"
APPLY=0
case "${1:-}" in --apply) APPLY=1 ;; "") ;; *) echo "usage: $0 [--apply]"; exit 2 ;; esac

for f in "$HOME/.zealot.env" "$HOME/.render.env"; do [ -f "$f" ] && . "$f"; done
for c in gh jq curl; do
  command -v "$c" >/dev/null || { echo "missing tool: $c (pkg install $c)"; exit 2; }
done
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: run  gh auth login"; exit 2; }
KEY="${RENDER_API_KEY:-${RENDER_TOKEN:-}}"
if [ -z "$KEY" ]; then read -rsp "Render API key: " KEY; echo; fi
[ -n "$KEY" ] || { echo "no Render API key"; exit 2; }

BLK=0; WARN=0; FIXED=0
ok()      { printf 'ok       %s\n' "$*"; }
warn()    { printf 'WARN     %s\n' "$*"; WARN=$((WARN+1)); }
blocker() { printf 'BLOCKER  %s\n' "$*"; BLK=$((BLK+1)); }
fixed()   { printf 'FIXED    %s\n' "$*"; FIXED=$((FIXED+1)); }
strip()   { printf '%s' "${1%/}"; }
norm()    { printf '%s' "$1" | tr -d ': \r\n' | tr 'A-F' 'a-f'; }
valid()   { printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'; }

# ---- Render (source of truth for what the running service uses)
echo "reading Render variables ..."
RV='{}'; cursor=""
while :; do
  page=$(curl -fsS -H "Authorization: Bearer $KEY" \
    "https://api.render.com/v1/services/$SVC/env-vars?limit=100${cursor:+&cursor=$cursor}") \
    || { echo "Render API call failed (check the key and service id)"; exit 2; }
  n=$(jq length <<<"$page")
  [ "$n" -eq 0 ] && break
  RV=$(jq -c --argjson p "$page" '. + ($p | map({(.envVar.key): (.envVar.value // "")}) | add)' <<<"$RV")
  [ "$n" -lt 100 ] && break
  cursor=$(jq -r '.[-1].cursor' <<<"$page")
done
rv() { jq -r --arg k "$1" '.[$k] // empty' <<<"$RV"; }
render_set() {
  jq -n --arg v "$2" '{value:$v}' | curl -fsS -X PUT \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d @- \
    "https://api.render.com/v1/services/$SVC/env-vars/$1" >/dev/null
}

# ---- storage repo
echo "== Preflight: storage repo"
echo "storage repo: $REPO"
gv() { local o; o=$(gh api "repos/$REPO/actions/variables/$1" --jq .value 2>/dev/null) && printf '%s' "$o"; }
SECRETS=$(gh api "repos/$REPO/actions/secrets" --paginate --jq '.secrets[].name') \
  || { echo "cannot list secrets of $REPO (need admin access; run gh auth status)"; exit 2; }
has_secret() { grep -qx "$1" <<<"$SECRETS"; }

sync_var() {  # NAME WANT  (WANT empty = nothing to copy from)
  local name="$1" want="$2" have why
  have=$(gv "$name")
  if [ -z "$want" ]; then
    if [ -n "$have" ]; then ok "variable $name set ($have)"
    else blocker "variable $name missing and there is nothing to copy it from"; fi
    return
  fi
  if [ "$(strip "$have")" = "$(strip "$want")" ]; then ok "variable $name = $have"; return; fi
  why="missing"; [ -n "$have" ] && why="differs (repo: $have, Render: $want)"
  if [ "$APPLY" -eq 1 ] && gh variable set "$name" --body "$want" -R "$REPO" >/dev/null 2>&1; then
    fixed "variable $name set to $want ($why before)"
  else
    blocker "variable $name $why"
  fi
}

# Audience: what Render uses for OIDC (CI_OIDC_AUDIENCE, else https://ZEALOT_DOMAIN)
AUD=$(rv CI_OIDC_AUDIENCE)
[ -z "$AUD" ] && [ -n "$(rv ZEALOT_DOMAIN)" ] && AUD="https://$(rv ZEALOT_DOMAIN)"
AUD="${AUD%/}"
[ -z "$AUD" ] && warn "Render has neither CI_OIDC_AUDIENCE nor ZEALOT_DOMAIN"
sync_var ZEALOT_URL "$AUD"
sync_var R2_STAGING_ENDPOINT "$(rv R2_STAGING_ENDPOINT)"
sync_var R2_STAGING_BUCKET "$(rv R2_STAGING_BUCKET)"

# ---- organisation certificate SHA-256
KS_PW="${KEYSTORE_PASSWORD:-}"; KS_AL="${KEYSTORE_ALIAS:-}"
KP="${KEYSTORE_KEY_PASSWORD:-}"; KP_ASKED=0; [ -n "$KP" ] && KP_ASKED=1
ks_inputs() {
  [ -n "${KEYSTORE:-}" ] && [ -f "$KEYSTORE" ] || return 1
  [ -n "$KS_PW" ] || { read -rsp "Keystore password: " KS_PW; echo; }
  [ -n "$KS_AL" ] || read -rp "Key alias: " KS_AL
  if [ "$KP_ASKED" -eq 0 ]; then read -rsp "Key password (Enter if same as keystore password): " KP; echo; KP_ASKED=1; fi
  [ -n "$KS_PW" ] && [ -n "$KS_AL" ]
}
C_ENV=$(norm "${CERT:-}"); C_REPO=$(norm "$(gv RELEASE_CERT_SHA256)"); C_REN=$(norm "$(rv CI_COMPILE_EXPECT_CERT_SHA256)")
CERT_FINAL=""; bad=0
for c in "$C_ENV" "$C_REPO" "$C_REN"; do
  [ -z "$c" ] && continue
  valid "$c" || { blocker "a certificate value is not 64 hex characters: $c"; bad=1; continue; }
  if [ -z "$CERT_FINAL" ]; then CERT_FINAL="$c"
  elif [ "$c" != "$CERT_FINAL" ]; then blocker "certificate values disagree: $CERT_FINAL vs $c"; bad=1; fi
done
if [ -z "$CERT_FINAL" ] && [ "$bad" -eq 0 ] && command -v keytool >/dev/null && ks_inputs; then
  CERT_FINAL=$(norm "$(KS_PW_TMP="$KS_PW" keytool -list -v -keystore "$KEYSTORE" -alias "$KS_AL" \
    -storepass:env KS_PW_TMP 2>/dev/null | awk '/SHA256:/{print $2; exit}')")
  valid "$CERT_FINAL" && ok "certificate read from the keystore" || { CERT_FINAL=""; warn "keytool could not read the certificate"; }
fi
if [ -z "$CERT_FINAL" ]; then
  [ "$bad" -eq 0 ] && blocker "no org certificate SHA-256: run  CERT=<64 hex> ~/close-gaps.sh  or give KEYSTORE=..."
else
  sync_var RELEASE_CERT_SHA256 "$CERT_FINAL"
  if [ -z "$C_REN" ]; then
    if [ "$APPLY" -eq 1 ] && render_set CI_COMPILE_EXPECT_CERT_SHA256 "$CERT_FINAL"; then
      fixed "Render CI_COMPILE_EXPECT_CERT_SHA256 set (Render may redeploy; check its Events tab)"
    else
      blocker "Render is missing CI_COMPILE_EXPECT_CERT_SHA256 (without it nothing is marked signed)"
    fi
  else
    ok "Render CI_COMPILE_EXPECT_CERT_SHA256 matches"
  fi
fi

# ---- signing secrets (cannot be read back, only set)
if has_secret RELEASE_KEYSTORE_BASE64 && has_secret RELEASE_KEYSTORE_PASSWORD && has_secret RELEASE_KEY_ALIAS; then
  ok "secrets RELEASE_KEYSTORE_BASE64, RELEASE_KEYSTORE_PASSWORD, RELEASE_KEY_ALIAS exist"
else
  for s in RELEASE_KEYSTORE_BASE64 RELEASE_KEYSTORE_PASSWORD RELEASE_KEY_ALIAS; do
    has_secret "$s" || printf 'missing  secret %s\n' "$s"
  done
  if [ "$APPLY" -eq 1 ] && ks_inputs; then
    base64 -w0 < "$KEYSTORE" | gh secret set RELEASE_KEYSTORE_BASE64 -R "$REPO" >/dev/null 2>&1 \
      && printf '%s' "$KS_PW" | gh secret set RELEASE_KEYSTORE_PASSWORD -R "$REPO" >/dev/null 2>&1 \
      && printf '%s' "$KS_AL" | gh secret set RELEASE_KEY_ALIAS -R "$REPO" >/dev/null 2>&1 \
      && { [ -z "$KP" ] || [ "$KP" = "$KS_PW" ] || printf '%s' "$KP" | gh secret set RELEASE_KEY_PASSWORD -R "$REPO" >/dev/null 2>&1; } \
      && fixed "the three keystore secrets were set from $KEYSTORE" \
      || blocker "setting the keystore secrets failed"
  else
    blocker "keystore secrets missing: run  KEYSTORE=/path/release.jks ~/close-gaps.sh --apply"
  fi
fi

# ---- other storage-repo secrets
if has_secret CI_COMPILE_CALLBACK_TOKEN; then ok "secret CI_COMPILE_CALLBACK_TOKEN exists (cannot compare its value)"
elif [ -n "$(rv CI_COMPILE_CALLBACK_TOKEN)" ]; then
  if [ "$APPLY" -eq 1 ] && printf '%s' "$(rv CI_COMPILE_CALLBACK_TOKEN)" | gh secret set CI_COMPILE_CALLBACK_TOKEN -R "$REPO" >/dev/null 2>&1; then
    fixed "secret CI_COMPILE_CALLBACK_TOKEN copied from Render"
  else blocker "secret CI_COMPILE_CALLBACK_TOKEN missing (Render has it; --apply copies it)"; fi
else warn "CI_COMPILE_CALLBACK_TOKEN is on neither side"; fi
for s in R2_STAGING_CI_ACCESS_KEY_ID R2_STAGING_CI_SECRET_ACCESS_KEY; do
  has_secret "$s" && ok "secret $s exists" \
    || blocker "secret $s missing: needs a second R2 token from Cloudflare (Object Read and Write on the staging bucket); this script cannot create it"
done

echo
if [ "$APPLY" -eq 0 ]; then echo "Check only: nothing was changed. Run with --apply to fix what can be derived."; fi
echo "blockers: $BLK   warnings: $WARN   fixed: $FIXED"
[ "$BLK" -eq 0 ] && echo "No blockers." || echo "Fix the BLOCKER lines and run again."
[ "$BLK" -eq 0 ]
