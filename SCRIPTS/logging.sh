#!/usr/bin/env bash
set -E

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ERROR_LOG_FILE="$script_dir/../OUTPUTS/errors.md"

mkdir -p "$(dirname "$ERROR_LOG_FILE")"
touch "$ERROR_LOG_FILE"

log_error() {
  local exit_code="$1"
  local line="$2"
  local cmd="$3"
  local err="${4:-}"
  {
    printf '[%s] %s: line %s: exit %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$0" "$line" "$exit_code" "$cmd"
    [[ -n "$err" ]] && printf '%s\n' "$err"
  } >> "$ERROR_LOG_FILE"
  return 0
}

trap 'log_error $? $LINENO "$BASH_COMMAND"' ERR

run_cmd() {
  local lineno=${BASH_LINENO[0]}
  local output
  if ! output=$("$@" 2>&1); then
    log_error $? "$lineno" "$*" "$output"
    return 0
  else
    printf '%s\n' "$output"
  fi
}
