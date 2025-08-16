#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/logging.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [DATA_FILE or GLOB]
Creates sub-issues from the parent row's body by splitting on ';'.
Inherits labels from the row. Links child issues in the parent's body.
Idempotent via OUTPUTS/subissue_map.tsv.

Env:
  DATA_FILE  (optional) used if no positional arg
  PARENT_MAP (optional) defaults to OUTPUTS/issue_map.tsv

Outputs:
  OUTPUTS/subissue_map.tsv  (ParentTitle \\t ChildTitle \\t ChildURL \\t ChildNumber)
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

PARENT_MAP="${PARENT_MAP:-OUTPUTS/issue_map.tsv}"

DATA_SPEC="${1:-${DATA_FILE:-}}"
[[ -n "$DATA_SPEC" ]] || { echo "ERROR: provide DATA_FILE or glob (arg or env)."; usage; exit 1; }

# Resolve glob -> choose latest mtime
shopt -s nullglob
matches=( $DATA_SPEC )
(( ${#matches[@]} > 0 )) || { echo "ERROR: no files match: $DATA_SPEC" >&2; exit 1; }
if (( ${#matches[@]} > 1 )); then
  DATA_FILE="$(ls -1t "${matches[@]}" | head -n1)"
else
  DATA_FILE="${matches[0]}"
fi
shopt -u nullglob

[[ -f "$PARENT_MAP" ]] || { echo "ERROR: missing parent map: $PARENT_MAP (run ab-issues.sh first)"; exit 1; }

DELIM=$'\t'; [[ "$DATA_FILE" == *.csv ]] && DELIM=','

mkdir -p OUTPUTS
SUBMAP_OUT="OUTPUTS/subissue_map.tsv"
touch "$SUBMAP_OUT"

# load existing parent:child mappings
declare -A HAVE_PAIR=()
while IFS=$'\t' read -r pt ct _ _; do
  [[ -n "$pt" && -n "$ct" ]] && HAVE_PAIR["$pt:$ct"]=1
done < "$SUBMAP_OUT"

# Load parent map Title -> {URL, Number}
declare -A T2URL T2NUM
while IFS=$'\t' read -r t u n; do
  [[ -z "${t:-}" ]] && continue
  T2URL["$t"]="$u"
  T2NUM["$t"]="$n"
done < "$PARENT_MAP"

# Headers
IFS= read -r HEADER_LINE < "$DATA_FILE" || { echo "ERROR: empty file: $DATA_FILE"; exit 1; }
mapfile -t HEADERS < <(printf '%s' "$HEADER_LINE" | tr -d '\r' | awk -v FS="$DELIM" '{for(i=1;i<=NF;i++)print $i}')

TITLE_IDX=-1; BODY_IDX=-1; declare -a LABEL_IDXS=()
for i in "${!HEADERS[@]}"; do
  lh="${HEADERS[$i],,}"
  (( TITLE_IDX < 0 )) && [[ "$lh" == *"title"* ]] && TITLE_IDX=$i
  (( BODY_IDX  < 0 )) && [[ "$lh" == *"body"*  ]] && BODY_IDX=$i
  [[ "$lh" == *"label"* ]] && LABEL_IDXS+=("$i")
done
(( TITLE_IDX >= 0 && BODY_IDX >= 0 )) || { echo "ERROR: need *title* and *body* columns"; exit 1; }

TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT

# Process rows
while IFS= read -r line; do
  mapfile -t vals < <(
    printf '%s' "$line" | tr -d '\r' |
    awk -v FS="$DELIM" '{for(i=1;i<=NF;i++) print $i}'
  )

  ptitle="${vals[$TITLE_IDX]:-}"
  [[ -z "$ptitle" ]] && { echo "skip: empty parent title"; continue; }

  purl="${T2URL[$ptitle]:-}"; pnum="${T2NUM[$ptitle]:-}"
  [[ -z "$purl" || -z "$pnum" ]] && { echo "skip: parent not found in map: $ptitle"; continue; }

  body_raw="${vals[$BODY_IDX]:-}"
  IFS=';' read -r -a subs <<< "$body_raw"

  # inherit labels
  label_args=()
  for idx in "${LABEL_IDXS[@]}"; do
    v="${vals[$idx]:-}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [[ -n "$v" ]] && label_args+=("--label" "$v")
  done

  for token in "${subs[@]}"; do
    st="$(printf '%s' "$token" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$st" ]] && continue
    key="$ptitle:$st"
    if [[ -n "${HAVE_PAIR[$key]:-}" ]]; then
      echo "skip existing sub-issue: $key"
      continue
    fi

    echo "create sub-issue: $st"
    curl="$(gh issue create --title "$st" --body "" "${label_args[@]}")"
    cnum="$(basename "$curl")"
    printf "%s\t%s\t%s\t%s\n" "$ptitle" "$st" "$curl" "$cnum" >> "$SUBMAP_OUT"
    HAVE_PAIR["$key"]=1

    # Attach to parent via task list
    pbody="$TMPDIR/p.txt"
    gh issue view "$pnum" --json body -q '.body' > "$pbody"
    printf '\n- [ ] %s (#%s)\n' "$st" "$cnum" >> "$pbody"
    gh issue edit "$pnum" --body-file "$pbody"

    sleep 1
  done
done < <(tail -n +2 "$DATA_FILE")

echo "sub-issues done (source: $DATA_FILE). map: $SUBMAP_OUT"

