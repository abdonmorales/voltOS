#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# VoltOS live/install medium (archiso profile, derived from Arch's releng).

iso_name="voltos"
iso_label="VOLTOS_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="VoltOS <https://github.com/abdonmorales/voltOS>"
iso_application="VoltOS Live/Install Medium"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="voltos"
buildmodes=('iso')
bootmodes=('bios.syslinux'
           'uefi.systemd-boot')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
# zstd at level 19: about 95 MB smaller than level 15 (the ISO must stay
# under GitHub's 2 GiB limit for release files) and as fast to unpack; only
# building the image takes longer.
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19' '-b' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
)
