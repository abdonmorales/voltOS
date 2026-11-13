#!/bin/bash
#
# Make a VoltOS ISO bootable with UEFI Secure Boot enabled.
#
#   VOLTOS_SB_KEY=key.pem VOLTOS_SB_CERT=cert.pem tools/sign-iso.sh in.iso out.iso
#
# VOLTOS_SB_KEY / VOLTOS_SB_CERT are paths to the PEM private key and
# certificate made by tools/make-secureboot-key.sh (in CI they come from the
# GitHub Actions secrets of the same names).
#
# Boot chain on the signed medium:
#
#   firmware (Microsoft UEFI CA in db)
#     -> EFI/BOOT/BOOTx64.EFI   shim, signed by Microsoft (Fedora's build)
#     -> EFI/BOOT/grubx64.efi   systemd-boot, signed with the VoltOS key
#     -> vmlinuz-linux-lts      signed with the VoltOS key
#
# (AArch64: BOOTAA64.EFI, grubaa64.efi and mmaa64.efi, from Fedora's
# shim-aa64, signed by the Microsoft UEFI CA 2023.)
#
# shim accepts the VoltOS signatures once the VoltOS certificate is trusted,
# either in the firmware db or enrolled as a Machine Owner Key.  On first
# boot shim finds no trusted signature for systemd-boot and starts MokManager
# (EFI/BOOT/mmx64.efi): choose "Enroll key from disk" and pick
# VOLTOS-SECUREBOOT.cer from the medium.  Machines with Secure Boot off are
# unaffected.
#
set -euo pipefail

in=${1:?usage: sign-iso.sh in.iso out.iso}
out=${2:?usage: sign-iso.sh in.iso out.iso}
key=${VOLTOS_SB_KEY:?VOLTOS_SB_KEY must name the signing key file}
cert=${VOLTOS_SB_CERT:?VOLTOS_SB_CERT must name the certificate file}

# Fedora's shim, signed by the Microsoft UEFI CA (pinned), per architecture.
SHIM_DIR=usr/lib/efi/shim/16.1-5/EFI/fedora
SHIM_URL_x64=https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/Packages/s/shim-x64-16.1-5.x86_64.rpm
SHIM_SHA256_x64=a1bbabaca8e4398b2483c678240f4be4803e91390b512a7b618da3bc88e49917
SHIM_URL_aa64=https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/aarch64/os/Packages/s/shim-aa64-16.1-5.aarch64.rpm
SHIM_SHA256_aa64=778ca345d675d05de36745a1d582828d85d77f4f78b580b7caa340cd9f0bde19

for tool in xorriso mcopy mkfs.fat sbsign sbverify openssl bsdtar curl; do
	command -v "$tool" >/dev/null || { echo "sign-iso.sh: $tool is required" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- extract the EFI system partition the ISO appends -----------------------
# xorriso reports it as: -append_partition 2 0xef --interval:local_fs:STARTd-ENDd::
range=$(xorriso -indev "$in" -report_el_torito as_mkisofs 2>/dev/null |
    sed -n "s/^-append_partition 2 0xef --interval:local_fs:\([0-9]*\)d-\([0-9]*\)d::.*/\1 \2/p")
[ -n "$range" ] || { echo "sign-iso.sh: no EFI partition in $in" >&2; exit 1; }
set -- $range
dd if="$in" of="$tmp/esp-old.img" bs=512 skip="$1" count=$(($2 - $1 + 1)) status=none
mkdir "$tmp/esp"
mcopy -s -n -i "$tmp/esp-old.img" ::/ "$tmp/esp/"

boot=$tmp/esp/EFI/BOOT
# The medium's architecture, from its removable-media boot loader.
if [ -f "$boot/BOOTx64.EFI" ]; then
	efi=x64 loader=BOOTx64.EFI
elif [ -f "$boot/BOOTAA64.EFI" ]; then
	efi=aa64 loader=BOOTAA64.EFI
else
	echo "sign-iso.sh: no EFI/BOOT/BOOTx64.EFI or BOOTAA64.EFI" >&2
	exit 1
fi
url=SHIM_URL_$efi sum=SHIM_SHA256_$efi

# --- shim -------------------------------------------------------------------
curl -sSfL -o "$tmp/shim.rpm" "${!url}"
echo "${!sum}  $tmp/shim.rpm" | sha256sum -c --quiet
mkdir "$tmp/shim"
# (shim$efi.efi is a hard link inside the RPM, so unpack all of it.)
bsdtar -xf "$tmp/shim.rpm" -C "$tmp/shim"
# x64: Microsoft Corporation UEFI CA 2011; aa64: Microsoft UEFI CA 2023.
sbverify --list "$tmp/shim/$SHIM_DIR/shim$efi.efi" | grep -Eq 'Microsoft (Corporation )?UEFI CA' ||
    { echo "sign-iso.sh: shim is not signed by the Microsoft UEFI CA" >&2; exit 1; }

# sign <file> <output> [name shown]
sign()
{
	sbsign --key "$key" --cert "$cert" --output "$2" "$1" >/dev/null 2>&1
	sbverify --cert "$cert" "$2" >/dev/null 2>&1 ||
	    { echo "sign-iso.sh: signature check failed for $1" >&2; exit 1; }
	echo "sign-iso.sh: signed ${3:-${2#$tmp/esp/}}"
}

# systemd-boot becomes the second stage that shim loads by name.
sign "$boot/$loader" "$boot/grub$efi.efi"
install -m644 "$tmp/shim/$SHIM_DIR/shim$efi.efi" "$boot/$loader"
install -m644 "$tmp/shim/$SHIM_DIR/mm$efi.efi" "$boot/mm$efi.efi"

# Kernels and other EFI programs systemd-boot starts.
while IFS= read -r -d '' f; do
	sign "$f" "$f.signed" "${f#$tmp/esp/}"
	mv "$f.signed" "$f"
done < <(find "$tmp/esp" \( -name 'vmlinuz-*' -o -name 'memtest86x64.efi' \) -print0)

# The certificate users enroll with MokManager.
openssl x509 -in "$cert" -outform DER -out "$tmp/esp/VOLTOS-SECUREBOOT.cer"

# --- rebuild the FAT image (a little larger) and the ISO ----------------------
kib=$(( $(du -sk "$tmp/esp" | cut -f1) + 16384 ))
mkfs.fat -C -n ARCHISO_EFI "$tmp/esp.img" "$kib" >/dev/null
mcopy -s -i "$tmp/esp.img" "$tmp/esp"/* ::/

rm -f "$out"
xorriso -indev "$in" -outdev "$out" \
    -boot_image any replay \
    -append_partition 2 0xef "$tmp/esp.img" \
    -commit >/dev/null 2>"$tmp/xorriso.log" || {
	cat "$tmp/xorriso.log" >&2
	exit 1
}
echo "sign-iso.sh: wrote $out"
