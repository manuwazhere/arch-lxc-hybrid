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

as_user() { runuser -u "$UTENTE" -- env HOME="/home/$UTENTE" "$@"; }

# --- Build dall'AUR (sudo senza password solo per la durata di questi passi) -----------
log "Sudo senza password temporaneo per le build AUR"
echo "$UTENTE ALL=(ALL) NOPASSWD: ALL" >"$TMP_SUDOERS"
chmod 440 "$TMP_SUDOERS"
visudo -cf "$TMP_SUDOERS" >/dev/null

build_aur() { # pacchetto
  if pacman -Qi "$1" &>/dev/null; then
    log "$1 già installato ($(pacman -Q "$1"))"
  else
    log "Build di $1 dall'AUR"
    as_user bash "$STAGE/container/aur-build.sh" "$1"
  fi
}

# yay-bin e sunshine-bin con makepkg (Sunshine così tiene il pin e il PKGBUILD nel log);
# da qui in poi `yay -Syu` li aggiorna entrambi.
if ((INSTALL_AUR_HELPER)); then build_aur yay-bin; fi
build_aur sunshine-bin

if [[ -n $AUR_PACKAGES ]]; then
  command -v yay >/dev/null || die "AUR_PACKAGES richiede INSTALL_AUR_HELPER=1."
  read -ra aur <<<"$AUR_PACKAGES"
  for p in "${aur[@]}"; do
    echo "----- PKGBUILD di $p (per il log: controllalo) -----"
    as_user yay -Gp "$p" || warn "Impossibile stampare il PKGBUILD di $p"
  done
  log "Installazione con yay: ${aur[*]}"
  as_user yay -S --needed --noconfirm "${aur[@]}"
fi
cleanup

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
