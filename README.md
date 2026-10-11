# Arch Linux in LXC su Proxmox con Plasma Wayland e Sunshine

Desktop Arch + KDE Plasma (Wayland) in un container LXC **privileged** su Proxmox,
iGPU Intel con driver `i915` condivisa col container, streaming con Sunshine (cattura `kwin`,
codifica VAAPI) verso Moonlight. Niente SDDM: la sessione parte da un servizio systemd.

La procedura manuale originale è in [`docs/procedura-manuale.md`](docs/procedura-manuale.md).

## Requisiti

- Host Proxmox con iGPU Intel che usa **`i915`** (con `xe` ci sono reset della GPU; lo script si ferma).
- Dummy plug HDMI inserito nella porta HDMI della iGPU.
- Container sul bridge a 1G (`vmbr0`), la stessa velocità del client Moonlight.

## Uso

```bash
# sull'host Proxmox
git clone <questo-repo> && cd arch-lxc-sunshine
nano config.sh                # CTID, IP, storage, gateway, utente...
./install.sh                  # chiede la password dell'utente
./install.sh --recreate       # distrugge il CT (con conferma) e riparte da zero
```

Tutto è idempotente: puoi rilanciare `./install.sh` su un CT esistente.
I log restano in `logs/` (ignorati da git).

Fuori dallo script restano manuali: credenziali del pannello Sunshine (`https://<IP_CT>:47990`),
pairing con Moonlight, scelta del browser.

## Struttura

```
config.sh                 tutte le variabili (CTID, IP, risorse, utente, risoluzione...)
install.sh                orchestratore, da host Proxmox
lib.sh                    log/attese comuni
host/setup-host.sh        controllo i915, uinput, regola udev sui nodi GPU
host/create-ct.sh         template, pct create (privileged), righe del .conf, avvio
container/01-system.sh    pacman, pacchetti, utente, sudo, SSH, locale, impostazioni Plasma
container/02-sunshine.sh  sunshine-bin dall'AUR (sudo temporaneo), sunshine.conf, servizio
container/03-session.sh   avvio Plasma, rilevamento HDMI, 1920x1080@60, attesa Sunshine
container/verify.sh       verifiche (usabile anche da solo)
files/plasma-session.service
```

## Note di progetto

- **Connettore video**: `CONNETTORE=auto` cerca in `/sys/class/drm` l'uscita di tipo `HDMI-A-n`
  (le USB-C e la DP compaiono come `DP-n`), preferendo quella `connected`.
- **Password**: mai nel repo; chiesta a runtime o da `UTENTE_PASSWORD` (es. in `config.local.sh`).
- **AUR**: `yay-bin` e `sunshine-bin` si compilano con `makepkg` (`SUNSHINE_AUR_COMMIT` fissa un commit di
  Sunshine; i PKGBUILD finiscono nel log). Poi `yay -Syu` aggiorna repo e AUR insieme. Pacchetti AUR
  extra (es. Brave) in `AUR_PACKAGES`, meglio nel proprio `config.local.sh`. Senza helper:
  `INSTALL_AUR_HELPER=0`, e gli aggiornamenti AUR vanno fatti a mano.
- **Permessi GPU**: `renderD*` a 0666; `card*` a `CARD_MODE` (default 0660, da verificare).
- **Desktop**: `plasma-desktop` e non `plasma-meta`, così Discover, Bluetooth, applet di rete,
  firewall/thunderbolt/dischi/vault e KRDP non vengono installati. `powerdevil` è dipendenza dura
  di `plasma-desktop`: resta, ma la sospensione è mascherata e lo spegnimento schermo disattivato.
  Gli elenchi sono in `config.sh` (`PLASMA_PACKAGES`, `MEDIA_PACKAGES`). Baloo è disattivato di default.
- **Rete**: il CT sta su `vmbr0`. Il bufferbloat dell'iliadbox e un eventuale flow control
  sulla 2,5G sono questioni a parte, non gestite qui.

## Prova a freddo (checklist)

1. `./install.sh` fino in fondo, `verify.sh` tutto OK.
2. Pairing Moonlight, app "Desktop": immagine, mouse e tastiera, audio da YouTube.
3. `pct reboot <CTID>`, un minuto di attesa, riconnessione.
4. Video 4K lungo (30+ minuti) con seeding attivo: nessuna perdita di pacchetti.
5. Con `CARD_MODE=0660`: KWin parte? In caso contrario `CARD_MODE=0666`.
