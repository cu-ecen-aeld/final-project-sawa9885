#!/bin/bash
# Build the Raspberry Pi 5 gateway image with Buildroot.
# Output: buildroot/output/images/sdcard.img
#
# This script was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #1): https://claude.ai/code/cshk_01CSAPnyaYmJc1hcbrUg8bScPJ4y3B8gaWrv83AucuEYdA

set -e
cd "$(dirname "$0")"
source ./shared.sh

git submodule init
git submodule sync
git submodule update

if [ ! -e buildroot/.config ]
then
	echo "No buildroot/.config yet, loading ${AESD_MODIFIED_DEFCONFIG}"
	make -C buildroot BR2_EXTERNAL=${AESD_EXTERNAL_REL_BUILDROOT} ${AESD_DEFCONFIG_NAME}
else
	echo "Using the existing buildroot/.config"
	echo "Run ./save_config.sh after menuconfig changes, or delete buildroot/.config to reload the defconfig."
fi

make -C buildroot BR2_EXTERNAL=${AESD_EXTERNAL_REL_BUILDROOT}

echo "Image: buildroot/output/images/sdcard.img"
