#!/usr/bin/env bash
# Crea (o riprende) il container Arch privileged con i device per GPU, input e uinput.
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

CONF=/etc/pve/lxc/${CTID}.conf

add_conf() { grep -qxF "$1" "$CONF" || echo "$1" >>"$CONF"; }

ensure_conf() {
  # Righe necessarie per udev (/sys scrivibile), input e GPU (intera cartella /dev/dri).
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
  wait_for 120 "rete nel container (DNS)" wait_net || die "Il container non raggiunge la rete: controlla IP, gateway e DNS in config.sh"
}

if pct status "$CTID" &>/dev/null; then
  if [[ ${RECREATE:-0} == 1 ]]; then
    warn "Il CT $CTID esiste e verrà DISTRUTTO (disco incluso)."
    read -rp "Per confermare scrivi $CTID: " ans
    [[ $ans == "$CTID" ]] || die "Annullato."
    pct stop "$CTID" 2>/dev/null || true
    pct destroy "$CTID" --purge
  else
    log "Il CT $CTID esiste già: salto la creazione (usa --recreate per ripartire da zero)."
    ensure_conf
    start_and_wait
    exit 0
  fi
fi

# --- Template Arch ----------------------------------------------------------------
log "Template Arch"
pveam update >/dev/null
TEMPLATE=$(pveam available --section system | awk '$2 ~ /^archlinux-base/ {print $2}' | sort -V | tail -1)
[[ -n $TEMPLATE ]] || die "Nessun template archlinux-base trovato con pveam."
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# --- Creazione: PRIVILEGED (--unprivileged 0) fin dall'inizio ---------------------------
log "pct create $CTID ($CORES core, $((MEMORY_MB / 1024)) GB RAM, ${DISK_GB} GB su $STORAGE)"
ROOT_PW=$(openssl rand -base64 24) # root non serve via password: si entra con `pct enter`
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
log "Container $CTID avviato"
