# Plasma + Sunshine in un LXC Arch su Proxmox (iGPU Intel)

> **Nota sullo stato del repo:** questo è il manuale della procedura manuale, ricostruito prima di scriptarla. Per l'installazione lo sostituiscono gli script del repo, e alcune scelte sono cambiate (solo `capture = kwin`, `plasma-desktop` al posto di `plasma-meta`, niente Chromium, Discover e KWallet, swap a 0). Resta utile per capire il *perché* di ogni passo e come tabella dei problemi incontrati.
> English version: [manual-procedure.md](manual-procedure.md)

Ricostruito dalla procedura seguita: container Arch **privileged** su host Proxmox, iGPU Intel UHD 770 con driver `i915` (con `xe` comparivano reset della GPU), dummy plug HDMI, client Moonlight su Mac con collegamento a 1G.

**Segnaposto da sostituire:** `<CTID>` (ID del container), `<UTENTE>` (utente normale), `<IP_CT>` (IP del container), `<CONNETTORE>` (uscita video con il dummy plug, es. `HDMI-A-3`), `<GID_VIDEO>` e `<GID_RENDER>` (gid dei gruppi dentro il container, solo per la variante con i singoli device in 2.2).

**Stato finale funzionante:** sessione Plasma Wayland avviata da un servizio systemd (senza SDDM), cattura `kwin` in Sunshine, codifica VAAPI (HEVC a 40 Mbit/s o H.264), audio tramite l'uscita virtuale di Sunshine, input tramite `uinput`. Rete: il container sta sulla scheda a 1G dell'host (stessa velocità del client) e il traffico pesante (torrent, Samba, media) sulla 2,5G. GPU: nessun reset da quando l'host usa `i915`.

> La sezione 1 è ricostruita dalla conversazione. L'elenco **reale** dei pacchetti installati esplicitamente nel container originale (`pacman -Qqen` e `pacman -Qqem`) è questo; gli altri (konsole, dolphin, pipewire, wireplumber, spectacle, ffmpeg, mesa-utils...) sono arrivati come dipendenze:
> 
> ```
> archlinux-keyring base base-devel chromium ex-vi-compat git inetutils
> intel-media-driver iperf3 libva-utils mesa nano openssh pacman plasma-meta
> sudo vulkan-intel vulkan-tools
> AUR: sunshine-bin
> ```
> 
> In `pacman.conf` risulta attiva `DisableSandboxFilesystem` (con `DisableSandboxSyscalls` commentata). `sddm` non compare tra i pacchetti espliciti.

---

## 0. Prerequisiti e creazione del container

**Host (Proxmox)**

- Driver della iGPU: **`i915`** (quello predefinito per questa scheda: sulla riga di comando del kernel dell'host non devono esserci `xe.force_probe=4690`, `i915.force_probe=!4690` e `xe.max_vfs=7`). Con `xe` comparivano reset del motore grafico (sezione 4). Il nome del nodo cambia con il driver (`card0` con `xe`, `card1` con `i915` su questo host): per questo si passa al container l'intera cartella `/dev/dri` (2.2).
- Dummy plug HDMI collegato alla porta della iGPU. Serve a KWin (che pilota il DRM) per avere un'uscita video.
- Modulo `uinput` caricato e persistente:

```bash
modprobe uinput
echo uinput > /etc/modules-load.d/uinput.conf
```

- Permessi dei nodi della GPU: regola udev che li rende apribili da tutti. Serve con il bind mount di `/dev/dri` (nel container i gruppi dell'host hanno altri numeri) e per i container unprivileged:

```bash
cat > /etc/udev/rules.d/99-dri-permissions.rules <<'EOF'
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="card*", MODE="0666"
EOF
udevadm control --reload && udevadm trigger -s drm
```

La riga su `card*` è probabilmente più larga del necessario (non provato con `0660`). Con questa regola qualunque processo dell'host può aprire la GPU: accettabile su un homelab senza altri utenti.

**Container**

- Template Arch di Proxmox (`pveam update; pveam available --section system | grep -i arch`) oppure script della community.
- **Privileged**: togli la spunta "Unprivileged container" *alla creazione*. Se lo cambi dopo, il rootfs resta con uid spostati a 100000 e systemd segnala `unsafe path transition ... owned by 100000`: va ricreato.
- Features `nesting` e `fuse` (nel wizard `nesting` risulta grigio se non è unprivileged: si imposta a container creato, vedi 2.2).
- Risorse (core, RAM): non le abbiamo annotate, controlla con `pct config <CTID>`.
- Rete: nel nostro caso il container sta sulla scheda a **1G** (`vmbr0`), la stessa velocità del client, e il traffico pesante (torrent, Samba, media) sulla 2,5G (`vmbr1`). Con il container sulla 2,5G le raffiche di Sunshine verso un client a 1G facevano perdere pacchetti (sezione 3); il pacing della sezione 2.10 migliorava ma non risolveva del tutto.
- Per entrare dall'host: `pct enter <CTID>`, poi `exec bash -l` (la shell di `pct enter` non carica i profili).

---

## 1. Pacchetti installati con pacman

Tutto da root nel container (o con `sudo` dopo il passo 2.1), nell'ordine in cui è stato fatto.

### 1.1 Primo avvio: aggiornare il sistema

```bash
pacman-key --init && pacman-key --populate archlinux   # solo se pacman si lamenta delle chiavi
nano /etc/pacman.conf    # in [options] togli il commento a:  DisableSandboxFilesystem
pacman -Syu
```

Perché: il kernel dell'host non ha Landlock e pacman 7 dà `restricting filesystem access failed because Landlock is not supported by the kernel`. Lascia commentata `DisableSandboxSyscalls` (il filtro dei syscall funziona). In alternativa, senza toccare il file: `pacman --disable-sandbox -Syu` a ogni uso.

### 1.2 Base

```bash
pacman -S sudo openssh
systemctl enable --now sshd
```

### 1.3 GPU: driver media e Vulkan

```bash
pacman -S intel-media-driver libva-utils vulkan-intel mesa vulkan-tools
```

`intel-media-driver` dai repo ufficiali ha tutti i codec: non serve nessun repo aggiuntivo (su Fedora serviva RPM Fusion).

### 1.4 Desktop e audio

```bash
pacman -S plasma-meta konsole dolphin pipewire pipewire-pulse wireplumber
```

Alle richieste di provider (font, ecc.) accetta i default. `spectacle` e `ffmpeg` arrivano come dipendenze.

`sddm` è stato installato all'inizio ma **non si usa** (vedi 2.5): nel replica non installarlo; se pacman lo richiede come dipendenza, lascialo disabilitato.

### 1.5 Strumenti per compilare dall'AUR

```bash
pacman -S --needed base-devel git
```

### 1.6 Sunshine (AUR, pacchetto binario)

Sunshine **non è nei repo ufficiali** (`pacman -Ss sunshine` non trova niente): si usa `sunshine-bin` dall'AUR. Come utente normale, mai da root:

```bash
git clone https://aur.archlinux.org/sunshine-bin.git
cd sunshine-bin
less PKGBUILD        # controlla sempre prima di compilare dall'AUR
makepkg -si
```

Versione usata: 2026.914.233613 (`pacman -Qi sunshine-bin`). Il pacchetto installa il servizio utente `app-dev.lizardbyte.app.Sunshine.service`.

### 1.7 Opzionali di diagnostica

```bash
pacman -S mesa-utils iperf3    # glxgears; test di banda UDP
```

### 1.8 Non ancora fatto

Steam e Proton per i giochi (Warcraft II Remastered): serve abilitare `[multilib]` in `/etc/pacman.conf`, `lib32-vulkan-intel` e `steam`. Browser: Brave, installato come Flatpak (dal file di `chrome://gpu`: eseguibile in `/app/brave/brave`, Chrome 155, Wayland nativo con `--ozone-platform=wayland`, `--ignore-gpu-blocklist` e `--render-node-override=/dev/dri/renderD128`). Per questo non compare tra pacman e AUR; `chromium` tra i pacchetti espliciti è un'altra installazione, di cui non so l'uso. Con questa configurazione decodifica video (H.264, VP9, HEVC, AV1) e rendering risultano accelerati dalla iGPU.

---

## 2. Configurazioni, tweak e Sunshine

### 2.1 Utente, sudo, SSH

```bash
useradd -m -G wheel,video,render -s /bin/bash <UTENTE>
passwd <UTENTE>
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -c
```

Se `useradd` dice che `render` non esiste: `groupadd -r render` e riprova. Dal client: `ssh-copy-id <UTENTE>@<IP_CT>` (poi, se vuoi, `PasswordAuthentication no` in `/etc/ssh/sshd_config.d/`).

### 2.2 LXC: device, `/sys` scrivibile, input, GPU (sull'host)

Sull'host:

```bash
pct set <CTID> --features nesting=1,fuse=1
pct set <CTID> -dev0 /dev/uinput,mode=0666
```

In `/etc/pve/lxc/<CTID>.conf` aggiungi queste righe:

```
lxc.mount.auto: proc:rw sys:rw
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
```

Poi `pct reboot <CTID>`.

A cosa serve ciascuna:

| Voce | Perché |
| --- | --- |
| `/dev/dri` (bind mount + `c 226:*`) | KWin pilota l'uscita video; VAAPI usa il render node. Passare l'intera cartella evita di riscrivere le righe quando cambia il numero della scheda (`card0` con `xe`, `card1` con `i915`). Nel container i nodi arrivano con i permessi dell'host: servono quelli della regola udev della sezione 0. |
| `/dev/uinput` (`mode=0666`) | Sunshine crea mouse e tastiera virtuali. |
| `sys:rw` | `systemd-udevd` non parte con `/sys` in sola lettura; senza udev nessun device riceve i tag per `seat0` (logind) e KWin/libinput non vedono schermo e input. |
| `c 13:*` + mount di `/dev/input` | Il `/dev` di un LXC non si aggiorna da solo: servono i nodi `eventN` dell'host. |

**Variante con i singoli device** (funziona, ma il nome della card cambia con il driver e va riscritto; i `gid=` sono quelli dei gruppi **dentro** il container). Al posto del solo `-dev0 /dev/uinput` di sopra e delle due righe `/dev/dri` del `.conf`:

```bash
getent group video render      # nel container: i gid da usare sotto
pct set <CTID> \
  -dev0 /dev/dri/card1,gid=<GID_VIDEO> \
  -dev1 /dev/dri/renderD128,gid=<GID_RENDER> \
  -dev2 /dev/uinput,mode=0666
```

**Nessuna riga `lxc.cap.drop`**: erano servite solo per usare `setcap` con la cattura KMS. Con `capture = kwin` il container resta con le capability di default e Sunshine funziona. Non fare `setcap` su Sunshine.

### 2.3 Verifiche base (nel container)

```bash
ls -l /dev/dri /dev/uinput /dev/input        # cardN, renderD128, uinput, eventN
findmnt /sys                                  # deve avere rw
systemctl is-active systemd-udevd systemd-udev-trigger   # active, active
udevadm info /dev/dri/card1 | grep TAGS      # (card0 con xe) deve contenere seat e master-of-seat
loginctl seat-status seat0                    # deve elencare la card
LIBVA_DRIVER_NAME=iHD vainfo --display drm --device /dev/dri/renderD128   # H264/HEVC con EncSliceLP
vulkaninfo --summary 2>/dev/null | sed -n '/^Devices/,$p'                # Intel UHD 770
```

Se `systemd-udevd` risulta inattivo per `ConditionPathIsReadWrite=/sys`, `/sys` non è scrivibile: ricontrolla le righe del `.conf`. (Nel container originale esistono due drop-in `ConditionPathIsReadWrite=` per `systemd-udevd` e `systemd-udev-trigger`, creati prima di rendere `/sys` scrivibile: dopo non servono, non crearli.)

### 2.4 Locale (opzionale)

```bash
sed -i 's/^#it_IT.UTF-8/it_IT.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=it_IT.UTF-8' > /etc/locale.conf
```

### 2.5 Sessione Plasma Wayland senza SDDM

SDDM avvia un Xorg per la schermata di login che tiene aperto `card0`: KWin poi fallisce con `Failed to open /dev/dri/card0 device (Device or resource busy)`. Si usa un servizio che avvia direttamente la sessione:

```bash
systemctl disable --now sddm 2>/dev/null   # se installato

cat > /etc/systemd/system/plasma-session.service <<'EOF'
[Unit]
Description=Sessione Plasma Wayland
After=systemd-user-sessions.service systemd-logind.service systemd-udev-trigger.service
Wants=systemd-logind.service

[Service]
User=<UTENTE>
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

Verifica: `loginctl list-sessions` (sessione dell'utente su `seat0`, stato `active`) e `pgrep -a kwin_wayland`.

### 2.6 Plasma: niente spegnimento schermo né blocco, schermo a 60 Hz

Come `<UTENTE>`, da SSH:

```bash
kwriteconfig6 --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle false
kwriteconfig6 --file powerdevilrc --group AC --group Display --key DimDisplayWhenIdle false
kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false
kwriteconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume false
```

Da SSH le app Qt hanno bisogno di `WAYLAND_DISPLAY`:

```bash
export WAYLAND_DISPLAY=wayland-0
kscreen-doctor -o                                          # nome del connettore e modo attivo (con *)
kscreen-doctor output.<CONNETTORE>.mode.1920x1080@60
```

### 2.7 Sunshine: configurazione e avvio

Come `<UTENTE>`:

```bash
mkdir -p ~/.config/sunshine
cat >> ~/.config/sunshine/sunshine.conf <<'EOF'
capture = kwin
csrf_allowed_origins = https://<IP_CT>:47990
EOF

systemctl --user enable --now app-dev.lizardbyte.app.Sunshine.service
```

- `capture = kwin`: Sunshine chiede i frame a KWin (screencast), senza leggere i piani video via KMS (che dava schermo nero e richiedeva `CAP_SYS_ADMIN`).
- `csrf_allowed_origins`: senza, il pannello web risponde "CSRF Protection Error" se lo apri dall'IP del container.
- Pannello web: `https://<IP_CT>:47990` (certificato autofirmato). Al primo accesso crea utente e password.
- `~/.config/sunshine/sunshine_state.json` contiene le credenziali: **non committarlo** se metti la configurazione su GitHub.
- Il servizio utente parte con la sessione grafica (`graphical-session.target`) e ha una pausa di 5 secondi iniziale.

Verifica porte: `sudo ss -ltnp | grep -E ':(47984|47989|47990|48010)\b'`.

### 2.8 Pairing e impostazioni di Moonlight

1. In Moonlight aggiungi l'host `<IP_CT>` e leggi il PIN.
2. Nel pannello Sunshine, scheda *PIN*: inseriscilo.
3. Avvia l'app "Desktop".

Impostazioni che hanno funzionato:

- **Codec scelto a mano** (non "automatico"). HEVC a 40 Mbit/s va alla perfezione (anche in 5G con VPN); H.264 è l'alternativa.
- **YUV 4:4:4 disattivato**: l'host non lo supporta (il test dell'encoder dice `YUV444: unsupported`). Attivarlo cambia solo il bitrate di default proposto.
- HDR spento; 1080p a 60 fps. AV1 non disponibile in codifica su questa GPU.
- Renderer video di Moonlight sul Mac: **Metal** invece di "automatico" (tempi di rendering scesi a 1-2 ms).
- Statistiche in Moonlight: Ctrl+Opzione+Maiusc+S (se non ricordo male).

### 2.9 Prova a freddo

`pct reboot <CTID>`, attendi circa un minuto senza toccare niente, poi collegati con Moonlight. Controlla: immagine, mouse e tastiera, audio da YouTube, e che il browser non riparta silenziato (vedi sezione 3).

### 2.10 Pacing di rete (alternativa: la soluzione adottata è la scheda a 1G)

Se il container esce da un'interfaccia più veloce dei dispositivi a valle (per esempio la 2,5G dell'host verso un Mac o un access point a 1G), le raffiche di pacchetti di Sunshine (una per frame) possono riempire i buffer di uno switch o del router e causare perdite anche con banda abbondante. Nel nostro caso `iperf3 -u -b 40M/70` perdeva circa il 5,5% a 2,5G e quasi niente con il limite a 900 Mbit/s. Rallentare la velocità di invio poco sotto quella del collegamento più lento a valle (circa il 10% in meno: 900 per un Mac a 1G; con il limite pari alla velocità del collegamento le raffiche non si smussano) migliora molto, ma nei test lunghi con video 4K le perdite periodiche non sono sparite del tutto. La soluzione stabile è stata far uscire il container da una scheda alla stessa velocità del client (1G). Possibile causa, non verificata: l'invio a blocchi (GSO UDP), che il pacing non spezza.

Nel container (`eth0` è l'interfaccia del container):

```bash
sudo tc qdisc replace dev eth0 root fq maxrate 900mbit   # prova a mano
sudo tc qdisc del dev eth0 root                          # per toglierlo
```

Per renderlo permanente (unit systemd non ancora provata; `fq` può richiedere il modulo `sch_fq` sull'host):

```bash
cat > /etc/systemd/system/pacing-rete.service <<'EOF'
[Unit]
Description=Pacing di rete per lo streaming
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
systemctl enable --now pacing-rete
```

**Soluzione adottata:** collegare il container all'interfaccia a 1G dell'host (`vmbr0`) e spostare altrove il traffico pesante (qBittorrent è sulla 2,5G).

Verifica, con `iperf3 -s` acceso nel container e dal client (la modalità burst `/70` può non esistere nelle versioni vecchie di iperf3): `iperf3 -c <IP_CT> -u -b 40M/70 -l 1200 -t 20 -R`. La perdita deve essere vicina a zero.

---

## 3. Problemi incontrati e soluzioni

| Sintomo | Causa | Soluzione |
| --- | --- | --- |
| `restricting filesystem access failed because Landlock is not supported` | Il kernel dell'host non ha Landlock | `DisableSandboxFilesystem` in `pacman.conf` (1.1) |
| `Detected unsafe path transition / (owned by 100000)` | Container creato unprivileged e poi cambiato | Ricrearlo privileged dall'inizio |
| SDDM resta fermo, `seat0` senza device | udev non parte con `/sys` in sola lettura | `lxc.mount.auto: proc:rw sys:rw` (2.2) |
| KWin: `Failed to open /dev/dri/card0 (Device or resource busy)` | Il greeter di SDDM tiene `card0` | Servizio `plasma-session`, niente SDDM (2.5) |
| Sunshine con KMS: `Failed to gain CAP_SYS_ADMIN`, poi schermo nero con scia di cursori | Capability mancanti e piani video non leggibili | `capture = kwin` (2.7) |
| Pannello web: "CSRF Protection Error" | Origine non consentita | `csrf_allowed_origins` (2.7) |
| Mouse e tastiera non arrivano | Il `/dev` del container non ha i nodi `eventN` | Mount di `/dev/input` e `c 13:*` (2.2) |
| Moonlight: "l'host non supporta YUV 4:4:4" | Encoder VAAPI della iGPU senza 4:4:4 | Lasciarlo disattivato |
| Audio assente solo da YouTube, test audio di Plasma sì | Il browser riparte con il flusso audio **silenziato** (stato ricordato per applicazione da WirePlumber) | Con YouTube in riproduzione: `for i in $(pactl list short sink-inputs \| cut -f1); do pactl set-sink-input-mute "$i" 0; done` |
| Frame al secondo in ingresso più bassi con alcuni video | Molti video su YouTube sono a 24-30 fps e la cattura consegna frame quando lo schermo cambia | Controllare i fps reali nelle "Statistiche per nerd" |
| Moonlight: "slow network", frame persi dalla rete tra 0 e 35%, artefatti a tratti, fps tra 30 e 60 (sia cablato sia Wi-Fi) | Il container era collegato all'interfaccia di rete a 2,5G dell'host; sospetto di raffiche di pacchetti a 2,5G verso porte e dispositivi a 1G (confermato con `iperf3 -u -b 40M/70`: circa 5,5% di perdite a 2,5G; il dock del monitor Philips 243B non ha perso pacchetti nel test a 867 Mbit/s) | Collegare il container all'interfaccia a 1G, la stessa velocità del client (stabile); il pacing a 800-900 Mbit/s (2.10) migliorava ma non eliminava le perdite periodiche con video 4K lunghi |
| Finestre nere, blocchi a tratti, `dmesg` con `Engine reset: engine_class=rcs` e `Timedout job ... in plasmashell`, `plasma-discover` o `systemsettings` | Driver `xe` su questa scheda (ADL-S, kernel `7.0.14-20-pve`, GuC `70.49.4`) | Passare a `i915` togliendo dalla cmdline del kernel `xe.force_probe=4690`, `i915.force_probe=!4690` e `xe.max_vfs=7` (sezione 0): da allora nessun reset |
| `Device /dev/dri/card0 does not exist` dopo il cambio di driver | Il nome della card cambia (`card0` con `xe`, `card1` con `i915`) | Bind mount dell'intera cartella `/dev/dri` (2.2) |

Strumenti di diagnostica usati:

```bash
journalctl --user -u app-dev.lizardbyte.app.Sunshine.service -b --no-pager | tail -50
loginctl list-sessions
pactl info | grep -i 'default sink'; pactl list short sinks; pactl list short sink-inputs
```

---

## 4. Da verificare / aperto

- **Mouse troppo veloce:** risolto; non ho annotato quale impostazione (le opzioni erano l'ottimizzazione del mouse per il desktop remoto in Moonlight, o il profilo di accelerazione "piatto" in Plasma). Da annotare per lo script.
- **Rete:** risolta con il container sulla 1G e qBittorrent spostato sulla 2,5G. Da riverificare nell'installazione fresca con un video 4K lungo (almeno 30 minuti) e il seeding attivo.
- **HEVC a bassa potenza:** un test con `ffmpeg` mostra H.264 e HEVC alla pari, ma in Sunshine HEVC dava artefatti e cali in LAN. Molto probabilmente era la perdita di pacchetti sulla rete (vedi sopra: interfaccia a 2,5G) e non l'encoder; da riverificare con l'interfaccia a 1G. A 40 Mbit/s in 5G funzionava.
- **Blocco cambiando il tema in "automatico"** quando la cattura era KMS: da ripetere con `capture = kwin`.
- **Steam, Proton e Battle.net** per Warcraft II Remastered: non ancora fatto.
- **Reset del motore grafico (`xe`)**: il dmesg dell'host mostra più `Engine reset: engine_class=rcs`; il 10 ottobre alle 14:26:40 con `Timedout job ... in plasmashell`, undici secondi dopo l'avvio di uno stream. Altri reset il 10 ottobre: 14:49 (`plasma-discover`), 15:16:30 e 15:19:22 (`systemsettings`), 15:19:11 (`plasmashell`). Sono tutti attribuiti ad applicazioni KDE Qt Quick, non al browser né a Sunshine, e hanno lo stesso `seqno=4294967169` (se leggo bene, il valore iniziale: il primo lavoro di un nuovo contesto non si completa; non verificato). Da capire se sono correlati a finestre nere, blocchi e perdita di frame. Da quando l'host usa `i915` (YouTube 4K, Impostazioni, Discover, quick settings) non ne sono comparsi: il difetto è di `xe` su questa scheda e la configurazione GPU risulta stabile. Resta la possibilità di segnalarlo al tracker del driver `xe`, allegando il dump. Kernel dell'host `7.0.14-20-pve`, Mesa 26.2.4 nel container. Dump salvato il 10 ottobre (processo `plasma-discover`): il primo lavoro di un nuovo contesto non si è mai completato, il motore è fermo su un `PIPE_CONTROL` (stall e flush, se leggo bene i bit) nel batch, senza errori hardware né page fault; GuC `70.49.4` caricato (il driver vorrebbe `70.44.1`), PCI `8086:4690` rev `0c`. Per salvarne uno subito dopo un reset (dura pochi minuti): `sudo sh -c 'cat /sys/class/drm/card0/device/devcoredump/data > /root/xe-coredump.txt'`.
- **Hardening opzionale:** togliere `mount=nfs;cifs` dalle features se non servono (`pct set <CTID> --features nesting=1,fuse=1`), SSH solo con chiave, firewall di Proxmox sul container. Restano strutturali: container privileged e `/sys` scrivibile (servono per far funzionare tutto).

---

## 5. Prossimi passi e struttura proposta per lo script

1. Sistemare le ultime cose aperte (sezione 4).
2. Installazione fresca seguendo questo file alla lettera, annotando ogni deviazione: sono le correzioni da riportare nel file e nello script.
3. Script e repository Git.

Struttura proposta:

```
repo/
  host/        setup-host.sh          # regola udev, uinput, pct set, righe del .conf; nota sulla cmdline
  container/   setup-container.sh     # pacman, utente, locale, plasma-session, kwriteconfig6
               aur-sunshine.sh        # da utente normale (makepkg)
  files/       plasma-session.service, sunshine.conf.example,
               99-dri-permissions.rules, pacing-rete.service (opzionale)
  .gitignore                          # sunshine_state.json e qualsiasi credenziale
```

Note per lo script: variabili in testa (`CTID`, `UTENTE`, `IP_CT`, `CONNETTORE`); host e container sono due script distinti (girano in ambienti diversi); `makepkg` non va lanciato da root; i passi che richiedono un riavvio (`pct reboot`) vanno separati dal resto; il pairing con Moonlight e le credenziali del pannello restano manuali; l'unit `pacing-rete.service` non è stata provata.