#!/bin/bash
# Repack an already built image with Buildroot's stock Raspberry Pi card layout (issue #16).
# Same boot files and rootfs.ext4 as the build; only the layout changes to the one in
# buildroot/board/raspberrypi/genimage.cfg.in: a 32 MB FAT16 boot partition at sector 1,
# bootable flag set, no disk signature. Takes about a minute, no Buildroot rebuild.
#
# Usage: scripts/pi5-bringup/stock-layout-image.sh <buildroot/output> <out-dir>
# Writes <out-dir>/sdcard-stock-layout.img.
#
# This script was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #16): ISSUE16_SESSION_LINK

set -euo pipefail

OUTPUT="$(realpath "$1")"
OUT_DIR="$(mkdir -p "$2" && realpath "$2")"
IMAGES="${OUTPUT}/images"
HOST_BIN="${OUTPUT}/host/bin"
STOCK_CFG="${OUTPUT}/../board/raspberrypi/genimage.cfg.in"

[ -f "${IMAGES}/rootfs.ext4" ] || { echo "no ${IMAGES}/rootfs.ext4: build first" >&2; exit 1; }
[ -f "${STOCK_CFG}" ] || { echo "no ${STOCK_CFG}: is <buildroot/output> inside the Buildroot tree?" >&2; exit 1; }

# The same boot file list as Buildroot's board/raspberrypi/post-image.sh and our post-image.sh.
FILES=()
for i in "${IMAGES}"/*.dtb "${IMAGES}"/rpi-firmware/*; do
	FILES+=( "${i#${IMAGES}/}" )
done
FILES+=( "$(sed -n 's/^kernel=//p' "${IMAGES}/rpi-firmware/config.txt")" )
BOOT_FILES=$(printf '\\t\\t\\t"%s",\\n' "${FILES[@]}")

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
sed "s|#BOOT_FILES#|${BOOT_FILES}|; s|image sdcard.img|image sdcard-stock-layout.img|" \
	"${STOCK_CFG}" > "${WORK}/genimage.cfg"
mkdir "${WORK}/root"

PATH="${HOST_BIN}:${HOST_BIN}/../sbin:${PATH}" genimage \
	--rootpath "${WORK}/root" \
	--tmppath "${WORK}/tmp" \
	--inputpath "${IMAGES}" \
	--outputpath "${WORK}/out" \
	--config "${WORK}/genimage.cfg"

mv "${WORK}/out/sdcard-stock-layout.img" "${OUT_DIR}/"
echo "wrote ${OUT_DIR}/sdcard-stock-layout.img"
