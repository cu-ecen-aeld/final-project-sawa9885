################################################################################
#
# sx1302-hal
#
# Semtech's SX1302 HAL (libloragw), lora_pkt_fwd and util_chip_id for the
# Seeed WM1302 (SX1302 + SX1250, US915) on the Pi 5.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #3): https://claude.ai/code/cshk_01CSAPnwU8kGpRLfK6nchbsXUG2a95em6aXdDoBJsXAhS9
#
################################################################################

SX1302_HAL_VERSION = V2.1.0
SX1302_HAL_SITE = $(call github,Lora-net,sx1302_hal,$(SX1302_HAL_VERSION))
SX1302_HAL_LICENSE = BSD-3-Clause
SX1302_HAL_LICENSE_FILES = LICENSE.TXT
SX1302_HAL_INSTALL_STAGING = YES

# The upstream Makefiles set CC from CROSS_COMPILE and use their own CFLAGS.
# The top-level Makefile calls the sub-makes with -e, so environment variables
# override what the sub-Makefiles set. That's why only CROSS_COMPILE is passed,
# on the command line, and not Buildroot's TARGET_CONFIGURE_OPTS.
SX1302_HAL_MAKE_OPTS = CROSS_COMPILE="$(TARGET_CROSS)"

# Only the parts the gateway uses: libloragw (with libtools), the packet
# forwarder and the chip ID tool. util_boot, util_net_downlink and
# util_spectral_scan aren't needed.
SX1302_HAL_TARGETS = libtools libloragw packet_forwarder util_chip_id

define SX1302_HAL_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(SX1302_HAL_MAKE_OPTS) $(SX1302_HAL_TARGETS)
endef

# libloragw is a static library, linked into the tools. Install it with its
# headers in staging, for the packages that build against it later.
define SX1302_HAL_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0644 $(@D)/libloragw/libloragw.a $(STAGING_DIR)/usr/lib/libloragw.a
	$(INSTALL) -D -m 0644 $(@D)/libtools/libtinymt32.a $(STAGING_DIR)/usr/lib/libtinymt32.a
	$(INSTALL) -d $(STAGING_DIR)/usr/include/libloragw
	$(INSTALL) -m 0644 $(@D)/libloragw/inc/*.h $(STAGING_DIR)/usr/include/libloragw/
	$(INSTALL) -m 0644 $(@D)/libtools/inc/tinymt32.h $(STAGING_DIR)/usr/include/libloragw/
endef

# chip_id is installed as util_chip_id, the name of its upstream directory,
# since "chip_id" is too generic for /usr/bin.
define SX1302_HAL_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/packet_forwarder/lora_pkt_fwd $(TARGET_DIR)/usr/bin/lora_pkt_fwd
	$(INSTALL) -D -m 0755 $(@D)/util_chip_id/chip_id $(TARGET_DIR)/usr/bin/util_chip_id
	$(INSTALL) -D -m 0755 $(SX1302_HAL_PKGDIR)/reset_lgw.sh $(TARGET_DIR)/usr/bin/reset_lgw.sh
	$(INSTALL) -D -m 0644 $(SX1302_HAL_PKGDIR)/global_conf.json \
		$(TARGET_DIR)/etc/lora_pkt_fwd/global_conf.json
endef

$(eval $(generic-package))
