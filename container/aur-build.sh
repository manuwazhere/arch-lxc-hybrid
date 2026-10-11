#!/usr/bin/env bash
# Compila e installa sunshine-bin dall'AUR. DA UTENTE NORMALE (makepkg rifiuta root).
# Richiede sudo senza password: lo concede 02-sunshine.sh solo per la durata del build.
set -Eeuo pipefail
STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib.sh
source "$STAGE/lib.sh"
# shellcheck source=/dev/null
source "$STAGE/config.sh"
[[ $EUID -ne 0 ]] || die "Non lanciare makepkg come root."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

git clone https://aur.archlinux.org/sunshine-bin.git
cd sunshine-bin
if [[ -n $SUNSHINE_AUR_COMMIT ]]; then
  git checkout --quiet "$SUNSHINE_AUR_COMMIT"
fi
log "AUR sunshine-bin @ $(git rev-parse --short HEAD) ($(git log -1 --format=%cd --date=short))"
echo "----- PKGBUILD (per il log: controllalo) -----"
cat PKGBUILD
echo "----------------------------------------------"

makepkg -si --noconfirm
