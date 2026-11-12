#!/bin/bash
# Host test for gwmon (issue #6). Runs gwmon on this machine against a FAKE watchdog: a regular
# file in a temporary directory, so no real /dev/watchdog is ever opened and nothing can reset the
# host. Each feed appends a NUL byte to that file and the magic close appends 'V', so the file
# shows exactly what a real watchdog would have been told.
#
#   ./test/host-test.sh [path-to-gwmon]      plain run
#   VALGRIND=1 ./test/host-test.sh           gwmon runs under Valgrind; leaks and errors fail the test
#   GWMON_TEST_PORT=19000                    TCP port to use (default 19000)
#
# Needs bash and an OpenBSD-style nc. What this cannot test is listed in docs/issue6-gwmon.md:
# the real watchdog driver, the reset after kill -9, and the Buildroot package.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #6): TODO(issue-6-session-link)

set -u

GWMON=${1:-./gwmon}
PORT=${GWMON_TEST_PORT:-19000}
TMP=$(mktemp -d)
FAKE=$TMP/fake-watchdog
FAILS=0
PID=""

RUN=()
if [ "${VALGRIND:-0}" = 1 ]; then
	# One log file per process: in daemon mode the forked child is a second Valgrind process.
	RUN=(valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=all
		--track-fds=yes --error-exitcode=99 "--log-file=$TMP/valgrind.%p.log")
	valgrind --version
fi

cleanup() {
	[ -n "$PID" ] && kill -KILL "$PID" 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
check() { # check DESCRIPTION COMMAND...
	local what=$1
	shift
	if "$@"; then pass "$what"; else fail "$what"; fi
}

status() { nc -w 5 127.0.0.1 "$PORT" </dev/null; }

wait_for_port() {
	local n=0
	while ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
		n=$((n + 1))
		[ $n -gt 100 ] && return 1
		sleep 0.1
	done
}

wait_for_exit() { # wait_for_exit PID: for a process that is not a child of this shell
	local n=0
	while kill -0 "$1" 2>/dev/null; do
		n=$((n + 1))
		[ $n -gt 100 ] && return 1
		sleep 0.1
	done
}

# Sizes and contents of the fake watchdog file.
fake_size() { stat -c %s "$FAKE"; }
fake_last_byte() { tail -c 1 "$FAKE"; }
fake_non_nul_before_last() { head -c -1 "$FAKE" | tr -d '\0' | wc -c; }

LINE_RE='^gwmon [0-9]+\.[0-9]+\.[0-9]+ uptime=[0-9]+s daemon_uptime=[0-9]+s watchdog=fake wd_timeout=5s wd_interval=1s wd_feeds=[0-9]+ wd_last_feed_age=[0-9]+s$'

start_foreground() { # start_foreground EXTRA_ARGS...
	: > "$FAKE"
	"${RUN[@]}" "$GWMON" -p "$PORT" -t 5 -i 1 "$@" 2>"$TMP/stderr.log" &
	PID=$!
	wait_for_port
}

show_logs() {
	sed 's/^/    | /' "$TMP/stderr.log"
	for f in "$TMP"/valgrind.*.log; do
		[ -f "$f" ] || continue
		echo "    --- Valgrind log"
		sed 's/^/    | /' "$f"
		rm -f "$f"
	done
}

echo "== gwmon host test: $("$GWMON" -v), port $PORT, fake watchdog $FAKE"

echo "== 1. Foreground, status line, clean stop with SIGTERM"
check "gwmon starts and listens" start_foreground -w "$FAKE"
line=$(status)
echo "    status: $line"
check "status line has version, uptime and watchdog state" grep -Eq "$LINE_RE" <<<"$line"

for i in 1 2 3 4 5; do status >"$TMP/client.$i" & CLIENTS[$i]=$!; done
for i in 1 2 3 4 5; do wait "${CLIENTS[$i]}"; done
ok=0
for i in 1 2 3 4 5; do grep -Eq "$LINE_RE" "$TMP/client.$i" && ok=$((ok + 1)); done
check "five clients at once each get a status line ($ok/5)" [ "$ok" = 5 ]

line=$(echo "hello" | nc -w 5 127.0.0.1 "$PORT")
check "a client that sends data still gets the status line" grep -Eq "$LINE_RE" <<<"$line"

sleep 3.5 # at least three more timer feeds at -i 1
feeds=$(status | sed -n 's/.* wd_feeds=\([0-9]*\) .*/\1/p')
check "the watchdog is fed on the timer (wd_feeds=$feeds)" [ "${feeds:-0}" -ge 4 ]

kill -TERM "$PID"
wait "$PID"
rc=$?
PID=""
check "exit status 0 after SIGTERM (got $rc)" [ "$rc" = 0 ]
check "the last byte written to the watchdog is the magic 'V'" [ "$(fake_last_byte)" = V ]
check "every byte before it is a NUL keepalive ($(fake_size) bytes in total)" [ "$(fake_non_nul_before_last)" = 0 ]
check "the syslog output reports the magic close" grep -q "magic close after" "$TMP/stderr.log"
show_logs

echo "== 2. Clean stop with SIGINT"
check "gwmon starts and listens" start_foreground -w "$FAKE"
kill -INT "$PID"
wait "$PID"
rc=$?
PID=""
check "exit status 0 after SIGINT (got $rc)" [ "$rc" = 0 ]
check "the last byte written to the watchdog is the magic 'V'" [ "$(fake_last_byte)" = V ]
show_logs

echo "== 3. kill -9: no magic close, so a real watchdog would reset the board"
check "gwmon starts and listens" start_foreground -w "$FAKE"
sleep 1.5
kill -KILL "$PID"
wait "$PID" 2>/dev/null
PID=""
check "the watchdog was fed before the kill ($(fake_size) bytes)" [ "$(fake_size)" -ge 1 ]
check "no 'V' was written" [ "$(tr -d '\0' <"$FAKE" | wc -c)" = 0 ]
rm -f "$TMP"/valgrind.*.log # a killed process has no leak report

echo "== 4. Daemon mode (-d)"
: > "$FAKE"
"${RUN[@]}" "$GWMON" -d -p "$PORT" -t 5 -i 1 -w "$FAKE" 2>"$TMP/stderr.log"
rc=$?
check "gwmon -d returns 0 to the caller (got $rc)" [ "$rc" = 0 ]
check "the daemon listens" wait_for_port
DPID=$(pgrep -f -- "-d -p $PORT -t 5 -i 1 -w $FAKE" | head -n 1)
PID=$DPID
check "the daemon is running (pid ${DPID:-none}) and is a session leader" \
	[ -n "$DPID" -a "$(ps -o sid= -p "${DPID:-0}" 2>/dev/null | tr -d ' ')" = "${DPID:-x}" ]
line=$(status)
echo "    status: $line"
check "the daemon answers with a status line" grep -Eq "$LINE_RE" <<<"$line"
kill -TERM "$DPID"
check "the daemon exits after SIGTERM" wait_for_exit "$DPID"
PID=""
check "the last byte written to the watchdog is the magic 'V'" [ "$(fake_last_byte)" = V ]
if [ "${VALGRIND:-0}" = 1 ]; then
	bad=$(grep -L "ERROR SUMMARY: 0 errors" "$TMP"/valgrind.*.log | wc -l)
	check "Valgrind reports no errors in the daemon and its parent" [ "$bad" = 0 ]
fi
show_logs

echo "== 5. Start failures and watchdog states"
check "gwmon starts and listens" start_foreground -w none
line=$(status)
echo "    status: $line"
check "-w none reports watchdog=disabled" grep -Eq ' watchdog=disabled$' <<<"$line"
"${RUN[@]}" "$GWMON" -p "$PORT" -w none 2>/dev/null
rc=$?
check "a second gwmon on the same port fails to start (exit status $rc)" [ "$rc" = 1 ]
kill -TERM "$PID"; wait "$PID"; PID=""
show_logs

check "gwmon starts and listens" start_foreground -w "$TMP/no-such-device"
line=$(status)
echo "    status: $line"
check "a missing device reports watchdog=unavailable" grep -Eq ' watchdog=unavailable$' <<<"$line"
check "gwmon did not create the missing device" [ ! -e "$TMP/no-such-device" ]
kill -TERM "$PID"; wait "$PID"; rc=$?; PID=""
check "exit status 0 after SIGTERM (got $rc)" [ "$rc" = 0 ]
show_logs

"$GWMON" -t 5 -i 5 -w none 2>/dev/null
check "an interval that is not below the timeout is rejected" [ $? = 1 ]

echo
if [ "$FAILS" = 0 ]; then
	echo "RESULT: all checks passed$([ "${VALGRIND:-0}" = 1 ] && echo ' under Valgrind')"
	exit 0
fi
echo "RESULT: $FAILS check(s) FAILED"
exit 1
