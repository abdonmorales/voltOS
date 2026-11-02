#!/bin/bash
#
# Boot the VoltOS ISO in QEMU and check that it reaches the graphical
# GNOME live session.  Optionally run the unattended installer and boot
# the installed system through ZFSBootMenu.
#
#   tools/smoke-qemu.sh live-bios  <iso>   SeaBIOS, live desktop
#   tools/smoke-qemu.sh live-uefi  <iso>   OVMF, live desktop
#   tools/smoke-qemu.sh install    <iso>   OVMF, install to a ZFS disk,
#                                          then boot it via ZFSBootMenu
#
# Environment: SMOKE_TIMEOUT (seconds per boot, default 900 - QEMU without
# KVM is slow), SMOKE_SCREENSHOT (save a PNG of the desktop here), KVM=0/1.
#
set -euo pipefail

mode=${1:?mode}
iso=${2:?iso}
timeout=${SMOKE_TIMEOUT:-900}
tmp=$(mktemp -d)
pids=()
cleanup()
{
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
	rm -rf "$tmp"
}
trap cleanup EXIT

accel=tcg
if [ "${KVM:-auto}" != 0 ] && [ -w /dev/kvm ]; then
	accel=kvm
fi

ovmf_code=
ovmf_vars=
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
	[ -f "$c" ] && { ovmf_code=$c; break; }
done
for v in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
	[ -f "$v" ] && { ovmf_vars=$v; break; }
done

# qemu_boot <log> <extra args...>: start QEMU in the background with a
# serial log and a monitor socket for screenshots.
qemu_boot()
{
	local log=$1
	shift
	qemu-system-x86_64 -machine q35,accel=$accel -cpu max -smp 4 -m 4G \
	    -display none -vga std -monitor "unix:$tmp/mon,server,nowait" \
	    -serial "file:$log" -no-reboot "$@" >"$tmp/qemu.out" 2>&1 &
	pids+=($!)
}

# wait_for <log> <regex> <seconds>
wait_for()
{
	local i=0
	while [ "$i" -lt "$3" ]; do
		grep -aqE "$2" "$1" 2>/dev/null && return 0
		kill -0 "${pids[-1]}" 2>/dev/null || break
		sleep 1
		i=$((i + 1))
	done
	if kill -0 "${pids[-1]}" 2>/dev/null; then
		echo "smoke-qemu.sh: timed out waiting for /$2/" >&2
	else
		echo "smoke-qemu.sh: QEMU exited before /$2/ appeared:" >&2
		cat "$tmp/qemu.out" >&2 || true
	fi
	tail -n 60 "$1" >&2 2>/dev/null || true
	return 1
}

screenshot()
{
	[ -n "${SMOKE_SCREENSHOT:-}" ] || return 0
	echo "screendump $tmp/shot.ppm" | socat - "UNIX-CONNECT:$tmp/mon" >/dev/null
	sleep 2
	if command -v magick >/dev/null; then
		magick "$tmp/shot.ppm" "$SMOKE_SCREENSHOT"
	else
		cp "$tmp/shot.ppm" "${SMOKE_SCREENSHOT%.*}.ppm"
	fi
	echo "smoke-qemu.sh: screenshot $SMOKE_SCREENSHOT"
}

uefi_args()
{
	[ -n "$ovmf_code" ] || { echo "OVMF not found (install edk2-ovmf)" >&2; exit 1; }
	cp "$ovmf_vars" "$tmp/vars.fd"
	echo "-drive if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_code" \
	     "-drive if=pflash,format=raw,unit=1,file=$tmp/vars.fd"
}

# The live session reports on the serial port once GDM has logged the live
# user into GNOME (voltos-live-ready.service).  The installed system boots
# with a serial console (voltos.autoinstall.serial=1), so systemd's own
# status line shows when its graphical target is reached.
LIVE_RE='VOLTOS_LIVE_READY'
INSTALLED_RE='Reached target .*Graphical Interface'

case "$mode" in
live-bios)
	qemu_boot "$tmp/serial.log" -cdrom "$iso"
	wait_for "$tmp/serial.log" "$LIVE_RE" "$timeout"
	sleep 30
	screenshot
	;;
live-uefi)
	# shellcheck disable=SC2046
	qemu_boot "$tmp/serial.log" $(uefi_args) -cdrom "$iso"
	wait_for "$tmp/serial.log" "$LIVE_RE" "$timeout"
	sleep 30
	screenshot
	;;
install)
	# Boot the ISO's kernel directly so the unattended-install option can
	# be added to its command line; OVMF still provides a real UEFI
	# environment for efibootmgr and ZFSBootMenu.
	command -v bsdtar >/dev/null || { echo "bsdtar required" >&2; exit 1; }
	bsdtar -xf "$iso" -C "$tmp" voltos/boot/x86_64/vmlinuz-linux-lts \
	    voltos/boot/x86_64/initramfs-linux-lts.img
	label=$(blkid -o value -s LABEL "$iso" 2>/dev/null || isoinfo -d -i "$iso" | sed -n 's/^Volume id: //p')
	qemu-img create -f qcow2 "$tmp/disk.qcow2" 20G >/dev/null
	uefi=$(uefi_args)
	# shellcheck disable=SC2086
	qemu_boot "$tmp/install.log" $uefi -cdrom "$iso" \
	    -drive "file=$tmp/disk.qcow2,if=virtio,format=qcow2" \
	    -kernel "$tmp/voltos/boot/x86_64/vmlinuz-linux-lts" \
	    -initrd "$tmp/voltos/boot/x86_64/initramfs-linux-lts.img" \
	    -append "archisobasedir=voltos archisolabel=$label console=ttyS0 voltos.autoinstall=/dev/vda voltos.autoinstall.reboot=poweroff voltos.autoinstall.serial=1"
	wait_for "$tmp/install.log" 'VOLTOS_AUTOINSTALL_(OK|FAILED)' "$timeout"
	if grep -aq VOLTOS_AUTOINSTALL_FAILED "$tmp/install.log"; then
		tail -n 60 "$tmp/install.log" >&2
		exit 1
	fi
	wait "${pids[-1]}" || true

	# Second boot: firmware -> ZFSBootMenu -> zroot/ROOT/voltos -> GDM.
	# shellcheck disable=SC2086
	qemu_boot "$tmp/boot.log" $uefi \
	    -drive "file=$tmp/disk.qcow2,if=virtio,format=qcow2"
	wait_for "$tmp/boot.log" "$INSTALLED_RE" "$timeout"
	sleep 30
	screenshot
	;;
*)
	echo "unknown mode $mode" >&2
	exit 2
	;;
esac
echo "smoke-qemu.sh: $mode OK"
