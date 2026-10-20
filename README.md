# Arch Linux in an LXC on Proxmox with Plasma Wayland and Sunshine

🇮🇹 [Italiano](README.it.md)

A KDE Plasma or Hyprland (Wayland) desktop in a **privileged** Arch Linux LXC container on Proxmox,
sharing the host's Intel iGPU (`i915` driver), streamed with Sunshine (VAAPI encoding; `kwin` capture
for Plasma, `wlr` for Hyprland) to Moonlight.
No display manager: the session is started by a systemd service. The goal is a desktop that behaves
like a locally installed OS, with rock-solid GPU acceleration and streaming.

The original manual procedure (and the table of problems met along the way) is in
[`docs/manual-procedure.md`](docs/manual-procedure.md).

## Requirements

- Proxmox host with an Intel iGPU using the **`i915`** driver (with `xe` the GPU kept resetting on the
  tested card; the scripts stop if they see `xe`).
- An HDMI dummy plug in the iGPU's HDMI port.
- The container on a bridge with the same speed as the Moonlight client (1G in the tested setup).
- Tested on: Lenovo ThinkCentre M90q (UHD 770), Proxmox with kernel 7.0, Moonlight on a Mac.

## Usage

```bash
# on the Proxmox host, as root (use tmux: the install takes several minutes)
git clone <this-repo> && cd arch-lxc-sunshine
nano config.sh                # CTID, IP, gateway, storage, user...  (or use config.local.sh)
./install.sh                  # asks for the user's password
./install.sh --recreate       # destroys the CT (asks for confirmation) and starts from scratch
```

Everything is idempotent: you can re-run `./install.sh` on an existing container. Logs go to `logs/`
(ignored by git).

Personal values (gateway, DNS, locale, AUR packages...) go in `config.local.sh`, which is read after
`config.sh` and ignored by git, so `git pull` never conflicts with your settings:

```bash
# config.local.sh
GATEWAY=192.168.1.1      # your router, NOT the DNS server
DNS=192.168.1.53
AUR_PACKAGES="brave-bin"
```

### Choosing the desktop

`DESKTOP=plasma` (default) or `DESKTOP=hyprland`, in `config.sh` or `config.local.sh`. Everything
below the desktop is shared: host setup, container, GPU, session service without a display manager,
Sunshine, connector detection, checks. Only the packages, the session unit and the capture backend change.

- **plasma**: `plasma-desktop` + multimedia set, `capture = kwin`.
- **hyprland**: bare Hyprland (needs **>= 0.55**, the generated config is Lua) with foot, fuzzel,
  portals, clipboard and screenshot tools, `capture = wlr`. `~/.config/hypr/hyprland.lua` is created
  only if missing; `~/.config/hypr/monitors.lua` (output and mode) is regenerated on every run.
  Hyprland starts `hyprland-session.target` at launch, which pulls in `graphical-session.target` and
  with it the Sunshine user service. Keys: `Super+Return` terminal, `Super+Space` launcher, `Super+Q` close.

To try the other desktop use a new CT (`CTID`/`IP_CT`, see the "Addressing" note below) or `--recreate`.

Still manual after the script: the Sunshine panel credentials (`https://<IP_CT>:47990`), pairing with
Moonlight, and choosing a browser.

## What it does

- **Host**: checks the `i915` driver, loads `uinput`, sets the udev rule for the GPU nodes.
- **Container**: creates it (privileged, `nesting`, `fuse`, `/dev/dri` and `/dev/input` passthrough,
  writable `/sys`), installs the system, a user with sudo, a locale, SSH.
- **Desktop** (`DESKTOP=plasma`): `plasma-desktop` plus a multimedia set (Spectacle, Gwenview, Okular, Ark, VLC, thumbnailers).
  No Discover, Bluetooth, NetworkManager applet, firewall/thunderbolt/disks/vault KCMs, KRDP, KWallet.
  Baloo (file indexing) is off, suspend is disabled, screen-off and lock are off.
- **Desktop** (`DESKTOP=hyprland`): Hyprland and a small set of Wayland tools (see `HYPRLAND_PACKAGES`),
  plus a multimedia set (mpv, VLC, imv, Evince, Nautilus...). Suspend is disabled in both cases.
- **Sunshine**: `sunshine-bin` and `yay-bin` from the AUR, `capture = kwin` (Plasma) or `wlr` (Hyprland), user service enabled.
- **Session**: starts the desktop, detects the HDMI port, sets 1920x1080@60, waits for Sunshine, runs the checks.

## Layout

```
config.sh                 all the variables (CTID, IP, resources, user, resolution, packages...)
install.sh                orchestrator, run on the Proxmox host
lib.sh                    shared logging/waiting helpers
host/setup-host.sh        i915 check, uinput, udev rule for the GPU nodes
host/create-ct.sh         template, pct create (privileged), .conf lines, start
container/01-system.sh    pacman, packages, user, sudo, SSH, locale, desktop settings (Plasma or Hyprland)
container/02-sunshine.sh  yay-bin and sunshine-bin from the AUR (temporary sudo), sunshine.conf, service
container/03-session.sh   start the session, detect HDMI, 1920x1080@60, wait for Sunshine
container/aur-build.sh    builds one AUR package with makepkg (as a normal user)
container/verify.sh       checks (also usable on its own)
files/plasma-session.service, hyprland-session.service/.target, hyprland.lua
docs/                     manual procedure (EN/IT)
```

## Design notes

- **Video connector**: `CONNECTOR=auto` looks in `/sys/class/drm` for the `HDMI-A-n` output (USB-C with
  DP alt-mode and DisplayPort show up as `DP-n`) and prefers the one that is `connected`.
- **Password**: never in the repo; asked at runtime or taken from `CT_USER_PASSWORD`
  (e.g. in `config.local.sh`).
- **AUR**: `yay-bin` and `sunshine-bin` are built with `makepkg` (`SUNSHINE_AUR_COMMIT` pins a Sunshine
  commit; the PKGBUILDs end up in the log). Afterwards `yay -Syu` updates repos and AUR together. Extra AUR
  packages (e.g. Brave) go in `AUR_PACKAGES`. Without the helper (`INSTALL_AUR_HELPER=0`) AUR updates are manual.
- **GPU permissions**: `renderD*` at 0666; `card*` at `CARD_MODE` (0660 by default).
- **Addressing**: the last octet of the IP matches the CT ID (`.200` for CT 200), outside the router's
  DHCP pool. `create-ct.sh` refuses to create the container if the address is already configured in
  another CT/VM or answers to ping: a duplicate IP made traffic go to the wrong machine, and it only
  showed up from outside the LAN.
- **Sunshine options**: `SUNSHINE_EXTRA="hevc_mode=3"` (key=value, space separated) goes into
  `sunshine.conf`; `hevc_mode=3` advertises HEVC Main10 (10-bit). `avahi` is installed so Sunshine can
  announce itself over mDNS.
- **Network**: the CT sits on `vmbr0`. Upstream bufferbloat and any flow control on a 2.5G NIC are
  separate topics, not handled here.
- **Security**: the container is privileged, `/sys` is writable and the render node is world-accessible
  on the host. That is the price of making udev, input and the GPU work; fine for a homelab, think twice
  elsewhere.

## Cold-boot checklist

1. `./install.sh` to the end, `verify.sh` all OK.
2. Moonlight pairing, "Desktop" app: picture, mouse and keyboard, audio from YouTube.
3. `pct reboot <CTID>`, wait a minute, reconnect.
4. Long 4K video (30+ minutes) with seeding active: no packet loss.
5. With `CARD_MODE=0660`: does KWin (or Hyprland) start? If not, set `CARD_MODE=0666`.

## Known limitations

- **AV1 encoding** is not available on the UHD 770 (Sunshine finds no usable AV1 encoding entrypoint).
- **YUV 4:4:4** is not offered with the VAAPI path in our tests: the GPU lists the HEVC 4:4:4 profiles
  in `vainfo`, but Sunshine does not use them (it is a per-encoder feature, and host-side 4:4:4 on Linux
  has been a work in progress upstream).
- **Bitrate**: with Moonlight set to 20 Mbit/s, Sunshine logged "Streaming bitrate is 14988000" (about
  75%); with 40 Mbit/s, about 30. Observed, not explained here.
- **Clipboard sharing** between the container and the client is not available with stock Sunshine and
  Moonlight.
