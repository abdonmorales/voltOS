# VoltOS

VoltOS is an Arch Linux–based desktop distribution with:

- **A GNOME 2-lineage desktop with the Nimbus look.** The desktop is
  [MATE](https://mate-desktop.org), the continuation of GNOME 2 that
  OpenIndiana also ships, with the Sun/OpenSolaris Nimbus GTK theme, Metacity
  window theme and icon set from
  [abdonmorales/nimbus](https://github.com/abdonmorales/nimbus). LightDM
  offers **GNOME Flashback (Metacity)** as a fallback session.
- **A ZFS root with boot environments.** The system is installed on OpenZFS
  and booted by [ZFSBootMenu](https://zfsbootmenu.org). Every pacman
  transaction is preceded by a snapshot of the running boot environment, so
  any upgrade can be rolled back from the boot menu, the way Solaris and
  illumos boot environments work.
- **Its own installer.** A graphical installer (GTK 4/libadwaita) on the live
  desktop, with a text-mode fallback. Both run `voltos-install`, which copies
  the tested live system onto the ZFS pool, so installing works offline.
- **Secure Boot, with your own keys.** `sudo voltos-secureboot enable` enrols
  machine-owner keys (plus Microsoft's) and signs ZFSBootMenu and the kernels;
  updates are re-signed automatically.

VoltOS is built for x86_64 (UEFI and BIOS) and, as a newer port, AArch64
(64-bit ARM with UEFI). The logo is currently Tux.

## Status

| Piece | State |
| --- | --- |
| Package repository (`packages/`), incl. OpenZFS 2.4.4 | Builds on Arch Linux |
| Live ISO, MATE + Nimbus (`archiso/`) | New: switched from GNOME to MATE; being re-verified in CI |
| Installer to ZFS + ZFSBootMenu | `make smoke-install`: unattended install, then the installed system boots from ZFS through ZFSBootMenu to the login screen |
| Live ISO on BIOS | Boots to the live desktop under SeaBIOS in QEMU (CI) |
| Graphical installer | CI installs through the GUI (test mode), then boots the result to the login screen |
| AArch64 | New: packages and ISO built in CI on an Arch Linux ARM root; not yet boot-tested |
| CI (`.github/workflows/iso.yml`) | Builds, boots, installs and publishes on `v*` tags |

## Layout

```
archiso/                 live/install medium (archiso profile)
packages/
  nimbus-gtk-theme/      Nimbus GTK 3, Metacity and icon themes
  voltos-branding/       os-release identity, Tux logo, shared Nimbus defaults
  voltos-desktop/        MATE + GNOME Flashback defaults, LightDM greeter
  voltos-installer/      graphical and text installers (voltos-install)
  voltos-live/           live user, autologin helpers, unattended install
  voltos-zfs-snapshots/  pacman hook: snapshot before every transaction
  voltos-secureboot/     Secure Boot enrolment and signing (sbctl)
  zfs-utils/, zfs-dkms/  OpenZFS 2.4.4 (from the AUR recipes)
  zfsbootmenu-efi/       ZFSBootMenu 3.1.0 release EFI (x86_64)
  zfsbootmenu/           ZFSBootMenu built with generate-zbm (AArch64)
  perl-boolean/          Perl module generate-zbm needs
  linux-lts-aarch64/     the LTS kernel for AArch64
tools/
  build-packages.sh      build packages into out/repo (out/repo-aarch64)
  build-iso.sh           build out/voltos-YYYY.MM.DD-<arch>.iso
  alarm-buildroot.sh     create an Arch Linux ARM root to build AArch64 in
  alarm-chroot.sh        run a command in that root
  smoke-qemu.sh          boot / install tests in QEMU
  sign-iso.sh            sign the ISO for Secure Boot (shim + VoltOS key)
  make-secureboot-key.sh create the VoltOS Secure Boot key (run once)
```

## Building

On Arch Linux:

```sh
sudo tools/install-build-deps.sh
sudo make iso            # packages, then the ISO in out/
make smoke               # boot the live desktop under UEFI in QEMU
make smoke-install       # unattended ZFS install, then boot it to the login screen
SMOKE_SECBOOT=1 make smoke-install   # ...then enable Secure Boot and boot again
```

On any other Linux host with Docker:

```sh
make docker-iso
```

For AArch64, on an AArch64 Linux host (or x86_64 with qemu-user-static
binfmt support):

```sh
sudo tools/alarm-buildroot.sh /var/tmp/alarm
sudo tools/alarm-chroot.sh /var/tmp/alarm 'cd /voltos && tools/build-packages.sh && tools/build-iso.sh'
```

Building and testing in QEMU without KVM works, but the desktop is slow
there; use a host with `/dev/kvm` for interactive testing.

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

## AArch64

Arch Linux has no official AArch64 port, so VoltOS for ARM sits on
[Arch Linux ARM](https://archlinuxarm.org) with three differences:

- **Kernel.** Arch Linux ARM ships only the newest mainline kernel, which
  OpenZFS does not support yet. VoltOS builds the same `linux-lts` series as
  x86_64 for AArch64 (Arch Linux ARM's generic multi-platform configuration),
  under the same package names, so the installer and DKMS work unchanged.
- **ZFSBootMenu.** There is no upstream AArch64 release EFI. The
  `zfsbootmenu` package runs `generate-zbm` on the installed system, using the
  installed kernel, its ZFS module and systemd's EFI stub, and a pacman hook
  rebuilds it after kernel or OpenZFS updates (and re-signs it when Secure
  Boot signing is set up).
- **Boot.** The live medium boots with UEFI only (systemd-boot, the
  removable-media path `EFI/BOOT/BOOTAA64.EFI`); installed systems boot
  ZFSBootMenu from the same paths as on x86_64.

`archiso` and `dkms` are architecture-independent packages that Arch Linux
ARM does not carry; `tools/alarm-buildroot.sh` takes them from Arch Linux and
checks their signatures against `archlinux-keyring`.

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
- **Desktop.** MATE is the default session: Marco draws window frames with
  the Nimbus Metacity theme, and MATE's GTK 3 applications, Caja's desktop
  and the panel follow the Nimbus GTK theme and icons (Nimbus ships MATE
  styling). The Applications menu carries the VoltOS logo. LightDM's GTK
  greeter uses Nimbus too. GNOME Flashback (gnome-panel + Metacity) is the
  fallback session, picked from the greeter's session menu. Both run on
  X11. The few GTK 4/libadwaita programs (such as the installer) get
  Nimbus colours from `~/.config/gtk-4.0/gtk.css` in new accounts.
- **GNOME 2 itself.** A GNOME 2.32 desktop on GTK 2 (with Nimbus's original
  GTK 2 engine) is planned as a separate effort once this distribution is
  complete. Arch no longer ships GTK 2, so it will come from VoltOS's own
  packages.
- **Secure Boot.** Installed systems: firmware -> signed ZFSBootMenu ->
  signed kernel (ZFSBootMenu's locked-down kernel only kexecs kernels signed
  by a key in the firmware db, so `voltos-secureboot` signs both). Put the
  firmware in Setup Mode first. The live ISO: see below.
- **Unattended installs.** Booting the live medium with
  `voltos.autoinstall=/dev/DISK` installs to that disk without asking, with
  user `volt` / password `volt`. It exists for CI and mass deployment; never
  use it on a machine whose disk you need.

## Secure Boot for the live ISO

CI signs the ISO when the repository has two Actions secrets,
`VOLTOS_SB_KEY` and `VOLTOS_SB_CERT`. Create them once, on your own machine:

```sh
tools/make-secureboot-key.sh                 # -> secureboot-key/voltos-sb.{key,crt,cer}
gh secret set VOLTOS_SB_KEY  --repo abdonmorales/voltOS < secureboot-key/voltos-sb.key
gh secret set VOLTOS_SB_CERT --repo abdonmorales/voltOS < secureboot-key/voltos-sb.crt
```

Keep `voltos-sb.key` offline after that; anyone holding it can sign software
that machines trusting the VoltOS key will boot.

`tools/sign-iso.sh` turns the built ISO's UEFI boot path into
Microsoft-signed shim (Fedora's build) -> systemd-boot and kernel signed with
the VoltOS key. On a PC with Secure Boot on, the first boot stops in shim's
MokManager: choose *Enroll key from disk*, pick `VOLTOS-SECUREBOOT.cer` from
the medium, confirm, and reboot. After that the medium (and later releases
signed with the same key) boots normally. Without the secrets the ISO is
unsigned and still boots wherever Secure Boot is off. CI boots the signed
ISO with Secure Boot enforced (`tools/smoke-qemu.sh live-secureboot`).

## Credits

- Nimbus theme: Sun Microsystems, the OpenIndiana project, and contributors
  (see `packages/nimbus-gtk-theme`).
- OpenZFS packaging recipes adapted from the AUR `zfs-utils` and `zfs-dkms`
  packages (maintainers credited in each `PKGBUILD`).
- ZFSBootMenu: the zbm-dev project (MIT).
- shim: the rhboot project, Microsoft-signed build from Fedora.
- Tux: Larry Ewing and The GIMP (see `packages/voltos-branding`).
