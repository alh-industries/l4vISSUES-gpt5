#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Scan ALL issues in the repo and formally link children found in each parent's
task list (- [ ] / - [x]) via GitHub's Sub-issues REST API.

Usage: $(basename "$0") [--repo OWNER/REPO] [--state all|open|closed] [--replace] [--dry-run]

Options (all optional; defaults shown):
  --repo OWNER/REPO    Target repo (default: GH_REPO or GITHUB_REPOSITORY)
  --state all|open|closed   Which issues to scan (default: all)
  --replace            If a child already has a parent, re-parent to this parent (default: false)
  --dry-run            Show what would be linked; no changes (default: false)
  -h, --help           Show help

Env:
  GH_TOKEN or GITHUB_TOKEN   Token used by 'gh api' (Actions provides GITHUB_TOKEN)
  GH_REPO                    OWNER/REPO fallback if --repo omitted
EOF
}

# ---- defaults
STATE="all"
REPLACE="false"
DRYRUN="false"
GH_REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
API_VER="2022-11-28"

# ---- parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) GH_REPO="$2"; shift 2;;
    --state) STATE="$2"; shift 2;;
    --replace) REPLACE="true"; shift;;
    --dry-run) DRYRUN="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

[[ -n "${GH_REPO:-}" ]] || { echo "ERROR: set --repo or GH_REPO/GITHUB_REPOSITORY"; exit 1; }
command -v gh >/dev/null || { echo "ERROR: gh CLI not found"; exit 1; }

owner="${GH_REPO%/*}"
repo="${GH_REPO#*/}"
echo "Repo: $GH_REPO | State: $STATE | replace_parent=$REPLACE | dry_run=$DRYRUN"

TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT

# Small helper: polite rate-limit pause when near empty (best-effort)
check_rate() {
  local remaining reset
  if read -r remaining reset < <(gh api rate_limit --jq '.resources.core.remaining, .resources.core.reset' 2>/dev/null); then
    if (( remaining < 5 )); then
      local now epoch wait
      now="$(date +%s)"; epoch="${reset:-$now}"
      wait=$(( epoch - now + 2 ))
      (( wait > 0 )) && { echo "Rate limit low; sleeping ${wait}s…"; sleep "$wait"; }
    fi
  fi
}

# Extract issue mentions (#123 or owner/repo#123) ONLY from task-list lines
extract_tasklist_refs() {
  # stdin: full parent body
  grep -Ei '^[[:space:]]*[-*][[:space:]]*\[[[:space:]]*[x ]\][[:space:]]' \
  | grep -Eo '([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' \
  | sed 's/[[:space:]]//g' \
  | sort -u || true
}

# Get internal DB id for issue owner/repo#num
get_issue_id() {
  local own="$1" rep="$2" num="$3"
  gh api -H "X-GitHub-Api-Version: ${API_VER}" \
    "/repos/${own}/${rep}/issues/${num}" --jq .id
}

# Get a best-effort set of already-formally-linked children for parent (as OWNER/REPO#NUM)
list_existing_children() {
  local pnum="$1"
  local tmp="$TMPDIR/existing_${pnum}.txt"
  if gh api -H "X-GitHub-Api-Version: ${API_VER}" \
       "/repos/${GH_REPO}/issues/${pnum}/sub_issues" \
       --jq '.[] | "\(.repository_url)|\(.number)"' > "$tmp" 2>/dev/null; then
    sed -E 's|.*/repos/([^/]+)/([^/]+)/issues$|\1/\2|' "$tmp" \
      | awk -F'|' '{print $1"#"$2}' \
      | sort -u
  fi
}

# Link child (by internal id) to parent number
link_child_formal() {
  local parent_num="$1" child_id="$2"
  gh api -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: ${API_VER}" \
    "/repos/${GH_REPO}/issues/${parent_num}/sub_issues" \
    -f sub_issue_id="$child_id" \
    -f replace_parent="$REPLACE" >/dev/null
}

# Process a single potential parent issue
process_parent() {
  local pnum="$1"
  # Fetch body to decide if it even has task lists
  local body_file="$TMPDIR/body_${pnum}.txt"
  if ! gh api -H "X-GitHub-Api-Version: ${API_VER}" \
        "/repos/${GH_REPO}/issues/${pnum}" --jq .body > "$body_file" 2>/dev/null; then
    echo "skip: cannot read #$pnum"
    return
  fi

  # Extract candidate refs from task lists
  mapfile -t candidates < <(extract_tasklist_refs < "$body_file")
  [[ ${#candidates[@]} -gt 0 ]] || { echo "no task-list refs in #$pnum"; return; }

  # Existing formal children to skip
  mapfile -t existing < <(list_existing_children "$pnum" || true)
  # Put existing into an associative set
  declare -A EXIST=()
  for e in "${existing[@]:-}"; do EXIST["$e"]=1; done

  local linked_count=0
  for token in "${candidates[@]}"; do
    # Normalize token to OWNER/REPO#NUM (if "#123" assume current repo)
    local child_full
    if [[ "$token" =~ ^#([0-9]+)$ ]]; then
      child_full="${owner}/${repo}${token}"
    else
      child_full="$token"
    fi

    local child_owner="${child_full%%/*}"
    local rest="${child_full#*/}"   # repo#num
    local child_repo="${rest%%#*}"
    local child_num="${rest##*#}"

    # Basic guards
    [[ "$child_num" =~ ^[0-9]+$ ]] || { echo "  skip non-numeric: $child_full"; continue; }
    if [[ "$child_owner/$child_repo" == "$owner/$repo" && "$child_num" == "$pnum" ]]; then
      echo "  skip self-link: $child_full"
      continue
    fi
    # Formal sub-issues require same OWNER (org/user)
    if [[ "$child_owner" != "$owner" ]]; then
      echo "  skip different owner: $child_full (parent owner: $owner)"
      continue
    fi
    # Already linked?
    if [[ -n "${EXIST[${child_owner}/${child_repo}#${child_num}]:-}" ]]; then
      echo "  already linked: ${child_owner}/${child_repo}#${child_num}"
      continue
    fi

    # Resolve internal id and link
    check_rate
    if ! cid="$(get_issue_id "$child_owner" "$child_repo" "$child_num")"; then
      echo "  skip not found/inaccessible: ${child_owner}/${child_repo}#${child_num}"
      continue
    fi

    echo "  link ${child_owner}/${child_repo}#${child_num} -> $GH_REPO#$pnum (replace_parent=$REPLACE)"
    if [[ "$DRYRUN" == "true" ]]; then
      continue
    fi
    if link_child_formal "$pnum" "$cid"; then
      ((linked_count++))
    else
      echo "  ! link failed (continuing)"
    fi
    sleep 1
  done

  if [[ "$DRYRUN" == "true" ]]; then
    echo "dry-run: #$pnum done"
  else
    echo "linked $linked_count new child(ren) for #$pnum"
  fi
}

# ---- enumerate ALL issues (exclude PRs) with pagination
per=100
page=1
total_parents=0
while :; do
  mapfile -t batch < <(
    gh api -H "X-GitHub-Api-Version: ${API_VER}" \
      "/repos/${GH_REPO}/issues?state=${STATE}&per_page=${per}&page=${page}" \
      --jq '.[] | select(.pull_request|not) | .number' 2>/dev/null || true
  )
  [[ ${#batch[@]} -gt 0 ]] || break
  for num in "${batch[@]}"; do
    ((total_parents++))
    echo "== Parent #$num =="
    process_parent "$num"
  done
  ((page++))
done

echo "Scan complete. Parents processed: $total_parents"
[[ "$DRYRUN" == "true" ]] && echo "Note: dry-run performed; no changes were made."
