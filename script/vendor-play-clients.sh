#!/usr/bin/env bash
# vendor-play-clients.sh: fetch the pinned, vendored copies of the two reverse-engineered Play clients
# behind Z-P25's PlayCatalogSource adapter (docs/PARITY-KANBAN.md Z-P25, docs/UNOFFICIAL-ROUTES.md §1.1).
#
# Rule 2 of §1.1 is "pinned versions, vendored copies", so a yanked release or a deleted upstream cannot
# stop a build. This script is the one place the pins live: it clones each project at the exact commit
# recorded below into vendor/play/<name> and writes the commit into that copy's VENDORED file. It is
# idempotent: a re-run jumps each vendored copy to the pinned commit, so a hand-edited tree is reverted.
#
# It is NOT run in the sandbox (no network in this sandbox, and the token here cannot create the forks);
# it is what the operator or a build host runs once, and the resulting vendor/play/ tree is committed
# alongside the adapter. Neither library is imported by the Rails process: `PlayCatalogSource` shells out to
# a separate process that uses them (licence boundary, §1.1 rule 7 — Zealot is MIT, Aurora's GPlayApi is
# GPL-3.0-or-later).
#
# PREREQUISITE: the two forks must exist first (the URLs below are Zapier-codes' forks, per the operator's
# directive). Create them once from a machine that has your GitHub credentials — the sandbox token is
# read-only and cannot fork:
#   gh repo fork whyorean/GPlayApi --clone=false
#   gh repo fork AbhiTheModder/playstoreapi --clone=false
# A fork shares upstream's object store, so the pinned SHAs resolve in the fork with no sync needed.
#
#   bash script/vendor-play-clients.sh            # fetch/refresh both vendored copies
#   bash script/vendor-play-clients.sh gplayapi   # just one
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/vendor/play"

# --- the pins (Rule 2). Update a commit here deliberately, with a note in HANDOVER/kanban, never by hand
# in the vendored tree.
#
# The repo URL is OUR FORK, not upstream (operator directive, 2026-10-10): "we only need to fork the repo
# and use our forked version". A fork is the same object store as upstream, so the pinned commit below is
# reachable in the fork unchanged, and if upstream is deleted, renamed or force-pushes, the pin still
# resolves. The upstream each fork came from is recorded on the line so provenance is never lost.
GPLAYAPI_REPO='https://github.com/Zapier-codes/GPlayApi.git'  # our fork of whyorean/GPlayApi; GPL-3.0-or-later
GPLAYAPI_SHA='e90581facaccfd53f424c60ba84ce316bc67f3d3'       # 2020-11-08
PLAYSTOREAPI_REPO='https://github.com/Zapier-codes/playstoreapi.git' # our fork of AbhiTheModder/playstoreapi; parent BSD
PLAYSTOREAPI_SHA='ac57f327172ee609100cff3b3414e81dbf5c78a9'   # 2026-05-28

want="${1:-both}"
fetch() {
  local name="$1" repo="$2" sha="$3"
  [[ $want == both || $want == "$name" ]] || return 0
  mkdir -p "$dest"
  if [[ ! -d "$dest/$name/.git" ]]; then
    echo "cloning $name"
    git clone -q "$repo" "$dest/$name"
  else
    git -C "$dest/$name" fetch -q --all
  fi
  git -C "$dest/$name" checkout -q --detach "$sha"
  printf '%s\n%s\n%s\n' "$repo" "$sha" "$(git -C "$dest/$name" log -1 --format=%cI)" \
    > "$dest/$name/VENDORED"
  echo "vendored $name at $sha -> $dest/$name"
}

fetch gplayapi     "$GPLAYAPI_REPO"     "$GPLAYAPI_SHA"
fetch playstoreapi "$PLAYSTOREAPI_REPO" "$PLAYSTOREAPI_SHA"

echo
echo "Done. Commit vendor/play/ with the adapter. The pins are in this file; do not edit a vendored tree."
