#!/bin/bash
#
# Boot the VoltOS ISO in QEMU and check that it reaches the graphical
# MATE live session.  Optionally run the unattended installer and boot
# the installed system through ZFSBootMenu.
#
# The architecture follows the ISO's name (voltos-*-aarch64.iso: AArch64,
# QEMU's "virt" machine with AAVMF; otherwise x86_64) or SMOKE_ARCH.  On
# AArch64 only the UEFI modes (live-uefi, install-gui, install) exist.
#
#   tools/smoke-qemu.sh live-bios  <iso>   SeaBIOS, live desktop
#   tools/smoke-qemu.sh live-uefi  <iso>   OVMF, live desktop
#   tools/smoke-qemu.sh live-secureboot <iso>  signed ISO, Secure Boot on
#                                          (SMOKE_SB_CERT=VoltOS certificate)
#   tools/smoke-qemu.sh install-gui <iso>  OVMF, install with the graphical
#                                          installer (test mode), then boot it
#   tools/smoke-qemu.sh install    <iso>   OVMF, install to a ZFS disk,
#                                          then boot it via ZFSBootMenu
#                                          (SMOKE_SECBOOT=1: then enrol keys
#                                          with voltos-secureboot and boot
#                                          again with Secure Boot enforced)
#
# Environment: SMOKE_TIMEOUT (seconds per boot, default 900 - QEMU without
# KVM is slow), SMOKE_SCREENSHOT (save a PNG of the desktop here), KVM=0/1,
# SMOKE_REPO=<dir> (install: the signed repository the ISO was built from;
# the installed system must have [voltos] enabled and fetch and verify
# updates from it, standing in for the published repository),
# SMOKE_GPU (AArch64 display device: virtio-gpu-pci, the default, or ramfb,
# a firmware-only framebuffer).
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

arch=${SMOKE_ARCH:-}
if [ -z "$arch" ]; then
	case "$iso" in *-aarch64.iso) arch=aarch64 ;; *) arch=x86_64 ;; esac
fi
# The serial port the live and installed systems report on.
case $arch in
x86_64) console=ttyS0 ;;
aarch64) console=ttyAMA0 ;;
*) echo "smoke-qemu.sh: unknown architecture $arch" >&2; exit 1 ;;
esac

# KVM only runs guests of the host's own architecture.
accel=tcg
if [ "${KVM:-auto}" != 0 ] && [ -w /dev/kvm ] && [ "$(uname -m)" = "$arch" ]; then
	accel=kvm
fi
echo "smoke-qemu.sh: $arch guest, accel=$accel"

ovmf_code=
ovmf_vars=
ovmf_secboot=
if [ "$arch" = aarch64 ]; then
	# AAVMF: Arch's edk2-aarch64, Debian/Ubuntu's qemu-efi-aarch64.
	for c in /usr/share/edk2/aarch64/QEMU_CODE.fd /usr/share/edk2/aarch64/QEMU_EFI.fd \
	    /usr/share/AAVMF/AAVMF_CODE.fd; do
		[ -f "$c" ] && { ovmf_code=$c; break; }
	done
	for v in /usr/share/edk2/aarch64/QEMU_VARS.fd /usr/share/AAVMF/AAVMF_VARS.fd; do
		[ -f "$v" ] && { ovmf_vars=$v; break; }
	done
fi
for c in /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
    /usr/share/OVMF/OVMF_CODE_4M.secboot.fd; do
	[ "$arch" = x86_64 ] && [ -f "$c" ] && { ovmf_secboot=$c; break; }
done
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
	[ "$arch" = x86_64 ] && [ -f "$c" ] && { ovmf_code=$c; break; }
done
for v in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
	[ "$arch" = x86_64 ] && [ -f "$v" ] && { ovmf_vars=$v; break; }
done

# qemu_boot <log> <extra args...>: start QEMU in the background with a
# serial log and a monitor socket for screenshots.
qemu_boot()
{
	local log=$1
	shift
	rm -f "$tmp/qga"
	local machine
	if [ "$arch" = aarch64 ]; then
		# virt has no legacy devices: a USB keyboard and tablet, a
		# virtio NIC, and either a virtio GPU or ramfb (a plain
		# firmware framebuffer, the display without a kernel driver).
		# Under TCG a fixed, common CPU model rather than "max": QEMU
		# 8.2's emulation of newer instructions "max" offers (FEAT_MOPS,
		# which the kernel's memset uses) corrupts memory, and the kernel
		# crashed loading the ZFS module.  SMOKE_CPU overrides.
		machine=(qemu-system-aarch64 -machine virt -cpu "${SMOKE_CPU:-neoverse-n1}"
		    -device "${SMOKE_GPU:-virtio-gpu-pci}"
		    -device qemu-xhci -device usb-kbd -device usb-tablet
		    -nic user,model=virtio-net-pci)
		[ "$accel" = kvm ] && [ -z "${SMOKE_CPU:-}" ] && machine[4]=host
	else
		machine=(qemu-system-x86_64 -machine q35 -cpu max -vga std)
	fi
	"${machine[@]}" -accel "$accel" -smp 4 -m 4G \
	    -display none -monitor "unix:$tmp/mon,server,nowait" \
	    -device virtio-serial \
	    -chardev "socket,path=$tmp/qga,server=on,wait=off,id=qga0" \
	    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
	    -serial "file:$log" -no-reboot "$@" >"$tmp/qemu.out" 2>&1 &
	pids+=($!)
}

# wait_qemu_exit <seconds>: wait for the guest to power off and QEMU to
# exit; stop QEMU (and say so) if it has not by then, so a guest that hangs
# while shutting down cannot stall the test until the CI job's time limit.
wait_qemu_exit()
{
	local i=0 pid=${pids[-1]}
	echo "smoke-qemu.sh: $(date -u +%T) waiting for the guest to power off"
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$i" -ge "$1" ]; then
			echo "smoke-qemu.sh: guest still running after $1 s; stopping QEMU" >&2
			kill "$pid" 2>/dev/null || true
			sleep 5
			break
		fi
		sleep 5
		i=$((i + 5))
	done
	wait "$pid" 2>/dev/null || true
}

# wait_for <log> <regex> <seconds>
wait_for()
{
	local i=0
	while [ "$i" -lt "$3" ]; do
		if grep -aqE "$2" "$1" 2>/dev/null; then
			echo "smoke-qemu.sh: $(date -u +%T) saw /$2/"
			return 0
		fi
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
	tail -n 200 "$1" >&2 2>/dev/null || true
	return 1
}

# guest_sh <command>: run a shell command in the guest through the QEMU
# guest agent and print its output (empty if the agent is not up yet).
guest_sh()
{
	python3 -I - "$tmp/qga" "$1" "${SMOKE_GUEST_WAIT:-60}" <<'PY' 2>/dev/null || true
import base64, json, socket, sys, time
sock, cmd, wait = sys.argv[1], sys.argv[2], int(sys.argv[3])
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
for _ in range(wait):
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
	elif command -v convert >/dev/null; then
		convert "$tmp/shot.ppm" "$out"
	else
		cp "$tmp/shot.ppm" "${out%.*}.ppm"
	fi
	echo "smoke-qemu.sh: screenshot $out"
}

# check_doas: administrators use doas, not sudo: voltos-doas installed,
# sudo gone, doas.conf valid, granting wheel but not the live user.
check_doas()
{
	local out
	out=$(guest_sh '
		pacman -Q voltos-doas >/dev/null && echo has-voltos-doas
		pacman -Q sudo >/dev/null 2>&1 || echo no-sudo
		doas -C /etc/doas.conf && echo conf-valid
		grep -qx "permit persist :wheel" /etc/doas.conf && echo wheel-rule
		grep -q liveuser /etc/doas.conf || echo no-live-rule
		id -nG volt | grep -qw wheel && echo volt-in-wheel')
	printf 'smoke-qemu.sh: doas: %s\n' "$(echo $out)"
	[ "$(echo $out)" = "has-voltos-doas no-sudo conf-valid wheel-rule no-live-rule volt-in-wheel" ] || {
		echo "smoke-qemu.sh: the installed system's doas setup is wrong" >&2
		exit 1
	}
}

# check_updates <repo dir>: the installed system has the [voltos] repository
# and the VoltOS key, and pacman downloads and verifies the signed database
# and a package from <repo dir> (served to the guest over QEMU's user
# network, as the published repository would be).
check_updates()
{
	local out http
	python3 -m http.server 8089 --bind 127.0.0.1 --directory "$1" \
	    >"$tmp/http.log" 2>&1 &
	http=$!
	sleep 2
	out=$(guest_sh '
		set -e
		grep -A3 "^\[voltos\]" /etc/pacman.conf
		pacman-key --list-keys "VoltOS Package Signing Key" >/dev/null
		printf "[options]\nArchitecture = auto\n[voltos]\nSigLevel = Required DatabaseRequired\nServer = http://10.0.2.2:8089\n" >/tmp/repo-test.conf
		mkdir -p /tmp/repo-test/cache
		pacman --config /tmp/repo-test.conf --dbpath /tmp/repo-test -Sy >/dev/null
		f=$(pacman --config /tmp/repo-test.conf --dbpath /tmp/repo-test --cachedir /tmp/repo-test/cache -Sddp voltos-branding)
		curl -fsS -o /tmp/repo-test/p "$f"
		curl -fsS -o /tmp/repo-test/p.sig "$f.sig"
		pacman-key --verify /tmp/repo-test/p.sig /tmp/repo-test/p 2>&1 | tail -n 1
		echo UPDATES_OK' 2>&1)
	kill "$http" 2>/dev/null || true
	printf '%s\n' "$out"
	case $out in
	*'[voltos]'*UPDATES_OK*) echo "smoke-qemu.sh: [voltos] updates verify on the installed system" ;;
	*)
		echo "smoke-qemu.sh: the installed system cannot verify [voltos] updates" >&2
		cat "$tmp/http.log" >&2
		exit 1
		;;
	esac
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

# app_screenshots: open the graphical installer, a GTK 3 utility (Disks)
# and the file manager (Caja) in the live MATE session, one after another,
# and photograph each to check the Nimbus styling.  Caja goes last because
# its window belongs to the desktop's Caja process and is not easily closed.
# Each app's output goes to /tmp/smoke-<app>.log in the guest and is shown
# when the app is not running.  Best effort: never fails the test.
app_screenshots()
{
	local env='runuser -u liveuser -- env DISPLAY=:0 XAUTHORITY=/home/liveuser/.Xauthority XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus'
	local app shot
	[ -n "${SMOKE_SCREENSHOT:-}" ] || return 0
	for app in gui-install:installer gnome-disks:disks \
	    "caja --no-desktop /home/liveuser":files; do
		shot=${app##*:}
		app=${app%:*}
		guest_sh "$env setsid $app >/tmp/smoke-$shot.log 2>&1 &"
		sleep "${SMOKE_APP_WAIT:-25}"
		screenshot "$shot"
		# -x: match the process name, not this command line.
		if [ -z "$(guest_sh "pgrep -x '${app%% *}'")" ]; then
			echo "smoke-qemu.sh: $app is not running; its output:"
			guest_sh "cat /tmp/smoke-$shot.log"
		fi
		[ "$shot" = files ] || guest_sh "pkill -x '${app%% *}'" >/dev/null
	done
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

# cdrom_args: the ISO as a CD-ROM (virt has no IDE bus for -cdrom).
cdrom_args()
{
	if [ "$arch" = aarch64 ]; then
		echo "-device virtio-scsi-pci -device scsi-cd,drive=cd" \
		     "-drive if=none,id=cd,media=cdrom,readonly=on,file=$iso"
	else
		echo "-cdrom $iso"
	fi
}

# uefi_args runs in $(...), where its exit would not stop the script.
if [ "$mode" != live-bios ] && [ -z "$ovmf_code" ]; then
	echo "smoke-qemu.sh: no UEFI firmware for $arch (edk2-ovmf / edk2-aarch64, or ovmf / qemu-efi-aarch64)" >&2
	exit 1
fi

# virt's two flash devices must be the same size: pad a shorter AAVMF
# variable store to the size of the code image.  -L: distributions ship
# these files as symbolic links (Ubuntu's AAVMF_CODE.fd is one).
if [ "$arch" = aarch64 ] && [ -n "$ovmf_code" ]; then
	code_size=$(stat -L -c %s "$ovmf_code")
	if [ "$(stat -L -c %s "$ovmf_vars")" -lt "$code_size" ]; then
		cp -L "$ovmf_vars" "$tmp/aavmf-vars.fd"
		truncate -s "$code_size" "$tmp/aavmf-vars.fd"
		ovmf_vars=$tmp/aavmf-vars.fd
	fi
fi

# The live session reports on the serial port once LightDM has logged the
# live user into MATE (voltos-live-ready.service).  The installed system boots
# with a serial console (voltos.autoinstall.serial=1), so systemd's own
# status line shows when its graphical target is reached.
LIVE_RE='VOLTOS_LIVE_READY'
INSTALLED_RE='Reached target .*Graphical Interface'

case "$arch:$mode" in
aarch64:live-bios|aarch64:live-secureboot)
	echo "smoke-qemu.sh: $mode is x86_64 only" >&2
	exit 2
	;;
esac

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
	qemu_boot "$tmp/serial.log" $(uefi_args) $(cdrom_args)
	wait_for "$tmp/serial.log" "$LIVE_RE" "$timeout"
	check_sessions
	sleep 30
	screenshot
	app_screenshots
	;;
live-secureboot)
	# Secure Boot enforced, firmware trusting Microsoft's keys (for shim)
	# and the VoltOS certificate (SMOKE_SB_CERT) - what a PC that enrolled
	# the VoltOS key with MokManager amounts to.  Needs a signed ISO
	# (tools/sign-iso.sh) and virt-fw-vars.
	cert=${SMOKE_SB_CERT:?SMOKE_SB_CERT must name the VoltOS certificate}
	[ -n "$ovmf_secboot" ] || { echo "secure boot OVMF not found" >&2; exit 1; }
	virt-fw-vars -i "$ovmf_vars" -o "$tmp/sbvars.fd" --enroll-redhat \
	    --add-db 3d8b2a7e-5b6c-4f2a-9c1e-6a1f0b9d7c45 "$cert" \
	    --secure-boot >/dev/null
	qemu_boot "$tmp/serial.log" -machine smm=on \
	    -global driver=cfi.pflash01,property=secure,value=on \
	    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_secboot" \
	    -drive "if=pflash,format=raw,unit=1,file=$tmp/sbvars.fd" \
	    -cdrom "$iso"
	wait_for "$tmp/serial.log" "$LIVE_RE" "$timeout"
	sb=$(guest_sh 'od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d0-aa1d-00a0c92dd8a7')
	echo "smoke-qemu.sh: SecureBoot variable: $sb"
	[ "$(echo $sb | awk '{print $NF}')" = 1 ] || {
		echo "smoke-qemu.sh: live system did not boot with Secure Boot on" >&2
		exit 1
	}
	sleep 20
	screenshot
	;;
install-gui)
	# Install through the graphical installer: boot the live desktop with
	# an empty disk, start gui-install (the OpenSolaris installer) in its
	# test mode (it fills in its own screens and presses Install), then
	# boot the installed disk and wait for the login screen.
	qemu-img create -f qcow2 "$tmp/disk.qcow2" 20G >/dev/null
	uefi=$(uefi_args)
	# shellcheck disable=SC2086
	qemu_boot "$tmp/serial.log" $uefi $(cdrom_args) \
	    -drive "file=$tmp/disk.qcow2,if=virtio,format=qcow2"
	wait_for "$tmp/serial.log" "$LIVE_RE" "$timeout"
	env='runuser -u liveuser -- env DISPLAY=:0 XAUTHORITY=/home/liveuser/.Xauthority XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus'
	guest_sh "$env VOLTOS_INSTALLER_TEST=/dev/vda setsid gui-install >/tmp/installer-gui.log 2>&1 &"
	sleep 30
	screenshot progress
	i=0 result=
	while [ "$i" -lt "$timeout" ]; do
		result=$(guest_sh 'cat /tmp/voltos-installer-test.result 2>/dev/null')
		[ -n "$result" ] && break
		sleep 10
		i=$((i + 10))
	done
	echo "smoke-qemu.sh: graphical installer result: ${result:-none}"
	screenshot done
	case "$result" in
	ok*) ;;
	*)
		guest_sh 'cat /tmp/installer-gui.log /tmp/gui-install.log; tail -n 40 /var/log/voltos-install.log'
		exit 1
		;;
	esac
	guest_sh 'systemctl poweroff' >/dev/null
	wait_qemu_exit 900

	# The installed system: firmware -> ZFSBootMenu -> LightDM.
	# shellcheck disable=SC2086
	qemu_boot "$tmp/boot.log" $uefi \
	    -drive "file=$tmp/disk.qcow2,if=virtio,format=qcow2"
	wait_greeter "$timeout"
	sleep 10
	screenshot
	;;
install)
	# Boot the ISO's kernel directly so the unattended-install option can
	# be added to its command line; OVMF still provides a real UEFI
	# environment for efibootmgr and ZFSBootMenu.
	command -v bsdtar >/dev/null || { echo "bsdtar required" >&2; exit 1; }
	bsdtar -xf "$iso" -C "$tmp" "voltos/boot/$arch/vmlinuz-linux-lts" \
	    "voltos/boot/$arch/initramfs-linux-lts.img"
	label=$(blkid -o value -s LABEL "$iso" 2>/dev/null || isoinfo -d -i "$iso" | sed -n 's/^Volume id: //p')
	qemu-img create -f qcow2 "$tmp/disk.qcow2" 20G >/dev/null
	uefi=$(uefi_args)
	# shellcheck disable=SC2086
	qemu_boot "$tmp/install.log" $uefi $(cdrom_args) \
	    -drive "file=$tmp/disk.qcow2,if=virtio,format=qcow2" \
	    -kernel "$tmp/voltos/boot/$arch/vmlinuz-linux-lts" \
	    -initrd "$tmp/voltos/boot/$arch/initramfs-linux-lts.img" \
	    -append "archisobasedir=voltos archisolabel=$label console=$console voltos.autoinstall=/dev/vda voltos.autoinstall.reboot=poweroff voltos.autoinstall.serial=1"
	wait_for "$tmp/install.log" 'VOLTOS_AUTOINSTALL_(OK|FAILED)' "$timeout"
	if grep -aq VOLTOS_AUTOINSTALL_FAILED "$tmp/install.log"; then
		tail -n 60 "$tmp/install.log" >&2
		exit 1
	fi
	wait_qemu_exit 900

	# Second boot: firmware -> ZFSBootMenu -> zroot/ROOT/voltos -> LightDM.
	# shellcheck disable=SC2086
	qemu_boot "$tmp/boot.log" $uefi \
	    -drive "file=$tmp/disk.qcow2,if=virtio,format=qcow2"
	wait_for "$tmp/boot.log" "$INSTALLED_RE" "$timeout"
	wait_greeter "$timeout"
	sleep 10
	screenshot
	check_doas
	[ -z "${SMOKE_REPO:-}" ] || check_updates "$SMOKE_REPO"

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
		wait_qemu_exit 900
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
