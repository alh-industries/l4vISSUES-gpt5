#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/logging.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [DATA_FILE or GLOB]
Ensures project fields/options exist (idempotent) and applies values to each item.

Env:
  PROJECT_OWNER (optional)   defaults to GH_REPO owner
  PROJECT_NUMBER (optional)  numeric project id; defaults to OUTPUTS/project_number.txt
  DATA_FILE (optional)       used if no positional arg
  PARENT_MAP (optional)      default OUTPUTS/issue_map.tsv

Notes:
  - Recognizes headers: PROJECT_FIELD_*[:TYPE]
    TYPE: SINGLE_SELECT | DATE | (default) TEXT
  - Matches row to project item by *title* via PARENT_MAP (Title \\t URL \\t Number).
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

if [[ -z "${PROJECT_OWNER:-}" ]]; then
  if [[ -n "${GH_REPO:-}" ]]; then
    PROJECT_OWNER="${GH_REPO%%/*}"
  else
    echo "ERROR: Set PROJECT_OWNER or GH_REPO" >&2
    exit 1
  fi
fi

# Determine project number from env or output file (idempotent default)
if [[ -z "${PROJECT_NUMBER:-}" ]]; then
  if [[ -f OUTPUTS/project_number.txt ]]; then
    PROJECT_NUMBER="$(<OUTPUTS/project_number.txt)"
  else
    echo "ERROR: Set PROJECT_NUMBER or run ad-project.sh to create OUTPUTS/project_number.txt" >&2
    exit 1
  fi
fi

PARENT_MAP="${PARENT_MAP:-OUTPUTS/issue_map.tsv}"

resolve_data_file() {
  local spec="$1"
  shopt -s nullglob
  local matches
  readarray -t matches < <(compgen -G "$spec")
  (( ${#matches[@]} > 0 )) || { echo "ERROR: no files match: $spec" >&2; exit 1; }
  local latest
  # shellcheck disable=SC2012
  latest=$(ls -1t "${matches[@]}" | head -n1)
  printf '%s\n' "$latest"
  shopt -u nullglob
}

DATA_SPEC="${1:-${DATA_FILE:-}}"
[[ -n "$DATA_SPEC" ]] || { echo "ERROR: provide DATA_FILE or glob (arg or env)."; usage; exit 1; }
[[ -f "$PARENT_MAP" ]] || { echo "ERROR: missing $PARENT_MAP (run ab-issues.sh & ad-project.sh)"; exit 1; }

DATA_FILE="$(resolve_data_file "$DATA_SPEC")"

DELIM=$'\t'; [[ "$DATA_FILE" == *.csv ]] && DELIM=','

# ---- Build URL -> itemId map from the project (fresh) ----
declare -A URL2ITEM
ITEMS_JSON="$(mktemp)"; trap 'rm -f "$ITEMS_JSON"' EXIT
gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json > "$ITEMS_JSON"

while read -r url id; do
  [[ -n "$url" && -n "$id" ]] && URL2ITEM["$url"]="$id"
done < <(jq -r '.items.nodes[]? | select(.content.url != null) | "\(.content.url) \(.id)"' "$ITEMS_JSON")


# Ensure an issue URL exists in the project; return item id (idempotent)
ensure_item () {
  local url="$1"
  local id="${URL2ITEM[$url]:-}"
  if [[ -z "$id" ]]; then
    gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$url" >/dev/null
    # refresh map minimally to fetch this item's id
    gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json > "$ITEMS_JSON"
    id="$(jq -r --arg u "$url" '.items.nodes[]? | select(.content != null and .content.url==$u) | .id' "$ITEMS_JSON" | head -n1)"
    [[ -n "$id" ]] && URL2ITEM["$url"]="$id"
  fi
  printf '%s' "$id"
}

# ---- Headers & detect field columns ----
IFS= read -r HEADER_LINE < "$DATA_FILE" || { echo "ERROR: empty file: $DATA_FILE"; exit 1; }
mapfile -t HEADERS < <(printf '%s' "$HEADER_LINE" | tr -d '\r' | awk -v FS="$DELIM" '{for(i=1;i<=NF;i++)print $i}')

TITLE_IDX=-1
declare -a PF_IDXS=() PF_NAMES=() PF_TYPES=()

get_field_name(){ local h="$1"; echo "${h#PROJECT_FIELD_}" | awk -F':' '{print $1}'; }
get_field_type(){ local h="$1"; [[ "$h" == *:* ]] && echo "${h##*:}" || echo "TEXT"; }

for i in "${!HEADERS[@]}"; do
  hdr="${HEADERS[$i]}"
  (( TITLE_IDX < 0 )) && [[ "${hdr,,}" == *"title"* ]] && TITLE_IDX=$i
  if [[ "$hdr" == PROJECT_FIELD_* ]]; then
    PF_IDXS+=("$i")
    PF_NAMES+=("$(get_field_name "$hdr")")
    PF_TYPES+=("$(get_field_type "$hdr")")
  fi
done
(( TITLE_IDX >= 0 )) || { echo "ERROR: no *title* column in $DATA_FILE"; exit 1; }

# ---- Cache fields json for idempotent checks ----
FIELDS_JSON="$(mktemp)"; trap 'rm -f "$FIELDS_JSON"' RETURN
gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json > "$FIELDS_JSON"

ensure_field(){
  local name="$1" type="$2"
  local j="$3"
  jq -e --arg n "$name" '.fields[] | select(.name==$n)' "$FIELDS_JSON" >/dev/null && return 0
  echo "create field: $name ($type)"
  if [[ "$type" == "SINGLE_SELECT" ]]; then
    # For single select, we need to gather all possible options from the data file first.
    local options_string
    options_string=$(cut -d "$DELIM" -f $((PF_IDXS[j]+1)) < "$DATA_FILE" | tail -n +2 | sort -u | paste -sd "," -)
    gh project field-create "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --name "$name" --data-type "$type" --single-select-options "$options_string" >/dev/null
  else
    gh project field-create "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --name "$name" --data-type "$type" >/dev/null
  fi
  gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json > "$FIELDS_JSON"
}

# ---- Ensure fields exist (idempotent) ----
for j in "${!PF_IDXS[@]}"; do
  fname="${PF_NAMES[$j]}"; ftype="${PF_TYPES[$j]}"
  ensure_field "$fname" "$ftype" "$j"
done

# ---- Build Title -> URL from parent map ----
declare -A TITLE2URL
while IFS=$'\t' read -r t u _; do
  [[ -n "$t" && -n "$u" ]] && TITLE2URL["$t"]="$u"
done < "$PARENT_MAP"

# ---- Apply values to items ----
while IFS= read -r line; do
  mapfile -t vals < <(
    printf '%s' "$line" | tr -d '\r' |
    awk -v FS="$DELIM" '{for(i=1;i<=NF;i++) print $i}'
  )
  title="${vals[$TITLE_IDX]:-}"
  [[ -z "$title" ]] && continue

  url="${TITLE2URL[$title]:-}"
  [[ -z "$url" ]] && { echo "skip (no project item for title): $title"; continue; }

  item_id="$(ensure_item "$url")"
  [[ -n "$item_id" ]] || { echo "skip (no item id): $title"; continue; }

  for j in "${!PF_IDXS[@]}"; do
    idx="${PF_IDXS[$j]}"; fname="${PF_NAMES[$j]}"; ftype="${PF_TYPES[$j]}"
    val="${vals[$idx]:-}"
    [[ -z "$val" ]] && continue

    case "$ftype" in
      SINGLE_SELECT)
        gh project item-edit --id "$item_id" --field-name "$fname" --single-select-option-name "$val" >/dev/null
        ;;
      DATE)
        gh project item-edit --id "$item_id" --field-name "$fname" --date "$val" >/dev/null
        ;;
      *)
        gh project item-edit --id "$item_id" --field-name "$fname" --text "$val" >/dev/null
        ;;
    esac
    sleep 0.2
  done
done < <(tail -n +2 "$DATA_FILE")

echo "project fields applied (source: $DATA_FILE)."
