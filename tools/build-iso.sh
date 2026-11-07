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

# voltos-keyring only exists when the packages were signed
# (build-packages.sh with the signing key); unsigned builds go without it,
# and their installed systems without the [voltos] update repository.
if ! ls "$repo"/voltos-keyring-*.pkg.tar.zst >/dev/null 2>&1; then
	echo "build-iso.sh: unsigned repository; the ISO has no voltos-keyring" >&2
	sed -i '/^voltos-keyring$/d' "$profile/packages.x86_64"
fi

case $carch in
x86_64) ;;
aarch64)
	sed -e '/^zfsbootmenu-efi$/c zfsbootmenu' \
	    -e '/^\(amd-ucode\|intel-ucode\|syslinux\|memtest86+\|memtest86+-efi\)$/d' \
	    "$profile/packages.x86_64" >"$profile/packages.aarch64"
	# Arch Linux ARM signs its packages with its own keys.
	echo archlinuxarm-keyring >>"$profile/packages.aarch64"
	# memdisk is syslinux's (BIOS) RAM-disk helper; it does not exist here.
	sed -i 's/ memdisk / /' "$profile/airootfs/etc/mkinitcpio.conf.d/archiso.conf"
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

# GitHub refuses release files of 2 GiB or more; fail here, not hours later
# when the release job uploads the ISO.
iso=$(ls -t "$top"/out/voltos-*-"$carch".iso | head -n 1)
size=$(stat -c %s "$iso")
limit=$((2 * 1024 * 1024 * 1024))
echo "build-iso.sh: $(basename "$iso") is $((size / 1048576)) MiB" \
     "($(((limit - size) / 1048576)) MiB under GitHub's 2 GiB release-file limit)"
if [ "$size" -ge "$limit" ]; then
	echo "build-iso.sh: the ISO is too large to publish as a GitHub release file" >&2
	exit 1
fi
