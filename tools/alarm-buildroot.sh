#!/bin/bash
#
# Create an Arch Linux ARM (AArch64) build root for VoltOS packages and ISOs.
#
#   sudo tools/alarm-buildroot.sh /path/to/root
#
# Runs natively on AArch64 hosts (GitHub's ubuntu-24.04-arm runners) or on
# x86_64 with qemu-user binfmt.  The root gets base-devel plus the tools
# mkarchiso needs; Arch Linux ARM does not package archiso and dkms, so the
# architecture-independent ("any") builds are taken from Arch Linux itself
# and verified against archlinux-keyring.
#
set -euo pipefail

root=${1:?usage: alarm-buildroot.sh <root>}
mirror=${ALARM_MIRROR:-https://fl.us.mirror.archlinuxarm.org}
archmirror=${ARCH_MIRROR:-https://geo.mirror.pkgbuild.com}
tarball=ArchLinuxARM-aarch64-latest.tar.gz
here=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" -eq 0 ] || { echo "alarm-buildroot.sh: run as root" >&2; exit 1; }

dl=$(mktemp -d)
cleanup()
{
	rm -rf "$dl"
	# pacman-key leaves a gpg-agent running inside the root.
	if [ -x "$root/usr/bin/gpgconf" ] && mountpoint -q "$root/proc"; then
		chroot "$root" gpgconf --homedir /etc/pacman.d/gnupg --kill gpg-agent 2>/dev/null || true
	fi
	# alarm-chroot.sh leaves its mounts in place; take them down again.
	for m in voltos run dev sys proc; do
		! mountpoint -q "$root/$m" || umount -R "$root/$m" || umount -Rl "$root/$m"
	done
}
trap cleanup EXIT
curl -sSfL -o "$dl/$tarball" "$mirror/os/$tarball"
curl -sSfL -o "$dl/$tarball.md5" "$mirror/os/$tarball.md5"
(cd "$dl" && md5sum -c --quiet "$tarball.md5")

mkdir -p "$root"
bsdtar -xpf "$dl/$tarball" -C "$root"

cat >"$root/etc/pacman.d/mirrorlist" <<MIRRORS
Server = $mirror/\$arch/\$repo
Server = https://ca.us.mirror.archlinuxarm.org/\$arch/\$repo
Server = https://de3.mirror.archlinuxarm.org/\$arch/\$repo
MIRRORS
sed -i 's/^CheckSpace/#CheckSpace/; s/^#ParallelDownloads.*/ParallelDownloads = 4/' \
    "$root/etc/pacman.conf"
# Under qemu-user emulation pacman's download sandbox (Landlock, dropping
# to the alpm user) does not work; native AArch64 hosts keep it.
[ "$(uname -m)" = aarch64 ] ||
    sed -i 's/^\[options\]$/[options]\nDisableSandbox/' "$root/etc/pacman.conf"
# Use every CPU for package builds (the kernel above all).
# and zstd packages as on Arch Linux (Arch Linux ARM defaults to xz).
sed -i -e "s/^#\\?MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/" \
    -e "s/^PKGEXT=.*/PKGEXT='.pkg.tar.zst'/" "$root/etc/makepkg.conf"
# The tarball's kernel and board packages are irrelevant in a build root.
sed -i 's/^#IgnorePkg *=.*/IgnorePkg = linux-aarch64 linux-aarch64-headers/' \
    "$root/etc/pacman.conf"

run() { "$here/alarm-chroot.sh" "$root" "$@"; }

run 'pacman-key --init && pacman-key --populate archlinuxarm archlinux'
run 'pacman -Rdd --noconfirm linux-aarch64 2>/dev/null || true'
run 'pacman -Syu --noconfirm --needed base-devel git sudo archlinux-keyring \
    arch-install-scripts squashfs-tools libisoburn erofs-utils mtools \
    dosfstools e2fsprogs grub openssl python'

# archiso and dkms from Arch Linux (architecture-independent packages).
for pkg in archiso dkms; do
	ver=$(curl -sSfL "$archmirror/extra/os/x86_64/extra.db" | bsdtar -xOf - --include "$pkg-[0-9]*/desc" |
	    awk '/^%FILENAME%$/ {getline; print; exit}')
	[ -n "$ver" ] || { echo "alarm-buildroot.sh: $pkg not found in Arch extra" >&2; exit 1; }
	curl -sSfL -o "$root/tmp/$ver" "$archmirror/extra/os/x86_64/$ver"
	curl -sSfL -o "$root/tmp/$ver.sig" "$archmirror/extra/os/x86_64/$ver.sig"
	run "pacman-key --verify /tmp/$ver.sig /tmp/$ver && pacman -U --noconfirm /tmp/$ver"
	rm -f "$root/tmp/$ver" "$root/tmp/$ver.sig"
done
echo "alarm-buildroot.sh: build root ready in $root"
