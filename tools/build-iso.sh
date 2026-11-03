#!/bin/bash
#
# Build the VoltOS live/install ISO from archiso/ and the package repository
# made by build-packages.sh.  Needs root (mkarchiso) on Arch Linux or in a
# privileged archlinux container.
#
#   tools/build-iso.sh            -> out/voltos-YYYY.MM.DD-<arch>.iso
#
# The ISO is for the host's architecture.  archiso/ describes the x86_64
# medium; for aarch64 (built in tools/alarm-buildroot.sh's root) the profile
# is adapted on the fly: UEFI-only boot (systemd-boot), no x86 microcode,
# syslinux or memtest, Arch Linux ARM's [alarm] repository, and ZFSBootMenu
# built at install time (zfsbootmenu) instead of the x86_64 release EFI.
#
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
carch=$(uname -m)
repo=$top/out/repo
[ "$carch" = x86_64 ] || repo=$top/out/repo-$carch
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

case $carch in
x86_64) ;;
aarch64)
	sed -e '/^zfsbootmenu-efi$/c zfsbootmenu' \
	    -e '/^\(amd-ucode\|intel-ucode\|syslinux\|memtest86+\|memtest86+-efi\)$/d' \
	    "$profile/packages.x86_64" >"$profile/packages.aarch64"
	rm "$profile/packages.x86_64"
	sed -i -e 's/^arch=.*/arch="aarch64"/' \
	    -e "s/^bootmodes=.*/bootmodes=('uefi.systemd-boot')/" \
	    -e '/^ *.uefi.systemd-boot.)$/d' "$profile/profiledef.sh"
	rm -rf "$profile/syslinux" "$profile"/efiboot/loader/entries/*memtest*
	printf '\n[alarm]\nInclude = /etc/pacman.d/mirrorlist\n' >>"$profile/pacman.conf"
	;;
*)
	echo "build-iso.sh: unsupported architecture $carch" >&2
	exit 1
	;;
esac

# pacman caches packages by file name; a rebuilt VoltOS package with an
# unchanged version would otherwise be served stale from the host cache.
for f in "$repo"/*.pkg.tar.zst; do
	find /var/cache/pacman/pkg -maxdepth 1 -name "$(basename "$f")*" -delete
done

rm -rf "$work"
mkarchiso -v -r -w "$work" -o "$top/out" "$profile"
ls -l "$top"/out/*.iso
