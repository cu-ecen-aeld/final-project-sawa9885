#!/bin/sh
#
# Run LoRa Basics Station, the LoRaWAN gateway program, in the foreground. gwmon starts this
# script (gwmon -s), waits for it and starts it again when Station exits (issue #7). It takes
# the place of the S60station init script of issue #4: nothing else starts Station.
#
# Station's home directory is /etc/station. It holds station.conf (from the basicstation package)
# and the credential files cups.{uri,trust,crt,key} and/or tc.{uri,trust,crt,key}, which
# S35provision installs from the boot partition.
#
# Before Station starts, this script:
#   1. checks that there is a server address. With no .uri file it exits with status 78, which
#      tells gwmon "nothing to run": gwmon does not restart it and does not count a failure, so
#      a gateway without credentials stays up.
#   2. resets the WM1302 and reads the SX1302's EUI with util_chip_id (it runs reset_lgw.sh, which
#      runs wm1302-reset.sh), and writes the EUI to /var/run/station.eui. station.conf names that
#      file as its "routerid", so the gateway EUI is the concentrator's EUI. If the SX1302 does
#      not answer, the script exits with status 1 and gwmon counts a failed start.
#   3. waits up to 60 s for chronyd to set the clock. The Pi has no RTC battery, and TLS rejects
#      the server certificates when the date is wrong.
# Then it execs Station, so Station has the PID that gwmon started and gets gwmon's signals.
# Station resets the radio again itself each time it starts it ("radio_init" in station.conf).
#
# Station runs without --daemon: it stays in the foreground as one process and writes its log to
# /var/log/station.log (see station.conf). To restart it by hand: kill $(pidof station).
#
# Exit status: 78 nothing to run, 1 the EUI could not be read, otherwise Station's own.
#
# This file was partially generated using Claude Code using the chat sessions at:
# Link to chat session (issue #4): https://claude.ai/code/cshk_01CSAPnz8sDPokK7N8rieHo1BXzy3XPsziDucST29D43Kh
# Link to chat session (issue #7): https://claude.ai/code/cshk_01CSAPnyUYrsMvoThgHLYdiX7npiZ7nu2SeVLaZKVhC3Lx

STATION=/usr/bin/station
STATION_HOME=/etc/station
SPI_DEV=/dev/spidev0.0
EUI_FILE=/var/run/station.eui
# Written by Station itself, in its temp directory.
STATION_PID=/tmp/station.pid
# Up to 30 checks, 2 s apart, for chronyd to report a synchronised clock.
CLOCK_TRIES=30
# EX_CONFIG from sysexits.h. gwmon knows this status (EXIT_NOT_CONFIGURED in gwmon.c).
EXIT_NOT_CONFIGURED=78

log() {
	logger -t station "$*"
}

# Station needs at least one server address. These are all the names it looks for.
have_uri() {
	for f in cups cups-bak cups-boot tc tc-bak tc-boot; do
		[ -s "$STATION_HOME/$f.uri" ] && return 0
	done
	return 1
}

# util_chip_id prints "INFO: concentrator EUI: 0x0016c001f1135844".
read_eui() {
	eui=$(util_chip_id -d "$SPI_DEV" 2>/dev/null |
		sed -n 's/.*concentrator EUI: 0x\([0-9a-fA-F]\{16\}\).*/\1/p')
	[ -n "$eui" ] || return 1
	echo "$eui" > "$EUI_FILE"
}

if ! have_uri; then
	log "no cups.uri or tc.uri in $STATION_HOME, not starting (see the README, \"Flash and first boot\")"
	exit $EXIT_NOT_CONFIGURED
fi

# gwmon's child gets SIGTERM when gwmon dies, so no Station should be left from an earlier gwmon.
# If one is, it has to go first: util_chip_id resets the concentrator under it.
if pidof station >/dev/null; then
	log "another station is still running, stopping it"
	killall station 2>/dev/null
	sleep 1
	killall -9 station 2>/dev/null
fi
# Station refuses to start while the PID in this file belongs to a running process. After a
# kill -9 the file is stale, and its PID may belong to some other process by now.
rm -f "$STATION_PID"

if ! read_eui; then
	log "could not read the SX1302 EUI on $SPI_DEV"
	exit 1
fi
log "gateway EUI $(cat "$EUI_FILE"), starting when the clock is set"

if [ -x /usr/bin/chronyc ] && ! chronyc -n waitsync $CLOCK_TRIES 0 0 2 >/dev/null 2>&1; then
	log "clock not synchronised after $((CLOCK_TRIES * 2)) s, starting anyway"
fi

log "starting $STATION, uptime $(cut -d' ' -f1 /proc/uptime) s"
exec "$STATION" --home "$STATION_HOME"
