################################################################################
#
# basicstation
#
# Semtech's LoRa Basics Station, built for its "corecell" platform (SX1302
# reference design, which the Seeed WM1302 follows) in the "std" variant.
# It is the gateway program that AWS IoT Core for LoRaWAN accepts.
#
# Dependencies: bundled, not Buildroot's.
#   Upstream's makefiles "git clone" sx1302_hal and mbedtls during the build
#   (deps/*/prep.sh) and link them statically. This package keeps the static,
#   bundled build but lets Buildroot download both tarballs and check their
#   hashes, so the build is reproducible and works offline. They can't be
#   replaced with the Buildroot packages, because:
#   - libloragw: Station patches sx1302_hal V2.1.0 with its own
#     deps/lgw1302/V2.1.0-corecell.patch (about 2800 lines: Station logging,
#     SPI speed from the environment, LBT changes) and builds it with
#     -DSTATIONLOG. The libloragw.a that our sx1302-hal package puts in staging
#     is the unpatched library for lora_pkt_fwd, so it can't be linked here.
#   - mbedtls: Station 2.0.6 uses the mbedtls 2.x API. Buildroot 2026.02 has
#     mbedtls 3.6, which removed parts of it. The bundled copy is the last
#     2.28 LTS release (2.28.10) instead of the 2.28.0 that upstream pins,
#     for its security fixes. The API is the same.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #4): TODO(issue-4-session-link)
#
################################################################################

BASICSTATION_VERSION = v2.0.6
BASICSTATION_SITE = $(call github,lorabasics,basicstation,$(BASICSTATION_VERSION))
BASICSTATION_LICENSE = BSD-3-Clause (station, sx1302_hal), Apache-2.0 or GPL-2.0+ (mbedtls)
BASICSTATION_LICENSE_FILES = LICENSE \
	deps/lgw1302/platform-$(BASICSTATION_PLATFORM)/LICENSE.TXT \
	deps/mbedtls/platform-$(BASICSTATION_PLATFORM)/LICENSE

BASICSTATION_PLATFORM = corecell
BASICSTATION_VARIANT = std
BASICSTATION_BUILD_DIR = build-$(BASICSTATION_PLATFORM)-$(BASICSTATION_VARIANT)

# The same sx1302_hal release as our sx1302-hal package. It has to stay at the
# version that Station's patch was written for, whatever sx1302-hal moves to.
BASICSTATION_LGW_VERSION = V2.1.0
BASICSTATION_LGW_SOURCE = sx1302_hal-$(BASICSTATION_LGW_VERSION).tar.gz
BASICSTATION_MBEDTLS_VERSION = 2.28.10
BASICSTATION_MBEDTLS_SOURCE = mbedtls-$(BASICSTATION_MBEDTLS_VERSION).tar.bz2
BASICSTATION_EXTRA_DOWNLOADS = \
	$(call github,Lora-net,sx1302_hal,$(BASICSTATION_LGW_VERSION))/$(BASICSTATION_LGW_SOURCE) \
	https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$(BASICSTATION_MBEDTLS_VERSION)/$(BASICSTATION_MBEDTLS_SOURCE)

BASICSTATION_LGW_DIR = $(@D)/deps/lgw1302/platform-$(BASICSTATION_PLATFORM)
BASICSTATION_MBEDTLS_DIR = $(@D)/deps/mbedtls/platform-$(BASICSTATION_PLATFORM)

# Unpack the two dependencies where prep.sh would have cloned them. Upstream's
# deps makefiles only run prep.sh when platform-<platform>/ is missing, so with
# the sources in place nothing is fetched during the build.
define BASICSTATION_EXTRACT_DEPS
	mkdir -p $(BASICSTATION_LGW_DIR) $(BASICSTATION_MBEDTLS_DIR)
	$(call suitable-extractor,$(BASICSTATION_LGW_SOURCE)) \
		$(BASICSTATION_DL_DIR)/$(BASICSTATION_LGW_SOURCE) | \
		$(TAR) --strip-components=1 -C $(BASICSTATION_LGW_DIR) $(TAR_OPTIONS) -
	$(call suitable-extractor,$(BASICSTATION_MBEDTLS_SOURCE)) \
		$(BASICSTATION_DL_DIR)/$(BASICSTATION_MBEDTLS_SOURCE) | \
		$(TAR) --strip-components=1 -C $(BASICSTATION_MBEDTLS_DIR) $(TAR_OPTIONS) -
endef
BASICSTATION_POST_EXTRACT_HOOKS += BASICSTATION_EXTRACT_DEPS

# Station's own patch for libloragw, which prep.sh applies with "git apply".
define BASICSTATION_PATCH_LGW
	$(APPLY_PATCHES) $(BASICSTATION_LGW_DIR) $(@D)/deps/lgw1302 \
		$(BASICSTATION_LGW_VERSION)-$(BASICSTATION_PLATFORM).patch
endef
BASICSTATION_POST_PATCH_HOOKS += BASICSTATION_PATCH_LGW

# setup.gmk looks for a toolchain in $HOME/toolchain-corecell and builds CC,
# AR, LD, ... from TOOLPREFIX, so TOOLPREFIX is the one variable to override
# (setup.gmk still prints a "No toolchain for platform" warning, which is
# harmless). Its ARCH name for corecell, arm-linux-gnueabihf, is only a label
# in the build output: the compiler is Buildroot's aarch64 one.
# corecell/std has no optimisation flags upstream (-O0), so the Buildroot
# flags go in through setup.gmk's per-platform, per-variant CFLAGS variable.
# Its CFG counterpart adds -DCFG_no_rmtsh: Station's "rmtsh" feature lets the
# LNS open a root shell on the gateway. Nothing here uses it (the gateway is
# managed over SSH), so it is compiled out.
BASICSTATION_MAKE_OPTS = \
	platform=$(BASICSTATION_PLATFORM) \
	variant=$(BASICSTATION_VARIANT) \
	TOOLPREFIX="$(TARGET_CROSS)" \
	CFG.$(BASICSTATION_PLATFORM).$(BASICSTATION_VARIANT)="no_rmtsh" \
	CFLAGS.$(BASICSTATION_PLATFORM).$(BASICSTATION_VARIANT)="$(TARGET_CFLAGS)" \
	LDFLAGS.$(BASICSTATION_PLATFORM)="$(TARGET_LDFLAGS)"

# Three steps, because upstream's makefiles are not safe with "make -j":
# 1. mbedtls, in parallel and with the Buildroot flags. deps/mbedtls/makefile
#    would build it with "-Wall -std=gnu11" only (-O0), and would start three
#    "make lib" at once under -j. Built here first, its three libraries are up
#    to date when step 2 gets to them, and it only copies them.
# 2. The host tools (crc32, genkwcrcs: plain "gcc"), src/kwcrc.h and the deps
#    (libloragw, and the copies into build-corecell-std/), one job at a time.
# 3. Station itself, in parallel. It needs the libraries from step 2 in place
#    when its makefile is read, since it lists them with $(wildcard).
define BASICSTATION_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(BASICSTATION_MBEDTLS_DIR) lib \
		CC="$(TARGET_CC)" AR="$(TARGET_AR)" CFLAGS="$(TARGET_CFLAGS)"
	$(TARGET_MAKE_ENV) $(MAKE1) -C $(@D) $(BASICSTATION_MAKE_OPTS) \
		build-local/bin/crc32 src/kwcrc.h deps
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(BASICSTATION_MAKE_OPTS) s-all
endef

# station.conf has no secret, so it is installed here. The credential files
# (cups.*, tc.*) are never in the image: S35provision moves them from the boot
# partition into /etc/station, Station's home directory, at boot.
define BASICSTATION_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/$(BASICSTATION_BUILD_DIR)/bin/station \
		$(TARGET_DIR)/usr/bin/station
	$(INSTALL) -D -m 0644 $(BASICSTATION_PKGDIR)/station.conf \
		$(TARGET_DIR)/etc/station/station.conf
endef

define BASICSTATION_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(BASICSTATION_PKGDIR)/S60station \
		$(TARGET_DIR)/etc/init.d/S60station
endef

$(eval $(generic-package))
