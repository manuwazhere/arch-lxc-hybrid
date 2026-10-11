#!/usr/bin/env bash
# Dentro il container, come root: avvia la sessione Plasma, rileva la porta HDMI
# (dummy plug), imposta la risoluzione e attende che Sunshine sia in ascolto.
set -Eeuo pipefail
STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib.sh
source "$STAGE/lib.sh"
# shellcheck source=/dev/null
source "$STAGE/config.sh"
[[ $EUID -eq 0 ]] || die "Questo script va eseguito come root nel container."

UID_U=$(id -u "$UTENTE")
RT=/run/user/$UID_U

# kscreen-doctor come utente, con l'ambiente di una sessione grafica.
kd() {
  runuser -u "$UTENTE" -- env HOME="/home/$UTENTE" XDG_RUNTIME_DIR="$RT" \
    WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" \
    kscreen-doctor "$@"
}
strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g'; }

# Il nome del connettore DRM (card1-HDMI-A-3) coincide con quello che vede KWin (HDMI-A-3).
# Sul M90q l'unica porta HDMI è l'unica di tipo "HDMI-A": le USB-C con DP alt-mode e la DP
# compaiono come "DP-n", quindi il tipo basta a distinguerla.
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
    warn "Più uscite HDMI collegate (${connected[*]}): uso ${connected[0]}. Forza CONNETTORE in config.sh se è sbagliata."
    echo "${connected[0]}"
  elif ((${#found[@]} == 1)); then
    warn "La porta ${found[0]} esiste ma risulta scollegata: il dummy plug è inserito?"
    echo "${found[0]}"
  else
    warn "Nessuna porta HDMI-A trovata in /sys/class/drm (trovate: ${found[*]:-nessuna})."
    return 1
  fi
}

# --- Avvio sessione ---------------------------------------------------------------------------
log "Avvio di plasma-session"
systemctl start plasma-session.service
wait_for 120 "socket Wayland di KWin" test -S "$RT/wayland-0" \
  || die "KWin non è partito: guarda 'journalctl -u plasma-session -b' (card occupata? dummy plug?)"

# --- Connettore e risoluzione --------------------------------------------------------------------
if [[ $CONNETTORE == auto ]]; then
  CONN=$(detect_connector) || die "Impossibile individuare la porta HDMI: imposta CONNETTORE in config.sh."
else
  CONN=$CONNETTORE
fi
log "Connettore video: $CONN"

has_output() { kd -o 2>/dev/null | strip_ansi | grep -qw "$CONN"; }
wait_for 60 "output $CONN visibile a KWin" has_output \
  || warn "KWin non elenca $CONN: la risoluzione potrebbe non essere applicata."

log "Imposto $RISOLUZIONE su $CONN"
kd "output.${CONN}.mode.${RISOLUZIONE}" || warn "kscreen-doctor ha rifiutato il modo $RISOLUZIONE."
sleep 2
res=${RISOLUZIONE%@*}
hz=${RISOLUZIONE#*@}
if kd -o 2>/dev/null | strip_ansi | grep -Eq "[0-9]+:${res}@${hz}[0-9.]*\*"; then
  log "Modo attivo: $RISOLUZIONE"
else
  warn "Il modo $RISOLUZIONE non risulta attivo (il dummy plug potrebbe non offrirlo). Modi visibili:"
  kd -o 2>/dev/null | strip_ansi | grep -i 'modes' || true
fi

# --- Sunshine --------------------------------------------------------------------------------------
sunshine_up() { ss -ltn | grep -q ':47990 '; }
if wait_for 90 "Sunshine in ascolto sulla porta 47990" sunshine_up; then
  log "Sunshine attivo: https://${IP_CT}:47990"
else
  warn "Sunshine non è in ascolto. Ultime righe del suo log:"
  journalctl _SYSTEMD_USER_UNIT=app-dev.lizardbyte.app.Sunshine.service -n 30 --no-pager || true
fi
