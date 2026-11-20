#!/bin/sh
#
# Publish one gwmon health report to AWS IoT Core (issue #13).
#
# gwmon starts this script every 5 minutes (gwmon -P, see S99gwmon) with the report, one JSON
# object, on standard input. The script hands it to mosquitto_pub, which makes one MQTT
# connection over TLS, publishes the report with QoS 1 to
#     aesd/gateway/<gateway EUI>/health
# waits for the broker's acknowledgement and exits. Nothing stays connected between two reports.
#
# gwmon does not wait for this script: it runs as a child of its own, and gwmon kills it (and
# mosquitto_pub with it) if it has not ended after 30 s. So nothing here can delay the watchdog.
# gwmon also does the logging, one line when publishing starts to fail and one when it works
# again, so this script logs nothing. What mosquitto_pub said on the last attempt is kept in
# /var/run/gwmon-publish.err for a look over SSH.
#
# Credentials, in /etc/gwmon-health, installed from the boot partition by S35provision:
#     endpoint   host name of the account's AWS IoT data endpoint (...-ats.iot.<region>.amazonaws.com)
#     crt, key   the publisher's own device certificate and private key
# The server is checked against the CA bundle of the ca-certificates package, which has the
# Amazon root CAs. The MQTT client ID is aesd-gateway-<gateway EUI>-health: the AWS IoT policy
# of the certificate allows that client ID and that one topic only.
#
# The gateway EUI is the one station-run.sh has read from the SX1302 (/var/run/station.eui).
#
# Exit status: 0 published; 78 no credentials (gwmon then stops trying); anything else is a
# failed attempt (mosquitto_pub's own status, or 1 when the EUI is not known yet).
#
# The GWMON_HEALTH_* variables are for the host test and for trying a build from /tmp.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #13): ISSUE13_SESSION_LINK

HEALTH_DIR=${GWMON_HEALTH_DIR:-/etc/gwmon-health}
EUI_FILE=${GWMON_HEALTH_EUI_FILE:-/var/run/station.eui}
CA_FILE=${GWMON_HEALTH_CA:-/etc/ssl/certs/ca-certificates.crt}
PORT=${GWMON_HEALTH_PORT:-8883}
MOSQUITTO_PUB=${GWMON_HEALTH_MOSQUITTO_PUB:-/usr/bin/mosquitto_pub}
ERR_FILE=${GWMON_HEALTH_ERR_FILE:-/var/run/gwmon-publish.err}
# EX_CONFIG from sysexits.h. gwmon knows this status (EXIT_NOT_CONFIGURED in gwmon.c).
EXIT_NOT_CONFIGURED=78

for f in endpoint crt key; do
	[ -s "$HEALTH_DIR/$f" ] || exit $EXIT_NOT_CONFIGURED
done

exec 2>"$ERR_FILE"

eui=$(tr 'A-F' 'a-f' < "$EUI_FILE" 2>/dev/null | tr -cd '0-9a-f')
if [ ${#eui} -ne 16 ]; then
	echo "no gateway EUI in $EUI_FILE yet" >&2
	exit 1
fi
endpoint=$(tr -d ' \t\r\n' < "$HEALTH_DIR/endpoint")

# -s: the message is all of standard input. -q 1: exit only after the broker has acknowledged.
# -r: AWS IoT keeps the last report as a retained message, so the latest health of a gateway can
# be read at any time (console "Retained messages", or aws iot-data get-retained-message).
exec "$MOSQUITTO_PUB" -h "$endpoint" -p "$PORT" \
	--cafile "$CA_FILE" --cert "$HEALTH_DIR/crt" --key "$HEALTH_DIR/key" \
	-i "aesd-gateway-$eui-health" -t "aesd/gateway/$eui/health" -q 1 -r -s
