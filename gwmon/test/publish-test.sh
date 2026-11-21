#!/bin/bash
# Host test for the health publish of issue #13 with the REAL publish script and a REAL MQTT
# client: gwmon runs base_external/package/gwmon/gwmon-publish.sh, which runs mosquitto_pub
# against a local mosquitto broker with TLS and a required client certificate, the way AWS IoT
# Core is used. No AWS account is involved. The test makes its own CA, server and client
# certificates in a temporary directory and deletes them at the end.
#
#   ./test/publish-test.sh [path-to-gwmon] [path-to-gwmon-publish.sh]
#
# Needs mosquitto, mosquitto_pub, mosquitto_sub, openssl, python3 and an OpenBSD-style nc in PATH.
# The watchdog is a fake file, as in host-test.sh.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #13): https://claude.ai/code/cshk_01CSAPnymCy5ytzpd5YbDkk7GDXruVUH4TTxff71FBWGSW

set -u

GWMON=${1:-./gwmon}
PUBSH=${2:-../base_external/package/gwmon/gwmon-publish.sh}
PORT=${GWMON_TEST_PORT:-19000}
MQTT_PORT=${GWMON_TEST_MQTT_PORT:-18883}
TMP=$(mktemp -d)
FAKE=$TMP/fake-watchdog
EUI=0016c001deadbeef
FAILS=0
PID=""
BROKER=""
SUB=""
HOLE=""

cleanup() {
	for p in $PID $BROKER $SUB $HOLE; do kill -KILL "$p" 2>/dev/null; done
	rm -rf "$TMP"
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
check() {
	local what=$1
	shift
	if "$@"; then pass "$what"; else fail "$what"; fi
}
status() { nc -w 5 127.0.0.1 "$PORT" </dev/null; }
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p"; }
wait_status() {
	local n=0 limit=$(($2 * 5))
	until status | grep -Eq "$1"; do
		n=$((n + 1))
		[ $n -ge $limit ] && return 1
		sleep 0.2
	done
}
wait_port() { # wait_port PORT
	local n=0
	until nc -z 127.0.0.1 "$1" 2>/dev/null; do
		n=$((n + 1))
		[ $n -gt 50 ] && return 1
		sleep 0.1
	done
}
log_count() { grep -c "$1" "$TMP/stderr.log"; }

# ---- certificates: a CA, a server certificate for localhost and a client certificate
cd "$TMP" || exit 1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=test CA" -keyout ca.key -out ca.crt 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr 2>/dev/null
printf 'subjectAltName=DNS:localhost\n' >san.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile san.ext -out server.crt 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=gateway" -keyout client.key -out client.csr 2>/dev/null
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -out client.crt 2>/dev/null
mkdir -p health
echo localhost >health/endpoint
cp client.crt health/crt
cp client.key health/key
echo "$EUI" | tr a-f A-F >station.eui # station-run.sh writes the EUI as util_chip_id prints it
cd - >/dev/null || exit 1

cat >"$TMP/mosquitto.conf" <<EOF
listener $MQTT_PORT 127.0.0.1
cafile $TMP/ca.crt
certfile $TMP/server.crt
keyfile $TMP/server.key
require_certificate true
allow_anonymous true
log_dest stderr
EOF

start_broker() {
	mosquitto -c "$TMP/mosquitto.conf" 2>>"$TMP/broker.log" &
	BROKER=$!
	wait_port "$MQTT_PORT"
}
stop_broker() {
	kill -TERM "$BROKER" 2>/dev/null
	wait "$BROKER" 2>/dev/null
	BROKER=""
}
start_sub() { # all messages under aesd/#, one per line, with the topic
	mosquitto_sub -h localhost -p "$MQTT_PORT" --cafile "$TMP/ca.crt" --cert "$TMP/client.crt" \
		--key "$TMP/client.key" -t 'aesd/#' -v >>"$TMP/received" 2>>"$TMP/sub.log" &
	SUB=$!
	sleep 0.5
}
received() { cat "$TMP/received" 2>/dev/null | wc -l; }

export GWMON_HEALTH_DIR=$TMP/health
export GWMON_HEALTH_EUI_FILE=$TMP/station.eui
export GWMON_HEALTH_CA=$TMP/ca.crt
export GWMON_HEALTH_PORT=$MQTT_PORT
export GWMON_HEALTH_MOSQUITTO_PUB=$(command -v mosquitto_pub)
export GWMON_HEALTH_ERR_FILE=$TMP/publish.err

start_gwmon() { # start_gwmon EXTRA_ARGS...
	: >"$FAKE"
	: >"$TMP/stderr.log"
	"$GWMON" -p "$PORT" -t 5 -i 1 -w "$FAKE" -P "$PUBSH" "$@" 2>"$TMP/stderr.log" &
	PID=$!
	wait_port "$PORT"
}
stop_gwmon() {
	kill -TERM "$PID"
	wait "$PID"
	PID=""
}

echo "== publish test: $("$GWMON" -v), $(mosquitto -h | head -n 1), broker on port $MQTT_PORT"

echo "== 1. The publish script on its own"
start_broker
start_sub
printf '{"test":1}' | "$PUBSH"; rc=$?
sleep 0.5
check "a report is published (exit status $rc)" [ "$rc" = 0 -a "$(received)" = 1 ]
check "on the topic aesd/gateway/<lower-case EUI>/health, with the report as the message" \
	grep -qx "aesd/gateway/$EUI/health {\"test\":1}" "$TMP/received"
check "the broker saw the client ID aesd-gateway-<EUI>-health" \
	grep -q "as aesd-gateway-$EUI-health" "$TMP/broker.log"
GWMON_HEALTH_DIR=$TMP/no-such-dir "$PUBSH" </dev/null; rc=$?
check "no credentials: exit status 78 (got $rc)" [ "$rc" = 78 ]
GWMON_HEALTH_EUI_FILE=$TMP/no-such-file "$PUBSH" </dev/null; rc=$?
check "no gateway EUI yet: a failed attempt, exit status 1 (got $rc)" [ "$rc" = 1 ]
printf '{"test":2}' | GWMON_HEALTH_CA=$TMP/client.crt "$PUBSH"; rc=$?
sleep 0.5
check "a server certificate that does not check out: a failed attempt (exit status $rc), nothing published" \
	[ "$rc" != 0 -a "$(received)" = 1 ]

echo "== 2. gwmon publishes through the script every 2 s"
: >"$TMP/received"
start_gwmon -I 2 -O 1
check "three reports reach the subscriber" wait_status ' publish=ok publishes=3 ' 10
sleep 0.5
check "the subscriber has them ($(received))" [ "$(received)" -ge 3 ]
msg=$(tail -n 1 "$TMP/received" | cut -d' ' -f2-)
echo "    received: $(tail -n 1 "$TMP/received")"
check "the message is gwmon's JSON report" python3 -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if r["gwmon_version"] and "temp_c" in r else 1)' "$msg"
check "nothing but the first report is in the syslog output" [ "$(log_count "health publish")" = 1 ]

echo "== 3. Broker unreachable: one line in the syslog output, however many attempts fail"
stop_broker
check "five attempts fail: publish_fails=5" wait_status ' publish=failing .* publish_fails=5 ' 15
check "one 'failed' line for five failures" [ "$(log_count "health publish failed")" = 1 ]
echo "    $(grep "health publish failed" "$TMP/stderr.log" | sed 's/^[^:]*: //')"
echo "    mosquitto_pub said: $(cat "$TMP/publish.err")"
feeds1=$(status | field wd_feeds)
sleep 3
feeds2=$(status | field wd_feeds)
check "the watchdog is fed every second meanwhile (wd_feeds $feeds1, 3 s later $feeds2)" [ $((feeds2 - feeds1)) -ge 2 ]

echo "== 4. The broker is back: publishing resumes within one interval"
start_broker
t0=$(date +%s.%N)
back=1
wait_status ' publish=ok ' 5 && back=0
elapsed=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
check "the next attempt works, $elapsed s after the broker is back (interval 2 s)" \
	[ "$back" = 0 -a "$(awk -v e="$elapsed" 'BEGIN { print (e <= 2.6) }')" = 1 ]
check "one 'works again' line" [ "$(log_count "health publish works again")" = 1 ]
stop_gwmon

echo "== 5. A server that accepts the connection and then says nothing: gwmon kills the publish"
stop_broker
python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8); conns = []
while True:
    c, _ = s.accept(); conns.append(c)
' "$MQTT_PORT" &
HOLE=$!
wait_port "$MQTT_PORT"
start_gwmon -I 4 -O 2
check "two attempts hang and are killed: publish_fails=2" wait_status ' publish=failing .* publish_fails=2 ' 15
check "the kill is in the syslog output once" [ "$(log_count "was killed after 2 s without a result")" = 1 ]
check "no mosquitto_pub is left running" [ -z "$(pgrep -f "mosquitto_pub -h localhost -p $MQTT_PORT")" ]
line=$(status)
echo "    status: $line"
age=$(field wd_last_feed_age <<<"$line" | tr -d s)
check "the watchdog is still fed (wd_last_feed_age=${age}s)" [ "${age:-9}" -le 1 ]
stop_gwmon
kill -KILL "$HOLE"; wait "$HOLE" 2>/dev/null; HOLE=""

echo
if [ "$FAILS" = 0 ]; then
	echo "RESULT: all checks passed"
	exit 0
fi
echo "RESULT: $FAILS check(s) FAILED"
exit 1
