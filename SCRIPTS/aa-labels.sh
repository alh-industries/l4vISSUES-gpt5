#!/usr/bin/env bash
set -euo pipefail

# Load common helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

DATA_FILE="$1"

# Ensure outputs dir & error log exist
mkdir -p OUTPUTS
: > OUTPUTS/errors.md

# Header filters
is_label_col() {
  local hdr="${1,,}" # lowercase
  [[ "$hdr" =~ ^label(s)?$ ]] \
    || [[ "$hdr" =~ ^issue[_-]?label(_[0-9]+)?$ ]] \
    || [[ "$hdr" == labels* ]]
}

is_project_field_col() {
  local hdr="${1,,}"
  [[ "$hdr" =~ ^project(_)?field ]] \
    || [[ "$hdr" =~ ^project_field_ ]] \
    || [[ "$hdr" =~ ^project: ]] \
    || [[ "$hdr" =~ ^field: ]]
}

# Parse header row
IFS=$'\t' read -r -a headers < <(head -n1 "$DATA_FILE")
label_cols=()
for idx in "${!headers[@]}"; do
  if is_label_col "${headers[$idx]}" && ! is_project_field_col "${headers[$idx]}"; then
    label_cols+=("$idx")
  fi
done

if [[ ${#label_cols[@]} -eq 0 ]]; then
  echo "No label columns detected." >&2
  exit 0
fi

# Gather unique labels
declare -A seen_labels=()
tail -n +2 "$DATA_FILE" | while IFS=$'\t' read -r -a row; do
  for col_idx in "${label_cols[@]}"; do
    lbl="${row[$col_idx]}"
    [[ -z "$lbl" ]] && continue
    seen_labels["$lbl"]=1
  done
done

# Create labels if missing
for lbl in "${!seen_labels[@]}"; do
  safe "create label: $lbl" \
    gh label create "$lbl" \
      --repo "$GH_REPO" \
      --color "ededed" \
      --description "Auto-created label from import" \
    || true
done
