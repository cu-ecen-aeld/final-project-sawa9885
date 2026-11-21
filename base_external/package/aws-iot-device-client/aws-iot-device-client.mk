################################################################################
#
# aws-iot-device-client
#
# The AWS IoT Device Client with only its secure tunneling feature (issue #15).
# When a tunnel is opened in AWS for this gateway's thing, the client gets a
# message on its MQTT connection, connects out to the tunneling service and
# forwards the tunnel to the SSH server on 127.0.0.1:22. Both connections are
# outbound (TCP 443), so the gateway listens on nothing new.
#
# v1.10.1 is the latest upstream release. Upstream's own build clones the SDK
# with git while CMake configures (BUILD_SDK=ON). Here the SDK is a Buildroot
# package of its own, aws-iot-device-sdk-cpp-v2, at the commit upstream pins,
# and the client is built with BUILD_SDK=OFF against the static libraries in
# staging. No network access during the build.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #15): ISSUE15_SESSION_LINK
#
################################################################################

AWS_IOT_DEVICE_CLIENT_VERSION = v1.10.1
AWS_IOT_DEVICE_CLIENT_SITE = $(call github,awslabs,aws-iot-device-client,$(AWS_IOT_DEVICE_CLIENT_VERSION))
AWS_IOT_DEVICE_CLIENT_LICENSE = Apache-2.0
AWS_IOT_DEVICE_CLIENT_LICENSE_FILES = LICENSE
AWS_IOT_DEVICE_CLIENT_DEPENDENCIES = aws-iot-device-sdk-cpp-v2 openssl

# Every feature that can be excluded is, except secure tunneling (EXCLUDE_ST
# stays OFF): no Jobs (remote command execution), no Device Defender, no Fleet
# Provisioning, no shadows, no samples, no sensor publish, no PKCS#11.
# BUILD_TEST_DEPS=OFF: do not download and build googletest.
# GIT_VERSION=OFF: take the version from the .version file, not from git.
# LINK_DL=ON: the SDK is static but libcrypto is shared.
AWS_IOT_DEVICE_CLIENT_CONF_OPTS = \
	-DBUILD_SDK=OFF \
	-DBUILD_TEST_DEPS=OFF \
	-DGIT_VERSION=OFF \
	-DLINK_DL=ON \
	-DEXCLUDE_ST=OFF \
	-DEXCLUDE_JOBS=ON \
	-DEXCLUDE_DD=ON \
	-DEXCLUDE_FP=ON \
	-DEXCLUDE_SAMPLES=ON \
	-DEXCLUDE_PUBSUB=ON \
	-DEXCLUDE_SHADOW=ON \
	-DEXCLUDE_CONFIG_SHADOW=ON \
	-DEXCLUDE_SAMPLE_SHADOW=ON \
	-DEXCLUDE_SENSOR_PUBLISH=ON \
	-DEXCLUDE_SENSOR_PUBLISH_SAMPLES=ON \
	-DEXCLUDE_SECURE_ELEMENT=ON \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5

# The .version file in the v1.10.1 tarball still says v1.10.0. The client
# prints this string at start and with --version.
define AWS_IOT_DEVICE_CLIENT_SET_VERSION
	echo "v1.10.1-7f9547b*v1.10.1*1*10*1*0*7f9547b" > $(@D)/.version
endef
AWS_IOT_DEVICE_CLIENT_POST_PATCH_HOOKS += AWS_IOT_DEVICE_CLIENT_SET_VERSION

# Upstream's CMakeLists.txt has no install rule.
define AWS_IOT_DEVICE_CLIENT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/aws-iot-device-client \
		$(TARGET_DIR)/usr/bin/aws-iot-device-client
	$(INSTALL) -D -m 0755 $(AWS_IOT_DEVICE_CLIENT_PKGDIR)/tunnel-run.sh \
		$(TARGET_DIR)/usr/bin/tunnel-run.sh
endef

define AWS_IOT_DEVICE_CLIENT_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(AWS_IOT_DEVICE_CLIENT_PKGDIR)/S99tunnel \
		$(TARGET_DIR)/etc/init.d/S99tunnel
endef

$(eval $(cmake-package))
