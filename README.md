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
- **The OpenSolaris installer.** The live desktop's installer is
  OpenSolaris's own graphical installer (Caiman's gui-install, from
  OpenIndiana), ported to Linux and GTK 3: the same Welcome, Disk, Time Zone
  (with the world map), Locale, Users, Installation and Finish screens. A
  text-mode installer is the fallback. Both run `voltos-install`, which
  copies the tested live system onto the ZFS pool, so installing works
  offline.
- **Secure Boot, with your own keys.** `doas voltos-secureboot enable` enrols
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
| Graphical installer (OpenSolaris gui-install on GTK 3) | CI installs through the GUI (test mode), then boots the result to the login screen |
| AArch64 | Packages and ISO built in CI on an Arch Linux ARM root; CI boots the live desktop (virtio-gpu) and installs to ZFS, then boots the result through ZFSBootMenu to the login screen on a firmware-only framebuffer (ramfb). Newer and less tested than x86_64; no Secure Boot signing yet |
| GNOME 2.32 desktop (GTK 2) | In progress: GTK 2, Nimbus's GTK 2 engine and the GNOME 2 platform (ORBit2, GConf, Bonobo, GnomeVFS, libgnome/libgnomeui) are built; the desktop (Metacity, panel, session, Nautilus, ...) is being ported. Not on the ISO yet; planned to replace GNOME Flashback around VoltOS 1.5. MATE stays the default |
| Updates (`[voltos]` repository) | Signed packages published by CI to GitHub releases after the tests pass; the install test checks that the installed system verifies them |
| CI (`.github/workflows/iso.yml`) | Builds, boots and installs both architectures; publishes both ISOs on `v*` tags (0.x tags as pre-releases) |

## Layout

```
archiso/                 live/install medium (archiso profile)
packages/
  nimbus-gtk-theme/      Nimbus GTK 3, Metacity and icon themes
  voltos-branding/       os-release identity, Tux logo, shared Nimbus defaults
  voltos-desktop/        MATE + GNOME Flashback defaults, LightDM greeter
  voltos-installer/      voltos-install (the installation itself) and the text installer
  voltos-gui-install/    the OpenSolaris graphical installer, ported to GTK 3
  voltos-live/           live user, autologin helpers, unattended install
  voltos-zfs-snapshots/  pacman hook: snapshot before every transaction
  voltos-secureboot/     Secure Boot enrolment and signing (sbctl)
  voltos-keyring/        the VoltOS package signing key, for pacman-key
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
  make-repo-key.sh       create the VoltOS package signing key (run once)
  publish-repo.sh        publish the package repository (CI)
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

## The installer

`packages/voltos-gui-install/gui-install` is the OpenSolaris (Caiman)
graphical installer from OpenIndiana's slim_source, under the CDDL. Its
screens are kept; what is Solaris-specific underneath was replaced:

- **UI files and toolkit.** libglade files were converted to GtkBuilder
  (`tools/glade2builder.py`) and the code builds against GTK 3 through two
  small compatibility headers; the world map draws with cairo. The same
  sources are meant to build against GTK 2 for the GNOME 2 desktop.
- **Back end.** Solaris's liborchestrator becomes a Linux implementation of
  the same API: disks come from `lsblk`, and "Install" runs
  `pkexec voltos-install --config FILE` and turns its progress messages into
  the progress bar and slideshow. Time zones come from the IANA tz database.
- **VoltOS choices.** Whole-disk installs only (the fdisk partition editor and
  the upgrade screens are gone), no root password (the account created on the
  Users screen administers the system with doas), VoltOS branding, help and
  slides.

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
- **GNOME 2 itself.** A GNOME 2.32 desktop on GTK 2, with Nimbus's original
  GTK 2 engine, built as VoltOS's own packages (Arch no longer ships GTK 2
  or any of GNOME 2). Its window manager and panel take the names GNOME
  Flashback's use, so the two cannot be installed together: GNOME 2 is
  planned to replace Flashback as the second session around VoltOS 1.5,
  after more testing; until then it is not on the ISO. Manuals are left
  out (they need gnome-doc-utils, which needs Python 2).
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

## Administrator access: doas

VoltOS uses [doas](https://github.com/Duncaen/OpenDoas) instead of sudo.
The account made at installation is in `wheel`, which `/etc/doas.conf`
allows to run commands as root (`doas pacman -Syu`); root itself is locked.
The `voltos-doas` package provides it, replaces sudo on systems that had it
(`pacman -Syu` offers the swap) and keeps a small `sudo` command that hands
the usual forms (`sudo cmd`, `-u user`, `-i`/`-s`, `-n`) to doas, so scripts,
`makepkg -s` and AUR helpers keep working. Graphical prompts (the installer,
settings) use polkit as before.

## Updates

Installed systems get VoltOS's own packages (OpenZFS, ZFSBootMenu, Nimbus,
the `voltos-*` packages, and on AArch64 the kernel) from the `[voltos]`
repository, which the installer adds to `/etc/pacman.conf` ahead of `[core]`:

```ini
[voltos]
SigLevel = Required DatabaseRequired
Server = https://github.com/abdonmorales/voltOS/releases/download/repo-$arch
```

Everything else comes from Arch Linux (Arch Linux ARM on AArch64) as usual,
so `pacman -Syu` updates both.

The repository is the files of two GitHub releases, `repo-x86_64` and
`repo-aarch64`, which CI updates on every push to `main` once that
architecture's build and tests have passed (`tools/publish-repo.sh`). A
package file that is already published is never replaced, so **to ship a
change, bump the package's `pkgver` or `pkgrel`**; a rebuild of an unchanged
version is not published. Old versions are removed when the database stops
listing them.

Packages and the database are signed with the VoltOS package key; the
`voltos-keyring` package carries its public half and `pacman-key --populate`
trusts it. CI needs one secret, `VOLTOS_REPO_KEY`. Create it once, on your own
machine:

```sh
tools/make-repo-key.sh                       # -> repo-key/voltos-repo.{key,asc}
gh secret set VOLTOS_REPO_KEY --repo abdonmorales/voltOS < repo-key/voltos-repo.key
```

Keep `voltos-repo.key` offline after that: anyone holding it can publish
packages that every VoltOS system installs. If the key is ever replaced, bump
`voltos-keyring`'s `pkgver`. Without the secret (forks, local builds) the
packages are unsigned, there is no `voltos-keyring`, and installed systems do
not get the `[voltos]` repository.

A system installed before the repository existed can add it by hand (check
the fingerprint against the one `tools/make-repo-key.sh` printed):

```sh
curl -fLO https://github.com/abdonmorales/voltOS/releases/download/repo-$(uname -m)/voltos-repo.asc
doas pacman-key --add voltos-repo.asc
doas pacman-key --lsign-key <fingerprint>
# add the [voltos] section above to /etc/pacman.conf, before [core], then:
doas pacman -Sy voltos-keyring
```

## Credits

- Nimbus theme: Sun Microsystems, the OpenIndiana project, and contributors
  (see `packages/nimbus-gtk-theme`).
- OpenZFS packaging recipes adapted from the AUR `zfs-utils` and `zfs-dkms`
  packages (maintainers credited in each `PKGBUILD`).
- ZFSBootMenu: the zbm-dev project (MIT).
- shim: the rhboot project, Microsoft-signed build from Fedora.
- Tux: Larry Ewing and The GIMP (see `packages/voltos-branding`).
