# Arch Linux in un LXC su Proxmox con Plasma Wayland e Sunshine

🇬🇧 [English](README.md)

Un desktop KDE Plasma (Wayland) in un container LXC Arch Linux **privileged** su Proxmox, che condivide
la iGPU Intel dell'host (driver `i915`), con streaming tramite Sunshine (cattura `kwin`, codifica VAAPI)
verso Moonlight. Niente display manager: la sessione parte da un servizio systemd. L'obiettivo è un
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

Restano manuali: le credenziali del pannello Sunshine (`https://<IP_CT>:47990`), il pairing con
Moonlight e la scelta del browser.

## Cosa fa

- **Host**: controlla il driver `i915`, carica `uinput`, imposta la regola udev per i nodi della GPU.
- **Container**: lo crea (privileged, `nesting`, `fuse`, passthrough di `/dev/dri` e `/dev/input`,
  `/sys` scrivibile), installa il sistema, un utente con sudo, il locale, SSH.
- **Desktop**: `plasma-desktop` più un set multimediale (Spectacle, Gwenview, Okular, Ark, VLC, anteprime).
  Niente Discover, Bluetooth, applet NetworkManager, KCM di firewall/thunderbolt/dischi/vault, KRDP,
  KWallet. Baloo (indicizzazione file) è spento, la sospensione è disattivata, spegnimento schermo e
  blocco sono disattivati.
- **Sunshine**: `sunshine-bin` e `yay-bin` dall'AUR, `capture = kwin`, servizio utente abilitato.
- **Sessione**: avvia Plasma, rileva la porta HDMI, imposta 1920x1080@60, attende Sunshine, esegue le verifiche.

## Struttura

```
config.sh                 tutte le variabili (CTID, IP, risorse, utente, risoluzione, pacchetti...)
install.sh                orchestratore, da host Proxmox
lib.sh                    funzioni comuni di log e attesa
host/setup-host.sh        controllo i915, uinput, regola udev per i nodi GPU
host/create-ct.sh         template, pct create (privileged), righe del .conf, avvio
container/01-system.sh    pacman, pacchetti, utente, sudo, SSH, locale, impostazioni Plasma
container/02-sunshine.sh  yay-bin e sunshine-bin dall'AUR (sudo temporaneo), sunshine.conf, servizio
container/03-session.sh   avvio Plasma, rilevamento HDMI, 1920x1080@60, attesa Sunshine
container/aur-build.sh    compila un pacchetto AUR con makepkg (da utente normale)
container/verify.sh       verifiche (usabile anche da solo)
files/plasma-session.service
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
5. Con `CARD_MODE=0660`: KWin parte? In caso contrario `CARD_MODE=0666`.
