#!/bin/sh
# Post-build fixups for the AESD Pi 5 gateway rootfs. Buildroot passes the target directory as $1.
#
# This script was partially generated using Claude Code using the chat sessions at:
# Link to chat session (issue #1): https://claude.ai/code/cshk_01CSAPnyaYmJc1hcbrUg8bScPJ4y3B8gaWrv83AucuEYdA
# Link to chat session (issue #4): TODO(issue-4-session-link)

set -u
set -e

TARGET_DIR="$1"

# Mount the FAT boot partition on /boot, so first-boot files (wpa_supplicant.conf) can be read from it.
mkdir -p "${TARGET_DIR}/boot"
grep -q '^/dev/mmcblk0p1' "${TARGET_DIR}/etc/fstab" || \
	echo '/dev/mmcblk0p1	/boot		vfat	defaults,noatime	0	0' >> "${TARGET_DIR}/etc/fstab"

# Git only tracks 644/755, so set the SSH permissions dropbear expects here.
chmod 700 "${TARGET_DIR}/root" "${TARGET_DIR}/root/.ssh"
chmod 600 "${TARGET_DIR}/root/.ssh/authorized_keys"

# Buildroot's wpa_supplicant package installs a default /etc/wpa_supplicant.conf with an open
# "key_mgmt=NONE" network. S41wifi starts Wi-Fi whenever that file exists, so the gateway would
# join any open network. Remove it: the only Wi-Fi configuration is the one S35provision installs.
rm -f "${TARGET_DIR}/etc/wpa_supplicant.conf"
