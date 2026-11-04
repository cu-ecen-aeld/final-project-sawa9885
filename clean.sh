#!/bin/bash
# Remove the Buildroot build output (buildroot/output), the downloads (buildroot/dl) and .config.
#
# This script was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #1): __AI_SESSION_LINK__

set -e
cd "$(dirname "$0")"
source ./shared.sh

make -C buildroot BR2_EXTERNAL=${AESD_EXTERNAL_REL_BUILDROOT} distclean
