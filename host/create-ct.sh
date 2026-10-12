#!/usr/bin/env bash
# Creates (or resumes) the privileged Arch container with the GPU, input and uinput devices.
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

CONF=/etc/pve/lxc/${CTID}.conf

add_conf() { grep -qxF "$1" "$CONF" || echo "$1" >>"$CONF"; }

ensure_conf() {
  # Lines needed for udev (writable /sys), input and GPU (the whole /dev/dri folder).
  add_conf 'lxc.mount.auto: proc:rw sys:rw'
  add_conf 'lxc.cgroup2.devices.allow: c 13:* rwm'
  add_conf 'lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir'
  add_conf 'lxc.cgroup2.devices.allow: c 226:* rwm'
  add_conf 'lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir'
}

wait_net() {
  pct exec "$CTID" -- getent hosts archlinux.org
}

start_and_wait() {
  if [[ $(pct status "$CTID") != "status: running" ]]; then
    pct start "$CTID"
  fi
  wait_for 120 "container network (DNS)" wait_net || die "The container cannot reach the network: check IP, gateway and DNS in config.sh"
}

if pct status "$CTID" &>/dev/null; then
  if [[ ${RECREATE:-0} == 1 ]]; then
    warn "CT $CTID exists and will be DESTROYED (disk included)."
    read -rp "To confirm, type $CTID: " ans
    [[ $ans == "$CTID" ]] || die "Aborted."
    pct stop "$CTID" 2>/dev/null || true
    pct destroy "$CTID" --purge
  else
    log "CT $CTID already exists: skipping creation (use --recreate to start from scratch)."
    ensure_conf
    start_and_wait
    exit 0
  fi
fi

# Refuse to create the container on an address that is already taken. A duplicate IP makes
# traffic go to the wrong machine depending on who answered ARP last: it worked from the LAN
# and failed only from outside, which made it very hard to spot.
check_ip_free() {
  local f ip_re=${IP_CT//./\\.} used=()
  for f in /etc/pve/lxc/*.conf /etc/pve/qemu-server/*.conf; do
    [[ -e $f && $f != "$CONF" ]] || continue
    if grep -qE "ip=${ip_re}(/|,|$)" "$f"; then used+=("$f"); fi
  done
  ((${#used[@]} == 0)) || die "IP $IP_CT is already configured in: ${used[*]}"
  if ping -c1 -W1 "$IP_CT" &>/dev/null; then
    die "$IP_CT already answers on the network (another device, or a guest using DHCP). Pick a free address outside the router's DHCP pool."
  fi
}
log "Checking that $IP_CT is free"
check_ip_free

# --- Arch template -------------------------------------------------------------------
log "Arch template"
pveam update >/dev/null
TEMPLATE=$(pveam available --section system | awk '$2 ~ /^archlinux-base/ {print $2}' | sort -V | tail -1)
[[ -n $TEMPLATE ]] || die "No archlinux-base template found with pveam."
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# --- Creation: PRIVILEGED (--unprivileged 0) from the start -----------------------------
log "pct create $CTID ($CORES cores, $((MEMORY_MB / 1024)) GB RAM, ${DISK_GB} GB on $STORAGE)"
ROOT_PW=$(openssl rand -base64 24) # root needs no password login: use `pct enter`
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$CT_HOSTNAME" \
  --ostype archlinux \
  --unprivileged 0 \
  --cores "$CORES" \
  --memory "$MEMORY_MB" \
  --swap "$SWAP_MB" \
  --rootfs "$STORAGE:$DISK_GB" \
  --net0 "name=eth0,bridge=$BRIDGE,ip=$IP_CT/$CIDR,gw=$GATEWAY,firewall=0" \
  --nameserver "$DNS" \
  --timezone "$TIMEZONE" \
  --features nesting=1,fuse=1 \
  --dev0 /dev/uinput,mode=0666 \
  --onboot 1 \
  --password "$ROOT_PW"

ensure_conf
start_and_wait
log "Container $CTID started"
