################################################################################
#
# gwmon
#
# Gateway monitor daemon: TCP status server and hardware watchdog (issue #6).
# Built from the gwmon/ directory at the top of this repository.
#
# NOT YET BUILT WITH BUILDROOT: written and reviewed against sx1302-hal.mk and
# the Buildroot manual while the build tree was in use for issue #4. The bench
# checklist in docs/issue6-gwmon.md has the first build as its first step.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #6): TODO(issue-6-session-link)
#
################################################################################

# With the "local" site method Buildroot rsyncs the directory into
# output/build/gwmon-custom (it sets the version to "custom" itself), so
# GWMON_VERSION only documents the release. The version gwmon reports is
# GWMON_VERSION in gwmon/gwmon.c. After a source change: make gwmon-rebuild.
GWMON_VERSION = 1.0.0
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
endef

define GWMON_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(GWMON_PKGDIR)/S99gwmon $(TARGET_DIR)/etc/init.d/S99gwmon
endef

$(eval $(generic-package))
