#!/bin/sh
# Shared definitions for build.sh, save_config.sh and clean.sh.
#
# This script was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #1): https://claude.ai/code/cshk_01CSAPnyaYmJc1hcbrUg8bScPJ4y3B8gaWrv83AucuEYdA

AESD_DEFCONFIG_NAME=aesd_pi5_defconfig
AESD_EXTERNAL=base_external
# BR2_EXTERNAL is passed relative to the buildroot directory, as in the course assignments.
AESD_EXTERNAL_REL_BUILDROOT=../${AESD_EXTERNAL}
AESD_MODIFIED_DEFCONFIG=${AESD_EXTERNAL}/configs/${AESD_DEFCONFIG_NAME}
