#!/usr/bin/env bash
# Builds and installs an AUR package (default: sunshine-bin).
# Usage: aur-build.sh [package]. RUN AS A NORMAL USER (makepkg refuses root).
# Needs passwordless sudo: 02-sunshine.sh grants it only for the duration of the build.
set -Eeuo pipefail
STAGE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib.sh
source "$STAGE/lib.sh"
# shellcheck source=/dev/null
source "$STAGE/config.sh"
[[ $EUID -ne 0 ]] || die "Do not run makepkg as root."
PKG=${1:-sunshine-bin}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

git clone "https://aur.archlinux.org/${PKG}.git"
cd "$PKG"
# The commit pin only applies to Sunshine.
if [[ $PKG == sunshine-bin && -n $SUNSHINE_AUR_COMMIT ]]; then
  git checkout --quiet "$SUNSHINE_AUR_COMMIT"
fi
log "AUR $PKG @ $(git rev-parse --short HEAD) ($(git log -1 --format=%cd --date=short))"
echo "----- PKGBUILD (kept in the log: review it) -----"
cat PKGBUILD
echo "-------------------------------------------------"

makepkg -si --noconfirm
