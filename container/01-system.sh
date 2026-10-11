#!/usr/bin/env bash
# Dentro il container, come root: sistema, pacchetti, utente, locale, SSH, Plasma.
# Idempotente. Non installa SDDM né browser.
set -Eeuo pipefail
STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib.sh
source "$STAGE/lib.sh"
# shellcheck source=/dev/null
source "$STAGE/config.sh"
[[ $EUID -eq 0 ]] || die "Questo script va eseguito come root nel container."

as_user() { runuser -u "$UTENTE" -- env HOME="/home/$UTENTE" "$@"; }

# --- pacman: niente Landlock nel kernel dell'host, chiavi, aggiornamento -------------
log "pacman: sandbox, chiavi, aggiornamento"
if grep -qE '^#\s*DisableSandboxFilesystem' /etc/pacman.conf; then
  sed -i -E 's/^#\s*(DisableSandboxFilesystem)\s*$/\1/' /etc/pacman.conf
fi
grep -q '^DisableSandboxFilesystem' /etc/pacman.conf \
  || warn "DisableSandboxFilesystem non è in pacman.conf: se pacman si lamenta di Landlock usa 'pacman --disable-sandbox'."
pacman-key --init
pacman-key --populate archlinux
pacman -Syu --noconfirm

# --- Pacchetti -----------------------------------------------------------------------
log "Pacchetti (GPU, Plasma, audio, strumenti AUR)"
PKGS=(sudo openssh nano base-devel git
  intel-media-driver libva-utils vulkan-intel mesa vulkan-tools
  plasma-meta konsole dolphin pipewire pipewire-pulse wireplumber)
if ((INSTALL_DIAG)); then PKGS+=(mesa-utils iperf3); fi
if [[ -n $EXTRA_PACKAGES ]]; then
  read -ra extra <<<"$EXTRA_PACKAGES"
  PKGS+=("${extra[@]}")
fi
pacman -S --needed --noconfirm "${PKGS[@]}"

# SDDM: se arriva come dipendenza resta spento (tiene aperto la card e KWin fallisce).
systemctl disable --now sddm.service 2>/dev/null || true
systemctl mask sddm.service

# --- Utente, sudo, SSH -----------------------------------------------------------------
log "Utente '$UTENTE', sudo, SSH"
getent group render >/dev/null || groupadd -r render
if id "$UTENTE" &>/dev/null; then
  usermod -aG wheel,video,render "$UTENTE"
else
  useradd -m -G wheel,video,render -s /bin/bash "$UTENTE"
fi
UGRP=$(id -gn "$UTENTE")

echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -c -q

systemctl enable --now sshd
if [[ -n $SSH_PUBKEY ]]; then
  install -d -m 700 -o "$UTENTE" -g "$UGRP" "/home/$UTENTE/.ssh"
  AK=/home/$UTENTE/.ssh/authorized_keys
  touch "$AK"
  grep -qxF "$SSH_PUBKEY" "$AK" || echo "$SSH_PUBKEY" >>"$AK"
  chown "$UTENTE:$UGRP" "$AK"
  chmod 600 "$AK"
  if ((SSH_DISABLE_PASSWORD)); then
    printf 'PasswordAuthentication no\n' >/etc/ssh/sshd_config.d/10-no-password.conf
    systemctl reload sshd
  fi
elif ((SSH_DISABLE_PASSWORD)); then
  warn "SSH_DISABLE_PASSWORD=1 ma SSH_PUBKEY è vuota: non disattivo il login con password."
fi

# --- Locale e fuso orario --------------------------------------------------------------------
log "Locale e fuso orario"
for l in "$LOCALE" en_US.UTF-8; do
  sed -i -E "s/^#\s*(${l//./\\.} UTF-8)/\1/" /etc/locale.gen
done
locale-gen
printf 'LANG=%s\n' "$LOCALE" >/etc/locale.conf
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

# --- Plasma: niente spegnimento schermo né blocco (scritto prima del primo avvio) ------------
log "Impostazioni Plasma per sessione sempre attiva"
as_user kwriteconfig6 --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle false
as_user kwriteconfig6 --file powerdevilrc --group AC --group Display --key DimDisplayWhenIdle false
as_user kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false
as_user kwriteconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume false
if [[ -n $KB_LAYOUT ]]; then
  as_user kwriteconfig6 --file kxkbrc --group Layout --key Use true
  as_user kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "$KB_LAYOUT"
fi

# --- Sessione Plasma Wayland senza SDDM -----------------------------------------------------
log "Servizio plasma-session"
sed "s/@UTENTE@/$UTENTE/g" "$STAGE/files/plasma-session.service" >/etc/systemd/system/plasma-session.service
systemctl daemon-reload
systemctl set-default graphical.target
systemctl enable plasma-session.service # si avvia in 03-session.sh, dopo Sunshine

log "01-system completato"
