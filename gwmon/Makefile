# gwmon - gateway monitor daemon (issues #6, #7 and #13).
#
#   make                 build for the host
#   make CROSS_COMPILE=aarch64-none-linux-gnu-   cross build
#   make check           build, then run test/host-test.sh (no real watchdog is opened, and the
#                        supervised program is a fake station script)
#   make valgrind        the same test with gwmon under Valgrind
#   make publish-check   issue #13: gwmon, gwmon-publish.sh and mosquitto_pub against a local broker
#   make clean
#
# Buildroot builds this with CC, CFLAGS and LDFLAGS on the command line (see
# base_external/package/gwmon/gwmon.mk).
#
# This file was partially generated using Claude Code using the chat sessions at:
# Link to chat session (issue #6): https://claude.ai/code/cshk_01CSAPnx7BhY3Nsk5bW261b3NkPKAXvdTJyxZN6b8vcSPT
# Link to chat session (issue #7): https://claude.ai/code/cshk_01CSAPnyUYrsMvoThgHLYdiX7npiZ7nu2SeVLaZKVhC3Lx
# Link to chat session (issue #13): ISSUE13_SESSION_LINK

# make predefines CC as "cc", so "CC ?=" would never apply CROSS_COMPILE.
ifeq ($(origin CC),default)
CC = $(CROSS_COMPILE)gcc
endif

CFLAGS ?= -g -O2 -Wall -Wextra -Werror
LDFLAGS ?=

# Flags gwmon needs whatever CFLAGS the caller passes.
GWMON_CFLAGS = -std=gnu11 -pthread

TARGET = gwmon
OBJS = gwmon.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) $(GWMON_CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(GWMON_CFLAGS) -c -o $@ $<

check: all
	./test/host-test.sh ./$(TARGET)

valgrind: all
	VALGRIND=1 ./test/host-test.sh ./$(TARGET)

# Issue #13: the real publish script and mosquitto_pub against a local TLS mosquitto broker.
publish-check: all
	./test/publish-test.sh ./$(TARGET) $(PUBLISH_SCRIPT)
PUBLISH_SCRIPT ?= ../base_external/package/gwmon/gwmon-publish.sh

clean:
	rm -f $(TARGET) $(OBJS)

.PHONY: all check valgrind publish-check clean
