# shellcheck shell=bash
# =============================================================================
#  CONFIGURATION: the only file to edit before running ./install.sh
#  (put personal, non-versioned values in config.local.sh, ignored by git)
# =============================================================================

# --- Container ---------------------------------------------------------------
CTID=201
IP_CT=192.168.1.201
CIDR=24
GATEWAY=192.168.1.1          # WARNING: your LAN's real gateway (the router), NOT the DNS server
DNS=192.168.1.1
BRIDGE=vmbr0                 # 1G bridge, same speed as the Moonlight client
CT_HOSTNAME=arch-desktop

CORES=10
MEMORY_MB=16384
SWAP_MB=0
DISK_GB=64
STORAGE=local-zfs            # rootfs storage (check with `pvesm status`)
TEMPLATE_STORAGE=local       # storage holding the templates (vztmpl)

# --- Container user ----------------------------------------------------------
# The password is NOT stored here: install.sh asks for it
# (or reads the CT_USER_PASSWORD environment variable, e.g. from config.local.sh).
CT_USER=elm
SSH_PUBKEY=""                # optional: public key to authorize (the key itself, one line)
SSH_DISABLE_PASSWORD=0       # 1 = disable SSH password login (only if SSH_PUBKEY is set)

# --- System ------------------------------------------------------------------
TIMEZONE=Europe/Rome
LOCALE=it_IT.UTF-8           # e.g. en_US.UTF-8
KB_LAYOUT=""                 # optional Plasma keyboard layout (e.g. "it"); empty = leave alone

# --- Virtual display (HDMI dummy plug) ---------------------------------------
CONNECTOR=auto               # auto = detect the HDMI port; or force one, e.g. HDMI-A-3
RESOLUTION=1920x1080@60

# --- Host: permissions of the GPU device nodes -------------------------------
# renderD* stays 0666 (the container user needs it).
# card*: 0660 by default; if KWin fails to start, set 0666.
CARD_MODE=0660

# --- Miscellaneous -----------------------------------------------------------
SUNSHINE_AUR_COMMIT=""       # empty = latest AUR commit; or pin a hash for reproducibility
INSTALL_DIAG=1               # 1 = install mesa-utils and iperf3 (diagnostics)
EXTRA_PACKAGES=""            # extra pacman packages, space separated

# --- Desktop packages --------------------------------------------------------
# plasma-desktop instead of plasma-meta, on purpose: no Discover, Bluetooth,
# NetworkManager applet, firewall/thunderbolt/disks/vault KCMs, KRDP. A meta
# package does not let you drop its dependencies one by one.
# powerdevil stays: it is a hard dependency of plasma-desktop (we make it harmless
# in 01-system.sh).
PLASMA_PACKAGES="plasma-desktop kscreen kscreenlocker kwin kpipewire xdg-desktop-portal-kde \
plasma-pa plasma-systemmonitor kinfocenter kde-cli-tools kde-gtk-config breeze breeze-gtk \
kdeplasma-addons drkonqi ocean-sound-theme oxygen-sounds konsole dolphin"
INSTALL_MEDIA=1              # 1 = multimedia desktop (see MEDIA_PACKAGES)
MEDIA_PACKAGES="spectacle gwenview okular ark vlc vlc-plugins-all plasma5-integration \
ffmpegthumbs kdegraphics-thumbnailers kio-extras"
DISABLE_FILE_INDEXING=1      # 1 = disable Baloo (file indexing): avoids CPU/disk spikes
DISABLE_KWALLET=1            # 1 = disable KWallet: the session starts without a typed password

# --- AUR helper and AUR packages ---------------------------------------------
INSTALL_AUR_HELPER=1         # 1 = install yay-bin (via makepkg); then `yay -Syu` also updates Sunshine
AUR_PACKAGES=""              # extra AUR packages installed with yay (e.g. "brave-bin"):
                             # empty in the repo, set it in your own config.local.sh
