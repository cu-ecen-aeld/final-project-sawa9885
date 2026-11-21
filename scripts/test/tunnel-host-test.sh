#!/bin/bash
#
# Host test for the issue #15 scripts, run on the build PC (WSL), no Pi and no AWS needed:
#   - S35provision installs the four tunnel.* files from a fake boot partition with the
#     permissions the AWS IoT Device Client insists on, deletes them from "boot", and does
#     nothing on a second run.
#   - tunnel-run.sh with a fake client: exits 78 without credentials, restarts a crashing client
#     with a growing delay, resets the delay after a good run, and stops cleanly on SIGTERM.
#
# Usage: scripts/test/tunnel-host-test.sh     (exit status 0 when every check passes)
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #15): ISSUE15_SESSION_LINK

set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S35=$REPO/base_external/rootfs_overlay/etc/init.d/S35provision
RUNNER=$REPO/base_external/package/aws-iot-device-client/tunnel-run.sh

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
check() { # check "name" command...
	name=$1
	shift
	if "$@"; then
		echo "PASS $name"
		pass=$((pass + 1))
	else
		echo "FAIL $name"
		fail=$((fail + 1))
	fi
}
mode() { stat -c %a "$1"; }

# A fake logger on the PATH, so the scripts' log lines land in a file.
mkdir -p "$T/bin"
cat > "$T/bin/logger" <<'EOF'
#!/bin/sh
[ "$1" = -t ] && { tag=$2; shift 2; }
if [ $# -gt 0 ]; then echo "$tag: $*"; else sed "s/^/$tag: /"; fi >> "$LOGFILE"
EOF
chmod +x "$T/bin/logger"
export PATH="$T/bin:$PATH" LOGFILE="$T/log"

### S35provision ##############################################################################
# The script's paths, pointed into the temporary directory. /proc/mounts is replaced by a file
# that says the fake boot partition is mounted.
ROOT=$T/root
mkdir -p "$ROOT/boot" "$ROOT/etc"
echo "/dev/fake $ROOT/boot vfat rw 0 0" > "$T/mounts"
sed -e "s|^BOOT=.*|BOOT=$ROOT/boot|" \
	-e "s|=/etc/|=$ROOT/etc/|" \
	-e "s|/proc/mounts|$T/mounts|g" "$S35" > "$T/S35provision"

printf -- '-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n' > "$ROOT/boot/tunnel.cert.pem"
# A fake key. The marker is built from two parts so no line of this file looks like a key.
printf -- '-----BEGIN RSA %s-----\nZmFrZQ==\n-----END RSA %s-----\n' "PRIVATE KEY" "PRIVATE KEY" \
	> "$ROOT/boot/tunnel.key.pem"
# Written on Windows: CRLF and a byte order mark, which must be stripped.
printf '\357\273\277example-ats.iot.us-east-1.amazonaws.com\r\n' > "$ROOT/boot/tunnel.endpoint"
printf 'aesd-gw-test\r\n' > "$ROOT/boot/tunnel.thing"
cert_before=$(sha256sum < "$ROOT/boot/tunnel.cert.pem")

sh "$T/S35provision" start > "$T/s35.out" 2>&1
D=$ROOT/etc/aws-iot-device-client
check "S35: directory is 700" [ "$(mode "$D")" = 700 ]
check "S35: cert.pem is 644" [ "$(mode "$D/cert.pem")" = 644 ]
check "S35: key.pem is 600" [ "$(mode "$D/key.pem")" = 600 ]
check "S35: endpoint is 600" [ "$(mode "$D/endpoint")" = 600 ]
check "S35: thing is 600" [ "$(mode "$D/thing")" = 600 ]
check "S35: certificate copied byte for byte" [ "$(sha256sum < "$D/cert.pem")" = "$cert_before" ]
check "S35: endpoint without BOM and CR" [ "$(cat "$D/endpoint")" = "example-ats.iot.us-east-1.amazonaws.com" ]
check "S35: thing without CR" [ "$(cat "$D/thing")" = "aesd-gw-test" ]
check "S35: nothing left on boot" [ -z "$(ls "$ROOT/boot")" ]
check "S35: log names files only" sh -c "! grep -q -e ZmFrZQ -e example-ats '$LOGFILE'"

before=$(cd "$D" && ls -l --time-style=+%s)
sh "$T/S35provision" start > /dev/null 2>&1
check "S35: second boot changes nothing" [ "$(cd "$D" && ls -l --time-style=+%s)" = "$before" ]

### tunnel-run.sh #############################################################################
TD=$T/tunnel
mkdir -p "$TD"
# 1. No credentials: status 78, the fake client never runs.
: > "$LOGFILE"
cat > "$T/bin/fake-client" <<'EOF'
#!/bin/sh
echo run >> "$RUNS"
# Remember the arguments of the last run.
echo "$*" > "$ARGS"
# FAKE_MODE: crash (exit 1 at once), or run (until SIGTERM).
[ "$FAKE_MODE" = crash ] && exit 1
trap 'echo term >> "$RUNS"; exit 0' TERM
while :; do sleep 0.1; done
EOF
chmod +x "$T/bin/fake-client"
export TUNNEL_CLIENT="$T/bin/fake-client" TUNNEL_DIR="$TD" RUNS="$T/runs" ARGS="$T/args"
: > "$RUNS"
sh "$RUNNER"
check "run: exit 78 without credentials" [ $? = 78 ]
check "run: client not started without credentials" [ ! -s "$RUNS" ]

cp "$D/cert.pem" "$D/key.pem" "$D/endpoint" "$D/thing" "$TD/"

# 2. A client that crashes at once: restarted after 1, 2, 4 s (TUNNEL_MIN_DELAY=1).
: > "$LOGFILE"
: > "$RUNS"
FAKE_MODE=crash TUNNEL_MIN_DELAY=1 TUNNEL_MAX_DELAY=4 TUNNEL_GOOD_RUN=60 sh "$RUNNER" &
pid=$!
sleep 9.5
kill -TERM $pid
wait $pid
st=$?
check "run: crashing client restarted (4 or 5 runs in 9.5 s)" \
	sh -c "n=\$(grep -c run '$RUNS'); [ \$n -ge 4 ] && [ \$n -le 5 ]"
check "run: delays grow 1, 2, 4 s" \
	sh -c "grep -o 'again in [0-9]* s' '$LOGFILE' | head -3 | tr -dc '0-9\n' | tr '\n' ' ' | grep -q '^1 2 4 '"
check "run: delay capped at max" sh -c "! grep -q 'again in 8 s' '$LOGFILE'"
check "run: SIGTERM ends the loop with status 0" [ $st = 0 ]
check "run: arguments" grep -q -- "--endpoint example-ats.iot.us-east-1.amazonaws.com --cert $TD/cert.pem --key $TD/key.pem --thing-name aesd-gw-test --enable-tunneling true" "$ARGS"

# 3. A client that runs: SIGTERM reaches it, nothing is restarted, no process is left.
: > "$LOGFILE"
: > "$RUNS"
FAKE_MODE=run sh "$RUNNER" &
pid=$!
sleep 1
kill -TERM $pid
wait $pid
st=$?
sleep 0.3
check "run: SIGTERM stops a running client" grep -q term "$RUNS"
check "run: one run only" [ "$(grep -c '^run' "$RUNS")" = 1 ]
check "run: loop exits 0 on SIGTERM" [ $st = 0 ]
# "[f]ake" so the pattern does not match this check's own command line.
check "run: no client left" sh -c "! pgrep -f '$T/bin/[f]ake-client' >/dev/null"

# 4. A good run resets the delay: GOOD_RUN=1, the client runs 2 s then crashes.
cat > "$T/bin/fake-client" <<'EOF'
#!/bin/sh
echo run >> "$RUNS"
sleep 2
exit 1
EOF
: > "$LOGFILE"
: > "$RUNS"
TUNNEL_MIN_DELAY=1 TUNNEL_MAX_DELAY=4 TUNNEL_GOOD_RUN=1 sh "$RUNNER" &
pid=$!
sleep 8
kill -TERM $pid
wait $pid
check "run: delay stays at the minimum after good runs" \
	sh -c "[ \$(grep -c 'again in 1 s' '$LOGFILE') -ge 2 ] && ! grep -q 'again in 2 s' '$LOGFILE'"

echo "$pass passed, $fail failed"
[ $fail = 0 ]
