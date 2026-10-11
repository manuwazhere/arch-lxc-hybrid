#!/usr/bin/env bash
# Prepara l'host Proxmox (idempotente): controlla il driver i915, carica uinput,
# imposta i permessi dei nodi GPU. Non modifica mai la cmdline del kernel.
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
: "${CARD_MODE:=0660}"

# --- Driver della iGPU ---------------------------------------------------------
found_i915=0
for d in /sys/class/drm/card*; do
  [[ ${d##*/} =~ ^card[0-9]+$ ]] || continue
  [[ -r $d/device/vendor && $(<"$d/device/vendor") == 0x8086 ]] || continue
  [[ -L $d/device/driver ]] || continue
  drv=$(basename "$(readlink -f "$d/device/driver")")
  case $drv in
    i915) found_i915=1 ;;
    xe) die "La iGPU Intel usa il driver 'xe' (${d##*/}): su questa scheda causa reset del motore grafico. Togli dalla cmdline del kernel xe.force_probe, i915.force_probe=! e xe.max_vfs, poi riavvia l'host." ;;
  esac
done
((found_i915)) || warn "Nessuna iGPU Intel con driver i915 rilevata: controlla l'host prima di proseguire."

if grep -qE '(xe|i915)\.(force_probe|max_vfs)=' /proc/cmdline; then
  warn "La cmdline del kernel contiene parametri force_probe/max_vfs per xe/i915: con i915 non dovrebbero esserci."
fi

# --- uinput -----------------------------------------------------------------------
log "Modulo uinput"
modprobe uinput
printf 'uinput\n' >/etc/modules-load.d/uinput.conf

# --- Permessi dei nodi GPU ------------------------------------------------------------
RULE=/etc/udev/rules.d/99-dri-permissions.rules
new=$(printf 'SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"\nSUBSYSTEM=="drm", KERNEL=="card*", MODE="%s"' "$CARD_MODE")
if [[ ! -f $RULE || $(<"$RULE") != "$new" ]]; then
  log "Regola udev DRI (card*: $CARD_MODE, renderD*: 0666)"
  printf '%s\n' "$new" >"$RULE"
  udevadm control --reload
  udevadm trigger -s drm
  udevadm settle
else
  log "Regola udev DRI già a posto"
fi

log "Nodi GPU sull'host:"
stat -c '  %A %U:%G %n' /dev/dri/* /dev/uinput
