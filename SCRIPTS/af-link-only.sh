#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/logging.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") PARENT_ISSUE CHILD_ISSUE [CHILD_ISSUE...]
Links each child issue to the parent by appending task list items.

Env:
  GH_REPO (required) e.g. owner/repo
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

: "${GH_REPO:?Set GH_REPO=owner/repo}"

(( $# >= 2 )) || { echo "ERROR: need parent and at least one child" >&2; usage; exit 1; }

parent="$1"; shift
children=("$@")

GH_REPO_FLAG=(--repo "$GH_REPO")

check_rate_limit() {
  local rem reset now wait
  rem=$(gh "${GH_REPO_FLAG[@]}" api rate_limit --jq '.resources.core.remaining')
  reset=$(gh "${GH_REPO_FLAG[@]}" api rate_limit --jq '.resources.core.reset')
  now=$(date +%s)
  if (( rem < 1 )); then
    wait=$(( reset - now + 5 ))
    (( wait > 0 )) && { echo "hit primary rate limit, sleeping $wait" >&2; sleep "$wait"; }
  fi
}

tmpfile="$(mktemp)"; trap 'rm -f "$tmpfile"' EXIT

check_rate_limit
# Fetch parent body
gh "${GH_REPO_FLAG[@]}" issue view "$parent" --json body -q '.body' > "$tmpfile"

for child in "${children[@]}"; do
  check_rate_limit
  ctitle=$(gh "${GH_REPO_FLAG[@]}" issue view "$child" --json title -q '.title')
  printf '\n- [ ] %s (#%s)\n' "$ctitle" "$child" >> "$tmpfile"
  sleep 2 # avoid secondary rate limiting
done

check_rate_limit
gh "${GH_REPO_FLAG[@]}" issue edit "$parent" --body-file "$tmpfile"

log INFO "linked ${#children[@]} issue(s) to parent #$parent"
