# VoltOS

VoltOS is an Arch Linux–based desktop distribution with:

- **The Nimbus look and feel.** GNOME uses the Sun/OpenSolaris Nimbus GTK 3
  theme, window-manager theme and icon set by default, packaged from
  [abdonmorales/nimbus](https://github.com/abdonmorales/nimbus).
- **A ZFS root with boot environments.** The system is installed on OpenZFS
  and booted by [ZFSBootMenu](https://zfsbootmenu.org). Every pacman
  transaction is preceded by a snapshot of the running boot environment, so
  any upgrade can be rolled back from the boot menu, the way Solaris and
  illumos boot environments work.
- **Its own installer.** `voltos-install` is a guided installer that copies
  the tested live system onto the ZFS pool, so it works offline.

The first release targets x86_64. The logo is currently Tux.

## Status

| Piece | State |
| --- | --- |
| Package repository (`packages/`), incl. OpenZFS 2.4.4 | Builds on Arch Linux |
| Live ISO, GNOME + Nimbus (`archiso/`) | Builds; boots to the live desktop under UEFI in QEMU (CI) |
| Installer to ZFS + ZFSBootMenu | `make smoke-install` passes: unattended install, then the installed system boots from ZFS through ZFSBootMenu to GNOME's graphical target |
| Live ISO on BIOS | Boots to the live desktop under SeaBIOS in QEMU (CI) |
| CI (`.github/workflows/iso.yml`) | Builds, boots, installs and publishes on `v*` tags |

## Layout

```
archiso/                 live/install medium (archiso profile)
packages/
  nimbus-gtk-theme/      Nimbus GTK 3, Metacity and icon themes
  voltos-branding/       os-release identity, Tux logo, GNOME defaults
  voltos-installer/      voltos-install and its desktop launcher
  voltos-live/           live user, autologin helpers, unattended install
  voltos-zfs-snapshots/  pacman hook: snapshot before every transaction
  zfs-utils/, zfs-dkms/  OpenZFS 2.4.4 (from the AUR recipes)
  zfsbootmenu-efi/       ZFSBootMenu 3.1.0 release EFI
tools/
  build-packages.sh      build packages into out/repo
  build-iso.sh           build out/voltos-YYYY.MM.DD-x86_64.iso
  smoke-qemu.sh          boot / install tests in QEMU
```

## Building

On Arch Linux:

```sh
sudo tools/install-build-deps.sh
sudo make iso            # packages, then the ISO in out/
make smoke               # boot the live desktop under UEFI in QEMU
make smoke-install       # unattended ZFS install, then boot it
```

On any other Linux host with Docker:

```sh
make docker-iso
```

Building in QEMU without KVM works, but GNOME is very slow there; use a
host with `/dev/kvm` for interactive testing.

## Boot loaders

| Stage | Boot loader | Why |
| --- | --- | --- |
| Live ISO, BIOS | syslinux | archiso's standard BIOS path for CD/USB |
| Live ISO, UEFI | systemd-boot | archiso's standard UEFI path; simple, no ZFS needed on the medium |
| Installed system | ZFSBootMenu (UEFI) | Reads kernels straight from ZFS boot environments |

ZFSBootMenu is a small Linux system packaged as one EFI executable, which
the firmware starts directly from the EFI system partition. It imports the
pool, finds every boot environment (and its snapshots), and loads
`/boot/vmlinuz-linux-lts` and the initramfs from inside the chosen one with
kexec. Because the kernel lives in the boot environment rather than on the
ESP, rolling back or cloning a boot environment also rolls back its kernel,
and no boot-loader configuration has to be regenerated after upgrades.
Press Escape at its countdown to pick another boot environment or snapshot.

GRUB was not used for installed systems: its own ZFS driver lags OpenZFS
features, and it has no built-in notion of boot environments.

## Design notes

- **Kernel.** VoltOS uses `linux-lts`. ZFS is an out-of-tree module (its
  CDDL licence is incompatible with the kernel's GPL), and OpenZFS releases
  can lag new kernels. The LTS kernel keeps the ZFS module (rebuilt by DKMS)
  supported across updates.
- **Pool layout.** `voltos-install` creates:

  ```
  zroot                    pool (feature set pinned to openzfs-2.2-linux
                           so ZFSBootMenu can always import it)
  zroot/ROOT/voltos        boot environment, mounted at /, contains /boot
  zroot/home               /home, shared by all boot environments
  ```

  ZFSBootMenu is installed to the EFI system partition as
  `EFI/zbm/zfsbootmenu.EFI` (plus the removable-media fallback path). Installs
  require UEFI; the live ISO itself boots on BIOS and UEFI.
- **Identity.** `filesystem` owns `/usr/lib/os-release` and `/etc/issue`;
  `voltos-branding` re-applies the VoltOS versions from a pacman hook
  whenever they change.
- **GNOME and Nimbus.** GTK 3 applications and icons follow Nimbus.
  GTK 4/libadwaita applications
  (most core GNOME apps) and the GNOME Shell panel ignore GTK themes by
  design; they use the slate accent colour instead. A Nimbus GNOME Shell
  theme and libadwaita styling are future work. Arch no longer ships GTK 2,
  so Nimbus's GTK 2 engine is not built.
- **Unattended installs.** Booting the live medium with
  `voltos.autoinstall=/dev/DISK` installs to that disk without asking, with
  user `volt` / password `volt`. It exists for CI and mass deployment; never
  use it on a machine whose disk you need.

## Credits

- Nimbus theme: Sun Microsystems, the OpenIndiana project, and contributors
  (see `packages/nimbus-gtk-theme`).
- OpenZFS packaging recipes adapted from the AUR `zfs-utils` and `zfs-dkms`
  packages (maintainers credited in each `PKGBUILD`).
- ZFSBootMenu: the zbm-dev project (MIT).
- Tux: Larry Ewing and The GIMP (see `packages/voltos-branding`).
