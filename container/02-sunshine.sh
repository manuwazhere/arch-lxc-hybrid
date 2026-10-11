#!/usr/bin/env bash
# Dentro il container, come root: installa sunshine-bin (AUR), configura capture = kwin,
# abilita il servizio utente per tutti gli utenti (parte con la sessione grafica).
set -Eeuo pipefail
STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib.sh
source "$STAGE/lib.sh"
# shellcheck source=/dev/null
source "$STAGE/config.sh"
[[ $EUID -eq 0 ]] || die "Questo script va eseguito come root nel container."

TMP_SUDOERS=/etc/sudoers.d/99-tmp-aur-build
cleanup() { rm -f "$TMP_SUDOERS"; }
trap cleanup EXIT

# --- Build dall'AUR (sudo senza password solo per la durata del build) ----------------
if pacman -Qi sunshine-bin &>/dev/null; then
  log "sunshine-bin già installato ($(pacman -Q sunshine-bin))"
else
  log "Build di sunshine-bin dall'AUR"
  echo "$UTENTE ALL=(ALL) NOPASSWD: ALL" >"$TMP_SUDOERS"
  chmod 440 "$TMP_SUDOERS"
  visudo -cf "$TMP_SUDOERS" >/dev/null
  runuser -u "$UTENTE" -- env HOME="/home/$UTENTE" bash "$STAGE/container/aur-build.sh"
  cleanup
fi

# --- Configurazione ---------------------------------------------------------------------------
log "Configurazione di Sunshine"
UGRP=$(id -gn "$UTENTE")
CONF_DIR=/home/$UTENTE/.config/sunshine
CONF=$CONF_DIR/sunshine.conf
install -d -o "$UTENTE" -g "$UGRP" "$CONF_DIR"
touch "$CONF"

set_kv() { # chiave valore
  if grep -qE "^$1\s*=" "$CONF"; then
    sed -i -E "s|^$1\s*=.*|$1 = $2|" "$CONF"
  else
    echo "$1 = $2" >>"$CONF"
  fi
}
set_kv capture kwin
set_kv csrf_allowed_origins "https://${IP_CT}:47990"
chown "$UTENTE:$UGRP" "$CONF"

# Servizio utente: parte con graphical-session.target (cioè con plasma-session).
UNIT=app-dev.lizardbyte.app.Sunshine.service
if [[ -f /usr/lib/systemd/user/$UNIT ]]; then
  systemctl --global enable "$UNIT" || warn "Impossibile abilitare $UNIT: abilitalo a mano con 'systemctl --user enable --now $UNIT'"
else
  warn "Unit utente $UNIT non trovata: controlla il pacchetto sunshine-bin."
fi

log "02-sunshine completato"
