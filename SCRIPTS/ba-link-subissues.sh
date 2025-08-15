#!/usr/bin/env bash
#
# ba-link-subissues.sh
# Scan issues in GH_REPO, find task-list references to issues (#123 or owner/repo#123),
# and formally link them as sub-issues of the parent issue.
#
# Requires: GitHub CLI (`gh`) authenticated with a token that can write issues.
# Uses only `gh api` + `--jq`, no external `jq` dependency.
#
# Exit codes:
#  0 success
#  2 bad usage
#  3 missing prerequisites / env
#  4 API error (hard failure; most per-issue errors are soft and logged)

set -Eeuo pipefail
source "$(dirname "$0")/logging.sh"


# rich trace with timestamps, line numbers, and the exact command that failed
PS4='+ [${EPOCHREALTIME}] ${BASH_SOURCE##*/}:${LINENO}: ${FUNCNAME[0]:-main}: '
set -x
trap 'ec=$?; echo "::error file=${BASH_SOURCE[0]},line=${LINENO}::${BASH_COMMAND} (exit $ec)"; exit $ec' ERR

echo "gh version: $(gh --version 2>&1)"
echo "gh auth status:"
gh auth status || { echo "::error ::gh auth not ok"; }

echo "Current REST rate limit:"
gh api rate_limit | jq -r '.resources.core | "limit=\(.limit) remaining=\(.remaining) reset=\(.reset)"' || true


# ------------ defaults (overridable via env or flags) -------------------------
API_VER="${API_VER:-2022-11-28}"        # GitHub REST API version
STATE="${STATE:-open}"                  # open|closed|all
REPLACE="${REPLACE:-false}"             # "true" or "false" for replace_parent
DRYRUN="${DRYRUN:-false}"               # "true" to log actions only
PAGE_SIZE="${PAGE_SIZE:-100}"           # pagination size for issues listing
PARENT_ISSUE="${PARENT_ISSUE:-}"        # if set, process only this parent number
LOG_LEVEL="${LOG_LEVEL:-info}"          # debug|info|warn|error

# -----------------------------------------------------------------------------

usage() {
  cat <<'USAGE'
Usage:
  ba-link-subissues.sh [options]

Options (all optional; env vars shown in [] can also be used):
  -s, --state <open|closed|all>      Scan issues by state           [STATE]
  -r, --replace <true|false>         replace_parent when linking    [REPLACE]
      --dry-run                      Do not POST; log intended ops  [DRYRUN=true]
  -p, --page-size <n>                Issues page size (default 100) [PAGE_SIZE]
  -i, --issue <num>                  Process only this parent       [PARENT_ISSUE]
  -A, --api-version <ver>            REST API version               [API_VER]
  -L, --log-level <lvl>              debug|info|warn|error          [LOG_LEVEL]
  -h, --help                         Show help

Environment:
  GH_REPO (required) e.g. "OWNER/REPO"
  GH_TOKEN (normally provided to gh by Actions)
USAGE
}

# --------------------------- logging helpers ---------------------------------
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
lvl_num() {
  case "${1,,}" in
    debug) echo 10;;
    info)  echo 20;;
    warn)  echo 30;;
    error) echo 40;;
    *)     echo 20;;
  esac
}
LOG_CUR="$(lvl_num "$LOG_LEVEL")"
log() {
  local lvl="$1"; shift
  local n="$(lvl_num "$lvl")"
  (( n < LOG_CUR )) && return 0
  printf '%s %-5s %s\n' "$(_ts)" "${lvl^^}" "$*" >&2
}
die() { log error "$*"; exit 4; }

# --------------------------- prerequisites -----------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { log error "Missing command: $1"; exit 3; }; }

# --------------------------- arg parsing -------------------------------------
parse_args() {
  local opt
  while (( $# )); do
    opt="$1"; shift
    case "$opt" in
      -s|--state) STATE="${1:-}"; shift;;
      -r|--replace) REPLACE="${1:-}"; shift;;
      --dry-run) DRYRUN="true";;
      -p|--page-size) PAGE_SIZE="${1:-}"; shift;;
      -i|--issue) PARENT_ISSUE="${1:-}"; shift;;
      -A|--api-version) API_VER="${1:-}"; shift;;
      -L|--log-level) LOG_LEVEL="${1:-}"; LOG_CUR="$(lvl_num "$LOG_LEVEL")";;
      -h|--help) usage; exit 0;;
      *) log error "Unknown option: $opt"; usage; exit 2;;
    esac
  done
}

# --------------------------- rate limiting -----------------------------------
# Sleep until reset if we're nearly out of requests. Best-effort.
check_rate() {
  local remaining reset now wait
  if read -r remaining reset < <(gh api rate_limit --jq '.resources.core.remaining, .resources.core.reset' 2>/dev/null); then
    if (( remaining < 5 )); then
      now="$(date +%s)"
      wait=$(( reset - now + 2 ))
      (( wait > 0 )) && { log warn "Rate limit low; sleeping ${wait}s…"; sleep "$wait"; }
    fi
  fi
}

# --------------------------- helpers -----------------------------------------
require_env() {
  [[ -n "${GH_REPO:-}" ]] || { log error "GH_REPO is required (OWNER/REPO)"; exit 3; }
  [[ "$REPLACE" =~ ^(true|false)$ ]] || { log error "REPLACE must be true|false"; exit 2; }
  [[ "$STATE" =~ ^(open|closed|all)$ ]] || { log error "STATE must be open|closed|all"; exit 2; }
  [[ "$DRYRUN" =~ ^(true|false)$ ]] || { log error "DRYRUN must be true|false"; exit 2; }
  [[ "$PAGE_SIZE" =~ ^[1-9][0-9]*$ ]] || { log error "PAGE_SIZE must be a positive integer"; exit 2; }
}

owner_of() { echo "${1%/*}"; }
repo_of()  { echo "${1#*/}"; }

# Extract issue refs ONLY from GitHub task list lines in a body.
# Matches:
#   - "#123"
#   - "owner/repo#123"
extract_tasklist_refs() {
  # stdin: issue body
  # shellcheck disable=SC2016
  grep -Ei '^[[:space:]]*[-*][[:space:]]*\[[[:space:]]*[x ]\][[:space:]]' \
    | grep -Eo '([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' \
    | sed 's/[[:space:]]//g' \
    | sort -u || true
}

# Return internal DB id for OWNER REPO NUM
get_issue_id() {
  local own="$1" rep="$2" num="$3"
  gh api -H "X-GitHub-Api-Version: ${API_VER}" \
    "/repos/${own}/${rep}/issues/${num}" \
    --jq '.id'
}

# List already linked children for a parent issue number as "OWNER/REPO#NUM"
list_existing_children() {
  local parent_num="$1"
  # repository_url ends with ".../repos/OWNER/REPO"
  gh api -H "X-GitHub-Api-Version: ${API_VER}" \
    "/repos/${GH_REPO}/issues/${parent_num}/sub_issues" \
    --jq '.[] | "\(.repository_url)|\(.number)"' 2>/dev/null \
    | sed -E 's|.*/repos/([^/]+)/([^/]+)\||\1/\2#|' \
    | sort -u || true
}

# POST formal link
link_child_formal() {
  local parent_num="$1" child_id="$2"
  gh api -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: ${API_VER}" \
    "/repos/${GH_REPO}/issues/${parent_num}/sub_issues" \
    -F sub_issue_id="$child_id" \
    -F replace_parent="$REPLACE" >/dev/null
}

# Process a single parent issue
process_parent() {
  local pnum="$1"
  log info "Parent #$pnum"

  # Read body
  local body
  if ! body="$(gh api -H "X-GitHub-Api-Version: ${API_VER}" \
         "/repos/${GH_REPO}/issues/${pnum}" --jq '.body // ""' 2>/dev/null)"; then
    log warn "  cannot read body; skipping"
    return 0
  fi

  # Gather candidates from task list
  mapfile -t candidates < <(printf '%s\n' "$body" | extract_tasklist_refs)
  if (( ${#candidates[@]} == 0 )); then
    log debug "  no task-list references"
    return 0
  fi

  # Already-linked set
  mapfile -t existing < <(list_existing_children "$pnum")
  declare -A EXIST=()
  for e in "${existing[@]:-}"; do [[ -n "$e" ]] && EXIST["$e"]=1; done

  local owner parent_owner child_repo child_num child_owner cid linked=0
  parent_owner="$(owner_of "$GH_REPO")"
  for token in "${candidates[@]}"; do
    # Normalize to OWNER/REPO#NUM
    local full
    if [[ "$token" =~ ^#([0-9]+)$ ]]; then
      full="$(owner_of "$GH_REPO")/$(repo_of "$GH_REPO")${token}"
    else
      full="$token"
    fi

    child_owner="${full%%/*}"; local rest="${full#*/}"
    child_repo="${rest%%#*}"; child_num="${rest##*#}"

    # Guards
    [[ "$child_num" =~ ^[0-9]+$ ]] || { log debug "  skip non-numeric: $full"; continue; }
    if [[ "$child_owner/$child_repo" == "$GH_REPO" && "$child_num" == "$pnum" ]]; then
      log debug "  skip self-link: $full"; continue
    fi
    # Sub-issues must be within the same OWNER (org/user)
    if [[ "$child_owner" != "$parent_owner" ]]; then
      log debug "  skip different owner: $full (parent owner: $parent_owner)"; continue
    fi
    if [[ -n "${EXIST[${child_owner}/${child_repo}#${child_num}]:-}" ]]; then
      log debug "  already linked: ${child_owner}/${child_repo}#${child_num}"; continue
    fi

    # Resolve internal id
    check_rate
    if ! cid="$(get_issue_id "$child_owner" "$child_repo" "$child_num" 2>/dev/null)"; then
      log warn "  cannot resolve id: ${child_owner}/${child_repo}#${child_num}"
      continue
    fi

    log info "  link ${child_owner}/${child_repo}#${child_num} -> ${GH_REPO}#${pnum} (replace_parent=${REPLACE})"
    if [[ "$DRYRUN" == "true" ]]; then
      continue
    fi
    if link_child_formal "$pnum" "$cid"; then
      ((++linked))
      # update EXIST set to avoid duplicates in same run
      EXIST["${child_owner}/${child_repo}#${child_num}"]=1
      # be gentle to API
      sleep 1
    else
      log warn "  link failed (continuing)"
    fi
  done

  if [[ "$DRYRUN" == "true" ]]; then
    log info "  dry-run complete for #$pnum"
  else
    log info "  linked $linked new child(ren) for #$pnum"
  fi
}

# Enumerate parent issues (PRs excluded)
scan_all_parents() {
  local page=1
  local total=0
  local n
  local i
  while :; do
    mapfile -t nums < <(
      gh api -H "X-GitHub-Api-Version: ${API_VER}" \
        "/repos/${GH_REPO}/issues?state=${STATE}&per_page=${PAGE_SIZE}&page=${page}" \
        --jq '.[] | select(.pull_request|not) | .number' 2>/dev/null || true
    )
    (( ${#nums[@]} )) || break
    for (( i=0; i<${#nums[@]}; i++ )); do
      n="${nums[$i]}"
      ((++total))
      process_parent "$n"
    done
    ((page++))
  done
  log info "Scan complete. Parents processed: $total"
  [[ "$DRYRUN" == "true" ]] && log info "Note: dry-run performed; no changes were made."
}

# --------------------------- main --------------------------------------------
main() {
  need gh
  parse_args "$@"
  require_env

  log info "Repo: ${GH_REPO} | state=${STATE} | replace_parent=${REPLACE} | dry_run=${DRYRUN} | api=${API_VER}"
  gh auth status >/dev/null 2>&1 || log warn "gh not authenticated? (gh auth status failed)"

  if [[ -n "$PARENT_ISSUE" ]]; then
    [[ "$PARENT_ISSUE" =~ ^[0-9]+$ ]] || { log error "--issue must be a number"; exit 2; }
    process_parent "$PARENT_ISSUE"
    log info "Done (single issue)."
  else
    scan_all_parents
  fi
  # Dry-run path: emit a NOTICE annotation and succeed.
  if [[ "${DRYRUN,,}" == "true" ]]; then
  # Try to show the count if your scan code set one
    _count="${PARENT_COUNT:-${parents_processed:-unknown}}"
    echo "::notice file=${BASH_SOURCE[0]},line=$LINENO,title=Dry-run::Scan complete. Parents processed: ${_count}"
    exit 0
  fi

}

main "$@"
