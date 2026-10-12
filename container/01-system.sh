#!/usr/bin/env bash
# Inside the container, as root: system, packages, user, locale, SSH, Plasma.
# Idempotent. Installs no display manager and no browser.
set -Eeuo pipefail
STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib.sh
source "$STAGE/lib.sh"
# shellcheck source=/dev/null
source "$STAGE/config.sh"
[[ $EUID -eq 0 ]] || die "This script must run as root inside the container."

as_user() { runuser -u "$CT_USER" -- env HOME="/home/$CT_USER" "$@"; }

# --- pacman: no Landlock in the host kernel, keys, upgrade ----------------------------
log "pacman: sandbox, keys, upgrade"
if grep -qE '^#\s*DisableSandboxFilesystem' /etc/pacman.conf; then
  sed -i -E 's/^#\s*(DisableSandboxFilesystem)\s*$/\1/' /etc/pacman.conf
fi
grep -q '^DisableSandboxFilesystem' /etc/pacman.conf \
  || warn "DisableSandboxFilesystem is not in pacman.conf: if pacman complains about Landlock use 'pacman --disable-sandbox'."
pacman-key --init
pacman-key --populate archlinux
pacman -Syu --noconfirm

# --- Packages ----------------------------------------------------------------------
# Phase 1: base, GPU and audio. We pin the providers (jack, Qt multimedia backend) here,
# so that in phase 2 pacman does not have to pick them on its own with --noconfirm.
log "Packages: base, GPU, audio"
BASE=(sudo openssh nano base-devel git
  intel-media-driver libva-utils vulkan-intel mesa vulkan-tools
  pipewire pipewire-pulse pipewire-jack wireplumber qt6-multimedia-ffmpeg
  avahi)
if ((INSTALL_DIAG)); then BASE+=(mesa-utils iperf3); fi
pacman -S --needed --noconfirm "${BASE[@]}"

# Sunshine announces itself over mDNS. Without the daemon it logs "Failed to create client"
# and Moonlight cannot discover the host on its own.
systemctl enable --now avahi-daemon

# Phase 2: desktop (plasma-desktop, no meta package), multimedia, user extras.
log "Packages: Plasma and multimedia desktop"
DESKTOP=()
read -ra plasma <<<"$PLASMA_PACKAGES"
DESKTOP+=("${plasma[@]}")
if ((INSTALL_MEDIA)); then
  read -ra media <<<"$MEDIA_PACKAGES"
  DESKTOP+=("${media[@]}")
fi
if [[ -n $EXTRA_PACKAGES ]]; then
  read -ra extra <<<"$EXTRA_PACKAGES"
  DESKTOP+=("${extra[@]}")
fi
pacman -S --needed --noconfirm "${DESKTOP[@]}"

# Safety net: a display manager would hold the DRM card open and KWin would not start.
# (plasma-desktop brings none, but let's not depend on future dependencies.)
for dm in sddm plasmalogin plasma-login-manager gdm lightdm; do
  if systemctl list-unit-files "${dm}.service" --no-legend 2>/dev/null | grep -q .; then
    systemctl disable --now "${dm}.service" 2>/dev/null || true
    systemctl mask "${dm}.service"
  fi
done

# --- User, sudo, SSH ---------------------------------------------------------------
log "User '$CT_USER', sudo, SSH"
getent group render >/dev/null || groupadd -r render
if id "$CT_USER" &>/dev/null; then
  usermod -aG wheel,video,render "$CT_USER"
else
  useradd -m -G wheel,video,render -s /bin/bash "$CT_USER"
fi
UGRP=$(id -gn "$CT_USER")

echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -c -q

systemctl enable --now sshd
if [[ -n $SSH_PUBKEY ]]; then
  install -d -m 700 -o "$CT_USER" -g "$UGRP" "/home/$CT_USER/.ssh"
  AK=/home/$CT_USER/.ssh/authorized_keys
  touch "$AK"
  grep -qxF "$SSH_PUBKEY" "$AK" || echo "$SSH_PUBKEY" >>"$AK"
  chown "$CT_USER:$UGRP" "$AK"
  chmod 600 "$AK"
  if ((SSH_DISABLE_PASSWORD)); then
    printf 'PasswordAuthentication no\n' >/etc/ssh/sshd_config.d/10-no-password.conf
    systemctl reload sshd
  fi
elif ((SSH_DISABLE_PASSWORD)); then
  warn "SSH_DISABLE_PASSWORD=1 but SSH_PUBKEY is empty: leaving password login enabled."
fi

# --- Locale and time zone ----------------------------------------------------------
log "Locale and time zone"
for l in "$LOCALE" en_US.UTF-8; do
  sed -i -E "s/^#\s*(${l//./\\.} UTF-8)/\1/" /etc/locale.gen
done
locale-gen
printf 'LANG=%s\n' "$LOCALE" >/etc/locale.conf
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

# --- Plasma: always-on session (written before the first start) -----------------------
log "Plasma settings for an always-on session"
as_user kwriteconfig6 --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle false
as_user kwriteconfig6 --file powerdevilrc --group AC --group Display --key DimDisplayWhenIdle false
as_user kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false
as_user kwriteconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume false
# powerdevil is a hard dependency of plasma-desktop: instead of removing it, make suspend impossible.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
if ((DISABLE_FILE_INDEXING)); then
  as_user kwriteconfig6 --file baloofilerc --group 'Basic Settings' --key Indexing-Enabled false
fi
# KWallet is a dependency too: the session starts without a typed password, so it would
# only ask you to create one. Disabling the subsystem keeps it out of the way.
if ((DISABLE_KWALLET)); then
  as_user kwriteconfig6 --file kwalletrc --group Wallet --key Enabled false
fi
if [[ -n $KB_LAYOUT ]]; then
  as_user kwriteconfig6 --file kxkbrc --group Layout --key Use true
  as_user kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "$KB_LAYOUT"
fi

# --- Plasma Wayland session without a display manager -------------------------------
log "plasma-session service"
sed "s/@CT_USER@/$CT_USER/g" "$STAGE/files/plasma-session.service" >/etc/systemd/system/plasma-session.service
systemctl daemon-reload
systemctl set-default graphical.target
systemctl enable plasma-session.service # started in 03-session.sh, after Sunshine

log "01-system done"
