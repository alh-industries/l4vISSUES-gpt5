#!/usr/bin/env bash
# SCRIPTS/_common.sh
# Shared helpers: idempotency, error logging, header filters, small utils.

set -uo pipefail

# -------- Paths & files --------
OUTDIR="${OUTDIR:-OUTPUTS}"
ERRORS_FILE="${ERRORS_FILE:-$OUTDIR/errors.md}"

ensure_outputs() {
  mkdir -p "$OUTDIR"
  [[ -f "$ERRORS_FILE" ]] || : > "$ERRORS_FILE"
}

# -------- Error handling --------
timestamp_utc() { date -u +'%Y-%m-%d %H:%M:%S'; }

log_error() {
  # log_error "context" "details"
  ensure_outputs
  echo "- $(timestamp_utc) | $1 | $2" >> "$ERRORS_FILE"
}

safe() {
  # safe "context" cmd args...
  local ctx="$1"; shift
  if ! "$@"; then
    local code=$?
    log_error "$ctx" "exit=$code"
    return 0  # swallow error, continue
  fi
}

# -------- Text utils --------
normalize() { tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/ /g;s/^ | $//g'; }
sha12() { sha1sum | cut -c1-12; }

mk_uid_from_id_or_title() {
  # mk_uid_from_id_or_title "<id>" "<title>" -> echoes UID
  local raw_id="${1-}"; local title="${2-}"
  if [[ -n "${raw_id// }" ]]; then
    printf '%s' "$raw_id" | normalize | sed -E 's/ /-/g'
  else
    printf '%s' "$title" | normalize | sha12
  fi
}

# -------- Labels --------
dedup_labels() {
  # usage: dedup_labels "${arr[@]}"; echoes CSV of unique labels
  declare -A seen=(); local out=()
  for l in "$@"; do
    [[ -z "${l// }" || -n "${seen[$l]-}" ]] && continue
    seen["$l"]=1; out+=("$l")
  done
  (IFS=,; echo "${out[*]}")
}

ensure_label() {
  # ensure_label "<name>" ["color" "#ededed"] ["desc" "Auto-created"]
  local name="$1"; local color="${2:-ededed}"; local desc="${3:-Auto-created label}"
  safe "label.create:$name" gh label create "$name" --repo "$GH_REPO" --color "$color" --description "$desc"
}

# -------- Header detection (shared) --------
is_title_col() {
  local h="${1,,}"
  [[ "$h" =~ ^title$ || "$h" =~ ^issue[ _-]?title$ || "$h" == *"title"* ]]
}
is_body_col() {
  local h="${1,,}"
  [[ "$h" =~ ^body$ || "$h" =~ ^issue[ _-]?body$ || "$h" == *"body"* ]]
}
is_id_col() {
  local h="${1,,}"
  [[ "$h" =~ ^id$ || "$h" =~ ^issue[ _-]?id$ || "$h" == *"external_id"* || "$h" == *"uid"* ]]
}
is_label_col() {
  local h="${1,,}"
  [[ "$h" =~ ^label(s)?$ ]] || [[ "$h" =~ ^issue[_-]?label(_[0-9]+)?$ ]] || [[ "$h" == labels* ]]
}
is_project_field_col() {
  local h="${1,,}"
  [[ "$h" =~ ^project(_)?field ]] || [[ "$h" =~ ^project_field_ ]] || [[ "$h" =~ ^project: ]] || [[ "$h" =~ ^field: ]]
}
