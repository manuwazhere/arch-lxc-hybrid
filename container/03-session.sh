#!/usr/bin/env bash
# Inside the container, as root: starts the Plasma session, detects the HDMI port
# (dummy plug), sets the resolution and waits for Sunshine to listen.
set -Eeuo pipefail
STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib.sh
source "$STAGE/lib.sh"
# shellcheck source=/dev/null
source "$STAGE/config.sh"
[[ $EUID -eq 0 ]] || die "This script must run as root inside the container."

UID_U=$(id -u "$CT_USER")
RT=/run/user/$UID_U

# kscreen-doctor as the user, with the environment of a graphical session.
kd() {
  runuser -u "$CT_USER" -- env HOME="/home/$CT_USER" XDG_RUNTIME_DIR="$RT" \
    WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" \
    kscreen-doctor "$@"
}
strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g'; }

# The DRM connector name (card1-HDMI-A-3) matches what KWin sees (HDMI-A-3).
# On the M90q the only HDMI port is the only "HDMI-A" connector: the USB-C ports with
# DP alt-mode and the DisplayPort show up as "DP-n", so the type is enough to tell them apart.
detect_connector() {
  local c name found=() connected=()
  for c in /sys/class/drm/card*-HDMI-A-*; do
    [[ -e $c ]] || continue
    name=${c##*/}
    name=${name#card*-}
    found+=("$name")
    if [[ $(<"$c/status") == connected ]]; then connected+=("$name"); fi
  done
  if ((${#connected[@]} == 1)); then
    echo "${connected[0]}"
  elif ((${#connected[@]} > 1)); then
    warn "Several HDMI outputs connected (${connected[*]}): using ${connected[0]}. Force CONNECTOR in config.sh if that is wrong."
    echo "${connected[0]}"
  elif ((${#found[@]} == 1)); then
    warn "Port ${found[0]} exists but reports disconnected: is the dummy plug inserted?"
    echo "${found[0]}"
  else
    warn "No HDMI-A port found in /sys/class/drm (found: ${found[*]:-none})."
    return 1
  fi
}

# --- Start the session ------------------------------------------------------------------
log "Starting plasma-session"
systemctl start plasma-session.service
wait_for 120 "KWin's Wayland socket" test -S "$RT/wayland-0" \
  || die "KWin did not start: see 'journalctl -u plasma-session -b' (card busy? dummy plug?)"

# --- Connector and resolution -------------------------------------------------------------
if [[ $CONNECTOR == auto ]]; then
  CONN=$(detect_connector) || die "Could not find the HDMI port: set CONNECTOR in config.sh."
else
  CONN=$CONNECTOR
fi
log "Video connector: $CONN"

has_output() { kd -o 2>/dev/null | strip_ansi | grep -qw "$CONN"; }
wait_for 60 "output $CONN visible to KWin" has_output \
  || warn "KWin does not list $CONN: the resolution may not be applied."

log "Setting $RESOLUTION on $CONN"
kd "output.${CONN}.mode.${RESOLUTION}" || warn "kscreen-doctor rejected the mode $RESOLUTION."
sleep 2
res=${RESOLUTION%@*}
hz=${RESOLUTION#*@}
if kd -o 2>/dev/null | strip_ansi | grep -Eq "[0-9]+:${res}@${hz}[0-9.]*\*"; then
  log "Active mode: $RESOLUTION"
else
  warn "Mode $RESOLUTION is not active (the dummy plug may not offer it). Visible modes:"
  kd -o 2>/dev/null | strip_ansi | grep -i 'modes' || true
fi

# --- Sunshine ------------------------------------------------------------------------------
sunshine_up() { ss -ltn | grep -q ':47990 '; }
if wait_for 90 "Sunshine listening on port 47990" sunshine_up; then
  log "Sunshine is up: https://${IP_CT}:47990"
else
  warn "Sunshine is not listening. Last lines of its log:"
  journalctl _SYSTEMD_USER_UNIT=app-dev.lizardbyte.app.Sunshine.service -n 30 --no-pager || true
fi
