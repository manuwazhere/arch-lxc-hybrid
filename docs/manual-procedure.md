# Plasma + Sunshine in an Arch LXC on Proxmox (Intel iGPU)

> **Note on the state of the repo:** this is the manual procedure, reconstructed before it was scripted. The scripts in this repo replace it for installation, and some choices have changed (only `capture = kwin`, `plasma-desktop` instead of `plasma-meta`, no Chromium, Discover or KWallet, swap at 0). It is still useful for understanding *why* each step exists, and as a table of the problems we ran into.
> Italian version: [manual-procedure.it.md](manual-procedure.it.md)

Reconstructed from the procedure that was followed: **privileged** Arch container on a Proxmox host, Intel UHD 770 iGPU with the `i915` driver (with `xe` the GPU kept resetting), HDMI dummy plug, Moonlight client on a Mac over a 1G link.

**Placeholders to replace:** `<CTID>` (container ID), `<USER>` (regular user), `<IP_CT>` (container IP), `<CONNECTOR>` (video output with the dummy plug, e.g. `HDMI-A-3`), `<GID_VIDEO>` and `<GID_RENDER>` (gids of the groups inside the container, only for the single-devices variant in 2.2).

**Working end state:** Plasma Wayland session started by a systemd service (no SDDM), Sunshine capture through `kwin`, VAAPI encoding (HEVC at 40 Mbit/s or H.264), audio through Sunshine's virtual sink, input through `uinput`. Network: the container sits on the host's 1G NIC (same speed as the client) and heavy traffic (torrents, Samba, media) goes over the 2.5G one. GPU: no resets since the host moved to `i915`.

> Section 1 is reconstructed from the conversation. The **real** list of packages explicitly installed in the original container (`pacman -Qqen` and `pacman -Qqem`) is the one below; the others (konsole, dolphin, pipewire, wireplumber, spectacle, ffmpeg, mesa-utils...) came in as dependencies:
> 
> ```
> archlinux-keyring base base-devel chromium ex-vi-compat git inetutils
> intel-media-driver iperf3 libva-utils mesa nano openssh pacman plasma-meta
> sudo vulkan-intel vulkan-tools
> AUR: sunshine-bin
> ```
> 
> `pacman.conf` has `DisableSandboxFilesystem` enabled (with `DisableSandboxSyscalls` commented out). `sddm` is not among the explicit packages.

---

## 0. Prerequisites and creating the container

**Host (Proxmox)**

- iGPU driver: **`i915`** (the default for this card: the host's kernel command line must not contain `xe.force_probe=4690`, `i915.force_probe=!4690` or `xe.max_vfs=7`). With `xe` the graphics engine kept resetting (section 4). The device node name changes with the driver (`card0` with `xe`, `card1` with `i915` on this host): that is why the whole `/dev/dri` folder is passed to the container (2.2).
- HDMI dummy plug connected to the iGPU port. KWin (which drives DRM) needs it to have a video output.
- `uinput` module loaded and persistent:

```bash
modprobe uinput
echo uinput > /etc/modules-load.d/uinput.conf
```

- GPU node permissions: a udev rule that makes them openable by everyone. It is needed with the `/dev/dri` bind mount (the host's groups have different numbers inside the container) and for unprivileged containers:

```bash
cat > /etc/udev/rules.d/99-dri-permissions.rules <<'EOF'
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="card*", MODE="0666"
EOF
udevadm control --reload && udevadm trigger -s drm
```

The `card*` line is probably wider than necessary (not tried with `0660`). With this rule any host process can open the GPU: acceptable on a homelab with no other users.

**Container**

- Proxmox's Arch template (`pveam update; pveam available --section system | grep -i arch`) or a community script.
- **Privileged**: untick "Unprivileged container" *at creation time*. If you change it afterwards, the rootfs keeps uids shifted to 100000 and systemd reports `unsafe path transition ... owned by 100000`: it has to be recreated.
- `nesting` and `fuse` features (in the wizard `nesting` is greyed out unless the container is unprivileged: set it once the container exists, see 2.2).
- Resources (cores, RAM): we did not write them down, check with `pct config <CTID>`.
- Network: in our case the container sits on the **1G** NIC (`vmbr0`), the same speed as the client, and heavy traffic (torrents, Samba, media) on the 2.5G one (`vmbr1`). With the container on the 2.5G NIC, Sunshine's bursts towards a 1G client lost packets (section 3); the pacing in section 2.10 improved things but did not fully solve it.
- To get in from the host: `pct enter <CTID>`, then `exec bash -l` (the `pct enter` shell does not load profiles).

---

## 1. Packages installed with pacman

Everything as root in the container (or with `sudo` after step 2.1), in the order it was done.

### 1.1 First boot: update the system

```bash
pacman-key --init && pacman-key --populate archlinux   # only if pacman complains about keys
nano /etc/pacman.conf    # in [options] uncomment:  DisableSandboxFilesystem
pacman -Syu
```

Why: the host kernel has no Landlock and pacman 7 prints `restricting filesystem access failed because Landlock is not supported by the kernel`. Leave `DisableSandboxSyscalls` commented out (the syscall filter works). Alternatively, without touching the file: `pacman --disable-sandbox -Syu` every time.

### 1.2 Base

```bash
pacman -S sudo openssh
systemctl enable --now sshd
```

### 1.3 GPU: media driver and Vulkan

```bash
pacman -S intel-media-driver libva-utils vulkan-intel mesa vulkan-tools
```

`intel-media-driver` from the official repos has every codec: no extra repo needed (on Fedora RPM Fusion was required).

### 1.4 Desktop and audio

```bash
pacman -S plasma-meta konsole dolphin pipewire pipewire-pulse wireplumber
```

Accept the defaults when asked about providers (fonts, etc.). `spectacle` and `ffmpeg` come in as dependencies.

`sddm` was installed at the beginning but is **not used** (see 2.5): do not install it in the replica; if pacman asks for it as a dependency, leave it disabled.

### 1.5 Tools to build from the AUR

```bash
pacman -S --needed base-devel git
```

### 1.6 Sunshine (AUR, binary package)

Sunshine is **not in the official repos** (`pacman -Ss sunshine` finds nothing): use `sunshine-bin` from the AUR. As a regular user, never as root:

```bash
git clone https://aur.archlinux.org/sunshine-bin.git
cd sunshine-bin
less PKGBUILD        # always review before building from the AUR
makepkg -si
```

Version used: 2026.914.233613 (`pacman -Qi sunshine-bin`). The package installs the user service `app-dev.lizardbyte.app.Sunshine.service`.

### 1.7 Optional diagnostics

```bash
pacman -S mesa-utils iperf3    # glxgears; UDP bandwidth test
```

### 1.8 Not done yet

Steam and Proton for games (Warcraft II Remastered): this needs `[multilib]` enabled in `/etc/pacman.conf`, `lib32-vulkan-intel` and `steam`. Browser: Brave, installed as a Flatpak (from the `chrome://gpu` file: executable in `/app/brave/brave`, Chrome 155, native Wayland with `--ozone-platform=wayland`, `--ignore-gpu-blocklist` and `--render-node-override=/dev/dri/renderD128`). That is why it does not appear among pacman and AUR packages; `chromium` among the explicit packages is a different installation, whose use I do not know. With this setup video decoding (H.264, VP9, HEVC, AV1) and rendering show up as accelerated by the iGPU.

---

## 2. Configuration, tweaks and Sunshine

### 2.1 User, sudo, SSH

```bash
useradd -m -G wheel,video,render -s /bin/bash <USER>
passwd <USER>
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -c
```

If `useradd` says `render` does not exist: `groupadd -r render` and retry. From the client: `ssh-copy-id <USER>@<IP_CT>` (then, if you like, `PasswordAuthentication no` in `/etc/ssh/sshd_config.d/`).

### 2.2 LXC: devices, writable `/sys`, input, GPU (on the host)

On the host:

```bash
pct set <CTID> --features nesting=1,fuse=1
pct set <CTID> -dev0 /dev/uinput,mode=0666
```

In `/etc/pve/lxc/<CTID>.conf` add these lines:

```
lxc.mount.auto: proc:rw sys:rw
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
```

Then `pct reboot <CTID>`.

What each one is for:

| Entry | Why |
| --- | --- |
| `/dev/dri` (bind mount + `c 226:*`) | KWin drives the video output; VAAPI uses the render node. Passing the whole folder avoids rewriting the lines when the card number changes (`card0` with `xe`, `card1` with `i915`). Inside the container the nodes arrive with the host's permissions: you need the ones from the udev rule in section 0. |
| `/dev/uinput` (`mode=0666`) | Sunshine creates the virtual mouse and keyboard. |
| `sys:rw` | `systemd-udevd` does not start with a read-only `/sys`; without udev no device gets the `seat0` tags (logind) and KWin/libinput see neither screen nor input. |
| `c 13:*` + `/dev/input` mount | An LXC's `/dev` does not update by itself: it needs the host's `eventN` nodes. |

**Single-devices variant** (works, but the card name changes with the driver and has to be rewritten; the `gid=` values are those of the groups **inside** the container). Instead of the bare `-dev0 /dev/uinput` above and the two `/dev/dri` lines in the `.conf`:

```bash
getent group video render      # in the container: the gids to use below
pct set <CTID> \
  -dev0 /dev/dri/card1,gid=<GID_VIDEO> \
  -dev1 /dev/dri/renderD128,gid=<GID_RENDER> \
  -dev2 /dev/uinput,mode=0666
```

**No `lxc.cap.drop` lines**: they were only needed to use `setcap` with KMS capture. With `capture = kwin` the container keeps the default capabilities and Sunshine works. Do not `setcap` Sunshine.

### 2.3 Basic checks (in the container)

```bash
ls -l /dev/dri /dev/uinput /dev/input        # cardN, renderD128, uinput, eventN
findmnt /sys                                  # must have rw
systemctl is-active systemd-udevd systemd-udev-trigger   # active, active
udevadm info /dev/dri/card1 | grep TAGS      # (card0 with xe) must contain seat and master-of-seat
loginctl seat-status seat0                    # must list the card
LIBVA_DRIVER_NAME=iHD vainfo --display drm --device /dev/dri/renderD128   # H264/HEVC with EncSliceLP
vulkaninfo --summary 2>/dev/null | sed -n '/^Devices/,$p'                # Intel UHD 770
```

If `systemd-udevd` shows as inactive because of `ConditionPathIsReadWrite=/sys`, `/sys` is not writable: recheck the `.conf` lines. (The original container has two `ConditionPathIsReadWrite=` drop-ins for `systemd-udevd` and `systemd-udev-trigger`, created before `/sys` was made writable: they are not needed afterwards, do not create them.)

### 2.4 Locale (optional)

```bash
sed -i 's/^#it_IT.UTF-8/it_IT.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=it_IT.UTF-8' > /etc/locale.conf
```

(Use whichever locale you prefer, e.g. `en_US.UTF-8`.)

### 2.5 Plasma Wayland session without SDDM

SDDM starts an Xorg for the login screen that keeps `card0` open: KWin then fails with `Failed to open /dev/dri/card0 device (Device or resource busy)`. Use a service that starts the session directly:

```bash
systemctl disable --now sddm 2>/dev/null   # if installed

cat > /etc/systemd/system/plasma-session.service <<'EOF'
[Unit]
Description=Plasma Wayland session
After=systemd-user-sessions.service systemd-logind.service systemd-udev-trigger.service
Wants=systemd-logind.service

[Service]
User=<USER>
PAMName=login
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_CLASS=user
Environment=XDG_SEAT=seat0
Environment=XDG_SESSION_DESKTOP=KDE
Environment=XDG_CURRENT_DESKTOP=KDE
ExecStart=/usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl set-default graphical.target
systemctl enable --now plasma-session
```

Check: `loginctl list-sessions` (the user's session on `seat0`, state `active`) and `pgrep -a kwin_wayland`.

### 2.6 Plasma: no screen-off, no lock, display at 60 Hz

As `<USER>`, over SSH:

```bash
kwriteconfig6 --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle false
kwriteconfig6 --file powerdevilrc --group AC --group Display --key DimDisplayWhenIdle false
kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false
kwriteconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume false
```

Over SSH, Qt apps need `WAYLAND_DISPLAY`:

```bash
export WAYLAND_DISPLAY=wayland-0
kscreen-doctor -o                                          # connector name and active mode (marked with *)
kscreen-doctor output.<CONNECTOR>.mode.1920x1080@60
```

### 2.7 Sunshine: configuration and start

As `<USER>`:

```bash
mkdir -p ~/.config/sunshine
cat >> ~/.config/sunshine/sunshine.conf <<'EOF'
capture = kwin
csrf_allowed_origins = https://<IP_CT>:47990
EOF

systemctl --user enable --now app-dev.lizardbyte.app.Sunshine.service
```

- `capture = kwin`: Sunshine asks KWin for the frames (screencast), without reading the video planes through KMS (which gave a black screen and required `CAP_SYS_ADMIN`).
- `csrf_allowed_origins`: without it the web panel answers "CSRF Protection Error" when you open it from the container's IP.
- Web panel: `https://<IP_CT>:47990` (self-signed certificate). Create a user and password on first access.
- `~/.config/sunshine/sunshine_state.json` holds the credentials: **do not commit it** if you put the configuration on GitHub.
- The user service starts with the graphical session (`graphical-session.target`) and has an initial 5-second pause.

Check the ports: `sudo ss -ltnp | grep -E ':(47984|47989|47990|48010)\b'`.

### 2.8 Pairing and Moonlight settings

1. In Moonlight add the host `<IP_CT>` and read the PIN.
2. In the Sunshine panel, *PIN* tab: enter it.
3. Start the "Desktop" app.

Settings that worked:

- **Codec chosen by hand** (not "automatic"). HEVC at 40 Mbit/s works perfectly (even over 5G with a VPN); H.264 is the alternative.
- **YUV 4:4:4 off**: the host does not support it (the encoder test says `YUV444: unsupported`). Turning it on only changes the default bitrate that is suggested.
- HDR off; 1080p at 60 fps. AV1 encoding is not available on this GPU.
- Moonlight's video renderer on the Mac: **Metal** instead of "automatic" (rendering times dropped to 1-2 ms).
- Statistics in Moonlight: Ctrl+Option+Shift+S (if I remember correctly).

### 2.9 Cold-boot test

`pct reboot <CTID>`, wait about a minute without touching anything, then connect with Moonlight. Check: picture, mouse and keyboard, audio from YouTube, and that the browser does not come back muted (see section 3).

### 2.10 Network pacing (alternative: the adopted solution is the 1G NIC)

If the container leaves through an interface that is faster than the devices downstream (for example the host's 2.5G towards a Mac or an access point at 1G), Sunshine's packet bursts (one per frame) can fill the buffers of a switch or router and cause losses even with plenty of bandwidth. In our case `iperf3 -u -b 40M/70` lost about 5.5% at 2.5G and almost nothing with the 900 Mbit/s limit. Slowing the sending rate slightly below that of the slowest downstream link (about 10% less: 900 for a 1G Mac; with the limit equal to the link speed the bursts are not smoothed) improves things a lot, but in long 4K video tests the periodic losses did not disappear entirely. The stable solution was to make the container leave through a NIC with the same speed as the client (1G). Possible cause, not verified: block sending (UDP GSO), which pacing does not split.

In the container (`eth0` is the container's interface):

```bash
sudo tc qdisc replace dev eth0 root fq maxrate 900mbit   # try it by hand
sudo tc qdisc del dev eth0 root                          # to remove it
```

To make it permanent (systemd unit not tried yet; `fq` may need the `sch_fq` module on the host):

```bash
cat > /etc/systemd/system/network-pacing.service <<'EOF'
[Unit]
Description=Network pacing for streaming
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/tc qdisc replace dev eth0 root fq maxrate 900mbit
ExecStop=/usr/bin/tc qdisc del dev eth0 root

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now network-pacing
```

**Adopted solution:** connect the container to the host's 1G interface (`vmbr0`) and move heavy traffic elsewhere (qBittorrent is on the 2.5G one).

Check, with `iperf3 -s` running in the container and from the client (the `/70` burst mode may not exist in old iperf3 versions): `iperf3 -c <IP_CT> -u -b 40M/70 -l 1200 -t 20 -R`. Loss should be close to zero.

---

## 3. Problems met and solutions

| Symptom | Cause | Solution |
| --- | --- | --- |
| `restricting filesystem access failed because Landlock is not supported` | The host kernel has no Landlock | `DisableSandboxFilesystem` in `pacman.conf` (1.1) |
| `Detected unsafe path transition / (owned by 100000)` | Container created unprivileged and then changed | Recreate it privileged from the start |
| SDDM stays idle, `seat0` without devices | udev does not start with a read-only `/sys` | `lxc.mount.auto: proc:rw sys:rw` (2.2) |
| KWin: `Failed to open /dev/dri/card0 (Device or resource busy)` | SDDM's greeter holds `card0` | `plasma-session` service, no SDDM (2.5) |
| Sunshine with KMS: `Failed to gain CAP_SYS_ADMIN`, then a black screen with a trail of cursors | Missing capabilities and unreadable video planes | `capture = kwin` (2.7) |
| Web panel: "CSRF Protection Error" | Origin not allowed | `csrf_allowed_origins` (2.7) |
| Mouse and keyboard do not arrive | The container's `/dev` lacks the `eventN` nodes | Mount `/dev/input` and `c 13:*` (2.2) |
| Moonlight: "the host does not support YUV 4:4:4" | The iGPU's VAAPI encoder has no 4:4:4 | Leave it off |
| No audio only from YouTube, Plasma's audio test works | The browser comes back with its audio stream **muted** (state remembered per application by WirePlumber) | With YouTube playing: `for i in $(pactl list short sink-inputs \| cut -f1); do pactl set-sink-input-mute "$i" 0; done` |
| Lower incoming frames per second with some videos | Many YouTube videos are 24-30 fps and the capture delivers frames when the screen changes | Check the real fps in "Stats for nerds" |
| Moonlight: "slow network", frames dropped by the network between 0 and 35%, occasional artifacts, fps between 30 and 60 (both wired and Wi-Fi) | The container was connected to the host's 2.5G network interface; suspected packet bursts at 2.5G towards 1G ports and devices (confirmed with `iperf3 -u -b 40M/70`: about 5.5% loss at 2.5G; the Philips 243B monitor dock lost no packets in the 867 Mbit/s test) | Connect the container to the 1G interface, the same speed as the client (stable); pacing at 800-900 Mbit/s (2.10) improved things but did not remove the periodic losses with long 4K videos |
| Black windows, occasional freezes, `dmesg` with `Engine reset: engine_class=rcs` and `Timedout job ... in plasmashell`, `plasma-discover` or `systemsettings` | `xe` driver on this card (ADL-S, kernel `7.0.14-20-pve`, GuC `70.49.4`) | Switch to `i915` by removing `xe.force_probe=4690`, `i915.force_probe=!4690` and `xe.max_vfs=7` from the kernel cmdline (section 0): no resets since |
| `Device /dev/dri/card0 does not exist` after changing driver | The card name changes (`card0` with `xe`, `card1` with `i915`) | Bind mount the whole `/dev/dri` folder (2.2) |

Diagnostic tools used:

```bash
journalctl --user -u app-dev.lizardbyte.app.Sunshine.service -b --no-pager | tail -50
loginctl list-sessions
pactl info | grep -i 'default sink'; pactl list short sinks; pactl list short sink-inputs
```

---

## 4. To verify / open

- **Mouse too fast:** solved; I did not note which setting did it (the options were Moonlight's mouse optimization for remote desktop, or the "flat" acceleration profile in Plasma). To be noted for the script.
- **Network:** solved with the container on the 1G NIC and qBittorrent moved to the 2.5G one. To be rechecked on the fresh install with a long 4K video (at least 30 minutes) and seeding active.
- **Low-power HEVC:** an `ffmpeg` test shows H.264 and HEVC on par, but in Sunshine HEVC gave artifacts and drops on the LAN. Most likely it was packet loss on the network (see above: 2.5G interface) and not the encoder; to be rechecked with the 1G interface. At 40 Mbit/s over 5G it worked.
- **Freeze when switching the theme to "automatic"** while capture was KMS: to be repeated with `capture = kwin`.
- **Steam, Proton and Battle.net** for Warcraft II Remastered: not done yet.
- **Graphics engine resets (`xe`)**: the host's dmesg shows several `Engine reset: engine_class=rcs`; on 10 October at 14:26:40 with `Timedout job ... in plasmashell`, eleven seconds after a stream started. Other resets on 10 October: 14:49 (`plasma-discover`), 15:16:30 and 15:19:22 (`systemsettings`), 15:19:11 (`plasmashell`). All are attributed to KDE Qt Quick applications, not to the browser or Sunshine, and have the same `seqno=4294967169` (if I read it right, the initial value: the first job of a new context does not complete; not verified). To find out whether they are related to black windows, freezes and frame loss. Since the host moved to `i915` (YouTube 4K, Settings, Discover, quick settings) none have appeared: the defect is in `xe` on this card and the GPU configuration looks stable. It remains possible to report it to the `xe` driver tracker, attaching the dump. Host kernel `7.0.14-20-pve`, Mesa 26.2.4 in the container. Dump saved on 10 October (`plasma-discover` process): the first job of a new context never completed, the engine is stopped on a `PIPE_CONTROL` (stall and flush, if I read the bits right) in the batch, with no hardware errors or page faults; GuC `70.49.4` loaded (the driver would like `70.44.1`), PCI `8086:4690` rev `0c`. To save one right after a reset (it lasts a few minutes): `sudo sh -c 'cat /sys/class/drm/card0/device/devcoredump/data > /root/xe-coredump.txt'`.
- **Optional hardening:** remove `mount=nfs;cifs` from the features if not needed (`pct set <CTID> --features nesting=1,fuse=1`), SSH with keys only, Proxmox firewall on the container. Structural limits remain: privileged container and writable `/sys` (both needed to make everything work).

---

## 5. Next steps and proposed script layout

1. Settle the remaining open items (section 4).
2. Fresh install following this file to the letter, noting every deviation: those are the fixes to carry back into the file and the script.
3. Script and Git repository.

Proposed layout:

```
repo/
  host/        setup-host.sh          # udev rule, uinput, pct set, .conf lines; note on the cmdline
  container/   setup-container.sh     # pacman, user, locale, plasma-session, kwriteconfig6
               aur-sunshine.sh        # as a regular user (makepkg)
  files/       plasma-session.service, sunshine.conf.example,
               99-dri-permissions.rules, network-pacing.service (optional)
  .gitignore                          # sunshine_state.json and any credentials
```

Notes for the script: variables at the top (`CTID`, `USER`, `IP_CT`, `CONNECTOR`); host and container are two separate scripts (they run in different environments); `makepkg` must not be run as root; steps that need a reboot (`pct reboot`) must be kept apart from the rest; pairing with Moonlight and the panel credentials stay manual; the `network-pacing.service` unit has not been tried.

(Status: this layout was the plan; the repo now implements it with `install.sh`, `host/` and `container/`: see the README.)
