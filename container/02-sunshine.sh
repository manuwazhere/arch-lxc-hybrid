#!/usr/bin/env bash
# Inside the container, as root: installs yay-bin and sunshine-bin (AUR), sets capture = kwin,
# enables the user service for all users (it starts with the graphical session).
set -Eeuo pipefail
STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib.sh
source "$STAGE/lib.sh"
# shellcheck source=/dev/null
source "$STAGE/config.sh"
[[ $EUID -eq 0 ]] || die "This script must run as root inside the container."

TMP_SUDOERS=/etc/sudoers.d/99-tmp-aur-build
cleanup() { rm -f "$TMP_SUDOERS"; }
trap cleanup EXIT

as_user() { runuser -u "$CT_USER" -- env HOME="/home/$CT_USER" "$@"; }

# --- AUR builds (passwordless sudo only for the duration of these steps) ----------------
log "Temporary passwordless sudo for the AUR builds"
echo "$CT_USER ALL=(ALL) NOPASSWD: ALL" >"$TMP_SUDOERS"
chmod 440 "$TMP_SUDOERS"
visudo -cf "$TMP_SUDOERS" >/dev/null

build_aur() { # package
  if pacman -Qi "$1" &>/dev/null; then
    log "$1 already installed ($(pacman -Q "$1"))"
  else
    log "Building $1 from the AUR"
    as_user bash "$STAGE/container/aur-build.sh" "$1"
  fi
}

# yay-bin and sunshine-bin via makepkg (so Sunshine keeps its pin and its PKGBUILD in the log);
# from then on `yay -Syu` updates both.
if ((INSTALL_AUR_HELPER)); then build_aur yay-bin; fi
build_aur sunshine-bin

if [[ -n $AUR_PACKAGES ]]; then
  command -v yay >/dev/null || die "AUR_PACKAGES requires INSTALL_AUR_HELPER=1."
  read -ra aur <<<"$AUR_PACKAGES"
  for p in "${aur[@]}"; do
    echo "----- PKGBUILD of $p (kept in the log: review it) -----"
    as_user yay -Gp "$p" || warn "Could not print the PKGBUILD of $p"
  done
  log "Installing with yay: ${aur[*]}"
  as_user yay -S --needed --noconfirm "${aur[@]}"
fi
cleanup

# --- Configuration ---------------------------------------------------------------------
log "Configuring Sunshine"
UGRP=$(id -gn "$CT_USER")
CONF_DIR=/home/$CT_USER/.config/sunshine
CONF=$CONF_DIR/sunshine.conf
install -d -o "$CT_USER" -g "$UGRP" "$CONF_DIR"
touch "$CONF"

set_kv() { # key value
  if grep -qE "^$1\s*=" "$CONF"; then
    sed -i -E "s|^$1\s*=.*|$1 = $2|" "$CONF"
  else
    echo "$1 = $2" >>"$CONF"
  fi
}
set_kv capture kwin
set_kv csrf_allowed_origins "https://${IP_CT}:47990"
chown "$CT_USER:$UGRP" "$CONF"

# User service: starts with graphical-session.target (that is, with plasma-session).
UNIT=app-dev.lizardbyte.app.Sunshine.service
if [[ -f /usr/lib/systemd/user/$UNIT ]]; then
  systemctl --global enable "$UNIT" || warn "Could not enable $UNIT: enable it by hand with 'systemctl --user enable --now $UNIT'"
else
  warn "User unit $UNIT not found: check the sunshine-bin package."
fi

log "02-sunshine done"
