#!/usr/bin/env bash
set -euo pipefail

# Load common helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

DATA_FILE="${1:?Usage: ab-issues.sh <TSV_FILE>}"

mkdir -p OUTPUTS
# Do NOT truncate OUTPUTS/errors.md here; workflow init step should create/clear it.
touch OUTPUTS/errors.md
: > OUTPUTS/issue_map.tsv  # fresh map for this run

normalize() {
  # lowercase, squeeze spaces
  tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^ | $//g'
}

sha12() {
  sha1sum | cut -c1-12
}

# ---- Header detection helpers ----
is_title_col() {
  local h="${1,,}"
  [[ "$h" =~ ^title$ ]] || [[ "$h" =~ ^issue[ _-]?title$ ]] || [[ "$h" == *"title"* ]]
}
is_body_col() {
  local h="${1,,}"
  [[ "$h" =~ ^body$ ]] || [[ "$h" =~ ^issue[ _-]?body$ ]] || [[ "$h" == *"body"* ]]
}
is_label_col() {
  local h="${1,,}"
  # allow obvious label columns only
  [[ "$h" =~ ^label(s)?$ ]] \
    || [[ "$h" =~ ^issue[_-]?label(_[0-9]+)?$ ]] \
    || [[ "$h" == labels* ]]
}
is_project_field_col() {
  local h="${1,,}"
  [[ "$h" =~ ^project(_)?field ]] \
    || [[ "$h" =~ ^project_field_ ]] \
    || [[ "$h" =~ ^project: ]] \
    || [[ "$h" =~ ^field: ]]
}
is_id_col() {
  local h="${1,,}"
  [[ "$h" =~ ^id$ ]] || [[ "$h" =~ ^issue[_-]?id$ ]] || [[ "$h" == *"external_id"* ]] || [[ "$h" == *"uid"* ]]
}

# ---- Parse header row ----
IFS=$'\t' read -r -a HEADERS < <(head -n1 "$DATA_FILE")

title_idx=-1
body_idx=-1
id_idx=-1
label_idxs=()

for i in "${!HEADERS[@]}"; do
  hdr="${HEADERS[$i]}"
  if [[ $title_idx -lt 0 ]] && is_title_col "$hdr"; then title_idx=$i; fi
  if [[ $body_idx -lt 0 ]]  && is_body_col  "$hdr"; then body_idx=$i; fi
  if [[ $id_idx   -lt 0 ]] && is_id_col    "$hdr"; then id_idx=$i; fi
  if is_label_col "$hdr" && ! is_project_field_col "$hdr"; then
    label_idxs+=("$i")
  fi
done

if [[ $title_idx -lt 0 ]]; then
  echo "ERROR: No title column found in TSV header." >&2
  exit 1
fi

# ---- Process rows ----
tail -n +2 "$DATA_FILE" | while IFS=$'\t' read -r -a ROW || [[ -n "${ROW[*]-}" ]]; do
  TITLE="${ROW[$title_idx]-}"
  [[ -z "${TITLE// }" ]] && continue

  RAW_ID=""
  if [[ $id_idx -ge 0 ]]; then
    RAW_ID="${ROW[$id_idx]-}"
  fi

  BODY_CONTENT=""
  if [[ $body_idx -ge 0 ]]; then
    BODY_CONTENT="${ROW[$body_idx]-}"
  fi

  # Build UID: prefer explicit ID, else hash of normalized title
  if [[ -n "${RAW_ID// }" ]]; then
    UID="$(printf '%s' "$RAW_ID" | normalize)"
    UID="${UID// /-}"
  else
    UID="$(printf '%s' "$TITLE" | normalize | sha12)"
  fi
  KEY_LABEL="imp-key-$UID"

  # Compose label list from allowed columns
  labels=()
  for idx in "${label_idxs[@]}"; do
    val="${ROW[$idx]-}"
    [[ -z "${val// }" ]] && continue
    labels+=("$val")
  done

  # Idempotency check (existing issue with this key label)
  existing_num="$(gh issue list --repo "$GH_REPO" \
                  --search "label:$KEY_LABEL" \
                  --json number --jq '.[0].number' 2>/dev/null || true)"

  if [[ -n "$existing_num" ]]; then
    # Get URL for map (best-effort)
    existing_url="$(gh issue view "$existing_num" --repo "$GH_REPO" --json url --jq '.url' 2>/dev/null || true)"
    printf "%s\t%s\t%s\n" "$TITLE" "${existing_url:-}" "$existing_num" >> OUTPUTS/issue_map.tsv
    echo "Skip (idempotent): '$TITLE' already exists as #$existing_num"
    continue
  fi

  # Create issue
  tmp_body="$(mktemp)"
  printf "%s" "${BODY_CONTENT:-}" > "$tmp_body"

  # Ensure key label exists (non-blocking)
  safe "label.create:$KEY_LABEL" \
    gh label create "$KEY_LABEL" --repo "$GH_REPO" --color "ededed" --description "Import idempotency key"

  # Build label args
  # Always include the key label; append any user labels
  create_args=(--repo "$GH_REPO" --title "$TITLE" --body-file "$tmp_body" --json number,url --jq '.number+" "+.url')
  all_labels=("$KEY_LABEL" "${labels[@]:-}")
  if [[ ${#all_labels[@]} -gt 0 ]]; then
    # Deduplicate labels quickly
    declare -A seen=()
    dedup=()
    for l in "${all_labels[@]}"; do
      [[ -n "${seen[$l]-}" ]] && continue
      seen[$l]=1
      dedup+=("$l")
    done
    IFS=, read -r -a _ <<< "" # reset IFS array parsing just in case
    create_args+=(--label "$(IFS=,; echo "${dedup[*]}")")
  fi

  # Execute create (non-blocking error capture)
  create_out=""
  if ! create_out="$(gh issue create "${create_args[@]}")"; then
    log_error "issue.create:$TITLE" "gh issue create failed"
    rm -f "$tmp_body"
    continue
  fi
  rm -f "$tmp_body"

  new_num="$(awk '{print $1}' <<<"$create_out")"
  new_url="$(awk '{print $2}' <<<"$create_out")"

  # Map it
  printf "%s\t%s\t%s\n" "$TITLE" "$new_url" "$new_num" >> OUTPUTS/issue_map.tsv

  echo "Created: '$TITLE' (#$new_num)"
done
