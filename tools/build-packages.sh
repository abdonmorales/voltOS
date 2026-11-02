#!/bin/bash
#
# Build every VoltOS package and assemble the local pacman repository
# out/repo/voltos.db.  Run on Arch Linux (or in an archlinux container),
# as root or as a user with sudo.
#
#   tools/build-packages.sh [package ...]
#
# Packages are built in dependency order with makepkg.  Build-time
# dependencies are installed from the Arch repositories; packages that
# depend on other VoltOS packages only need them at install time.
#
# The OpenZFS tarballs are pinned by sha256 in their PKGBUILDs; their PGP
# signatures are not checked because a fresh build host has no keys for
# the OpenZFS release managers (pass VOLTOS_PGP=1 to require them).
#
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
repo=$top/out/repo
order=(nimbus-gtk-theme voltos-branding zfs-utils zfs-dkms zfsbootmenu-efi
       voltos-zfs-snapshots voltos-installer voltos-live)
[ "$#" -gt 0 ] && order=("$@")

if [ "$(id -u)" -eq 0 ]; then
	# makepkg refuses to run as root; build as an unprivileged user.
	id voltos-build >/dev/null 2>&1 || useradd -m voltos-build
	echo 'voltos-build ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/voltos-build
	as_builder() { sudo -u voltos-build --preserve-env=https_proxy,HTTPS_PROXY "$@"; }
	chown -R voltos-build "$top/packages"
	SUDO=
else
	as_builder() { "$@"; }
	SUDO=sudo
fi

mkdir -p "$repo"
pgp=--skippgpcheck
[ "${VOLTOS_PGP:-0}" = 1 ] && pgp=

for pkg in "${order[@]}"; do
	dir=$top/packages/$pkg
	[ -f "$dir/PKGBUILD" ] || { echo "no package $pkg" >&2; exit 1; }
	echo "==> Building $pkg"
	# Install the build-time dependencies (makedepends) from Arch.
	mapfile -t mk < <(cd "$dir" && bash -c \
	    'source ./PKGBUILD; printf "%s\n" "${makedepends[@]}"' | sed '/^$/d')
	if [ "${#mk[@]}" -gt 0 ]; then
		$SUDO pacman -S --needed --noconfirm "${mk[@]}"
	fi
	(cd "$dir" && as_builder makepkg --nodeps --clean --cleanbuild --force \
	    --noconfirm $pgp)
	for f in "$dir"/*.pkg.tar.zst; do
		cp "$f" "$repo/"
	done
done

rm -f "$repo"/voltos.db* "$repo"/voltos.files*
repo-add -q -n -R "$repo/voltos.db.tar.gz" "$repo"/*.pkg.tar.zst
echo "==> Repository: $repo"
ls -1 "$repo"
