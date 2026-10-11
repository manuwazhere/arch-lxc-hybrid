#!/usr/bin/env bash
# Verifiche dentro il container (sezione 2.3 della procedura manuale + extra).
# Utilizzabile anche da solo: sudo bash /opt/arch-sunshine-setup/container/verify.sh
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
t_session() { loginctl list-sessions --no-legend | awk -v u="$UTENTE" '$3==u && $4=="seat0"' | grep -q .; }
t_kwin() { pgrep -u "$UTENTE" kwin_wayland; }
t_no_sddm() { ! systemctl is-active --quiet sddm; }
t_va_h264() { LIBVA_DRIVER_NAME=iHD vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -Eq 'VAProfileH264.*EncSliceLP'; }
t_va_hevc() { LIBVA_DRIVER_NAME=iHD vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -Eq 'VAProfileHEVCMain.*EncSliceLP'; }
t_vulkan() { vulkaninfo --summary 2>/dev/null | grep -qi intel; }
t_port() { ss -ltn | grep -q ":$1 "; }
t_conf() { grep -Eq '^capture\s*=\s*kwin' "/home/$UTENTE/.config/sunshine/sunshine.conf"; }
t_no_tmp_sudoers() { [[ ! -e /etc/sudoers.d/99-tmp-aur-build ]]; }
t_uinput() { [[ -c /dev/uinput ]]; }
t_input() { compgen -G '/dev/input/event*'; }

log "Verifiche"
check "/sys scrivibile (rw)" t_sys_rw
check "systemd-udevd attivo" systemctl is-active --quiet systemd-udevd
check "systemd-udev-trigger eseguito" systemctl is-active --quiet systemd-udev-trigger
check "/dev/dri/renderD128 presente" test -c /dev/dri/renderD128
check "/dev/uinput presente" t_uinput
check "nodi /dev/input/event* presenti" t_input
check "seat0 elenca la scheda DRM" t_seat_card
check "sessione di $UTENTE su seat0" t_session
check "kwin_wayland in esecuzione" t_kwin
check "sddm non attivo" t_no_sddm
check "VA-API: H.264 in codifica (EncSliceLP)" t_va_h264
check "VA-API: HEVC in codifica (EncSliceLP)" t_va_hevc
check "Vulkan vede la GPU Intel" t_vulkan
check "sunshine.conf: capture = kwin" t_conf
check "Sunshine in ascolto (47989)" t_port 47989
check "Sunshine in ascolto (47990)" t_port 47990
check "sudoers temporaneo dell'AUR rimosso" t_no_tmp_sudoers

echo
log "Info (non sono controlli):"
stat -c '  %A %U:%G %n' /dev/dri/* 2>/dev/null || true
echo "  $(pacman -Q sunshine-bin 2>/dev/null || echo 'sunshine-bin non installato')"
echo "  kernel: $(uname -r)"

echo
log "Risultato: $pass OK, $fail FAIL"
((fail == 0))
