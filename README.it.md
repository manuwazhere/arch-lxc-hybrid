# Arch Linux in un LXC su Proxmox con Plasma Wayland e Sunshine

🇬🇧 [English](README.md)

Un desktop KDE Plasma o Hyprland (Wayland) in un container LXC Arch Linux **privileged** su Proxmox, che
condivide la iGPU Intel dell'host (driver `i915`), con streaming tramite Sunshine (codifica VAAPI; cattura
`kwin` per Plasma, `wlr` per Hyprland) verso Moonlight. Niente display manager: la sessione parte da un servizio systemd. L'obiettivo è un
desktop che si comporta come un SO installato in locale, con accelerazione GPU e streaming solidi.

La procedura manuale originale (con la tabella dei problemi incontrati) è in
[`docs/manual-procedure.it.md`](docs/manual-procedure.it.md).

## Requisiti

- Host Proxmox con iGPU Intel che usa il driver **`i915`** (con `xe` la GPU andava in reset sulla scheda
  provata; gli script si fermano se vedono `xe`).
- Un dummy plug HDMI nella porta HDMI della iGPU.
- Il container su un bridge con la stessa velocità del client Moonlight (1G nell'installazione provata).
- Provato su: Lenovo ThinkCentre M90q (UHD 770), Proxmox con kernel 7.0, Moonlight su Mac.

## Uso

```bash
# sull'host Proxmox, da root (usa tmux: l'installazione dura diversi minuti)
git clone <questo-repo> && cd arch-lxc-sunshine
nano config.sh                # CTID, IP, gateway, storage, utente...  (oppure usa config.local.sh)
./install.sh                  # chiede la password dell'utente
./install.sh --recreate       # distrugge il CT (chiede conferma) e riparte da zero
```

Tutto è idempotente: puoi rilanciare `./install.sh` su un container esistente. I log restano in `logs/`
(ignorati da git).

I valori personali (gateway, DNS, locale, pacchetti AUR...) vanno in `config.local.sh`, che viene letto
dopo `config.sh` ed è ignorato da git, così un `git pull` non va mai in conflitto con le tue impostazioni:

```bash
# config.local.sh
GATEWAY=192.168.1.1      # il tuo router, NON il server DNS
DNS=192.168.1.53
AUR_PACKAGES="brave-bin"
```

### Scelta del desktop

`DESKTOP=plasma` (default) oppure `DESKTOP=hyprland`, in `config.sh` o `config.local.sh`. Tutto ciò che
sta sotto il desktop è in comune: host, container, GPU, servizio di sessione senza display manager,
Sunshine, rilevamento del connettore, verifiche. Cambiano solo pacchetti, unit di sessione e backend di cattura.

- **plasma**: `plasma-desktop` + set multimediale, `capture = kwin`.
- **hyprland**: Hyprland essenziale (serve la **>= 0.55**, la config generata è in Lua) con foot, fuzzel,
  portal, clipboard e strumenti per screenshot, `capture = wlr`. `~/.config/hypr/hyprland.lua` viene creato
  solo se manca; `~/.config/hypr/monitors.lua` (uscita e modo) è rigenerato a ogni esecuzione. Hyprland
  avvia `hyprland-session.target`, che attiva `graphical-session.target` e con esso il servizio utente di
  Sunshine. Tasti: `Super+Invio` terminale, `Super+Spazio` launcher, `Super+Q` chiudi.

Per provare l'altro desktop usa un CT nuovo (`CTID`/`IP_CT`, vedi la nota "Indirizzi") o `--recreate`.

Restano manuali: le credenziali del pannello Sunshine (`https://<IP_CT>:47990`), il pairing con
Moonlight e la scelta del browser.

## Cosa fa

- **Host**: controlla il driver `i915`, carica `uinput`, imposta la regola udev per i nodi della GPU.
- **Container**: lo crea (privileged, `nesting`, `fuse`, passthrough di `/dev/dri` e `/dev/input`,
  `/sys` scrivibile), installa il sistema, un utente con sudo, il locale, SSH.
- **Desktop** (`DESKTOP=plasma`): `plasma-desktop` più un set multimediale (Spectacle, Gwenview, Okular, Ark, VLC, anteprime).
  Niente Discover, Bluetooth, applet NetworkManager, KCM di firewall/thunderbolt/dischi/vault, KRDP,
  KWallet. Baloo (indicizzazione file) è spento, la sospensione è disattivata, spegnimento schermo e
  blocco sono disattivati.
- **Desktop** (`DESKTOP=hyprland`): Hyprland e pochi strumenti Wayland (vedi `HYPRLAND_PACKAGES`), più un
  set multimediale (mpv, VLC, imv, Evince, Nautilus...). In entrambi i casi la sospensione è disattivata.
- **Sunshine**: `sunshine-bin` e `yay-bin` dall'AUR, `capture = kwin` (Plasma) o `wlr` (Hyprland), servizio utente abilitato.
- **Sessione**: avvia il desktop, rileva la porta HDMI, imposta 1920x1080@60, attende Sunshine, esegue le verifiche.

## Struttura

```
config.sh                 tutte le variabili (CTID, IP, risorse, utente, risoluzione, pacchetti...)
install.sh                orchestratore, da host Proxmox
lib.sh                    funzioni comuni di log e attesa
host/setup-host.sh        controllo i915, uinput, regola udev per i nodi GPU
host/create-ct.sh         template, pct create (privileged), righe del .conf, avvio
container/01-system.sh    pacman, pacchetti, utente, sudo, SSH, locale, impostazioni desktop (Plasma o Hyprland)
container/02-sunshine.sh  yay-bin e sunshine-bin dall'AUR (sudo temporaneo), sunshine.conf, servizio
container/03-session.sh   avvio sessione, rilevamento HDMI, 1920x1080@60, attesa Sunshine
container/aur-build.sh    compila un pacchetto AUR con makepkg (da utente normale)
container/verify.sh       verifiche (usabile anche da solo)
files/plasma-session.service, hyprland-session.service/.target, hyprland.lua
docs/                     procedura manuale (EN/IT)
```

## Note di progetto

- **Connettore video**: `CONNECTOR=auto` cerca in `/sys/class/drm` l'uscita `HDMI-A-n` (le USB-C con
  DP alt-mode e la DisplayPort compaiono come `DP-n`), preferendo quella `connected`.
- **Password**: mai nel repo; chiesta a runtime o da `CT_USER_PASSWORD` (es. in `config.local.sh`).
- **AUR**: `yay-bin` e `sunshine-bin` si compilano con `makepkg` (`SUNSHINE_AUR_COMMIT` fissa un commit di
  Sunshine; i PKGBUILD finiscono nel log). Poi `yay -Syu` aggiorna repo e AUR insieme. Pacchetti AUR
  extra (es. Brave) in `AUR_PACKAGES`. Senza helper (`INSTALL_AUR_HELPER=0`) gli aggiornamenti AUR vanno
  fatti a mano.
- **Permessi GPU**: `renderD*` a 0666; `card*` a `CARD_MODE` (0660 di default).
- **Indirizzi**: l'ultimo ottetto dell'IP coincide con l'ID del CT (`.200` per il CT 200), fuori dal pool
  DHCP del router. `create-ct.sh` si rifiuta di creare il container se l'indirizzo è già configurato in
  un altro CT/VM o risponde al ping: un IP duplicato faceva arrivare il traffico alla macchina sbagliata,
  e si vedeva solo da fuori dalla LAN.
- **Opzioni di Sunshine**: `SUNSHINE_EXTRA="hevc_mode=3"` (chiave=valore, separati da spazio) finisce in
  `sunshine.conf`; `hevc_mode=3` annuncia HEVC Main10 (10 bit). `avahi` è installato perché Sunshine
  possa annunciarsi via mDNS.
- **Rete**: il CT sta su `vmbr0`. Il bufferbloat a monte e un eventuale flow control su una scheda a 2,5G
  sono questioni a parte, non gestite qui.
- **Sicurezza**: il container è privileged, `/sys` è scrivibile e il render node è accessibile a tutti
  sull'host. È il prezzo per far funzionare udev, input e GPU: va bene per un homelab, altrove
  pensaci due volte.

## Prova a freddo (checklist)

1. `./install.sh` fino in fondo, `verify.sh` tutto OK.
2. Pairing Moonlight, app "Desktop": immagine, mouse e tastiera, audio da YouTube.
3. `pct reboot <CTID>`, un minuto di attesa, riconnessione.
4. Video 4K lungo (30+ minuti) con seeding attivo: nessuna perdita di pacchetti.
5. Con `CARD_MODE=0660`: KWin (o Hyprland) parte? In caso contrario `CARD_MODE=0666`.

## Limiti noti

- **Codifica AV1**: non disponibile sulla UHD 770 (Sunshine non trova un entrypoint di codifica AV1 utilizzabile).
- **YUV 4:4:4**: non offerto con il percorso VAAPI nei nostri test: la GPU elenca i profili HEVC 4:4:4 in
  `vainfo`, ma Sunshine non li usa (è una funzione per singolo encoder, e il 4:4:4 lato host su Linux è
  stato un lavoro in corso a monte).
- **Bitrate**: con Moonlight a 20 Mbit/s, Sunshine registra "Streaming bitrate is 14988000" (circa il 75%);
  con 40 Mbit/s circa 30. Osservato, non spiegato qui.
- **Appunti condivisi** tra container e client: non disponibili con Sunshine e Moonlight originali.
