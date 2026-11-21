#!/bin/sh
# Post-build fixups for the AESD Pi 5 gateway rootfs. Buildroot passes the target directory as $1.
#
# This script was partially generated using Claude Code using the chat sessions at:
# Link to chat session (issue #1): https://claude.ai/code/cshk_01CSAPnyaYmJc1hcbrUg8bScPJ4y3B8gaWrv83AucuEYdA
# Link to chat session (issue #4): https://claude.ai/code/cshk_01CSAPnz8sDPokK7N8rieHo1BXzy3XPsziDucST29D43Kh
# Link to chat session (issue #14): https://claude.ai/code/cshk_01CSAPnw8JdnxyUhwWGJBPcSLfcF3QEhzhBNyWzKEnnQbG

set -u
set -e

TARGET_DIR="$1"

# Read-only root filesystem (issue #14). The kernel mounts / read-only, and with
# BR2_TARGET_GENERIC_REMOUNT_ROOTFS_RW off, inittab no longer remounts it read-write. The fstab
# line for / is only documentation (noauto), so make it say what is true.
sed -i 's|^/dev/root\([[:space:]]\+\)/\([[:space:]]\+\)ext2\([[:space:]]\+\)rw,noauto|/dev/root\1/\2ext4\3ro,noauto|' \
	"${TARGET_DIR}/etc/fstab"

# Mount the FAT boot partition on /boot, so first-boot files (wpa_supplicant.conf) can be read from
# it. Read-only: FAT has no journal, so it is only written while S35provision moves files off it
# (remount rw, then ro again). An entry from an older build with "defaults" is replaced.
mkdir -p "${TARGET_DIR}/boot"
sed -i '\|^/dev/mmcblk0p1[[:space:]]|d' "${TARGET_DIR}/etc/fstab"
echo '/dev/mmcblk0p1	/boot		vfat	ro,noatime	0	0' >> "${TARGET_DIR}/etc/fstab"

# The writable data partition (issue #14). S00datafs checks and mounts it, with a tmpfs as the
# fallback; this line is noauto, so "mount -a" leaves it alone, and it lets "mount /data" work by hand.
mkdir -p "${TARGET_DIR}/data"
grep -q '^/dev/mmcblk0p3' "${TARGET_DIR}/etc/fstab" || \
	echo '/dev/mmcblk0p3	/data		ext4	noauto,noatime	0	0' >> "${TARGET_DIR}/etc/fstab"
# /data is a mount point: anything under it in the image would be hidden by the mount.
find "${TARGET_DIR}/data" -mindepth 1 -delete

# What has to persist moves to /data, through relative symlinks: a relative link resolves inside
# TARGET_DIR on the build host too, so a package that installs through one cannot write to the
# host's own /data. A directory left by an older build is removed first.
#   /etc/station            Basics Station's home: the credentials and the -bak/.done files
#                           Station writes when CUPS updates them. station.conf and version.txt
#                           are in /usr/share/basicstation; S00datafs links them into /data/station.
#   /etc/gateway-provision  the first-boot provisioning secret (issue #10)
#   /etc/dropbear           the SSH host key, generated at the first boot (Buildroot's dropbear
#                           package links it to /var/run/dropbear, a new key at every boot)
#   /etc/gwmon-health       gwmon-publish.sh's AWS IoT certificate, key and endpoint (issue #13)
#   /etc/aws-iot-device-client  the tunnel client's certificate, key, endpoint, thing (issue #15)
for d in station gateway-provision dropbear gwmon-health aws-iot-device-client; do
	if [ -d "${TARGET_DIR}/etc/${d}" ] && [ ! -L "${TARGET_DIR}/etc/${d}" ]; then
		rm -rf "${TARGET_DIR}/etc/${d}"
	fi
	ln -snf "../data/${d}" "${TARGET_DIR}/etc/${d}"
done

# Git only tracks 644/755, so set the SSH permissions dropbear expects here.
chmod 700 "${TARGET_DIR}/root" "${TARGET_DIR}/root/.ssh"
chmod 600 "${TARGET_DIR}/root/.ssh/authorized_keys"

# Buildroot's wpa_supplicant package installs a default /etc/wpa_supplicant.conf with an open
# "key_mgmt=NONE" network. S41wifi starts Wi-Fi whenever that file exists, so the gateway would
# join any open network. Remove it: the only Wi-Fi configuration is the one S35provision installs
# (in /data/wpa_supplicant.conf since issue #14).
rm -f "${TARGET_DIR}/etc/wpa_supplicant.conf"
