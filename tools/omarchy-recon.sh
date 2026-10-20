#!/usr/bin/env bash
# Reconnaissance for the Omarchy layer. READ-ONLY: installs nothing, changes nothing
# (it only clones Omarchy into a temp dir and queries pacman and the AUR).
#
# Run it inside the container, as root or as the user:
#   pct exec <CTID> -- bash -s -- [REF] < tools/omarchy-recon.sh      # from the Proxmox host
#   bash omarchy-recon.sh [REF]                                       # inside the CT
# REF is an Omarchy tag or branch (default v4.0.6). The report is also saved to
# ~/omarchy-recon-<REF>.txt (override with OUT=/path).
set -Eeuo pipefail

REF=${1:-v4.0.6}
OUT=${OUT:-$HOME/omarchy-recon-$REF.txt}
REPO=https://github.com/omacom/omarchy.git

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for c in git curl pacman; do command -v "$c" >/dev/null || die "$c not found"; done
HAVE_JQ=1
command -v jq >/dev/null || { HAVE_JQ=0; warn "jq not found: the AUR lookup is skipped (pacman -S jq)."; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
log "Cloning Omarchy $REF (shallow)"
git -c advice.detachedHead=false clone -q --depth 1 -b "$REF" "$REPO" "$TMP/omarchy" || die "Cannot clone $REF from $REPO"
SRC=$TMP/omarchy

{
  echo "Omarchy recon: ref=$REF commit=$(git -C "$SRC" rev-parse --short HEAD) date=$(date +%F)"
  echo "container: $(pacman -Q linux 2>/dev/null || uname -r), arch=$(uname -m)"
  echo

  # ---- 1. Packages: official / AUR / neither ------------------------------------------------
  for list in omarchy-base omarchy-other omarchy-x86_64-only; do
    f=$SRC/install/$list.packages
    [[ -f $f ]] || { echo "## $list.packages: not present in $REF"; echo; continue; }
    mapfile -t pkgs < <(grep -vE '^\s*(#|$)' "$f" | awk '{print $1}' | sort -u)
    official=() other=() aur=() unknown=()
    for p in "${pkgs[@]}"; do
      if pacman -Si "$p" &>/dev/null; then official+=("$p"); else other+=("$p"); fi
    done
    if ((${#other[@]})) && ((HAVE_JQ)); then
      for ((i = 0; i < ${#other[@]}; i += 100)); do
        args=()
        for p in "${other[@]:i:100}"; do args+=(--data-urlencode "arg[]=$p"); done
        mapfile -t found < <(curl -fsS -G "https://aur.archlinux.org/rpc/v5/info" "${args[@]}" | jq -r '.results[].Name' || true)
        aur+=("${found[@]}")
      done
      for p in "${other[@]}"; do
        printf '%s\n' "${aur[@]}" | grep -qxF "$p" || unknown+=("$p")
      done
    else
      unknown=("${other[@]}")
    fi
    echo "## $list.packages: ${#pkgs[@]} total = ${#official[@]} official + ${#aur[@]} AUR + ${#unknown[@]} neither"
    ((${#aur[@]})) && echo "   AUR:     ${aur[*]}"
    ((${#unknown[@]})) && echo "   NEITHER (Omarchy's own repo?): ${unknown[*]}"
    echo
  done

  # ---- 2. How Omarchy adds its own pacman repo ----------------------------------------------
  echo "## Omarchy pacman repo / keyring references (install/, etc/, bin/):"
  grep -rnE 'mirror\.omarchy\.org|omarchy-keyring|\[omarchy\]|pacman-key' "$SRC/install" "$SRC/etc" "$SRC/bin" 2>/dev/null \
    | sed "s|^$SRC/||" | head -15 || true
  echo

  # ---- 3. Which commands depend on things the container does not have -----------------------
  nbin=$(find "$SRC/bin" -maxdepth 1 -type f | wc -l)
  echo "## bin/: $nbin commands. Dependence on bare-metal / installer-only pieces:"
  for k in 'uwsm' 'ufw' 'snapper' 'limine' 'plymouth' 'sddm' 'nmcli|iwctl|impala' \
    'bluetoothctl|bluetui' 'powerprofilesctl' 'docker' 'brightnessctl' 'hyprsunset' 'pacman' 'yay'; do
    mapfile -t hits < <(grep -lE "$k" "$SRC"/bin/* 2>/dev/null | xargs -r -n1 basename || true)
    printf '  %-26s %3d  %s\n' "$k" "${#hits[@]}" "$(printf '%s ' "${hits[@]:0:8}")"
  done
} 2>&1 | tee "$OUT"

log "Report saved to $OUT"
