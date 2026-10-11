# shellcheck shell=bash
# =============================================================================
#  CONFIGURAZIONE: è l'unico file da modificare prima di lanciare ./install.sh
#  (per valori personali non versionati usa config.local.sh, ignorato da git)
# =============================================================================

# --- Container ---------------------------------------------------------------
CTID=201
IP_CT=192.168.1.201
CIDR=24
GATEWAY=192.168.1.1          # ATTENZIONE: verifica che sia il gateway della tua LAN
DNS=192.168.1.1
BRIDGE=vmbr0                 # scheda a 1G, la stessa velocità del client Moonlight
CT_HOSTNAME=arch-desktop

CORES=10
MEMORY_MB=16384
SWAP_MB=512
DISK_GB=64
STORAGE=local-zfs            # storage del rootfs (ATTENZIONE: verifica con `pvesm status`)
TEMPLATE_STORAGE=local       # storage dei template (vztmpl)

# --- Utente del container ----------------------------------------------------
# La password NON sta qui: viene chiesta all'avvio di install.sh
# (oppure da variabile d'ambiente UTENTE_PASSWORD, es. in config.local.sh).
UTENTE=elm
SSH_PUBKEY=""                # opzionale: chiave pubblica da autorizzare (contenuto, una riga)
SSH_DISABLE_PASSWORD=0       # 1 = disattiva il login SSH con password (solo se SSH_PUBKEY è impostata)

# --- Sistema -----------------------------------------------------------------
TIMEZONE=Europe/Rome
LOCALE=it_IT.UTF-8
KB_LAYOUT=""                 # opzionale: layout tastiera di Plasma (es. "it"); vuoto = non toccare

# --- Schermo virtuale (dummy plug HDMI) ---------------------------------------
CONNETTORE=auto              # auto = rileva la porta HDMI; oppure forza, es. HDMI-A-3
RISOLUZIONE=1920x1080@60

# --- Host: permessi dei nodi della GPU ----------------------------------------
# I renderD* restano 0666 (servono all'utente nel container).
# card*: 0660 è da verificare (se KWin non parte, rimetti 0666).
CARD_MODE=0660

# --- Opzioni varie -------------------------------------------------------------
SUNSHINE_AUR_COMMIT=""       # vuoto = ultimo commit dell'AUR; oppure fissa un hash per riproducibilità
INSTALL_DIAG=1               # 1 = installa mesa-utils e iperf3 (diagnostica)
EXTRA_PACKAGES=""            # pacchetti pacman aggiuntivi, separati da spazio
