#!/bin/sh
#
# Run the AWS IoT Device Client (secure tunneling only) and start it again whenever it exits
# (issue #15). S99tunnel starts this script in the background; it is the client's respawn loop.
#
# The client keeps one MQTT connection to AWS IoT Core and waits. When a tunnel is opened in AWS
# for this gateway's thing, it connects out to the tunneling service and forwards the tunnel to
# the SSH server on 127.0.0.1:22. It listens on no port.
#
# Its four files are installed by S35provision from the boot partition into
# /etc/aws-iot-device-client (mode 700):
#   cert.pem   the thing's certificate          (644, the client insists on it)
#   key.pem    its private key                  (600)
#   endpoint   the account's AWS IoT endpoint   (host name, one line)
#   thing      the thing name                   (one line; also the MQTT client ID)
# If one is missing this script exits with status 78 and nothing runs: a gateway without tunnel
# credentials is a gateway without the remote shell, and everything else works as before.
#
# This loop is kept apart from gwmon on purpose. gwmon supervises Station and feeds the hardware
# watchdog; a client that crashes at every start must never count as a gateway fault and reset the
# Pi. So the client is restarted here, with a delay that doubles from 5 s to 5 min while it keeps
# failing (AWS unreachable, clock not set yet, certificate revoked) and goes back to 5 s once it
# has run for a minute. It runs at low priority, and its output goes to syslog (tag "tunnel"), not
# to a file of its own that could fill /var/log.
#
# Settings can be changed in /etc/default/tunnel, for example TUNNEL_LOG_LEVEL=DEBUG.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #15): https://claude.ai/code/cshk_01CSAPnxBTBTRh5jk4ugaU6pVi3LQF38pioZ4gsNNQDvGQ

CLIENT=${TUNNEL_CLIENT:-/usr/bin/aws-iot-device-client}
TUNNEL_DIR=${TUNNEL_DIR:-/etc/aws-iot-device-client}
TUNNEL_LOG_LEVEL=INFO
MIN_DELAY=${TUNNEL_MIN_DELAY:-5}
MAX_DELAY=${TUNNEL_MAX_DELAY:-300}
# A run this long counts as "it worked": the next restart is quick again.
GOOD_RUN=${TUNNEL_GOOD_RUN:-60}
# EX_CONFIG from sysexits.h, as in station-run.sh.
EXIT_NOT_CONFIGURED=78

[ -r /etc/default/tunnel ] && . /etc/default/tunnel

log() {
	logger -t tunnel "$*"
}

for f in cert.pem key.pem endpoint thing; do
	if [ ! -s "$TUNNEL_DIR/$f" ]; then
		log "no $TUNNEL_DIR/$f, not starting (see docs/issue15-secure-tunnel.md)"
		exit $EXIT_NOT_CONFIGURED
	fi
done
# tr: files written on Windows end in CR LF.
ENDPOINT=$(head -n 1 "$TUNNEL_DIR/endpoint" | tr -d '\r ')
THING=$(head -n 1 "$TUNNEL_DIR/thing" | tr -d '\r ')

# The client expands "~" for its default paths and keeps a lock file (one client per thing).
export HOME="${HOME:-/root}"
export LOCK_FILE_PATH="${LOCK_FILE_PATH:-/var/run/}"

stopping=0
stop() {
	stopping=1
	# SIGTERM: the client closes its tunnel and its MQTT connection and exits.
	killall "${CLIENT##*/}" 2>/dev/null
}
trap stop TERM INT

uptime_s() {
	cut -d. -f1 /proc/uptime
}

delay=$MIN_DELAY
while [ $stopping = 0 ]; do
	started=$(uptime_s)
	log "starting $CLIENT for thing $THING"
	# No --root-ca: the client then uses the system trust store (ca-certificates), which has the
	# Amazon root CAs. The features other than tunneling are compiled out; they are also
	# switched off here, so the command line says what runs.
	nice -n 10 "$CLIENT" \
		--endpoint "$ENDPOINT" \
		--cert "$TUNNEL_DIR/cert.pem" \
		--key "$TUNNEL_DIR/key.pem" \
		--thing-name "$THING" \
		--enable-tunneling true \
		--log-type STDOUT \
		--log-level "$TUNNEL_LOG_LEVEL" 2>&1 | logger -t tunnel &
	# Wait in the background, so the trap runs as soon as the signal arrives.
	wait $!
	[ $stopping = 1 ] && break

	ran=$(($(uptime_s) - started))
	if [ $ran -ge $GOOD_RUN ]; then
		delay=$MIN_DELAY
	fi
	log "client exited after $ran s, starting it again in $delay s"
	# Sleep in the background too, for the same reason.
	sleep $delay &
	wait $!
	if [ $ran -lt $GOOD_RUN ]; then
		delay=$((delay * 2))
		[ $delay -gt $MAX_DELAY ] && delay=$MAX_DELAY
	fi
done
log "stopped"
exit 0
