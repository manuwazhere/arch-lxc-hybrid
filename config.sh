# shellcheck shell=bash
# =============================================================================
#  CONFIGURATION: the only file to edit before running ./install.sh
#  (put personal, non-versioned values in config.local.sh, ignored by git)
# =============================================================================

# --- Container ---------------------------------------------------------------
CTID=200                     # convention: same number as the last octet of IP_CT
IP_CT=192.168.1.200          # must be unique and OUTSIDE the router's DHCP pool (create-ct.sh checks)
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

# --- Desktop -----------------------------------------------------------------
# plasma   = KDE Plasma (Wayland), Sunshine capture = kwin
# hyprland = Hyprland (Wayland), Sunshine capture = wlr. Needs Hyprland >= 0.55
#            (the generated config is Lua). Same GPU/Sunshine/session plumbing.
DESKTOP=plasma
# hyprland only: 1 = start Hyprland through uwsm (the Wayland session manager) instead of
# start-hyprland. Required by the Omarchy layer (34 of its commands use uwsm-app).
HYPRLAND_UWSM=0

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
# card*: 0660 by default; if KWin/Hyprland fails to start, set 0666.
CARD_MODE=0660

# --- Miscellaneous -----------------------------------------------------------
SUNSHINE_AUR_COMMIT=""       # empty = latest AUR commit; or pin a hash for reproducibility
SUNSHINE_EXTRA="hevc_mode=3"  # extra sunshine.conf options, space separated key=value;
                             # hevc_mode=3 also advertises HEVC Main10 (10-bit). Empty = none
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
INSTALL_MEDIA=1              # 1 = multimedia desktop (MEDIA_PACKAGES, or HYPRLAND_MEDIA_PACKAGES)
MEDIA_PACKAGES="spectacle gwenview okular ark vlc vlc-plugins-all plasma5-integration \
ffmpegthumbs kdegraphics-thumbnailers kio-extras"
DISABLE_FILE_INDEXING=1      # 1 = disable Baloo (file indexing): avoids CPU/disk spikes
DISABLE_KWALLET=1            # 1 = disable KWallet: the session starts without a typed password

# --- Hyprland packages (DESKTOP=hyprland) ----------------------------------------
# Deliberately bare: compositor, portals, terminal, launcher, clipboard and screenshot
# tools. No bar, no display manager, no browser. INSTALL_MEDIA=1 adds the set below.
HYPRLAND_PACKAGES="hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpolkitagent \
qt6-wayland foot fuzzel wl-clipboard grim slurp jq noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd"
HYPRLAND_MEDIA_PACKAGES="mpv vlc vlc-plugins-all imv evince file-roller nautilus ffmpegthumbnailer"

# --- Omarchy layer (DESKTOP=hyprland + HYPRLAND_UWSM=1) -------------------------------
# Copies Omarchy's files (Hyprland Lua config, quickshell shell, themes, omarchy-* commands) from a
# pinned tag. It does NOT install Omarchy's own pacman packages (omarchy / omarchy-settings): they
# hard-depend on sddm, limine and snapper and ship hooks that would break pacman -Syu in a container.
INSTALL_OMARCHY=0
OMARCHY_REF="v4.0.6"          # tag of https://github.com/omacom/omarchy
# Commit of https://github.com/omacom/omarchy-pkgs: PKGBUILDs for packages that are not in the Arch repos.
OMARCHY_PKGS_REF="c9518288fabfcd1c83fd9163f95f067df4c6cddc"
# Packages built from omarchy-pkgs even when Arch has them (quickshell: Omarchy pins a patched build).
OMARCHY_BUILD_FROM_PKGS="quickshell"
# Packages of omarchy-base.packages that are NOT installed: bare metal, boot, services, big apps.
OMARCHY_SKIP_PACKAGES="bluez bluez-tools bluez-utils bolt brightnessctl ddcutil asdcontrol \
cups cups-filters cups-pk-helper system-config-printer docker docker-buildx docker-compose lazydocker \
ufw ufw-docker plymouth sddm networkmanager power-profiles-daemon wireless-regdb kernel-modules-hook \
qemu-user-static-binfmt plocate tzupdate gnome-disk-utility dotnet-runtime mariadb-libs postgresql-libs \
fcitx5 fcitx5-gtk fcitx5-qt noto-fonts-cjk libreoffice-fresh obs-studio kdenlive obsidian xournalpp pinta \
chromium gpu-screen-recorder localsend cliamp herdr aether omawrite omacut ttfx tensaku ttf-ia-writer \
ttf-jetbrains-mono-nerd-basic \
hyprland-preview-share-picker hyprsunset clang llvm yay nvim moonlight-qt tesseract tesseract-data-eng"
# omarchy-* commands that are not installed (regex on the command name): they would touch the
# bootloader, snapshots, the display manager, mirrors or the whole system.
OMARCHY_SKIP_COMMANDS='^omarchy-(system-factory-reset.*|upgrade-to-quattro|provision-owner|hibernation-.*|refresh-limine|refresh-sddm|snapshot|plymouth-.*|reinstall.*|channel-set|update(-.*)?)$'

# --- AUR helper and AUR packages ---------------------------------------------
INSTALL_AUR_HELPER=1         # 1 = install yay-bin (via makepkg); then `yay -Syu` also updates Sunshine
AUR_PACKAGES=""              # extra AUR packages installed with yay (e.g. "brave-bin"):
                             # empty in the repo, set it in your own config.local.sh
