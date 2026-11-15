# VoltOS release notes

Each release is a snapshot of the rolling system: the ISOs of that day, with
VoltOS's own packages at that release's versions.  Installed systems keep
updating with `doas pacman -Syu` and need no reinstall between releases.
The release workflow takes the notes for a `vX.Y.Z` tag from the section
for `X.Y.Z` below.

## 0.2.0 (in development)

Safer updates and verifiable downloads.

- **Kernel updates OpenZFS cannot build for are refused.** `zfs-dkms`
  depends on a `linux-lts` below the first kernel its OpenZFS release does
  not support, so `pacman -Syu` stops with an error instead of installing a
  kernel that leaves the next boot without its root file system.  Update the
  rest with `doas pacman -Syu --ignore linux-lts,linux-lts-headers` until a
  new `zfs-dkms` is published.
- **Signed checksums.** `SHA256SUMS` and `SHA256SUMS-aarch64` are signed with
  the VoltOS signing key (fingerprint
  `5580 7487 EFAB 5F26 D4A3 2EFF 48A0 A16B EDE3 47A7`); see "Downloading" in
  the README.
- **Version in os-release.** `/usr/lib/os-release` gives the VoltOS version
  (`VERSION_ID=0.2.0`).
- **GNOME 2's applications in the GNOME 2 session.** With `voltos-gnome2`
  installed, the GNOME 2.32 session uses Nautilus for folders and GNOME
  Terminal as the terminal, and leaves MATE's Caja and MATE Terminal out of
  its menus; the MATE session keeps Caja.  NetworkManager's icon now shows
  in GNOME 2's panel (its autostart entry skipped sessions named GNOME).
- **Installer.** It keeps its log on the installed system
  (`/var/log/voltos-install.log`), and stops processes left running in the
  new system before it exports the pool, which on AArch64 could fail with
  "pool is busy".

### Known issues

- The ISOs boot with Secure Boot only when the release was built with the
  Secure Boot signing secrets set; otherwise turn Secure Boot off to boot the
  installer, and turn it on after installing with `voltos-secureboot enable`.
- x86_64 systems installed from ISOs before November 13, 2026 have no Arch
  mirror configured; see "Updates" in the README for the one-line fix.
- AArch64 is tested in an emulated machine (QEMU, AAVMF) only.

## 0.1.0

The first release.

- Arch Linux base for x86_64 (UEFI and BIOS) and AArch64 (UEFI), with the
  MATE desktop in the Nimbus look, and GNOME Flashback as a second session.
- ZFS root with boot environments, booted by ZFSBootMenu; a snapshot before
  every pacman transaction.
- Installers: the OpenSolaris graphical installer, ported to GTK 3, and
  `voltos-install` for the text console.
- Secure Boot: signed ISOs (when the signing secrets are set), and
  `voltos-secureboot enable` for installed systems.
- `doas` instead of `sudo`; `pico` as the default editor.
- The signed `[voltos]` package repository for updates, with the GNOME 2.32
  desktop on GTK 2 (`voltos-gnome2`) and Apache OpenOffice 4.1.17
  (`openoffice`, built from source for AArch64).
