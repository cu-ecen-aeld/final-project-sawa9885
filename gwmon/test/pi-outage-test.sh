#!/bin/sh
# Issue #13 outage test, run ON THE GATEWAY, detached from the SSH session:
#     setsid sh /tmp/pi-outage-test.sh 600 </dev/null >/dev/null 2>&1 &
#
# It takes the gateway off the internet for SECONDS (default 600) by deleting the default route,
# then puts the same route back by itself. The LAN route stays, so SSH from the LAN keeps
# working during the test; only traffic to the internet (AWS) fails, as with a pulled WAN.
#
# Risk and recovery: if this script died between the two steps, the gateway would stay off the
# internet, but it would still be reachable over SSH on the LAN, and the route can be put back
# by hand with the command in /tmp/pi-outage-test.restore. udhcpc also adds the default route
# again at its next lease renewal.
#
# Every 10 s it logs the route state to /tmp/pi-outage-test.log and to syslog with the tag
# outage-test. The image has no nc, so gwmon's status is logged from the PC meanwhile.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #13): ISSUE13_SESSION_LINK

SECONDS_OFF=${1:-600}
LOG=/tmp/pi-outage-test.log
# busybox "ip route show default" lists every route, so filter by hand.
default_routes() { ip route | grep "^default"; }
route=$(default_routes | head -n 1)

say() {
	echo "$(date -u +%H:%M:%S) $*" >>"$LOG"
	logger -t outage-test "$*"
}

if [ -z "$route" ]; then
	say "no default route, nothing to do"
	exit 1
fi
echo "ip route add $route" >/tmp/pi-outage-test.restore
trap '' HUP INT

say "default route removed for $SECONDS_OFF s (was: $route)"
ip route del default
t=0
while [ $t -lt "$SECONDS_OFF" ]; do
	sleep 10
	t=$((t + 10))
	say "off for $t s, $(default_routes | wc -l) default route(s)"
done
# udhcpc may have put it back already at a lease renewal; the log above shows when.
# shellcheck disable=SC2086 # the route is a list of words
[ -n "$(default_routes)" ] || ip route add $route ||
	say "FAILED to put the route back: run $(cat /tmp/pi-outage-test.restore)"
say "default route back: $(default_routes)"
t=0
while [ $t -lt 360 ]; do
	sleep 10
	t=$((t + 10))
	say "back for $t s"
done
say "end of the test script"
