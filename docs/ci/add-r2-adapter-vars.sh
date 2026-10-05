#!/usr/bin/env bash
# Adds R2_BUCKET, R2_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY on Render, copied from the
# R2_STAGING_* values already there. Operator's decision (2026-10-05): R2 stays staging-only, the storage
# method stays RELEASE_STORAGE_ADAPTER=github, credentials are only ADDED. Nothing in the app reads these
# four while the adapter is github (only app/services/release_storage/r2_adapter.rb does, with r2).
#   bash ~/zealot/docs/ci/add-r2-adapter-vars.sh            # dry run: shows what it would add
#   bash ~/zealot/docs/ci/add-r2-adapter-vars.sh --apply    # adds the missing ones
# Never overwrites a variable that already has a value. Never prints a secret (10-char fingerprint only).
# Setting a Render variable may start a deploy; with --apply the script now waits for a NEW deploy to be live (and
# starts one through the API if Render does not), so it can be followed straight by enable-pipeline.sh (Task 40n-h).
# Needs: curl, jq, sha256sum. Uses RENDER_API_KEY or RENDER_TOKEN (already set).
set -u
for f in "$HOME/.zealot.env" "$HOME/.render.env"; do [ -f "$f" ] && . "$f"; done
RENDER_API_KEY="${RENDER_API_KEY:-${RENDER_TOKEN:-}}"
: "${RENDER_API_KEY:?no Render key: set RENDER_API_KEY or RENDER_TOKEN}"
SVC="${RENDER_SERVICE_ID:-srv-dalsvf942hec73dk2vg0}"
API="${RENDER_API_URL:-https://api.render.com/v1}"   # override only for tests against a stub
auth=(-H "Authorization: Bearer $RENDER_API_KEY")
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib-render-deploy.sh"   # deploy_snapshot, wait_new_live (Task 40n-h)
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

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

adapter=$(rv RELEASE_STORAGE_ADAPTER)
[ "$adapter" = github ] || { echo "RELEASE_STORAGE_ADAPTER is '$adapter', not github: stopping, nothing changed."; exit 1; }

# target source kind (S = secret: show a fingerprint only)
pairs='R2_BUCKET R2_STAGING_BUCKET P
R2_ENDPOINT R2_STAGING_ENDPOINT P
R2_ACCESS_KEY_ID R2_STAGING_ACCESS_KEY_ID S
R2_SECRET_ACCESS_KEY R2_STAGING_SECRET_ACCESS_KEY S'

show() { if [ "$2" = S ]; then printf %s "$1" | sha256sum | cut -c1-10; else printf %s "$1"; fi; }
todo=""; bad=0
while read -r target source kind; do
  have=$(rv "$target"); src=$(rv "$source")
  if [ -n "$have" ]; then printf '  keep    %-22s already set (%s)\n' "$target" "$(show "$have" "$kind")"
  elif [ -z "$src" ]; then printf '  BLOCKED %-22s source %s is not set on Render\n' "$target" "$source"; bad=$((bad+1))
  else printf '  add     %-22s from %s (%s)\n' "$target" "$source" "$(show "$src" "$kind")"; todo="$todo $target:$source"
  fi
done <<< "$pairs"

[ "$bad" -gt 0 ] && { echo "$bad source(s) missing. Nothing changed."; exit 1; }
[ -z "$todo" ] && { echo "Nothing to add."; exit 0; }
[ "$APPLY" -ne 1 ] && { echo "Dry run: nothing changed. Re-run with --apply."; exit 0; }

deploy_snapshot || exit 2
for t in $todo; do
  target=${t%%:*}; source=${t#*:}
  jq -n --arg v "$(rv "$source")" '{value:$v}' \
    | curl -fsS -X PUT "${auth[@]}" -H "Content-Type: application/json" -d @- "$API/services/$SVC/env-vars/$target" >/dev/null \
    || { echo "failed to set $target"; exit 2; }
  echo "set $target"
done
echo "Variables set. Waiting for a new deploy to be live:"
wait_new_live "$DEPLOY_SNAP" || exit $?
echo "Done. The deploy is live; next: enable-pipeline.sh."
