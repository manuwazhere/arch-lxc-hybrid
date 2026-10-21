#!/usr/bin/env bash
# Inside the container, as root: system, packages, user, locale, SSH, desktop (Plasma or Hyprland).
# Idempotent. Installs no display manager and no browser.
set -Eeuo pipefail
STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib.sh
source "$STAGE/lib.sh"
# shellcheck source=/dev/null
source "$STAGE/config.sh"
[[ $EUID -eq 0 ]] || die "This script must run as root inside the container."
DESKTOP=${DESKTOP:-plasma}
HYPRLAND_UWSM=${HYPRLAND_UWSM:-0}
[[ $DESKTOP == plasma || $DESKTOP == hyprland ]] || die "Invalid DESKTOP: '$DESKTOP' (plasma or hyprland)"

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

# Phase 2: desktop, multimedia, user extras.
DESKTOP_PKGS=()
if [[ $DESKTOP == plasma ]]; then
  log "Packages: Plasma and multimedia desktop"
  # plasma-desktop, no meta package
  read -ra plasma <<<"$PLASMA_PACKAGES"
  DESKTOP_PKGS+=("${plasma[@]}")
  if ((INSTALL_MEDIA)); then
    read -ra media <<<"$MEDIA_PACKAGES"
    DESKTOP_PKGS+=("${media[@]}")
  fi
else
  log "Packages: Hyprland and multimedia desktop"
  read -ra hypr <<<"$HYPRLAND_PACKAGES"
  DESKTOP_PKGS+=("${hypr[@]}")
  if ((HYPRLAND_UWSM)); then DESKTOP_PKGS+=(uwsm); fi
  if ((INSTALL_MEDIA)); then
    read -ra media <<<"$HYPRLAND_MEDIA_PACKAGES"
    DESKTOP_PKGS+=("${media[@]}")
  fi
fi
if [[ -n $EXTRA_PACKAGES ]]; then
  read -ra extra <<<"$EXTRA_PACKAGES"
  DESKTOP_PKGS+=("${extra[@]}")
fi
pacman -S --needed --noconfirm "${DESKTOP_PKGS[@]}"

# Safety net: a display manager would hold the DRM card open and the compositor would not start.
# (neither desktop brings one, but let's not depend on future dependencies.)
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

# --- Always-on session: suspend can never happen (both desktops) --------------------------
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# --- Plasma: always-on session (written before the first start) -----------------------
if [[ $DESKTOP == plasma ]]; then
  log "Plasma settings for an always-on session"
  as_user kwriteconfig6 --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle false
  as_user kwriteconfig6 --file powerdevilrc --group AC --group Display --key DimDisplayWhenIdle false
  as_user kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false
  as_user kwriteconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume false
  # powerdevil is a hard dependency of plasma-desktop: instead of removing it, we made suspend
  # impossible above (sleep.target masked).
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
fi

# --- Wayland session without a display manager ---------------------------------------------
if [[ $DESKTOP == plasma ]]; then
  log "plasma-session service"
  sed "s/@CT_USER@/$CT_USER/g" "$STAGE/files/plasma-session.service" >/etc/systemd/system/plasma-session.service
  systemctl daemon-reload
  systemctl set-default graphical.target
  systemctl enable plasma-session.service # started in 04-session.sh, after Sunshine
else
  log "Hyprland config and hyprland-session service"
  # The generated config is Lua: Hyprland >= 0.55 (older versions would ignore it).
  hypr_ver=$(pacman -Q hyprland | awk '{print $2}')
  if [[ $(vercmp "${hypr_ver%%-*}" 0.55.0) -lt 0 ]]; then
    warn "hyprland $hypr_ver is older than 0.55: it will ignore the Lua config (hyprland.lua)."
  fi

  UGRP=$(id -gn "$CT_USER")
  HCONF=/home/$CT_USER/.config/hypr
  install -d -o "$CT_USER" -g "$UGRP" "/home/$CT_USER/.config" "$HCONF"
  if [[ -e $HCONF/hyprland.lua ]]; then
    log "$HCONF/hyprland.lua already exists: leaving it alone"
  else
    sed "s|@KB_LAYOUT@|$KB_LAYOUT|g" "$STAGE/files/hyprland.lua" >"$HCONF/hyprland.lua"
    chown "$CT_USER:$UGRP" "$HCONF/hyprland.lua"
  fi

  # User target that Hyprland starts at launch: it pulls in graphical-session.target (Sunshine).
  install -D -m 644 "$STAGE/files/hyprland-session.target" /etc/systemd/user/hyprland-session.target

  if ((HYPRLAND_UWSM)); then
    # uwsm starts Hyprland and graphical-session.target itself: the target above becomes a no-op.
    [[ -f /usr/share/wayland-sessions/hyprland.desktop ]] \
      || warn "/usr/share/wayland-sessions/hyprland.desktop is missing: 'uwsm start -- hyprland.desktop' will fail."
    install -D -m 755 "$STAGE/files/hyprland-uwsm-session" /usr/local/libexec/hyprland-uwsm-session
    install -D -m 644 "$STAGE/files/hyprland-session.target.d-uwsm.conf" \
      /etc/systemd/user/hyprland-session.target.d/10-uwsm.conf
    HYPR_BIN=/usr/local/libexec/hyprland-uwsm-session
  else
    rm -rf /etc/systemd/user/hyprland-session.target.d /usr/local/libexec/hyprland-uwsm-session
    # Recent Hyprland ships a launcher (start-hyprland); fall back to the bare binary.
    if [[ -x /usr/bin/start-hyprland ]]; then HYPR_BIN=/usr/bin/start-hyprland; else HYPR_BIN=/usr/bin/Hyprland; fi
  fi

  unit=/etc/systemd/system/hyprland-session.service
  old_sum=$(sha256sum "$unit" 2>/dev/null | cut -d' ' -f1 || true)
  sed -e "s/@CT_USER@/$CT_USER/g" -e "s|@HYPRLAND_BIN@|$HYPR_BIN|g" \
    "$STAGE/files/hyprland-session.service" >"$unit"
  new_sum=$(sha256sum "$unit" | cut -d' ' -f1)
  systemctl daemon-reload
  systemctl set-default graphical.target
  systemctl enable hyprland-session.service # started in 04-session.sh, after Sunshine
  # A session that is already running keeps the old launcher until it is restarted.
  if [[ -n $old_sum && $old_sum != "$new_sum" ]] && systemctl is-active --quiet hyprland-session.service; then
    log "Session unit changed (HYPRLAND_UWSM=$HYPRLAND_UWSM): restarting hyprland-session"
    systemctl restart hyprland-session.service
  fi
fi

log "01-system done"
