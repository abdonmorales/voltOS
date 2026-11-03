#!/bin/bash
#
# Build every VoltOS package and assemble the local pacman repository
# out/repo/voltos.db.  Run on Arch Linux (or in an archlinux container),
# as root or as a user with sudo.
#
#   tools/build-packages.sh [package ...]
#
# The repository is for the host's architecture: out/repo on x86_64,
# out/repo-<arch> elsewhere (aarch64: build inside tools/alarm-buildroot.sh's
# root).  Packages whose arch=() excludes the host are skipped, so the same
# list serves both (zfsbootmenu-efi is x86_64-only; VoltOS's own linux-lts
# build is AArch64-only, x86_64 uses Arch's).
#
# Packages are built in dependency order with makepkg.  Build-time
# dependencies are installed from the Arch repositories; packages that
# depend on other VoltOS packages only need them at install time.
#
# The OpenZFS tarballs are pinned by sha256 in their PKGBUILDs; their PGP
# signatures are not checked because a fresh build host has no keys for
# the OpenZFS release managers (pass VOLTOS_PGP=1 to require them).
#
# With VOLTOS_REPO_KEY_FILE set to the package signing key (tools/make-repo-key.sh;
# the VOLTOS_REPO_KEY secret in CI), every package and the database are signed
# and voltos-keyring is built with the key's public half.  Without it the
# repository is unsigned and voltos-keyring is skipped.
#
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
carch=$(uname -m)
repo=$top/out/repo
[ "$carch" = x86_64 ] || repo=$top/out/repo-$carch
order=(voltos-keyring linux-lts-aarch64 nimbus-gtk-theme voltos-branding voltos-desktop zfs-utils zfs-dkms
       zfsbootmenu-efi perl-boolean zfsbootmenu
       voltos-zfs-snapshots voltos-secureboot voltos-installer voltos-gui-install
       voltos-live)
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

# shellcheck source=tools/repo-key.sh
. "$top/tools/repo-key.sh"
repo_key_import
trap repo_key_cleanup EXIT
if [ -n "$REPO_KEY" ]; then
	gpg --batch --export "$REPO_KEY" >"$top/packages/voltos-keyring/voltos.gpg"
	echo "$REPO_KEY:4:" >"$top/packages/voltos-keyring/voltos-trusted"
	chmod 644 "$top/packages/voltos-keyring/voltos.gpg" "$top/packages/voltos-keyring/voltos-trusted"
fi

mkdir -p "$repo"
pgp=--skippgpcheck
[ "${VOLTOS_PGP:-0}" = 1 ] && pgp=

for pkg in "${order[@]}"; do
	dir=$top/packages/$pkg
	[ -f "$dir/PKGBUILD" ] || { echo "no package $pkg" >&2; exit 1; }
	archs=$(cd "$dir" && bash -c 'source ./PKGBUILD; echo " ${arch[*]} "')
	if [[ $archs != *" any "* && $archs != *" $carch "* ]]; then
		echo "==> Skipping $pkg (not for $carch)"
		continue
	fi
	if [ "$pkg" = voltos-keyring ] && [ -z "$REPO_KEY" ]; then
		echo "==> Skipping $pkg (no signing key)"
		continue
	fi
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
		[ -z "$REPO_KEY" ] || repo_sign "$repo/${f##*/}"
	done
done

rm -f "$repo"/voltos.db* "$repo"/voltos.files*
sign=()
[ -z "$REPO_KEY" ] || sign=(--sign --key "$REPO_KEY")
repo-add -q -n -R "${sign[@]}" "$repo/voltos.db.tar.gz" "$repo"/*.pkg.tar.zst
echo "==> Repository: $repo"
ls -1 "$repo"
