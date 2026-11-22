#!/bin/bash
#
# Boot the VoltOS ISO in QEMU and check that it reaches the graphical
# MATE live session.  Optionally run the unattended installer and boot
# the installed system through ZFSBootMenu.
#
# The architecture follows the ISO's name (voltos-*-aarch64.iso: AArch64,
# QEMU's "virt" machine with AAVMF; otherwise x86_64) or SMOKE_ARCH.  On
# AArch64 only the UEFI modes (live-uefi, live-secureboot, install-gui,
# install) exist.
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
# a firmware-only framebuffer),
# SMOKE_GNOME2=1 (install and install-gui, with SMOKE_REPO: choose the
# GNOME 2.32 desktop in the installer, which downloads it from that
# repository; install then logs in to it, and restarts and powers off the
# machine from its shutdown dialog),
# SMOKE_EXTRAS=science,engineering (install, with SMOKE_REPO: also choose
# those tools in the installer, and check that they work),
# SMOKE_UPGRADE=1 (install, with SMOKE_REPO and an earlier release's ISO:
# then update the installed system with pacman -Syu, VoltOS's packages from
# SMOKE_REPO, and check that it boots again; SMOKE_UPGRADE_WAIT: seconds the
# update may take, default 2400).
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
	# Secure Boot capable (Debian/Ubuntu); with the empty variable store
	# above it starts in Setup Mode.
	for c in /usr/share/AAVMF/AAVMF_CODE.secboot.fd /usr/share/edk2/aarch64/QEMU_CODE.secboot.fd; do
		[ -f "$c" ] && { ovmf_secboot=$c; break; }
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

# serve_repo <repo dir>: serve the repository to the guest at
# http://10.0.2.2:8089 (QEMU's user network) until stop_repo, standing in
# for the published [voltos] repository.
serve_repo()
{
	python3 -m http.server 8089 --bind 127.0.0.1 --directory "$1" \
	    >"$tmp/http-install.log" 2>&1 &
	repo_http=$!
	pids+=("$repo_http")
	sleep 2
}

stop_repo()
{
	[ -z "${repo_http:-}" ] || kill "$repo_http" 2>/dev/null || true
	repo_http=
}

# check_printing: printing and Bluetooth are set up on the installed system:
# CUPS (started by its socket), Avahi and BlueZ enabled, CUPS answers, and
# Gutenprint's drivers are there.
check_printing()
{
	local out
	out=$(guest_sh '
		systemctl is-enabled cups.socket avahi-daemon.socket bluetooth.service | tr "\n" " "; echo
		lpstat -r
		lpinfo -m 2>/dev/null | grep -q gutenprint && echo gutenprint-drivers
		command -v system-config-printer >/dev/null && echo print-settings
		command -v blueman-manager >/dev/null && echo blueman')
	printf 'smoke-qemu.sh: printing and Bluetooth: %s\n' "$(echo $out)"
	[ "$(echo $out)" = "enabled enabled enabled scheduler is running gutenprint-drivers print-settings blueman" ] || {
		echo "smoke-qemu.sh: printing or Bluetooth is not set up on the installed system" >&2
		exit 1
	}
}

# check_extras <list>: the science and engineering tools the installer
# installed (SMOKE_EXTRAS) work: an LC-3 program assembles and runs, Octave,
# Python's SciPy stack, R, Verilog, the Arm toolchain; and the MATLAB and
# Vivado installers are there with what they need.
check_extras()
{
	local out want=
	out=$(SMOKE_GUEST_WAIT=300 guest_sh '
		cd /tmp
		if pacman -Q voltos-science >/dev/null 2>&1; then
			octave-cli --eval "disp(6*7)" 2>/dev/null | grep -qx 42 && echo octave
			python -c "import numpy, scipy, matplotlib, pandas, sympy, sklearn, jupyterlab" && echo python
			Rscript -e "cat(6*7)" 2>/dev/null | grep -qx 42 && echo r
			[ "$(uname -m)" != x86_64 ] || { voltos-matlab-install --help | grep -q mpm && echo matlab-installer; }
		fi
		if pacman -Q voltos-engineering >/dev/null 2>&1; then
			printf ".ORIG x3000\nLEA R0, MSG\nPUTS\nHALT\nMSG .STRINGZ \"LC3 OK\"\n.END\n" >t.asm
			lc3-assembler t.asm >/dev/null && printf "run\nquit\n" |
			    timeout 30 lc3-simulator t.obj | grep -q "LC3 OK" && echo lc3
			printf "module t; initial begin \$display(\"verilog ok\"); \$finish; end endmodule\n" >t.v
			iverilog -o t.vvp t.v && vvp t.vvp | grep -q "verilog ok" && echo verilog
			if [ "$(uname -m)" = x86_64 ]; then
				[ -x /usr/bin/lc3tools ] && echo lc3tools-gui
				printf "int main(void){return 0;}\n" >t.c
				arm-none-eabi-gcc -mcpu=cortex-m4 -mthumb --specs=nosys.specs t.c -o t.elf && echo arm-gcc
				ldconfig -p | grep -q "libtinfo.so.5 " && echo libtinfo5
				udevadm verify /usr/lib/udev/rules.d/70-voltos-fpga-cables.rules >/dev/null 2>&1 && echo cable-rules
			fi
		fi')
	printf 'smoke-qemu.sh: tools: %s\n' "$(echo $out)"
	case ",$1," in
	*,science,*)
		want="octave python r"
		[ "$arch" != x86_64 ] || want="$want matlab-installer" ;;
	esac
	case ",$1," in
	*,engineering,*)
		want="$want lc3 verilog"
		[ "$arch" != x86_64 ] || want="$want lc3tools-gui arm-gcc libtinfo5 cable-rules" ;;
	esac
	[ "$(echo $out)" = "$(echo $want)" ] || {
		echo "smoke-qemu.sh: the installed tools do not work (want: $(echo $want))" >&2
		guest_sh 'grep -E "error|warning" /var/log/voltos-install.log | tail -n 20' >&2
		exit 1
	}
}

# check_doas: administrators use doas, not sudo: voltos-doas installed,
# sudo gone, doas.conf valid, granting wheel but not the live user.
check_doas()
{
	local out
	out=$(guest_sh '
		pacman -Q voltos-doas >/dev/null && echo has-voltos-doas
		# By name: pacman -Q sudo would find voltos-doas, which provides sudo.
		pacman -Qq | grep -qx sudo || echo no-sudo
		doas -C /etc/doas.conf && echo conf-valid
		grep -qx "permit persist setenv { EDITOR VISUAL } :wheel" /etc/doas.conf && echo wheel-rule
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

# gnome2_session: wait for volt's GNOME 2.32 session (LightDM autologin),
# and set g2env to the environment its programs need (display, X
# authority, session bus), taken from gnome-session itself.
gnome2_session()
{
	local i=0 pid
	while [ "$i" -lt 300 ]; do
		pid=$(guest_sh 'pgrep -u volt -x gnome-session | head -n 1')
		if [ -n "$pid" ] && [ -n "$(guest_sh 'pgrep -u volt -x gnome-panel')" ]; then
			g2env=$(guest_sh "tr '\\0' '\\n' </proc/$pid/environ | grep -E '^(DISPLAY|XAUTHORITY|DBUS_SESSION_BUS_ADDRESS|XDG_CURRENT_DESKTOP|XDG_DATA_DIRS|XDG_CONFIG_DIRS)=' | tr '\\n' ' '")
			echo "smoke-qemu.sh: GNOME 2.32 session up: $g2env"
			return 0
		fi
		sleep 5
		i=$((i + 5))
	done
	echo "smoke-qemu.sh: no GNOME 2.32 session" >&2
	guest_sh 'journalctl -b -u lightdm --no-pager | tail -n 40; tail -n 40 /home/volt/.xsession-errors' >&2
	return 1
}

# gnome2_shutdown_dialog: ask volt's session manager for its shutdown
# dialog (the panel's System > Shut Down; Shutdown is gnome-session's D-Bus
# method for it), and screenshot it.
gnome2_shutdown_dialog()
{
	guest_sh "runuser -u volt -- env $g2env dbus-send --session --type=method_call --dest=org.gnome.SessionManager /org/gnome/SessionManager org.gnome.SessionManager.Shutdown" >/dev/null
	sleep 10
	screenshot "$1"
}

# check_gnome2_installed: the installer installed the GNOME 2.32 desktop
# (DESKTOP=gnome2) in place of GNOME Flashback and made it LightDM's
# default session.
check_gnome2_installed()
{
	local out
	out=$(guest_sh '
		pacman -Q voltos-gnome2 >/dev/null && echo voltos-gnome2
		pacman -Q gnome-flashback >/dev/null 2>&1 || echo no-flashback
		grep -qx user-session=gnome2 /etc/lightdm/lightdm.conf.d/60-voltos-desktop.conf && echo default-session')
	printf 'smoke-qemu.sh: GNOME 2 installation: %s\n' "$(echo $out)"
	[ "$(echo $out)" = "voltos-gnome2 no-flashback default-session" ] || {
		echo "smoke-qemu.sh: the installer did not install GNOME 2.32 as the desktop" >&2
		guest_sh 'grep -B2 -A20 "Installing voltos-gnome2" /var/log/voltos-install.log | tail -n 40' >&2
		exit 1
	}
}

# check_gnome2: log volt in to the GNOME 2.32 desktop the installer installed
# (LightDM's default session: autologin names no session), check its
# defaults, and restart and power off from its shutdown dialog:
# gnome-session asks systemd-logind (VoltOS's patch; GNOME 2 used
# ConsoleKit).  The machine must restart, then power off.
check_gnome2()
{
	local out log
	check_gnome2_installed
	out=$(SMOKE_GUEST_WAIT=600 guest_sh '
		pacman -S --noconfirm --needed xdotool >/tmp/xdotool.log 2>&1
		echo "rc=$?"')
	printf '%s\n' "$out" | grep -q '^rc=0$' || {
		echo "smoke-qemu.sh: installing xdotool failed" >&2
		guest_sh 'tail -n 20 /tmp/xdotool.log' >&2
		exit 1
	}
	guest_sh '
		groupadd -rf autologin
		gpasswd -a volt autologin >/dev/null
		mkdir -p /etc/lightdm/lightdm.conf.d
		printf "[Seat:*]\nautologin-user=volt\n" >/etc/lightdm/lightdm.conf.d/99-smoke-gnome2.conf
		systemctl restart lightdm' >/dev/null
	gnome2_session || exit 1
	sleep 20
	screenshot gnome2

	# GNOME 2's applications are the session's defaults (gnome2-session):
	# Nautilus, gedit, Evince, Eye of GNOME and File Roller open their
	# files, MATE's Pluma and terminal are not in the menus,
	# NetworkManager's applet runs in the panel, and so do GNOME 2's volume
	# control, power manager and screensaver, which answers the panel's
	# Lock Screen (gnome-screensaver-command).
	out=$(guest_sh "runuser -u volt -- env $g2env sh -c '
		echo desktop=\$XDG_CURRENT_DESKTOP
		for t in inode/directory text/plain application/pdf image/png application/zip; do
			gio mime \$t | head -n 1 | sed \"s|.*: |\$t=|\"
		done
		grep -qx Hidden=true /usr/share/voltos-gnome2/applications/pluma.desktop && echo pluma-hidden
		[ \"\$(readlink -e /usr/share/icons/nimbus/24x24/places/start-here.png)\" = /usr/share/icons/hicolor/24x24/apps/voltos-logo.png ] && echo menu-logo
		grep -qx Hidden=true /usr/share/voltos-gnome2/applications/mate-terminal.desktop && echo mate-terminal-hidden
		pgrep -u volt -x nm-applet >/dev/null && echo nm-applet
		[ -e /usr/lib/gedit-2/plugins/libspell.so ] && enchant-lsmod-2 -list-dicts | grep -q "^en_US" && echo spell-checker
		n=\$(pgrep -u volt -x nautilus | head -n 1)
		grep -q libnautilus-fileroller.so /proc/\$n/maps && echo fileroller-extension
		grep -q libevince-properties-page.so /proc/\$n/maps && echo evince-extension
		for d in gnome-volume-control-applet gnome-power-manager gnome-screensaver; do
			pgrep -u volt -f \"^(/usr/bin/)?\$d\" >/dev/null && echo \$d
		done
		pgrep -u volt -f blueman-applet >/dev/null && echo blueman-applet
		pgrep -u volt -f system-config-printer-applet >/dev/null && echo print-applet
		gnome-screensaver-command --query >/dev/null 2>&1 && echo lock-command'")
	printf '%s\n' "$out" | sed 's/^/smoke-qemu.sh: GNOME 2 defaults: /'
	case $(echo $out) in
	"desktop=GNOME2:GNOME inode/directory=nautilus-folder-handler.desktop text/plain=gedit.desktop application/pdf=evince.desktop image/png=eog.desktop application/zip=file-roller.desktop pluma-hidden menu-logo mate-terminal-hidden nm-applet spell-checker fileroller-extension evince-extension gnome-volume-control-applet gnome-power-manager gnome-screensaver blueman-applet print-applet lock-command") ;;
	*)
		echo "smoke-qemu.sh: GNOME 2's applications are not the session's defaults" >&2
		exit 1
		;;
	esac
	# gedit 2 and Eye of GNOME 2, opened as from Nautilus.
	guest_sh "runuser -u volt -- env $g2env sh -c 'gio open /usr/lib/os-release; gio open /usr/share/pixmaps/voltos-logo.svg' >/dev/null 2>&1 &" >/dev/null
	sleep 15
	screenshot gnome2-apps
	guest_sh 'pkill -u volt -x gedit; pkill -u volt -x eog' >/dev/null
	sleep 2

	# Restart: the dialog's Restart button.
	gnome2_shutdown_dialog gnome2-shutdown-dialog
	guest_sh "runuser -u volt -- env $g2env xdotool key alt+r" >/dev/null
	wait_qemu_exit 300
	grep -aq 'reboot: Restarting system' "$tmp/boot.log" || {
		echo "smoke-qemu.sh: GNOME 2.32's Restart did not restart the machine" >&2
		tail -n 60 "$tmp/boot.log" >&2
		exit 1
	}
	echo "smoke-qemu.sh: GNOME 2.32 restarted the machine"

	# Power off: the dialog's own timeout (60 s), whose action is Shut Down.
	log=$tmp/boot-gnome2.log
	# shellcheck disable=SC2086
	qemu_boot "$log" $uefi -drive "file=$tmp/disk.qcow2,if=virtio,format=qcow2"
	wait_for "$log" "$INSTALLED_RE" "$timeout"
	gnome2_session || exit 1
	sleep 20
	gnome2_shutdown_dialog gnome2-shutdown-timeout
	wait_qemu_exit 300
	grep -aq 'reboot: Power down' "$log" || {
		echo "smoke-qemu.sh: GNOME 2.32's Shut Down did not power the machine off" >&2
		tail -n 60 "$log" >&2
		exit 1
	}
	echo "smoke-qemu.sh: GNOME 2.32 powered the machine off"
}

# check_upgrade <repo dir>: upgrade the installed system (installed from an
# earlier release's ISO) with pacman -Syu, VoltOS's packages from <repo dir>
# and Arch's from its mirrors, as a user would; then check that the ZFS
# module was built for every kernel, that VoltOS's packages are the new
# ones, and that the system boots to the login screen again.
check_upgrade()
{
	local http out pkg want have
	python3 -m http.server 8089 --bind 127.0.0.1 --directory "$1" \
	    >"$tmp/http-upgrade.log" 2>&1 &
	http=$!
	sleep 2
	out=$(SMOKE_GUEST_WAIT=${SMOKE_UPGRADE_WAIT:-2400} guest_sh '
		. /usr/lib/os-release; echo "from=${VERSION_ID:-0.1.0}"
		sed -i "/^\[voltos\]/,/^Server/ s|^Server = .*|Server = http://10.0.2.2:8089|" /etc/pacman.conf
		pacman -Syu --noconfirm >/tmp/upgrade.log 2>&1
		echo "rc=$?"
		tail -n 5 /tmp/upgrade.log
		for m in /usr/lib/modules/*/vmlinuz; do
			d=${m%/vmlinuz}
			if find "$d" -name "zfs.ko*" | grep -q .; then
				echo "zfs-module ${d##*/}"
			else
				echo "no-zfs-module ${d##*/}"
			fi
		done
		pacman -Q voltos-branding voltos-installer zfs-dkms linux-lts
		echo "services $(systemctl is-enabled cups.socket bluetooth.service | tr "\n" " ")"')
	kill "$http" 2>/dev/null || true
	printf '%s\n' "$out"
	printf '%s\n' "$out" | grep -q '^rc=0$' || {
		echo "smoke-qemu.sh: pacman -Syu failed on the installed system" >&2
		guest_sh 'tail -n 60 /tmp/upgrade.log' >&2
		exit 1
	}
	if printf '%s\n' "$out" | grep -q '^no-zfs-module'; then
		echo "smoke-qemu.sh: a kernel has no ZFS module after the upgrade" >&2
		guest_sh 'dkms status; grep -i -A5 dkms /tmp/upgrade.log | tail -n 40' >&2
		exit 1
	fi
	# Printing and Bluetooth come with the update (voltos-desktop).
	printf '%s\n' "$out" | grep -q '^services enabled enabled $' || {
		echo "smoke-qemu.sh: the update did not enable printing and Bluetooth" >&2
		exit 1
	}
	for pkg in voltos-branding voltos-installer; do
		want=$(cd "$1" && ls "$pkg"-[0-9]*.pkg.tar.zst | sort -V | tail -n 1 |
		    sed "s/^$pkg-//; s/-[^-]*\.pkg\.tar\.zst$//")
		have=$(printf '%s\n' "$out" | sed -n "s/^$pkg //p")
		[ "$have" = "$want" ] || {
			echo "smoke-qemu.sh: $pkg is $have after the upgrade, not $want" >&2
			exit 1
		}
	done

	# The upgraded system boots: firmware -> ZFSBootMenu -> LightDM.
	guest_sh 'systemctl poweroff' >/dev/null
	wait_qemu_exit 900
	# shellcheck disable=SC2086
	qemu_boot "$tmp/upgraded.log" $uefi \
	    -drive "file=$tmp/disk.qcow2,if=virtio,format=qcow2"
	wait_for "$tmp/upgraded.log" "$INSTALLED_RE" "$timeout"
	wait_greeter "$timeout"
	sleep 10
	screenshot upgraded
	out=$(guest_sh '. /usr/lib/os-release; echo "$PRETTY_NAME"; uname -r')
	printf '%s\n' "$out" | sed 's/^/smoke-qemu.sh: upgraded system: /'
}

uefi_args()
{
	[ -n "$ovmf_code" ] || { echo "OVMF not found (install edk2-ovmf)" >&2; exit 1; }
	cp "$ovmf_vars" "$tmp/vars.fd"
	if [ "${SMOKE_SECBOOT:-0}" = 1 ]; then
		# Secure Boot capable firmware, no keys enrolled (Setup Mode).
		# The variable store must be SMM-protected for it to work.
		[ -n "$ovmf_secboot" ] || { echo "secure boot OVMF not found" >&2; exit 1; }
		if [ "$arch" = aarch64 ]; then
			# virt keeps the variables in its second flash device;
			# there is no SMM to protect them.
			echo "-drive if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_secboot" \
			     "-drive if=pflash,format=raw,unit=1,file=$tmp/vars.fd"
			return
		fi
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
aarch64:live-bios)
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
	if [ "$arch" = aarch64 ]; then
		# Both of virt's flash devices the same size (see below).
		truncate -s "$(stat -L -c %s "$ovmf_secboot")" "$tmp/sbvars.fd"
		# shellcheck disable=SC2046
		qemu_boot "$tmp/serial.log" \
		    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_secboot" \
		    -drive "if=pflash,format=raw,unit=1,file=$tmp/sbvars.fd" \
		    $(cdrom_args)
	else
		qemu_boot "$tmp/serial.log" -machine smm=on \
		    -global driver=cfi.pflash01,property=secure,value=on \
		    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_secboot" \
		    -drive "if=pflash,format=raw,unit=1,file=$tmp/sbvars.fd" \
		    -cdrom "$iso"
	fi
	wait_for "$tmp/serial.log" "$LIVE_RE" "$timeout"
	# Secure Boot as the booted system sees it: the firmware's SecureBoot
	# variable, and the kernel's own report (its log), through the guest
	# agent, which can still be starting when the desktop reports ready.
	info=
	for _ in 1 2 3 4 5 6; do
		info=$(guest_sh '
			echo "efivar: $(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>&1)"
			ls -d /sys/firmware/efi /sys/firmware/efi/efivars 2>&1 | sed "s/^/sysfs: /"
			findmnt -n -o FSTYPE,TARGET -t efivarfs | sed "s/^/mount: /"
			dmesg | grep -i -E "secure ?boot|lockdown|efi: " | head -n 20 | sed "s/^/kernel: /"')
		[ -n "$info" ] && break
		sleep 10
	done
	printf '%s\n' "$info" | sed 's/^/smoke-qemu.sh: /'
	if printf '%s\n' "$info" | grep -q '^efivar: .* 1$'; then
		echo "smoke-qemu.sh: the firmware reports Secure Boot on"
	elif printf '%s\n' "$info" | grep -qi '^kernel: .*secure boot enabled'; then
		echo "smoke-qemu.sh: the kernel reports Secure Boot on"
	elif grep -aq 'UEFI Secure Boot is enabled' "$tmp/serial.log"; then
		# The kernel's EFI stub (AArch64) says so on the firmware console.
		echo "smoke-qemu.sh: the kernel's EFI stub reports Secure Boot on"
	else
		echo "smoke-qemu.sh: live system did not boot with Secure Boot on" >&2
		exit 1
	fi
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
	# The account screen waits 20 s (VOLTOS_INSTALLER_TEST_HOLD) for its
	# screenshot.  With SMOKE_GNOME2 and SMOKE_REPO, it chooses GNOME 2.32,
	# which the installer downloads from SMOKE_REPO.
	sw=
	if [ "${SMOKE_GNOME2:-0}" = 1 ] && [ -n "${SMOKE_REPO:-}" ]; then
		serve_repo "$SMOKE_REPO"
		sw="VOLTOS_INSTALLER_TEST_SOFTWARE=gnome2 VOLTOS_INSTALLER_TEST_SERVER=http://10.0.2.2:8089"
	fi
	guest_sh "$env VOLTOS_INSTALLER_TEST=/dev/vda VOLTOS_INSTALLER_TEST_HOLD=20 $sw setsid gui-install >/tmp/installer-gui.log 2>&1 &"
	i=0
	while [ "$i" -lt 600 ] && [ -z "$(guest_sh 'cat /tmp/voltos-installer-test.screen 2>/dev/null')" ]; do
		sleep 2
		i=$((i + 2))
	done
	sleep 3
	screenshot account
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
	stop_repo
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
	[ -z "$sw" ] || check_gnome2_installed
	;;
install)
	# Boot the ISO's kernel directly so the unattended-install option can
	# be added to its command line; OVMF still provides a real UEFI
	# environment for efibootmgr and ZFSBootMenu.
	command -v bsdtar >/dev/null || { echo "bsdtar required" >&2; exit 1; }
	bsdtar -xf "$iso" -C "$tmp" "voltos/boot/$arch/vmlinuz-linux-lts" \
	    "voltos/boot/$arch/initramfs-linux-lts.img"
	label=$(blkid -o value -s LABEL "$iso" 2>/dev/null || isoinfo -d -i "$iso" | sed -n 's/^Volume id: //p')
	qemu-img create -f qcow2 "$tmp/disk.qcow2" 30G >/dev/null
	uefi=$(uefi_args)
	# The software chosen at installation (SMOKE_GNOME2, SMOKE_EXTRAS),
	# downloaded from SMOKE_REPO.
	choices=
	if [ -n "${SMOKE_REPO:-}" ] && { [ "${SMOKE_GNOME2:-0}" = 1 ] || [ -n "${SMOKE_EXTRAS:-}" ]; }; then
		serve_repo "$SMOKE_REPO"
		choices="voltos.autoinstall.server=http://10.0.2.2:8089"
		[ "${SMOKE_GNOME2:-0}" != 1 ] || choices="$choices voltos.autoinstall.desktop=gnome2"
		[ -z "${SMOKE_EXTRAS:-}" ] || choices="$choices voltos.autoinstall.extras=$SMOKE_EXTRAS"
	fi
	# shellcheck disable=SC2086
	qemu_boot "$tmp/install.log" $uefi $(cdrom_args) \
	    -drive "file=$tmp/disk.qcow2,if=virtio,format=qcow2" \
	    -kernel "$tmp/voltos/boot/$arch/vmlinuz-linux-lts" \
	    -initrd "$tmp/voltos/boot/$arch/initramfs-linux-lts.img" \
	    -append "archisobasedir=voltos archisolabel=$label console=$console voltos.autoinstall=/dev/vda voltos.autoinstall.reboot=poweroff voltos.autoinstall.serial=1 $choices"
	wait_for "$tmp/install.log" 'VOLTOS_AUTOINSTALL_(OK|FAILED)' "$timeout"
	stop_repo
	# Software the installer could not download is not fatal to it, but
	# is to the test.
	if grep -a '\[voltos-install\] Not installed:' "$tmp/install.log" >&2; then
		echo "smoke-qemu.sh: the installer could not install the chosen software" >&2
		exit 1
	fi
	if grep -aq VOLTOS_AUTOINSTALL_FAILED "$tmp/install.log"; then
		tail -n 60 "$tmp/install.log" >&2
		exit 1
	fi
	# Processes the installer had to stop to release the pool (none, as a
	# rule): reported, to find what starts them.
	grep -a 'Stopping a process left in the target' "$tmp/install.log" |
	    sed 's/^.*\[voltos-install\] /smoke-qemu.sh: installer: /' >&2 || :
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
	# The installer leaves its log on the installed system (since 0.2.0;
	# not when SMOKE_UPGRADE installs an earlier release).
	[ "${SMOKE_UPGRADE:-0}" = 1 ] ||
	[ "$(guest_sh 'grep -c "\[voltos-install\] Finishing" /var/log/voltos-install.log')" = 1 ] || {
		echo "smoke-qemu.sh: no installation log in /var/log/voltos-install.log" >&2
		exit 1
	}
	[ "${SMOKE_UPGRADE:-0}" = 1 ] || check_printing
	[ -z "${SMOKE_REPO:-}" ] || [ -z "${SMOKE_EXTRAS:-}" ] || check_extras "$SMOKE_EXTRAS"
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

	# SMOKE_UPGRADE=1 (needs SMOKE_REPO; <iso> is an earlier release):
	# update the installed system to SMOKE_REPO's packages and boot it.
	if [ "${SMOKE_UPGRADE:-0}" = 1 ] && [ -n "${SMOKE_REPO:-}" ]; then
		check_upgrade "$SMOKE_REPO"
	fi

	# SMOKE_GNOME2=1 (needs SMOKE_REPO): the GNOME 2.32 desktop on the
	# installed system; ends with the machine powered off.
	if [ "${SMOKE_GNOME2:-0}" = 1 ] && [ -n "${SMOKE_REPO:-}" ]; then
		check_gnome2
	fi
	;;
*)
	echo "unknown mode $mode" >&2
	exit 2
	;;
esac
echo "smoke-qemu.sh: $mode OK"
