#!/usr/bin/env bash
# Prepares the Proxmox host (idempotent): checks the i915 driver, loads uinput,
# sets the permissions of the GPU device nodes. Never touches the kernel cmdline.
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
: "${CARD_MODE:=0660}"

# --- iGPU driver ----------------------------------------------------------------
found_i915=0
for d in /sys/class/drm/card*; do
  [[ ${d##*/} =~ ^card[0-9]+$ ]] || continue
  [[ -r $d/device/vendor && $(<"$d/device/vendor") == 0x8086 ]] || continue
  [[ -L $d/device/driver ]] || continue
  drv=$(basename "$(readlink -f "$d/device/driver")")
  case $drv in
    i915) found_i915=1 ;;
    xe) die "The Intel iGPU uses the 'xe' driver (${d##*/}): on this card it caused graphics engine resets. Remove xe.force_probe, i915.force_probe=! and xe.max_vfs from the host kernel cmdline, then reboot the host." ;;
  esac
done
((found_i915)) || warn "No Intel iGPU with the i915 driver found: check the host before going on."

if grep -qE '(xe|i915)\.(force_probe|max_vfs)=' /proc/cmdline; then
  warn "The kernel cmdline has force_probe/max_vfs parameters for xe/i915: with i915 they should not be there."
fi

# --- uinput -----------------------------------------------------------------------
log "uinput module"
modprobe uinput
printf 'uinput\n' >/etc/modules-load.d/uinput.conf

# --- GPU device node permissions ------------------------------------------------------
RULE=/etc/udev/rules.d/99-dri-permissions.rules
new=$(printf 'SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"\nSUBSYSTEM=="drm", KERNEL=="card*", MODE="%s"' "$CARD_MODE")
if [[ ! -f $RULE || $(<"$RULE") != "$new" ]]; then
  log "DRI udev rule (card*: $CARD_MODE, renderD*: 0666)"
  printf '%s\n' "$new" >"$RULE"
  udevadm control --reload
  udevadm trigger -s drm
  udevadm settle
else
  log "DRI udev rule already in place"
fi

log "GPU nodes on the host:"
stat -c '  %A %U:%G %n' /dev/dri/* /dev/uinput
