#!/bin/bash
# Save the current buildroot/.config as base_external/configs/aesd_pi5_defconfig.
#
# This script was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #1): __AI_SESSION_LINK__

set -e
cd "$(dirname "$0")"
source ./shared.sh

make -C buildroot BR2_EXTERNAL=${AESD_EXTERNAL_REL_BUILDROOT} savedefconfig \
	BR2_DEFCONFIG=${AESD_EXTERNAL_REL_BUILDROOT}/configs/${AESD_DEFCONFIG_NAME}
