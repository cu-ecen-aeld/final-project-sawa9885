################################################################################
#
# gwmon
#
# Gateway monitor daemon: TCP status server, hardware watchdog (issue #6),
# Basics Station supervisor and gateway health (issue #7), health reports to
# AWS IoT Core (issue #13).
# Built from the gwmon/ directory at the top of this repository.
#
# This file was partially generated using Claude Code using the chat sessions at:
# Link to chat session (issue #6): https://claude.ai/code/cshk_01CSAPnx7BhY3Nsk5bW261b3NkPKAXvdTJyxZN6b8vcSPT
# Link to chat session (issue #7): https://claude.ai/code/cshk_01CSAPnyUYrsMvoThgHLYdiX7npiZ7nu2SeVLaZKVhC3Lx
# Link to chat session (issue #13): ISSUE13_SESSION_LINK
#
################################################################################

# With the "local" site method Buildroot rsyncs the directory into
# output/build/gwmon-2.1.0. GWMON_VERSION only names that directory: the
# version gwmon reports is GWMON_VERSION in gwmon/gwmon.c, so keep the two the
# same. After a source change: make gwmon-rebuild.
GWMON_VERSION = 2.1.0
GWMON_SITE = $(BR2_EXTERNAL_project_base_PATH)/../gwmon
GWMON_SITE_METHOD = local

# Leave a host build (make -C gwmon) out of the copy. A host gwmon binary that
# is newer than gwmon.c would otherwise be installed on the target as it is.
GWMON_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS = --exclude=/gwmon --exclude='*.o'

# TARGET_CONFIGURE_OPTS passes CC, CFLAGS and LDFLAGS for the target on the
# command line. gwmon's Makefile adds the flags it needs itself (GWMON_CFLAGS).
define GWMON_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D) all
endef

define GWMON_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/gwmon $(TARGET_DIR)/usr/bin/gwmon
	$(INSTALL) -D -m 0755 $(GWMON_PKGDIR)/gwmon-publish.sh $(TARGET_DIR)/usr/bin/gwmon-publish.sh
endef

define GWMON_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(GWMON_PKGDIR)/S99gwmon $(TARGET_DIR)/etc/init.d/S99gwmon
endef

$(eval $(generic-package))
