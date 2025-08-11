#!/usr/bin/env bash
set -euo pipefail

# Load common helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

DATA_FILE="${1:?Usage: ac-subissues.sh <TSV_FILE>}"
PARENT_MAP="${PARENT_MAP:-OUTPUTS/issue_map.tsv}"  # Title \t URL \t Number

mkdir -p OUTPUTS
touch OUTPUTS/errors.md
: > OUTPUTS/subissue_map.tsv

normalize() {
  tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/ /g;s/^ | $//g'
}
sha12() { sha1sum | cut -c1-12; }

# ---- Header detection helpers (match ab-issues.sh) ----
is_title_col() { local h="${1,,}"; [[ "$h" =~ ^title$ || "$h" =~ ^issue[ _-]?title$ || "$h" == *"title"* ]]; }
is_body_col()  { local h="${1,,}"; [[ "$h" =~ ^body$  || "$h" =~ ^issue[ _-]?body$  || "$h" == *"body"*  ]]; }
is_label_col() {
  local h="${1,,}"
  [[ "$h" =~ ^label(s)?$ ]] || [[ "$h" =~ ^issue[_-]?label(_[0-9]+)?$ ]] || [[ "$h" == labels* ]]
}
is_project_field_col() {
  local h="${1,,}"
  [[ "$h" =~ ^project(_)?field ]] || [[ "$h" =~ ^project_field_ ]] || [[ "$h" =~ ^project: ]] || [[ "$h" =~ ^field: ]]
}

# ---- Load parent map (Title -> Number) ----
declare -A TITLE_TO_NUM
if [[ -f "$PARENT_MAP" ]]; then
  # Expect: Title \t URL \t Number
  while IFS=$'\t' read -r t _ n; do
    [[ -z "${t// }" || -z "${n// }" ]] && continue
    TITLE_TO_NUM["$t"]="$n"
  done < <(tail -n +1 "$PARENT_MAP")
else
  echo "ERROR: Parent map not found at $PARENT_MAP" >&2
  exit 1
fi

# ---- Parse TSV header ----
IFS=$'\t' read -r -a HEADERS < <(head -n1 "$DATA_FILE")
title_idx=-1; body_idx=-1; label_idxs=()

for i in "${!HEADERS[@]}"; do
  hdr="${HEADERS[$i]}"
  if [[ $title_idx -lt 0 ]] && is_title_col "$hdr"; then title_idx=$i; fi
  if [[ $body_idx  -lt 0 ]] && is_body_col  "$hdr";  then body_idx=$i;  fi
  if is_label_col "$hdr" && ! is_project_field_col "$hdr"; then
    label_idxs+=("$i")
  fi
done

if [[ $title_idx -lt 0 ]]; then
  echo "ERROR: No title column found in TSV header." >&2
  exit 1
fi
# body is needed for sub-issue tokens
if [[ $body_idx -lt 0 ]]; then
  echo "WARN: No body column found; no sub-issues to create." >&2
  exit 0
fi

# ---- Process each parent row ----
tail -n +2 "$DATA_FILE" | while IFS=$'\t' read -r -a ROW || [[ -n "${ROW[*]-}" ]]; do
  PARENT_TITLE="${ROW[$title_idx]-}"
  [[ -z "${PARENT_TITLE// }" ]] && continue

  PARENT_NUM="${TITLE_TO_NUM[$PARENT_TITLE]-}"
  if [[ -z "$PARENT_NUM" ]]; then
    log_error "subissues.parent_lookup:$PARENT_TITLE" "no parent number in $PARENT_MAP"
    continue
  fi

  BODY_CONTENT="${ROW[$body_idx]-}"
  [[ -z "${BODY_CONTENT// }" ]] && continue

  # Build label list from row (filtering out project-field-ish headers; id keys are filtered later)
  row_labels=()
  for idx in "${label_idxs[@]}"; do
    val="${ROW[$idx]-}"
    [[ -z "${val// }" ]] && continue
    row_labels+=("$val")
  done

  # Extract sub-issue tokens: split on ';'
  IFS=';' read -r -a TOKENS <<< "$BODY_CONTENT"

  for raw_token in "${TOKENS[@]}"; do
    SUB_TITLE="$(printf '%s' "$raw_token" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "${SUB_TITLE// }" ]] && continue

    # --- Sub-issue UID & key label (derived from parent title + sub title) ---
    parent_norm="$(printf '%s' "$PARENT_TITLE" | normalize)"
    sub_norm="$(printf '%s' "$SUB_TITLE" | normalize)"
    SUB_UID="$(printf '%s|%s' "$parent_norm" "$sub_norm" | sha12)"
    SUB_KEY="imp-key-$SUB_UID"

    # Idempotency check: existing issue with this key
    existing="$(gh issue list --repo "$GH_REPO" \
                --search "label:$SUB_KEY" \
                --json number --jq '.[0].number' 2>/dev/null || true)"

    if [[ -n "$existing" ]]; then
      # best-effort URL
      ex_url="$(gh issue view "$existing" --repo "$GH_REPO" --json url --jq '.url' 2>/dev/null || true)"
      printf "%s\t%s\t%s\t%s\n" "$PARENT_TITLE" "$SUB_TITLE" "${ex_url:-}" "$existing" >> OUTPUTS/subissue_map.tsv
      echo "Skip (idempotent): sub-issue '$SUB_TITLE' exists as #$existing (parent #$PARENT_NUM)"
      # Ensure checklist link exists (optional, idempotent append)
      # (We won't fail if we can't patch the body)
      parent_body="$(gh issue view "$PARENT_NUM" --repo "$GH_REPO" --json body --jq '.body' 2>/dev/null || echo "")"
      line="- [ ] $SUB_TITLE (#$existing)"
      if ! grep -Fqx "$line" <<<"$parent_body"; then
        new_body="$parent_body"$'\n'"$line"
        safe "parent.body.append:#$PARENT_NUM:$SUB_TITLE" gh issue edit "$PARENT_NUM" --repo "$GH_REPO" --body "$new_body"
      fi
      continue
    fi

    # --- Build labels for the sub-issue: inherit row labels, filtering ---
    inherit=()
    for L in "${row_labels[@]}"; do
      [[ "$L" == imp-key-* ]] && continue
      [[ "$L" =~ ^PROJECT_FIELD_ ]] && continue
      inherit+=("$L")
    done
    # always include the sub key label
    all_labels=("$SUB_KEY" "${inherit[@]}")

    # Ensure key label exists (non-blocking)
    safe "label.create:$SUB_KEY" \
      gh label create "$SUB_KEY" --repo "$GH_REPO" --color "ededed" --description "Import idempotency key"

    # Create sub-issue
    create_args=(--repo "$GH_REPO" --title "$SUB_TITLE" --json number,url --jq '.number+" "+.url')
    if [[ ${#all_labels[@]} -gt 0 ]]; then
      # dedupe
      declare -A seen=(); dedup=()
      for l in "${all_labels[@]}"; do
        [[ -n "${seen[$l]-}" ]] && continue; seen[$l]=1; dedup+=("$l")
      done
      create_args+=(--label "$(IFS=,; echo "${dedup[*]}")")
    fi

    out=""
    if ! out="$(gh issue create "${create_args[@]}")"; then
      log_error "subissue.create:$PARENT_TITLE->$SUB_TITLE" "gh issue create failed"
      continue
    fi
    sub_num="$(awk '{print $1}' <<<"$out")"
    sub_url="$(awk '{print $2}' <<<"$out")"

    # Link in parent checklist (idempotent append)
    parent_body="$(gh issue view "$PARENT_NUM" --repo "$GH_REPO" --json body --jq '.body' 2>/dev/null || echo "")"
    line="- [ ] $SUB_TITLE (#$sub_num)"
    if ! grep -Fqx "$line" <<<"$parent_body"; then
      new_body="$parent_body"$'\n'"$line"
      safe "parent.body.append:#$PARENT_NUM:$SUB_TITLE" gh issue edit "$PARENT_NUM" --repo "$GH_REPO" --body "$new_body"
    fi

    # Map it
    printf "%s\t%s\t%s\t%s\n" "$PARENT_TITLE" "$SUB_TITLE" "$sub_url" "$sub_num" >> OUTPUTS/subissue_map.tsv
    echo "Created sub-issue '$SUB_TITLE' (#$sub_num) under parent #$PARENT_NUM"
  done
done
