#!/usr/bin/env bash
# Orchestrator: run as root on the Proxmox host.
#   ./install.sh              install (if the CT already exists, re-run the idempotent steps)
#   ./install.sh --recreate   destroy the existing CT (with confirmation) and start from scratch
set -Eeuo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$REPO_DIR"
# shellcheck source=lib.sh
source ./lib.sh

RECREATE=0
for arg in "$@"; do
  case $arg in
    --recreate) RECREATE=1 ;;
    -h | --help) sed -n '2,4p' "$0"; exit 0 ;;
    *) die "Unknown option: $arg" ;;
  esac
done

set -a
# shellcheck source=config.sh
source ./config.sh
if [[ -f ./config.local.sh ]]; then
  # shellcheck source=/dev/null
  source ./config.local.sh
fi
set +a
export RECREATE
STAGE_DIR=/opt/arch-sunshine-setup

mkdir -p logs
exec > >(tee -a "logs/install-$(date +%Y%m%d-%H%M%S).log") 2>&1

# --- Preflight checks -----------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
command -v pct >/dev/null || die "pct not found: this script must run on the Proxmox host."
[[ $CT_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid CT_USER: '$CT_USER'"

# --- User password (asked up front so you can walk away afterwards) -------------------
PW=${CT_USER_PASSWORD:-}
ct_exists=0
pct status "$CTID" &>/dev/null && ct_exists=1
if [[ -z $PW ]] && { ((ct_exists == 0)) || ((RECREATE == 1)); }; then
  while :; do
    read -rsp "Password for user '$CT_USER' in the container: " PW
    echo
    read -rsp "Repeat the password: " PW2
    echo
    [[ -n $PW && $PW == "$PW2" ]] && break
    warn "Empty or mismatching password, try again."
  done
fi

# --- 1. Host ----------------------------------------------------------------------
log "[1/5] Host preparation"
bash host/setup-host.sh

# --- 2. Container -----------------------------------------------------------------
log "[2/5] Creating and starting container $CTID"
bash host/create-ct.sh

# --- 3. Copy the scripts into the container ----------------------------------------
log "[3/5] Copying the scripts into the container"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
tar -C "$REPO_DIR" -czf "$tmpdir/setup.tgz" lib.sh container files
# Only the variables needed inside the container (the password is not among them).
for v in CT_USER IP_CT TIMEZONE LOCALE KB_LAYOUT SSH_PUBKEY SSH_DISABLE_PASSWORD \
  CONNECTOR RESOLUTION SUNSHINE_AUR_COMMIT SUNSHINE_EXTRA INSTALL_DIAG EXTRA_PACKAGES \
  PLASMA_PACKAGES INSTALL_MEDIA MEDIA_PACKAGES DISABLE_FILE_INDEXING DISABLE_KWALLET \
  INSTALL_AUR_HELPER AUR_PACKAGES; do
  declare -p "$v"
done >"$tmpdir/config.sh"

pct push "$CTID" "$tmpdir/setup.tgz" /tmp/arch-sunshine-setup.tgz
pct exec "$CTID" -- bash -c "rm -rf '$STAGE_DIR' && mkdir -p '$STAGE_DIR' \
  && tar -xzf /tmp/arch-sunshine-setup.tgz -C '$STAGE_DIR' && rm -f /tmp/arch-sunshine-setup.tgz"
pct push "$CTID" "$tmpdir/config.sh" "$STAGE_DIR/config.sh" --perms 644
pct exec "$CTID" -- chmod -R go+rX "$STAGE_DIR"

# --- 4. System, user, Plasma, Sunshine ------------------------------------------------
log "[4/5] System, user, Plasma and Sunshine (the long part)"
pct exec "$CTID" -- bash "$STAGE_DIR/container/01-system.sh"
if [[ -n $PW ]]; then
  # The password goes through stdin: it never shows up in process arguments.
  printf '%s:%s\n' "$CT_USER" "$PW" | pct exec "$CTID" -- chpasswd
  log "Password set for '$CT_USER'"
fi
pct exec "$CTID" -- bash "$STAGE_DIR/container/02-sunshine.sh"

# --- 5. Session and verification --------------------------------------------------------
log "[5/5] Starting the Plasma session and verifying"
pct exec "$CTID" -- bash "$STAGE_DIR/container/03-session.sh"
pct exec "$CTID" -- bash "$STAGE_DIR/container/verify.sh" || warn "Some checks failed: read the list above."

cat <<EOF

Done. Manual steps left:
  1. Open https://${IP_CT}:47990 and create the Sunshine panel user and password.
  2. In Moonlight add the host ${IP_CT}, read the PIN and enter it in the panel (PIN tab).
  3. Start the "Desktop" app. Cold-boot test: pct reboot ${CTID}, wait ~1 minute, reconnect.
  4. Install the browser you prefer (pacman, or yay for the AUR).

After a --recreate, ssh will warn "REMOTE HOST IDENTIFICATION HAS CHANGED": that is expected
(the container has new host keys). Verify the fingerprint, then: ssh-keygen -R ${IP_CT}
EOF
