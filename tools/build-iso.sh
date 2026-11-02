#!/bin/bash
#
# Build the VoltOS live/install ISO from archiso/ and the package repository
# made by build-packages.sh.  Needs root (mkarchiso) on Arch Linux or in a
# privileged archlinux container.
#
#   tools/build-iso.sh            -> out/voltos-YYYY.MM.DD-x86_64.iso
#
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
repo=$top/out/repo
work=${VOLTOS_WORK:-$top/work}

[ "$(id -u)" -eq 0 ] || { echo "build-iso.sh: run as root" >&2; exit 1; }
[ -f "$repo/voltos.db" ] || { echo "build-iso.sh: run build-packages.sh first" >&2; exit 1; }
command -v mkarchiso >/dev/null || pacman -S --needed --noconfirm archiso

# mkarchiso reads the profile in place; build from a copy with the
# repository path filled in so the checkout stays clean.
profile=$(mktemp -d)
trap 'rm -rf "$profile"' EXIT
cp -a "$top/archiso/." "$profile/"
sed -i "s|@VOLTOS_REPO@|$repo|" "$profile/pacman.conf"

# pacman caches packages by file name; a rebuilt VoltOS package with an
# unchanged version would otherwise be served stale from the host cache.
for f in "$repo"/*.pkg.tar.zst; do
	find /var/cache/pacman/pkg -maxdepth 1 -name "$(basename "$f")*" -delete
done

rm -rf "$work"
mkarchiso -v -r -w "$work" -o "$top/out" "$profile"
ls -l "$top"/out/*.iso
