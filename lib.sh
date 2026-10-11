# shellcheck shell=bash
# Shared helpers (logging, errors, waiting). Include with `source`.

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# wait_for <seconds> <description> <command...>
# Retries the command (shell functions work too) every 2 s until it succeeds.
wait_for() {
  local timeout=$1 desc=$2 i
  shift 2
  for ((i = 0; i < timeout; i += 2)); do
    if "$@" &>/dev/null; then return 0; fi
    sleep 2
  done
  warn "Timeout (${timeout}s) waiting for: ${desc}"
  return 1
}
