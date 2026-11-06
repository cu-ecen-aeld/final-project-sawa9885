#!/bin/sh
# reset_lgw.sh for the Seeed WM1302 Pi HAT on the Pi 5.
#
# lora_pkt_fwd and util_chip_id run "reset_lgw.sh start" before they open the concentrator and
# "reset_lgw.sh stop" when they exit (see 0001-Run-reset_lgw.sh-from-PATH-...patch). Semtech's
# version drives sysfs GPIOs, which the Pi 5 doesn't number from 0, so this one calls
# wm1302-reset.sh from the rootfs overlay, which uses libgpiod.
#
# This script was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #3): https://claude.ai/code/cshk_01CSAPnwU8kGpRLfK6nchbsXUG2a95em6aXdDoBJsXAhS9

case "$1" in
start)
	exec /usr/bin/wm1302-reset.sh
	;;
stop)
	# Semtech's stop only unexports the sysfs GPIOs. There is nothing to release with libgpiod.
	exit 0
	;;
*)
	echo "Usage: $0 {start|stop}" >&2
	exit 1
	;;
esac
