#!/usr/bin/env bash
# Task 40n-h. Sourced by enable-pipeline.sh and add-r2-adapter-vars.sh; not run on its own.
#
# Why it exists: both scripts used to change a Render variable and then read "the latest deploy" as a pass. The latest
# deploy at that moment was the OLD live one, so they reported success before any new deploy had even started (seen
# 2026-10-05: nothing newer than the old deploy appeared until the operator POSTed a deploy by hand).
#
# What it does instead: deploy_snapshot records the ids of the newest deploys BEFORE the change. wait_new_live then
#   1. waits up to DEPLOY_GRACE seconds for a deploy whose id is not in the snapshot to appear;
#   2. if none appears, starts one through the API (POST /services/$SVC/deploys) and waits for that;
#   3. waits until the newest deploy is `live`, then waits DEPLOY_SETTLE seconds and checks it is still the newest
#      (a second variable change can queue another deploy right behind the first);
#   4. stops on build_failed, update_failed, canceled or pre_deploy_failed, and after DEPLOY_MAX seconds.
# It compares ids, never clocks, so the phone's clock does not matter.
#
# The caller defines: API, SVC, auth (a bash array of curl -H options). Needs curl and jq.
# Return codes: 0 live, 2 API/network problem, 3 deploy failed, did not appear, or timed out.
# Tunables (seconds): DEPLOY_GRACE=60 DEPLOY_POLL=10 DEPLOY_SETTLE=20 DEPLOY_MAX=900.
DEPLOY_GRACE="${DEPLOY_GRACE:-60}"
DEPLOY_POLL="${DEPLOY_POLL:-10}"
DEPLOY_SETTLE="${DEPLOY_SETTLE:-20}"
DEPLOY_MAX="${DEPLOY_MAX:-900}"
DEPLOY_SNAP=""

deploy_list() { curl -fsS "${auth[@]}" "$API/services/$SVC/deploys?limit=${1:-5}"; }

# Sets DEPLOY_SNAP (one id per line). Returns 2 when the list cannot be read: an empty snapshot taken from a failed
# call would make every old deploy look new, which is the bug this file fixes.
deploy_snapshot() {
  local j
  j=$(deploy_list 5) || { echo "  cannot read the deploy list from Render"; return 2; }
  DEPLOY_SNAP=$(printf %s "$j" | jq -r '.[].deploy.id') || return 2
}

wait_new_live() {
  local snap="$1" waited=0 posted=0 t=0 j id newest st again
  while :; do   # 1. a deploy that was not there before the change must appear
    j=$(deploy_list 5) || { echo "  cannot read the deploy list from Render"; return 2; }
    id=$(printf %s "$j" | jq -r --arg s "$snap" \
      '($s | split("\n")) as $old | [.[].deploy | select((.id as $i | $old | index($i)) | not)] | .[0].id // empty')
    [ -n "$id" ] && { echo "  new deploy: $id"; break; }
    if [ "$waited" -ge "$DEPLOY_GRACE" ]; then
      if [ "$posted" -eq 1 ]; then echo "  no new deploy appeared even after starting one; stop here"; return 3; fi
      echo "  no new deploy after ${waited}s; starting one through the API"
      curl -fsS -X POST "${auth[@]}" -H "Content-Type: application/json" -d '{"clearCache":"do_not_clear"}' \
        "$API/services/$SVC/deploys" >/dev/null || { echo "  could not start a deploy"; return 2; }
      posted=1; waited=0; continue
    fi
    sleep "$DEPLOY_POLL"; waited=$((waited + DEPLOY_POLL))
  done
  while [ "$t" -le "$DEPLOY_MAX" ]; do   # 2. the newest deploy must be live (and stay the newest)
    j=$(deploy_list 1) || { echo "  cannot read the deploy list from Render"; return 2; }
    newest=$(printf %s "$j" | jq -r '.[0].deploy.id // empty'); st=$(printf %s "$j" | jq -r '.[0].deploy.status // empty')
    if printf '%s\n' "$snap" | grep -qx "$newest"; then
      echo "  newest deploy $newest is one from before the change; waiting"
    else
      echo "  deploy $newest: $st"
      case "$st" in
        live)
          sleep "$DEPLOY_SETTLE"
          again=$(deploy_list 1 | jq -r '.[0].deploy.id // empty')
          [ "$again" = "$newest" ] && return 0
          echo "  another deploy started behind it; waiting for that one" ;;
        build_failed|update_failed|canceled|pre_deploy_failed) echo "  deploy ended '$st'; stop here"; return 3 ;;
      esac
    fi
    sleep "$DEPLOY_POLL"; t=$((t + DEPLOY_POLL))
  done
  echo "  no live deploy after ${DEPLOY_MAX}s; stop here"; return 3
}
