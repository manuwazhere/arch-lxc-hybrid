#!/usr/bin/env bash
# Orchestratore: da lanciare come root sull'host Proxmox.
#   ./install.sh              installa (se il CT esiste già, rieseguo gli step idempotenti)
#   ./install.sh --recreate   distrugge il CT esistente (con conferma) e riparte da zero
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
    *) die "Opzione sconosciuta: $arg" ;;
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

# --- Controlli preliminari -----------------------------------------------------
[[ $EUID -eq 0 ]] || die "Esegui come root sull'host Proxmox."
command -v pct >/dev/null || die "pct non trovato: questo script va lanciato sull'host Proxmox."
[[ $UTENTE =~ ^[a-z_][a-z0-9_-]*$ ]] || die "UTENTE non valido: '$UTENTE'"

# --- Password dell'utente (chiesta subito, così puoi allontanarti dopo) ----------
PW=${UTENTE_PASSWORD:-}
ct_exists=0
pct status "$CTID" &>/dev/null && ct_exists=1
if [[ -z $PW ]] && { ((ct_exists == 0)) || ((RECREATE == 1)); }; then
  while :; do
    read -rsp "Password per l'utente '$UTENTE' nel container: " PW
    echo
    read -rsp "Ripeti la password: " PW2
    echo
    [[ -n $PW && $PW == "$PW2" ]] && break
    warn "Password vuota o diversa, riprova."
  done
fi

# --- 1. Host ---------------------------------------------------------------------
log "[1/5] Preparazione host"
bash host/setup-host.sh

# --- 2. Container ----------------------------------------------------------------
log "[2/5] Creazione e avvio del container $CTID"
bash host/create-ct.sh

# --- 3. Copia degli script nel container -------------------------------------------
log "[3/5] Copia degli script nel container"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
tar -C "$REPO_DIR" -czf "$tmpdir/setup.tgz" lib.sh container files
# Solo le variabili che servono dentro il container (la password non c'è).
for v in UTENTE IP_CT TIMEZONE LOCALE KB_LAYOUT SSH_PUBKEY SSH_DISABLE_PASSWORD \
  CONNETTORE RISOLUZIONE SUNSHINE_AUR_COMMIT INSTALL_DIAG EXTRA_PACKAGES \
  PLASMA_PACKAGES INSTALL_MEDIA MEDIA_PACKAGES DISABLE_FILE_INDEXING \
  INSTALL_AUR_HELPER AUR_PACKAGES; do
  declare -p "$v"
done >"$tmpdir/config.sh"

pct push "$CTID" "$tmpdir/setup.tgz" /tmp/arch-sunshine-setup.tgz
pct exec "$CTID" -- bash -c "rm -rf '$STAGE_DIR' && mkdir -p '$STAGE_DIR' \
  && tar -xzf /tmp/arch-sunshine-setup.tgz -C '$STAGE_DIR' && rm -f /tmp/arch-sunshine-setup.tgz"
pct push "$CTID" "$tmpdir/config.sh" "$STAGE_DIR/config.sh" --perms 644
pct exec "$CTID" -- chmod -R go+rX "$STAGE_DIR"

# --- 4. Sistema, utente, Plasma, Sunshine --------------------------------------------
log "[4/5] Sistema, utente, Plasma e Sunshine (la parte più lunga)"
pct exec "$CTID" -- bash "$STAGE_DIR/container/01-system.sh"
if [[ -n $PW ]]; then
  # La password passa da stdin: non compare tra gli argomenti dei processi.
  printf '%s:%s\n' "$UTENTE" "$PW" | pct exec "$CTID" -- chpasswd
  log "Password impostata per '$UTENTE'"
fi
pct exec "$CTID" -- bash "$STAGE_DIR/container/02-sunshine.sh"

# --- 5. Sessione e verifica ------------------------------------------------------------
log "[5/5] Avvio sessione Plasma e verifica"
pct exec "$CTID" -- bash "$STAGE_DIR/container/03-session.sh"
pct exec "$CTID" -- bash "$STAGE_DIR/container/verify.sh" || warn "Qualche verifica è fallita: leggi l'elenco sopra."

cat <<EOF

Fatto. Passi manuali rimasti:
  1. Apri https://${IP_CT}:47990 e crea utente e password del pannello Sunshine.
  2. In Moonlight aggiungi l'host ${IP_CT}, leggi il PIN e inseriscilo nel pannello (scheda PIN).
  3. Avvia l'app "Desktop". Prova a freddo: pct reboot ${CTID}, attendi ~1 minuto, ricollegati.
  4. Installa il browser che preferisci (Discover, pacman o Flatpak).
EOF
