# shellcheck shell=bash
# Funzioni comuni (log, errori, attese). Da includere con `source`.

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERRORE:\033[0m %s\n' "$*" >&2; exit 1; }

# wait_for <secondi> <descrizione> <comando...>
# Ripete il comando (anche una funzione di shell) ogni 2 s finché riesce.
wait_for() {
  local timeout=$1 desc=$2 i
  shift 2
  for ((i = 0; i < timeout; i += 2)); do
    if "$@" &>/dev/null; then return 0; fi
    sleep 2
  done
  warn "Timeout (${timeout}s) in attesa di: ${desc}"
  return 1
}
