#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/logging.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [DATA_FILE or GLOB]
Reads TSV/CSV and creates missing labels only (idempotent).
DATA_FILE can be a concrete path or a glob like TSV_HERE/*.tsv

Env:
  DATA_FILE (optional)  used if no positional arg

Examples:
  ./SCRIPTS/aa-labels.sh TSV_HERE/*.tsv
  DATA_FILE=TSV_HERE/PLANNERv9.1.tsv ./SCRIPTS/aa-labels.sh
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

DATA_SPEC="${1:-${DATA_FILE:-}}"
[[ -n "$DATA_SPEC" ]] || { echo "ERROR: provide DATA_FILE or glob (arg or env)."; usage; exit 1; }

# Resolve glob → pick latest mtime
shopt -s nullglob
matches=( $DATA_SPEC )
if (( ${#matches[@]} == 0 )); then
  echo "ERROR: no files match: $DATA_SPEC" >&2; exit 1
fi
if (( ${#matches[@]} > 1 )); then
  DATA_FILE="$(ls -1t "${matches[@]}" | head -n1)"
else
  DATA_FILE="${matches[0]}"
fi
shopt -u nullglob

DELIM=$'\t'; [[ "$DATA_FILE" == *.csv ]] && DELIM=','

# headers
IFS= read -r HEADER_LINE < "$DATA_FILE" || { echo "ERROR: empty file: $DATA_FILE"; exit 1; }
mapfile -t HEADERS < <(printf '%s' "$HEADER_LINE" | tr -d '\r' | awk -v FS="$DELIM" '{for(i=1;i<=NF;i++)print $i}')

# label columns (case-insensitive "*label*")
declare -a LABEL_IDXS=()
for i in "${!HEADERS[@]}"; do
  lh="${HEADERS[$i],,}"
  [[ "$lh" == *"label"* ]] && LABEL_IDXS+=("$i")
done
(( ${#LABEL_IDXS[@]} > 0 )) || { echo "No *label* columns found in $DATA_FILE"; exit 0; }

# collect labels from file (fresh parse)
declare -A NEED
while IFS= read -r line; do
  mapfile -t vals < <(
    printf '%s' "$line" | tr -d '\r' |
    awk -v FS="$DELIM" '{for(i=1;i<=NF;i++) print $i}'
  )
  for idx in "${LABEL_IDXS[@]}"; do
    v="${vals[$idx]:-}"
    # trim
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [[ -n "$v" ]] && NEED["$v"]=1
  done
done < <(tail -n +2 "$DATA_FILE")

# idempotent: list existing labels once
mapfile -t EXISTING < <(gh label list --json name -q '.[].name')
declare -A HAVE; for n in "${EXISTING[@]}"; do HAVE["$n"]=1; done

# create only missing (no color/description)
for label in "${!NEED[@]}"; do
  if [[ -n "${HAVE[$label]:-}" ]]; then
    echo "have: $label"
  else
    echo "create: $label"
    run_cmd gh label create "$label"
  fi
done

echo "labels done (source: $DATA_FILE)."
