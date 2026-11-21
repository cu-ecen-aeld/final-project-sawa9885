################################################################################
#
# aws-iot-device-sdk-cpp-v2
#
# The AWS IoT Device SDK for C++ v2, the library that aws-iot-device-client is
# written on (issue #15). The version is the one that device client v1.10.1
# pins in its CMakeLists.txt.awssdk (commit 74c8b683, tag v1.30.3): upstream
# builds and tests the client against that SDK and no other.
#
# The SDK carries the AWS Common Runtime as nested git submodules (aws-crt-cpp,
# then aws-c-common, aws-c-io, aws-c-mqtt, s2n-tls, ...), which a GitHub
# release tarball leaves out. So this is a git download with submodules:
# Buildroot clones once, packs a reproducible tarball into the download
# directory and checks its hash, and later builds work offline.
#
# Static libraries, staging only. The device client is the one program that
# uses them, so nothing from this package is installed on the target.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #15): https://claude.ai/code/cshk_01CSAPnxBTBTRh5jk4ugaU6pVi3LQF38pioZ4gsNNQDvGQ
#
################################################################################

AWS_IOT_DEVICE_SDK_CPP_V2_VERSION = v1.30.3
AWS_IOT_DEVICE_SDK_CPP_V2_SITE = https://github.com/aws/aws-iot-device-sdk-cpp-v2.git
AWS_IOT_DEVICE_SDK_CPP_V2_SITE_METHOD = git
AWS_IOT_DEVICE_SDK_CPP_V2_GIT_SUBMODULES = YES
AWS_IOT_DEVICE_SDK_CPP_V2_LICENSE = Apache-2.0
AWS_IOT_DEVICE_SDK_CPP_V2_LICENSE_FILES = documents/LICENSE crt/aws-crt-cpp/LICENSE \
	crt/aws-c-iot/LICENSE crt/aws-crt-cpp/crt/s2n/LICENSE
AWS_IOT_DEVICE_SDK_CPP_V2_INSTALL_STAGING = YES
AWS_IOT_DEVICE_SDK_CPP_V2_INSTALL_TARGET = NO
AWS_IOT_DEVICE_SDK_CPP_V2_DEPENDENCIES = openssl

# BUILD_DEPS: build the bundled Common Runtime (the submodules).
# USE_OPENSSL: use Buildroot's libcrypto instead of building the bundled
#   aws-lc, a second crypto library that would otherwise be compiled.
# BUILD_SHARED_LIBS=OFF comes after Buildroot's own =ON on the command line.
# BUILD_TESTING=OFF: no test programs (they would not run on the build host).
# CMAKE_POLICY_VERSION_MINIMUM: the SDK and parts of the CRT ask for CMake 3.1,
#   which the CMake 4 of Buildroot 2026.02 refuses unless told to go ahead.
AWS_IOT_DEVICE_SDK_CPP_V2_CONF_OPTS = \
	-DBUILD_DEPS=ON \
	-DUSE_OPENSSL=ON \
	-DBUILD_SHARED_LIBS=OFF \
	-DBUILD_TESTING=OFF \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5

$(eval $(cmake-package))
