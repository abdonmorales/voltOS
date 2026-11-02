#
# VoltOS build entry points.
#
# On Arch Linux (as root, or with sudo):
#   make packages      build every package into out/repo
#   make iso           build out/voltos-*.iso (needs root)
#   make smoke         boot the ISO in QEMU (UEFI live desktop)
#   make smoke-install unattended ZFS install + boot via ZFSBootMenu
#
# On any Linux host with Docker:
#   make docker-iso    run packages + iso inside a privileged archlinux container
#

ISO = $(lastword $(sort $(wildcard out/voltos-*-x86_64.iso)))

.PHONY: packages iso smoke smoke-bios smoke-install docker-iso clean

packages:
	tools/build-packages.sh

iso: packages
	tools/build-iso.sh

smoke:
	tools/smoke-qemu.sh live-uefi $(ISO)

smoke-bios:
	tools/smoke-qemu.sh live-bios $(ISO)

smoke-install:
	tools/smoke-qemu.sh install $(ISO)

docker-iso:
	docker run --rm --privileged -v "$(CURDIR)":/voltos -w /voltos \
	    archlinux:latest bash -c \
	    'tools/install-build-deps.sh && tools/build-packages.sh && tools/build-iso.sh'

clean:
	rm -rf out work
