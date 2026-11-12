# gwmon - gateway monitor daemon (issue #6).
#
#   make                 build for the host
#   make CROSS_COMPILE=aarch64-none-linux-gnu-   cross build
#   make check           build, then run test/host-test.sh (no real watchdog is opened)
#   make valgrind        the same test with gwmon under Valgrind
#   make clean
#
# Buildroot builds this with CC, CFLAGS and LDFLAGS on the command line (see
# base_external/package/gwmon/gwmon.mk).
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #6): https://claude.ai/code/cshk_01CSAPnx7BhY3Nsk5bW261b3NkPKAXvdTJyxZN6b8vcSPT

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

clean:
	rm -f $(TARGET) $(OBJS)

.PHONY: all check valgrind clean
