#!/bin/sh
# Reset the Seeed WM1302 LoRaWAN module (SX1302 + SX1261) on its Pi HAT with libgpiod.
#
# Semtech's reset_lgw.sh drives the pins through /sys/class/gpio with global GPIO numbers, which
# the Pi 5 doesn't keep (the header is at base 569 there, not 0). This uses the GPIO character
# device through libgpiod's gpioset instead (libgpiod 1.6, since the toolchain has 5.4 headers).
#
# gpiochip: on the Pi 5 the 40-pin header is on the RP1 I/O controller. Its chip is labelled
# "pinctrl-rp1" (gpiochip0, 1f000d0000.gpio, 54 lines), and header GPIO N is line N.
# The chip is looked up by that label in case the gpiochip numbering changes.
#
# WM1302 Pi HAT pins (as in Seeed's reset_lgw.sh):
#   GPIO17  SX1302 reset, active high
#   GPIO5   SX1261 reset, active low
#
# This script was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #2): https://claude.ai/code/cshk_01CSAPnvczn7U1rhz8Wn7mvALHP1X5aHUucnKHJGvS8E1v

set -e

SX1302_RESET=17
SX1261_RESET=5
PULSE_US=100000

CHIP=$(gpiodetect | awk '/\[pinctrl-rp1\]/ { print $1; exit }')
if [ -z "$CHIP" ]; then
	echo "wm1302-reset: no pinctrl-rp1 gpiochip found" >&2
	exit 1
fi

echo "wm1302-reset: resetting the SX1302 (GPIO${SX1302_RESET}) and SX1261 (GPIO${SX1261_RESET}) on ${CHIP}"

# Assert both resets for 100 ms, then release them and hold for another 100 ms before exiting,
# so the SX1302 is out of reset before a forwarder opens it. When gpioset exits, the RP1 keeps
# the lines as outputs at their last values (17 low, 5 high), and the default pulls (GPIO17 down,
# GPIO5 up) match those values.
gpioset --mode=time --usec=${PULSE_US} "$CHIP" ${SX1302_RESET}=1 ${SX1261_RESET}=0
gpioset --mode=time --usec=${PULSE_US} "$CHIP" ${SX1302_RESET}=0 ${SX1261_RESET}=1

echo "wm1302-reset: done"
