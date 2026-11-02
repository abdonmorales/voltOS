#!/bin/bash
# Install everything needed to build and smoke-test VoltOS on Arch Linux
# (used by CI inside an archlinux container).
set -euo pipefail
pacman -Syu --noconfirm --needed \
    base-devel git archiso sudo \
    qemu-system-x86 qemu-img edk2-ovmf socat libarchive imagemagick
