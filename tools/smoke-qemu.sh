#!/bin/bash
#
# Boot the VoltOS ISO in QEMU and check that it reaches the graphical
# MATE live session.  Optionally run the unattended installer and boot
# the installed system through ZFSBootMenu.
#
#   tools/smoke-qemu.sh live-bios  <iso>   SeaBIOS, live desktop
#   tools/smoke-qemu.sh live-uefi  <iso>   OVMF, live desktop
#   tools/smoke-qemu.sh install    <iso>   OVMF, install to a ZFS disk,
#                                          then boot it via ZFSBootMenu
#                                          (SMOKE_SECBOOT=1: then enrol keys
#                                          with voltos-secureboot and boot
#                                          again with Secure Boot enforced)
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
ovmf_secboot=
for c in /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
    /usr/share/OVMF/OVMF_CODE_4M.secboot.fd; do
	[ -f "$c" ] && { ovmf_secboot=$c; break; }
done
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
	rm -f "$tmp/qga"
	qemu-system-x86_64 -machine q35,accel=$accel -cpu max -smp 4 -m 4G \
	    -display none -vga std -monitor "unix:$tmp/mon,server,nowait" \
	    -device virtio-serial \
	    -chardev "socket,path=$tmp/qga,server=on,wait=off,id=qga0" \
	    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
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

# guest_sh <command>: run a shell command in the guest through the QEMU
# guest agent and print its output (empty if the agent is not up yet).
guest_sh()
{
	python3 -I - "$tmp/qga" "$1" <<'PY' 2>/dev/null || true
import base64, json, socket, sys, time
sock, cmd = sys.argv[1], sys.argv[2]
def call(f, req):
    f.write(json.dumps(req) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            return r
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sock)
f = s.makefile("rw")
call(f, {"execute": "guest-sync", "arguments": {"id": 7}})
pid = call(f, {"execute": "guest-exec", "arguments": {"path": "/bin/sh",
      "arg": ["-c", cmd], "capture-output": True}})["return"]["pid"]
for _ in range(60):
    st = call(f, {"execute": "guest-exec-status", "arguments": {"pid": pid}})["return"]
    if st.get("exited"):
        sys.stdout.write(base64.b64decode(st.get("out-data", "")).decode())
        break
    time.sleep(1)
PY
}

# wait_greeter <seconds>: wait until the display manager shows its login
# screen, i.e. a greeter-class session exists in logind (LightDM's greeter
# runs as the lightdm user, GDM's as gdm).
wait_greeter()
{
	local i=0 out
	while [ "$i" -lt "$1" ]; do
		out=$(guest_sh 'for s in $(loginctl list-sessions --no-legend | awk "{print \$1}"); do loginctl show-session "$s" -p Class -p Name -p Type | tr "\n" " "; echo; done')
		if printf '%s\n' "$out" | grep -q 'Class=greeter'; then
			echo "smoke-qemu.sh: login screen is up ($out)"
			return 0
		fi
		sleep 5
		i=$((i + 5))
	done
	echo "smoke-qemu.sh: no greeter session after $1 s" >&2
	echo "last logind sessions: $out" >&2
	return 1
}

# screenshot [suffix]: save the screen to $SMOKE_SCREENSHOT (with -suffix
# inserted before the extension when given).
screenshot()
{
	local out
	[ -n "${SMOKE_SCREENSHOT:-}" ] || return 0
	out=$SMOKE_SCREENSHOT
	[ -n "${1:-}" ] && out="${SMOKE_SCREENSHOT%.*}-$1.${SMOKE_SCREENSHOT##*.}"
	echo "screendump $tmp/shot.ppm" | socat - "UNIX-CONNECT:$tmp/mon" >/dev/null
	sleep 2
	if command -v magick >/dev/null; then
		magick "$tmp/shot.ppm" "$out"
	else
		cp "$tmp/shot.ppm" "${out%.*}.ppm"
	fi
	echo "smoke-qemu.sh: screenshot $out"
}

# check_sessions: MATE must be installed as the default session and GNOME
# Flashback (Metacity) as the fallback offered by the greeter.
check_sessions()
{
	local list
	list=$(guest_sh 'ls /usr/share/xsessions')
	printf 'smoke-qemu.sh: sessions: %s\n' "$(echo $list)"
	for want in mate.desktop gnome-flashback-metacity.desktop; do
		printf '%s\n' "$list" | grep -qx "$want" || {
			echo "smoke-qemu.sh: session $want is missing" >&2
			exit 1
		}
	done
}

# app_screenshots: open the file manager (Caja), a GTK 3 utility (Disks) and
# the graphical installer in the live MATE session and photograph each, to
# check the Nimbus styling.  Best effort: never fails the test.
app_screenshots()
{
	local env='runuser -u liveuser -- env DISPLAY=:0 XAUTHORITY=/home/liveuser/.Xauthority XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus'
	[ -n "${SMOKE_SCREENSHOT:-}" ] || return 0
	guest_sh "$env setsid caja --no-desktop /home/liveuser >/dev/null 2>&1 &"
	sleep "${SMOKE_APP_WAIT:-25}"
	screenshot files
	guest_sh "pkill -f 'caja --no-desktop'; $env setsid gnome-disks >/dev/null 2>&1 &"
	sleep "${SMOKE_APP_WAIT:-25}"
	screenshot disks
	guest_sh "pkill -f gnome-disks; $env setsid voltos-installer-gtk >/dev/null 2>&1 &"
	sleep "${SMOKE_APP_WAIT:-25}"
	screenshot installer
}

uefi_args()
{
	[ -n "$ovmf_code" ] || { echo "OVMF not found (install edk2-ovmf)" >&2; exit 1; }
	cp "$ovmf_vars" "$tmp/vars.fd"
	if [ "${SMOKE_SECBOOT:-0}" = 1 ]; then
		# Secure Boot capable firmware, no keys enrolled (Setup Mode).
		# The variable store must be SMM-protected for it to work.
		[ -n "$ovmf_secboot" ] || { echo "secure boot OVMF not found" >&2; exit 1; }
		echo "-machine smm=on -global driver=cfi.pflash01,property=secure,value=on" \
		     "-drive if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_secboot" \
		     "-drive if=pflash,format=raw,unit=1,file=$tmp/vars.fd"
		return
	fi
	echo "-drive if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_code" \
	     "-drive if=pflash,format=raw,unit=1,file=$tmp/vars.fd"
}

# The live session reports on the serial port once LightDM has logged the
# live user into MATE (voltos-live-ready.service).  The installed system boots
# with a serial console (voltos.autoinstall.serial=1), so systemd's own
# status line shows when its graphical target is reached.
LIVE_RE='VOLTOS_LIVE_READY'
INSTALLED_RE='Reached target .*Graphical Interface'

case "$mode" in
live-bios)
	qemu_boot "$tmp/serial.log" -cdrom "$iso"
	wait_for "$tmp/serial.log" "$LIVE_RE" "$timeout"
	check_sessions
	sleep 30
	screenshot
	app_screenshots
	;;
live-uefi)
	# shellcheck disable=SC2046
	qemu_boot "$tmp/serial.log" $(uefi_args) -cdrom "$iso"
	wait_for "$tmp/serial.log" "$LIVE_RE" "$timeout"
	check_sessions
	sleep 30
	screenshot
	app_screenshots
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

	# Second boot: firmware -> ZFSBootMenu -> zroot/ROOT/voltos -> LightDM.
	# shellcheck disable=SC2086
	qemu_boot "$tmp/boot.log" $uefi \
	    -drive "file=$tmp/disk.qcow2,if=virtio,format=qcow2"
	wait_for "$tmp/boot.log" "$INSTALLED_RE" "$timeout"
	wait_greeter "$timeout"
	sleep 10
	screenshot

	if [ "${SMOKE_SECBOOT:-0}" = 1 ]; then
		# Enrol the machine owner's keys and sign the boot chain from
		# inside the installed system, then boot with Secure Boot on.
		out=$(guest_sh 'voltos-secureboot enable 2>&1; echo "rc=$?"')
		printf '%s\n' "$out"
		printf '%s\n' "$out" | grep -q '^rc=0$' || {
			echo "smoke-qemu.sh: voltos-secureboot enable failed" >&2
			exit 1
		}
		guest_sh 'systemctl poweroff' >/dev/null
		wait "${pids[-1]}" || true
		# shellcheck disable=SC2086
		qemu_boot "$tmp/sb.log" $uefi \
		    -drive "file=$tmp/disk.qcow2,if=virtio,format=qcow2"
		wait_for "$tmp/sb.log" "$INSTALLED_RE" "$timeout"
		wait_greeter "$timeout"
		sb=$(guest_sh 'sbctl status 2>&1')
		printf '%s\n' "$sb"
		printf '%s\n' "$sb" | grep -Eq 'Secure Boot:.*Enabled' || {
			echo "smoke-qemu.sh: Secure Boot is not enabled after reboot" >&2
			exit 1
		}
		echo "smoke-qemu.sh: booted with Secure Boot enforced"
		screenshot secureboot
	fi
	;;
*)
	echo "unknown mode $mode" >&2
	exit 2
	;;
esac
echo "smoke-qemu.sh: $mode OK"
