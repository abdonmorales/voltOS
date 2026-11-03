# gui-install for VoltOS

The OpenSolaris graphical installer, ported to Linux and GTK 3.

It comes from the Caiman installer project of OpenSolaris, as maintained by
OpenIndiana in [slim_source](https://github.com/OpenIndiana/slim_source)
(`usr/src/cmd/gui-install` and `usr/src/cmd/gui-aux`, imported at commit
c19616d). Those files are under the CDDL 1.0 (`LICENSE.CDDL`; the CDDL
headers' `usr/src/OPENSOLARIS.LICENSE` is that file) and keep their
copyright notices. VoltOS's changes to them, and the new files below, are
under the MIT licence.

## What changed

- **Toolkit.** The libglade UI files were converted to GtkBuilder
  (`tools/glade2builder.py` in the VoltOS tree); `compat/glade-compat.h`
  keeps the `glade_xml_*` calls working and `compat/gtk-compat.h` maps the
  GTK 2 names the code uses. The world map and time-zone widgets draw with
  cairo. The same sources are meant to build against GTK 2 again
  (`-Dgtk=2`) for VoltOS's GNOME 2 desktop.
- **Back end.** Solaris's liborchestrator, libzoneinfo and liblogsvc are
  replaced by `compat/orchestrator-linux.c` (disks from lsblk; the install
  is `pkexec voltos-install --config FILE`), `compat/zoneinfo-linux.c` (the
  IANA tz database) and standard-error logging.
- **Screens.** The Disk screen offers whole-disk installs only (GPT, an EFI
  system partition and a ZFS pool); the fdisk partition editor and the
  upgrade screens are gone. The Users screen creates the administrator
  account (root is locked; there is no root password). Branding, help texts,
  slides and the licence page are VoltOS's.
- **Test mode.** `VOLTOS_INSTALLER_TEST=<disk>` drives every screen and
  installs, writing the result to `/tmp/voltos-installer-test.result`
  (`src/test-mode.c`). `CAIMAN_DUMMY_INSTALL=1` stops short of installing.

## Building

```sh
meson setup build && meson compile -C build
```

It runs as the desktop user; only voltos-install runs as root.
