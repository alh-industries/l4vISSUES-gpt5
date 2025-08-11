#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [DATA_FILE or GLOB]
Creates issues from TSV/CSV. No idempotency (re-runs will create duplicates).

Env:
  GH_REPO   (required)  e.g. owner/repo
  DATA_FILE (optional)  used if no positional arg

Outputs:
  OUTPUTS/issue_map.tsv   (Title \\t URL \\t Number)

Examples:
  GH_REPO=owner/repo ./SCRIPTS/ab-issues.sh TSV_HERE/*.tsv
  GH_REPO=owner/repo DATA_FILE=TSV_HERE/PLANNERv9.1.tsv ./SCRIPTS/ab-issues.sh
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

: "${GH_REPO:?Set GH_REPO=owner/repo}"
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

GH_REPO_FLAG=(--repo "$GH_REPO")
DELIM=$'\t'; [[ "$DATA_FILE" == *.csv ]] && DELIM=','

mkdir -p OUTPUTS

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
MAP_OUT="OUTPUTS/issue_map.tsv"
: > "$MAP_OUT"

while IFS= read -r line; do
  mapfile -t vals < <(
    printf '%s' "$line" | tr -d '\r' |
    awk -v FS="$DELIM" '{for(i=1;i<=NF;i++) print $i}'
  )

  title="${vals[$TITLE_IDX]:-}"
  [[ -z "$title" ]] && { echo "skip: empty title"; continue; }

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
  url="$(gh "${GH_REPO_FLAG[@]}" issue create --title "$title" --body-file "$body_file" "${label_args[@]}")"
  num="$(basename "$url")"
  printf "%s\t%s\t%s\n" "$title" "$url" "$num" >> "$MAP_OUT"

  # soften rate limits
  sleep 1
done < <(tail -n +2 "$DATA_FILE")

echo "issues done (source: $DATA_FILE). map: $MAP_OUT"
