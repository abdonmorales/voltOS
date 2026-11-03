#!/bin/bash
#
# Run a command inside a build root made by alarm-buildroot.sh, with the
# VoltOS checkout mounted at /voltos.
#
#   sudo tools/alarm-chroot.sh /path/to/root 'command ...'
#
set -euo pipefail
root=${1:?root}
shift
top=$(cd "$(dirname "$0")/.." && pwd)

mountpoint -q "$root/proc" || mount -t proc proc "$root/proc"
mountpoint -q "$root/sys" || mount --rbind /sys "$root/sys"
mountpoint -q "$root/dev" || mount --rbind /dev "$root/dev"
mountpoint -q "$root/run" || mount -t tmpfs tmpfs "$root/run"
mkdir -p "$root/voltos"
mountpoint -q "$root/voltos" || mount --bind "$top" "$root/voltos"
rm -f "$root/etc/resolv.conf"
cp -L /etc/resolv.conf "$root/etc/resolv.conf"
# Trust the host's CA bundle as well (e.g. TLS-inspecting proxies).
if [ -n "${ALARM_EXTRA_CA:-}" ]; then
	cp "$ALARM_EXTRA_CA" "$root/etc/ca-certificates/trust-source/anchors/extra-ca.crt"
	chroot "$root" update-ca-trust
fi

exec chroot "$root" /usr/bin/env -i HOME=/root TERM=dumb LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/bin \
    ${HTTPS_PROXY:+HTTPS_PROXY=$HTTPS_PROXY https_proxy=$HTTPS_PROXY} \
    /bin/bash -c "$*"
