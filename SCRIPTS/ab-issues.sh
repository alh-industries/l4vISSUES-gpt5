#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/logging.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [DATA_FILE or GLOB]
Creates issues from a TSV. Idempotent via OUTPUTS/issue_map.tsv.

Env:
  DATA_FILE (optional)  used if no positional arg

Outputs:
  OUTPUTS/issue_map.tsv   (Title \t URL \t Number)

Examples:
  ./SCRIPTS/ab-issues.sh TSV_HERE/*.tsv
  DATA_FILE=TSV_HERE/PLANNERv9.1.tsv ./SCRIPTS/ab-issues.sh
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

DATA_SPEC="${1:-${DATA_FILE:-}}"
[[ -n "$DATA_SPEC" ]] || { echo "ERROR: provide DATA_FILE or glob (arg or env)."; usage; exit 1; }

# Resolve glob → first match
shopt -s nullglob
matches=( $DATA_SPEC )
(( ${#matches[@]} )) || { echo "ERROR: no files match: $DATA_SPEC" >&2; exit 1; }
DATA_FILE="${matches[0]}"
shopt -u nullglob

DELIM=$'\t'

mkdir -p OUTPUTS
MAP_OUT="OUTPUTS/issue_map.tsv"
touch "$MAP_OUT"

# load existing titles for idempotency
declare -A HAVE_TITLE=()
while IFS=$'\t' read -r t _; do
  [[ -n "$t" ]] && HAVE_TITLE["$t"]=1
done < "$MAP_OUT"

# headers
IFS= read -r HEADER_LINE < "$DATA_FILE" || { echo "ERROR: empty file: $DATA_FILE"; exit 1; }
mapfile -t HEADERS < <(printf '%s' "$HEADER_LINE" | tr -d '\r' | awk -v FS="$DELIM" '{for(i=1;i<=NF;i++)print $i}')

# find indices by substring (case-insensitive)
TITLE_IDX=-1; BODY_IDX=-1; declare -a LABEL_IDXS=()
for i in "${!HEADERS[@]}"; do
  lh="${HEADERS[$i],,}"
  (( TITLE_IDX < 0 )) && [[ "$lh" == *"title"* ]] && TITLE_IDX=$i
  (( BODY_IDX  < 0 )) && [[ "$lh" == *"body"*  ]] && BODY_IDX=$i
  [[ "$lh" == *"label"* ]] && LABEL_IDXS+=("$i")
done
(( TITLE_IDX >= 0 )) || { echo "ERROR: no *title* column found in $DATA_FILE"; exit 1; }

TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT

while IFS= read -r line; do
  mapfile -t vals < <(
    printf '%s' "$line" | tr -d '\r' |
    awk -v FS="$DELIM" '{for(i=1;i<=NF;i++) print $i}'
  )

  title="${vals[$TITLE_IDX]:-}"
  [[ -z "$title" ]] && { echo "skip: empty title"; continue; }
  if [[ -n "${HAVE_TITLE[$title]:-}" ]]; then
    echo "skip existing: $title"
    continue
  fi

  # labels
  label_args=()
  for idx in "${LABEL_IDXS[@]}"; do
    v="${vals[$idx]:-}"
    # trim
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [[ -n "$v" ]] && label_args+=("--label" "$v")
  done

  # body verbatim via --body-file
  body_file="$TMPDIR/body.txt"
  if (( BODY_IDX >= 0 )); then
    # write exact bytes; no transforms
    printf '%s' "${vals[$BODY_IDX]}" > "$body_file"
  else
    : > "$body_file"
  fi

  echo "create: $title"
  url="$(run_cmd gh issue create --title "$title" --body-file "$body_file" "${label_args[@]}")"
  if [[ -z "$url" ]]; then
    echo "warn: failed to create issue: $title (see OUTPUTS/errors.md)" >&2
    continue
  fi
  num="$(basename "$url")"
  printf "%s\t%s\t%s\n" "$title" "$url" "$num" >> "$MAP_OUT"
  HAVE_TITLE["$title"]=1

  # soften rate limits
  sleep 1
done < <(tail -n +2 "$DATA_FILE")

echo "issues done (source: $DATA_FILE). map: $MAP_OUT"

