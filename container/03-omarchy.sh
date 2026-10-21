#!/usr/bin/env bash
# Inside the container, as root: the Omarchy layer (DESKTOP=hyprland, HYPRLAND_UWSM=1,
# INSTALL_OMARCHY=1). Idempotent.
#
# It does NOT install Omarchy's own pacman packages (omarchy, omarchy-settings): they hard-depend on
# sddm, limine and snapper, ship a libalpm hook that blocks pacman -Syu and overwrite files such as
# /etc/nsswitch.conf and /etc/os-release. Instead it
#   1. fetches the pinned tag (OMARCHY_REF) and the pinned PKGBUILDs (OMARCHY_PKGS_REF),
#   2. installs the packages of install/omarchy-base.packages minus OMARCHY_SKIP_PACKAGES
#      (official repos with pacman, the rest built from omarchy-pkgs or from the AUR),
#   3. copies the files the two packages would have installed (minus the bare-metal ones),
#   4. seeds the desktop user's ~/.config from Omarchy's defaults.
set -Eeuo pipefail
STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib.sh
source "$STAGE/lib.sh"
# shellcheck source=/dev/null
source "$STAGE/config.sh"
[[ $EUID -eq 0 ]] || die "This script must run as root inside the container."
[[ ${DESKTOP:-} == hyprland ]] || die "The Omarchy layer needs DESKTOP=hyprland."
((${HYPRLAND_UWSM:-0})) || die "The Omarchy layer needs HYPRLAND_UWSM=1."

OMARCHY_PATH=/usr/share/omarchy
WORK=/opt/omarchy-src
UGRP=$(id -gn "$CT_USER")
UHOME=/home/$CT_USER
SRC=$WORK/omarchy
PKGS=$WORK/pkgs

TMP_SUDOERS=/etc/sudoers.d/99-tmp-omarchy-build
cleanup() { rm -f "$TMP_SUDOERS"; }
trap cleanup EXIT

as_user() { runuser -u "$CT_USER" -- env HOME="$UHOME" "$@"; }
in_array() { local n=$1 e; shift; for e; do [[ $e == "$n" ]] && return 0; done; return 1; }

# --- 1. Sources ---------------------------------------------------------------------------
log "Fetching Omarchy $OMARCHY_REF and omarchy-pkgs ${OMARCHY_PKGS_REF:0:10}"
rm -rf "$WORK"
install -d "$WORK"
git -c advice.detachedHead=false clone -q --depth 1 -b "$OMARCHY_REF" https://github.com/omacom/omarchy.git "$SRC"
git init -q "$PKGS"
git -C "$PKGS" remote add origin https://github.com/omacom/omarchy-pkgs.git
git -C "$PKGS" fetch -q --depth 1 origin "$OMARCHY_PKGS_REF"
git -C "$PKGS" -c advice.detachedHead=false checkout -q FETCH_HEAD
chmod -R go+rX "$WORK"
log "omarchy $(git -C "$SRC" rev-parse --short HEAD), omarchy-pkgs $(git -C "$PKGS" rev-parse --short HEAD)"

# --- 2. Packages --------------------------------------------------------------------------
log "Sorting omarchy-base.packages"
mapfile -t want < <(grep -vE '^\s*(#|$)' "$SRC/install/omarchy-base.packages" | awk '{print $1}')
read -ra skip <<<"$OMARCHY_SKIP_PACKAGES"
read -ra force_build <<<"$OMARCHY_BUILD_FROM_PKGS"

echo "$CT_USER ALL=(ALL) NOPASSWD: ALL" >"$TMP_SUDOERS"
chmod 440 "$TMP_SUDOERS"
visudo -cf "$TMP_SUDOERS" >/dev/null

official=() build=() aur=() missing=() skipped=()
for p in "${want[@]}"; do
  if in_array "$p" "${skip[@]}"; then
    skipped+=("$p")
  elif in_array "$p" "${force_build[@]}" && [[ -f $PKGS/pkgbuilds/$p/PKGBUILD ]]; then
    build+=("$p")
  elif pacman -Si "$p" &>/dev/null; then
    official+=("$p")
  elif [[ -f $PKGS/pkgbuilds/$p/PKGBUILD ]]; then
    build+=("$p")
  elif command -v yay >/dev/null && as_user yay -Si "$p" &>/dev/null; then
    aur+=("$p")
  else
    missing+=("$p")
  fi
done
log "Official: ${#official[@]}. Built from omarchy-pkgs: ${#build[@]} (${build[*]:-none}). AUR: ${#aur[@]} (${aur[*]:-none}). Skipped: ${#skipped[@]}."
((${#missing[@]})) && warn "Not found anywhere, skipped: ${missing[*]}"

if ((${#official[@]})); then
  log "pacman: ${#official[@]} packages"
  pacman -S --needed --noconfirm "${official[@]}"
fi

build_pkgbuild() { # name: build omarchy-pkgs/pkgbuilds/<name> with makepkg and install it
  local name=$1 dir work ver conflicts c
  dir=$PKGS/pkgbuilds/$name
  ver=$(as_user bash -c "cd '$dir' && source ./PKGBUILD && echo \"\${epoch:+\$epoch:}\$pkgver-\$pkgrel\"")
  if [[ $(pacman -Q "$name" 2>/dev/null | awk '{print $2}') == "$ver" ]]; then
    log "$name $ver already installed"
    return 0
  fi
  # A package that conflicts with one already installed is skipped, not forced: pacman -U would
  # abort the whole install. (ttf-jetbrains-mono-nerd-basic provides the same font as the
  # ttf-jetbrains-mono-nerd that the Hyprland package set already installs.)
  conflicts=$(as_user bash -c "cd '$dir' && source ./PKGBUILD && printf '%s\n' \"\${conflicts[@]:-}\"")
  for c in $conflicts; do
    c=${c%%[<>=]*}
    if pacman -Qq "$c" &>/dev/null; then
      warn "Skipping $name: it conflicts with the installed $c"
      return 0
    fi
  done
  log "Building $name $ver (omarchy-pkgs)"
  work=$(as_user mktemp -d)
  as_user cp -a "$dir/." "$work/"
  echo "----- PKGBUILD of $name (kept in the log: review it) -----"
  cat "$work/PKGBUILD"
  echo "----------------------------------------------------------"
  as_user bash -c "cd '$work' && makepkg -s --noconfirm --needed"
  # Install only the package we asked for: a split PKGBUILD (yaru: gtk, gnome-shell, xfwm4 themes...)
  # produces several, and the others have dependencies we do not want (gtk-engine-murrine, gnome-shell).
  local files=("$work/$name"-[0-9]*.pkg.tar.*)
  [[ -e ${files[0]} ]] || die "makepkg did not produce a package named $name (files: $(ls "$work"))"
  pacman -U --noconfirm --needed "${files[@]}"
  rm -rf "$work"
}
for p in "${build[@]}"; do build_pkgbuild "$p"; done

if ((${#aur[@]})); then
  for p in "${aur[@]}"; do
    echo "----- PKGBUILD of $p (kept in the log: review it) -----"
    as_user yay -Gp "$p" || warn "Could not print the PKGBUILD of $p"
  done
  log "yay: ${aur[*]}"
  as_user yay -S --needed --noconfirm "${aur[@]}"
fi
cleanup

# A package that Arch also ships (quickshell) must not be replaced by the Arch build on the next
# pacman -Syu: Omarchy's build is patched and pinned. Re-run this script to move to a new tag.
for p in "${build[@]}"; do
  pacman -Si "$p" &>/dev/null || continue
  if grep -qE "^IgnorePkg\s*=.*(\s|=)$p(\s|$)" /etc/pacman.conf; then continue; fi
  if grep -qE '^IgnorePkg\s*=' /etc/pacman.conf; then
    sed -i -E "s/^(IgnorePkg\s*=.*)$/\1 $p/" /etc/pacman.conf
  else
    sed -i "/^\[options\]/a IgnorePkg = $p" /etc/pacman.conf
  fi
  log "$p added to IgnorePkg (pacman.conf)"
done

# --- 3. System files ----------------------------------------------------------------------
log "Copying Omarchy into $OMARCHY_PATH"
# Stale commands from a previous tag.
if [[ -d $OMARCHY_PATH/bin ]]; then
  for l in "$OMARCHY_PATH"/bin/*; do rm -f "/usr/bin/$(basename "$l")"; done
  rm -rf "${OMARCHY_PATH:?}/bin"
fi
install -d "$OMARCHY_PATH" "$OMARCHY_PATH/bin"
for d in install themes migrations shell default config applications; do
  rm -rf "${OMARCHY_PATH:?}/$d"
  cp -a "$SRC/$d" "$OMARCHY_PATH/$d"
done
install -Dm644 "$SRC/version" "$OMARCHY_PATH/version"
rm -rf "$OMARCHY_PATH"/themes/*/backgrounds/intros 2>/dev/null || true

ncmd=0 nskip=0
for f in "$SRC"/bin/*; do
  [[ -f $f ]] || continue
  b=$(basename "$f")
  if [[ $b =~ $OMARCHY_SKIP_COMMANDS ]]; then
    nskip=$((nskip + 1))
    continue
  fi
  install -Dm755 "$f" "/usr/bin/$b"
  ln -sfn "/usr/bin/$b" "$OMARCHY_PATH/bin/$b"
  ncmd=$((ncmd + 1))
done
log "$ncmd omarchy-* commands installed in /usr/bin, $nskip skipped (OMARCHY_SKIP_COMMANDS)"

# Session environment (uwsm) and login shells.
install -Dm644 "$SRC/default/uwsm/env.d/10-omarchy" /usr/share/uwsm/env.d/10-omarchy
printf '%s\n' '[ -r /usr/share/omarchy/default/bash/env-bootstrap ] && . /usr/share/omarchy/default/bash/env-bootstrap' \
  >/etc/profile.d/omarchy.sh

# Icon font used by the shell, fontconfig rules, default terminal list.
if [[ -f $SRC/default/fonts/omarchy/omarchy.ttf ]]; then
  install -Dm644 "$SRC/default/fonts/omarchy/omarchy.ttf" /usr/share/fonts/omarchy/omarchy.ttf
fi
if [[ -f $SRC/default/fontconfig/conf.avail/50-omarchy.conf ]]; then
  install -Dm644 "$SRC/default/fontconfig/conf.avail/50-omarchy.conf" /usr/share/fontconfig/conf.avail/50-omarchy.conf
  ln -sfn /usr/share/fontconfig/conf.avail/50-omarchy.conf /etc/fonts/conf.d/50-omarchy.conf
fi
fc-cache -f >/dev/null 2>&1 || true
if [[ -d $SRC/default/xdg-terminal-exec ]]; then
  install -d /usr/share/xdg-terminal-exec
  cp -a "$SRC"/default/xdg-terminal-exec/. /usr/share/xdg-terminal-exec/
fi

# The one sudo rule Omarchy's theme switching relies on (the rest of /etc is left out). Without it
# every theme change opens a polkit password prompt: omarchy-theme-set-browser-policy, which paints
# the browser accent colour, falls back to pkexec when sudo would ask for a password.
install -Dm440 "$SRC/etc/sudoers.d/omarchy-theme-browser" /etc/sudoers.d/omarchy-theme-browser
if ! visudo -cf /etc/sudoers.d/omarchy-theme-browser >/dev/null; then
  rm -f /etc/sudoers.d/omarchy-theme-browser
  warn "sudoers rule omarchy-theme-browser rejected by visudo: not installed"
fi

# Omarchy's own user services (hardware-related ones are left out).
if [[ -d $SRC/default/systemd/user ]]; then
  for f in "$SRC"/default/systemd/user/*.service; do
    [[ -f $f ]] || continue
    case $(basename "$f") in *bluetooth* | *bt-* | *thunderbolt* | *usb* | *brightness* | *tailscale* | *sleep* | *speaker* | *internal-monitor* | *fcitx5*) continue ;; esac
    install -Dm644 "$f" "/usr/lib/systemd/user/$(basename "$f")"
  done
fi

# --- 4. The desktop user's configuration --------------------------------------------------
log "Seeding $UHOME/.config from Omarchy's defaults"
CONF=$UHOME/.config
install -d -o "$CT_USER" -g "$UGRP" "$CONF" "$CONF/hypr"
# Our minimal Hyprland config makes room for Omarchy's (kept as a backup).
if [[ -f $CONF/hypr/hyprland.lua ]] && ! grep -q omarchy "$CONF/hypr/hyprland.lua"; then
  mv "$CONF/hypr/hyprland.lua" "$CONF/hypr/hyprland.lua.minimal-bak"
  log "Previous hyprland.lua saved as hyprland.lua.minimal-bak"
fi
# Never overwrites a file the user already has (edits survive re-runs).
cp -a --no-clobber "$OMARCHY_PATH"/config/. "$CONF"/
chown -R "$CT_USER:$UGRP" "$CONF"

# Keyboard layout, if set in config.sh (Omarchy's input.lua is the user override file).
if [[ -n ${KB_LAYOUT:-} ]]; then
  printf '%s\n' '-- Written by container/03-omarchy.sh from KB_LAYOUT in config.sh.' \
    "hl.config({ input = { kb_layout = \"$KB_LAYOUT\" } })" >"$CONF/hypr/input.lua"
  chown "$CT_USER:$UGRP" "$CONF/hypr/input.lua"
fi

# Screensaver (after 2.5 minutes) and idle lock (after 5) are Omarchy shell features: its idle
# service honours this state file. They would interrupt a streamed session while nobody is looking,
# so "stay awake" is the default here. OMARCHY_STAY_AWAKE=0 in config.local.sh keeps Omarchy's behaviour.
STAYAWAKE=$UHOME/.local/state/omarchy/indicators/stay-awake
install -d -o "$CT_USER" -g "$UGRP" "$UHOME/.local" "$UHOME/.local/state" "$UHOME/.local/state/omarchy" \
  "$UHOME/.local/state/omarchy/indicators"
if ((${OMARCHY_STAY_AWAKE:-1})); then
  touch "$STAYAWAKE"
  chown "$CT_USER:$UGRP" "$STAYAWAKE"
else
  rm -f "$STAYAWAKE"
fi

# Mark Omarchy's migrations as done: they are for installs coming from older versions.
STATE=$UHOME/.local/state/omarchy/migrations
install -d -o "$CT_USER" -g "$UGRP" "$UHOME/.local" "$UHOME/.local/state" "$UHOME/.local/state/omarchy" "$STATE"
for m in "$SRC"/migrations/*.sh; do
  [[ -f $m ]] && touch "$STATE/$(basename "$m")"
done
chown -R "$CT_USER:$UGRP" "$UHOME/.local/state/omarchy"

# --- 5. Restart the session so that Omarchy's config and shell come up ------------------------
if systemctl is-active --quiet hyprland-session.service; then
  log "Restarting hyprland-session to load Omarchy"
  systemctl restart hyprland-session.service
fi
log "03-omarchy done"
