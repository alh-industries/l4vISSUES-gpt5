#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ERROR_LOG_FILE="$script_dir/../OUTPUTS/errors.md"
INFO_LOG_FILE="$script_dir/../OUTPUTS/info.md" 


mkdir -p "$(dirname "$ERROR_LOG_FILE")"
touch "$ERROR_LOG_FILE"
touch "$INFO_LOG_FILE"


# Add a separator to the error log at the beginning of each run
printf -- '---\n' >> "$ERROR_LOG_FILE"

log_info() {
    printf -- '[%s] [INFO] %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$INFO_LOG_FILE"
}

log_error() {
  local exit_code="$1"
  local line="$2"
  local cmd="$3"
  local err="${4:-}"
  {
    printf -- '- [%s] source: %s/%s | script: %s | line: %s | exit: %s | cmd: %s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" \
      "${GITHUB_WORKFLOW:-local}" \
      "${GITHUB_JOB:-local}" \
      "$0" \
      "$line" \
      "$exit_code" \
      "$cmd"
    
    [[ -n "$err" ]] && printf '%s\n' "$err"
    printf '\n'
  } >> "$ERROR_LOG_FILE"
  return "$exit_code"
}

trap 'log_error $? $LINENO "$BASH_COMMAND"' ERR

run_cmd() {
  local lineno=${BASH_LINENO[0]}
  local output
  if ! output=$("$@" 2>&1); then
    log_error $? "$lineno" "$*" "$output"
    return 1
  else
    printf '%s\n' "$output"
  fi
}
