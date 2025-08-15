#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/logging.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0")
Creates or reuses a non-classic GitHub Project, then adds all parent/sub issues.

Env (all via env vars):
  PROJECT_OWNER (required)  @me or org name
  PROJECT_TITLE (required)  project title to create or reuse
  PARENT_MAP    (optional)  default OUTPUTS/issue_map.tsv
  SUBMAP        (optional)  default OUTPUTS/subissue_map.tsv

Outputs:
  OUTPUTS/project_number.txt  (project number for downstream steps)
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

: "${PROJECT_OWNER:?Set PROJECT_OWNER (@me or org)}"
: "${PROJECT_TITLE:?Set PROJECT_TITLE}"
PARENT_MAP="${PARENT_MAP:-OUTPUTS/issue_map.tsv}"
SUBMAP="${SUBMAP:-OUTPUTS/subissue_map.tsv}"

[[ -f "$PARENT_MAP" ]] || { echo "ERROR: missing $PARENT_MAP (run ab-issues.sh first)"; exit 1; }
[[ -f "$SUBMAP" ]] || echo "Note: $SUBMAP not found; will add parents only."

mkdir -p OUTPUTS

# ----- Find or create project (idempotent) -----
proj_num=$(
  gh project list --owner "$PROJECT_OWNER" --format json \
  | jq -r --arg t "$PROJECT_TITLE" '.projects[] | select(.title==$t) | .number' \
  | head -n1
)

if [[ -z "$proj_num" ]]; then
  proj_num=$(
    gh project create --owner "$PROJECT_OWNER" --title "$PROJECT_TITLE" --format json \
    | jq -r '.number'
  )
  echo "created project #$proj_num"
else
  echo "using project #$proj_num"
fi

echo "$proj_num" > OUTPUTS/project_number.txt

# ----- Link project to repository (optional, idempotent) -----
if [[ -n "${GH_REPO:-}" ]]; then
  linked_repo=$(gh project view "$proj_num" --owner "$PROJECT_OWNER" --format json \
    | jq -r --arg r "$GH_REPO" '.linkedRepositories[]?.nameWithOwner' \
    | grep -Fx "${GH_REPO}" || true)
  if [[ -n "$linked_repo" ]]; then
    echo "project already linked to $GH_REPO"
  else
    gh project link "$proj_num" --owner "$PROJECT_OWNER" --repo "$GH_REPO" >/dev/null
    echo "linked project to $GH_REPO"
  fi
fi

# ----- Build set of existing item URLs (avoid duplicate adds) -----
declare -A HAVE
mapfile -t existing_urls < <(
  gh project view "$proj_num" --owner "$PROJECT_OWNER" --format json \
  | jq -r '.items[]?.content?.url // empty'
)
for u in "${existing_urls[@]}"; do
  [[ -n "$u" ]] && HAVE["$u"]=1
done

add_item () {
  local url="$1"
  if [[ -n "${HAVE[$url]:-}" ]]; then
    echo "have item: $url"
  else
    gh project item-add "$proj_num" --owner "$PROJECT_OWNER" --url "$url" >/dev/null
    echo "added: $url"
    HAVE["$url"]=1
  fi
}

# ----- Add parent issues -----
while IFS=$'\t' read -r _ url _; do
  [[ -z "${url:-}" ]] && continue
  add_item "$url"; sleep 0.2
done < "$PARENT_MAP"

# ----- Add sub-issues (if file present) -----
if [[ -f "$SUBMAP" ]]; then
  while IFS=$'\t' read -r _ _ url _; do
    [[ -z "${url:-}" ]] && continue
    add_item "$url"; sleep 0.2
  done < "$SUBMAP"
fi

echo "project import done (#$proj_num). Output: OUTPUTS/project_number.txt"
