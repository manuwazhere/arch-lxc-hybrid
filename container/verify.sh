#!/usr/bin/env bash
# Checks inside the container (section 2.3 of the manual procedure, plus extras).
# Can also be used on its own: sudo bash /opt/arch-sunshine-setup/container/verify.sh
STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib.sh
source "$STAGE/lib.sh"
# shellcheck source=/dev/null
source "$STAGE/config.sh"

pass=0
fail=0
check() {
  local desc=$1
  shift
  if "$@" &>/dev/null; then
    printf '  \033[32mOK\033[0m   %s\n' "$desc"
    ((++pass))
  else
    printf '  \033[31mFAIL\033[0m %s\n' "$desc"
    ((++fail))
  fi
}

t_sys_rw() { findmnt -no OPTIONS /sys | grep -qw rw; }
t_seat_card() { loginctl seat-status seat0 | grep -q drm; }
t_session() { loginctl list-sessions --no-legend | awk -v u="$CT_USER" '$3==u && $4=="seat0"' | grep -q .; }
t_kwin() { pgrep -u "$CT_USER" kwin_wayland; }
t_va_h264() { LIBVA_DRIVER_NAME=iHD vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -Eq 'VAProfileH264.*EncSliceLP'; }
t_va_hevc() { LIBVA_DRIVER_NAME=iHD vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -Eq 'VAProfileHEVCMain.*EncSliceLP'; }
t_vulkan() { vulkaninfo --summary 2>/dev/null | grep -qi intel; }
t_port() { ss -ltn | grep -q ":$1 "; }
t_conf() { grep -Eq '^capture\s*=\s*kwin' "/home/$CT_USER/.config/sunshine/sunshine.conf"; }
t_no_tmp_sudoers() { [[ ! -e /etc/sudoers.d/99-tmp-aur-build ]]; }
t_uinput() { [[ -c /dev/uinput ]]; }
t_avahi() { systemctl is-active --quiet avahi-daemon; }
t_extra_opts() {
  local kv conf="/home/$CT_USER/.config/sunshine/sunshine.conf" opts
  read -ra opts <<<"${SUNSHINE_EXTRA:-}"
  for kv in "${opts[@]}"; do grep -Eq "^${kv%%=*}\\s*=\\s*${kv#*=}\\s*$" "$conf" || return 1; done
}
t_input() { compgen -G '/dev/input/event*'; }
t_no_dm() { ! systemctl list-units --type=service --state=active --no-legend | grep -Eiq '(sddm|plasmalogin|plasma-login|gdm|lightdm)'; }
t_absent() { local p; for p in "$@"; do pacman -Q "$p" &>/dev/null && return 1; done; return 0; }
t_sleep_masked() { [[ $(systemctl is-enabled sleep.target 2>/dev/null) == masked ]]; }
t_kwallet_off() { [[ $(runuser -u "$CT_USER" -- env HOME="/home/$CT_USER" kreadconfig6 --file kwalletrc --group Wallet --key Enabled) == false ]]; }

log "Checks"
check "/sys is writable (rw)" t_sys_rw
check "systemd-udevd active" systemctl is-active --quiet systemd-udevd
check "systemd-udev-trigger done" systemctl is-active --quiet systemd-udev-trigger
check "/dev/dri/renderD128 present" test -c /dev/dri/renderD128
check "/dev/uinput present" t_uinput
check "/dev/input/event* nodes present" t_input
check "seat0 lists the DRM card" t_seat_card
check "session of $CT_USER on seat0" t_session
check "kwin_wayland running" t_kwin
check "no display manager active" t_no_dm
check "excluded packages absent (discover, bluedevil, plasma-nm, flatpak-kcm, plasma-meta...)" \
  t_absent discover bluedevil plasma-nm flatpak-kcm plasma-meta plasma-firewall plasma-thunderbolt plasma-disks plasma-welcome krdp plasma-vault
check "suspend disabled (sleep.target masked)" t_sleep_masked
if ((DISABLE_KWALLET)); then check "KWallet disabled" t_kwallet_off; fi
if ((INSTALL_MEDIA)); then check "VLC installed" pacman -Q vlc; fi
check "VA-API: H.264 encoding (EncSliceLP)" t_va_h264
check "VA-API: HEVC encoding (EncSliceLP)" t_va_hevc
check "Vulkan sees the Intel GPU" t_vulkan
check "sunshine.conf: capture = kwin" t_conf
check "sunshine.conf: extra options (${SUNSHINE_EXTRA:-none})" t_extra_opts
check "avahi-daemon active (mDNS announcement)" t_avahi
check "Sunshine listening (47989)" t_port 47989
check "Sunshine listening (47990)" t_port 47990
check "temporary AUR sudoers removed" t_no_tmp_sudoers
if ((INSTALL_AUR_HELPER)); then check "yay installed" command -v yay; fi
read -ra aur_pkgs <<<"${AUR_PACKAGES:-}"
for p in "${aur_pkgs[@]}"; do check "AUR package $p installed" pacman -Q "$p"; done

echo
log "Info (not checks):"
stat -c '  %A %U:%G %n' /dev/dri/* 2>/dev/null || true
echo "  $(pacman -Q sunshine-bin 2>/dev/null || echo 'sunshine-bin not installed')"
echo "  kernel: $(uname -r)"

echo
log "Result: $pass OK, $fail FAIL"
((fail == 0))
