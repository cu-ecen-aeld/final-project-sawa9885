#!/bin/bash
# Host test for gwmon (issues #6 and #7). Runs gwmon on this machine against a FAKE watchdog: a
# regular file in a temporary directory, so no real /dev/watchdog is ever opened and nothing can
# reset the host. Each feed appends a NUL byte to that file and the magic close appends 'V', so
# the file shows exactly what a real watchdog would have been told.
#
# Sections 6 to 10 (issue #7) test the supervision with a FAKE station: a shell script that the
# test writes. A mode file tells it what to do at each start: run until it is killed, exit with
# status 1, or exit with status 78 ("nothing to run"). The uplink count is tested with lines
# appended to a fake Station log, and the temperature with a text file in place of the I2C bus.
#
#   ./test/host-test.sh [path-to-gwmon]      plain run
#   VALGRIND=1 ./test/host-test.sh           gwmon runs under Valgrind; leaks and errors fail the test
#   GWMON_TEST_PORT=19000                    TCP port to use (default 19000)
#
# Needs bash and an OpenBSD-style nc. What this cannot test is listed in docs/issue6-gwmon.md and
# docs/issue7-gwmon-v2.md: the real watchdog driver and the reset it causes, the real Station, the
# STTS751 sensor, and the Buildroot package.
#
# This file was partially generated using Claude Code using the chat sessions at:
# Link to chat session (issue #6): https://claude.ai/code/cshk_01CSAPnx7BhY3Nsk5bW261b3NkPKAXvdTJyxZN6b8vcSPT
# Link to chat session (issue #7): https://claude.ai/code/cshk_01CSAPnyUYrsMvoThgHLYdiX7npiZ7nu2SeVLaZKVhC3Lx

set -u

GWMON=${1:-./gwmon}
PORT=${GWMON_TEST_PORT:-19000}
TMP=$(mktemp -d)
FAKE=$TMP/fake-watchdog
FAILS=0
PID=""
SPID="" # the fake station, when a test has to clean it up itself

# The fake station and its files (sections 6 to 10).
STATION=$TMP/fake-station
MODE=$TMP/station-mode       # run | fail | unconfigured, read by the fake station at each start
STARTS=$TMP/station-starts   # one line per start: "<pid> <seconds since the epoch>"
READY=$TMP/station-ready     # its pid, once the fake station has set its SIGTERM trap
SIGNALS=$TMP/station-signals # "TERM" for each SIGTERM the fake station caught
SLOG=$TMP/station.log        # stands in for /var/log/station.log
TEMPF=$TMP/temperature       # stands in for the I2C bus of the temperature sensor

RUN=()
if [ "${VALGRIND:-0}" = 1 ]; then
	# One log file per process: in daemon mode the forked child is a second Valgrind process.
	# --child-silent-after-fork: the forked child that execs the fake station (or fails to) is
	# not a gwmon run of its own and must not write a report into its parent's log.
	RUN=(valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=all
		--track-fds=yes --error-exitcode=99 --child-silent-after-fork=yes
		"--log-file=$TMP/valgrind.%p.log")
	valgrind --version
fi

cleanup() {
	[ -n "$PID" ] && kill -KILL "$PID" 2>/dev/null
	[ -n "$SPID" ] && kill -KILL "$SPID" 2>/dev/null
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
		VG_LOGS=$((VG_LOGS + 1))
		grep -q "ERROR SUMMARY: 0 errors" "$f" || fail "Valgrind reports errors (log below)"
		echo "    --- Valgrind log"
		sed 's/^/    | /' "$f"
		rm -f "$f"
	done
}

VG_LOGS=0

# ---- helpers for the supervision tests

field() { # field NAME: the value of NAME= in the status line on stdin
	sed -n "s/.* $1=\([^ ]*\).*/\1/p"
}

wait_status() { # wait_status REGEX SECONDS: poll the status line until it matches
	local n=0 limit=$(($2 * 5))
	until status | grep -Eq "$1"; do
		n=$((n + 1))
		[ $n -ge $limit ] && return 1
		sleep 0.2
	done
}

uplink_line() { # uplink_line FCNT: a line as Station logs it for a received frame
	echo "2026-11-18 20:00:0$1.000 [S2E:VERB] RX 902.3MHz DR3 SF7/BW125 snr=9.8 rssi=-82 xtime=0x8200004F6BEAB4 - updf mhdr=80 DevAddr=00BC32BD FCtrl=82 FCnt=$1 FOpts=[] 0D mic=1 (15 bytes)"
}

make_fake_station() {
	cat >"$STATION" <<EOF
#!/bin/bash
# Fake Basics Station for the gwmon host test, written by host-test.sh.
echo "\$\$ \$(date +%s.%N)" >>"$STARTS"
case "\$(cat "$MODE" 2>/dev/null)" in
	fail) exit 1 ;;
	unconfigured) exit 78 ;;
esac
trap 'echo TERM >>"$SIGNALS"; exit 143' TERM
echo \$\$ >>"$READY"
while :; do sleep 0.2; done
EOF
	chmod +x "$STATION"
}

station_ready() { # station_ready PID: wait until that fake station catches SIGTERM
	local n=0
	until grep -qx "$1" "$READY" 2>/dev/null; do
		n=$((n + 1))
		[ $n -gt 50 ] && return 1
		sleep 0.1
	done
}

reset_station_files() {
	rm -f "$STARTS" "$READY" "$SIGNALS" "$SLOG" "$SLOG.1"
	echo run >"$MODE"
	echo 27.5 >"$TEMPF"
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

V1_RE=${LINE_RE%\$} # the version 1 fields, without the end-of-line anchor
SUP_ARGS=(-w "$FAKE" -s "$STATION" -l "$SLOG" -T "$TEMPF")
gone() { ! kill -0 "$1" 2>/dev/null; }
stop_gwmon() { # SIGTERM, then the two checks every clean stop has to pass
	kill -TERM "$PID"
	wait "$PID"
	rc=$?
	PID=""
	check "exit status 0 after SIGTERM (got $rc)" [ "$rc" = 0 ]
	check "the last byte written to the watchdog is the magic 'V'" [ "$(fake_last_byte)" = V ]
}

echo "== 6. Supervision: the station is started, its exit is seen and it is restarted (issue #7)"
make_fake_station
reset_station_files
{ uplink_line 1; uplink_line 2; } >"$SLOG" # written "before gwmon started": must not be counted
check "gwmon starts and listens" start_foreground "${SUP_ARGS[@]}" -S 3
check "gwmon has started the fake station" wait_status ' station=running ' 5
line=$(status)
echo "    status: $line"
check "the status line keeps the version 1 fields and adds station, uplinks and temp" grep -Eq \
	"$V1_RE station=running station_pid=[0-9]+ station_uptime=[0-9]+s station_restarts=0 station_fails=0 uplinks=0 last_uplink_age=never temp=27\.5C\$" <<<"$line"

{ uplink_line 3; echo "2026-11-18 20:00:04.000 [SYN:INFO] Time sync qualities: min=166 q90=170 max=171"; uplink_line 4; uplink_line 5; } >>"$SLOG"
check "three uplink lines (and one other line) added to the log: uplinks=3" wait_status ' uplinks=3 last_uplink_age=[0-3]s ' 5
uplink_line 6 | cut -c1-60 | tr -d '\n' >>"$SLOG"
sleep 1.5
uplink_line 6 | cut -c61- >>"$SLOG"
check "a line that arrives in two parts is counted once: uplinks=4" wait_status ' uplinks=4 ' 5
uplink_line 7 >>"$SLOG"
mv "$SLOG" "$SLOG.1"
{ uplink_line 8; uplink_line 9; } >"$SLOG"
check "log rotation: the old file is read to its end, the new one from its start: uplinks=7" wait_status ' uplinks=7 ' 5

echo -3.5 >"$TEMPF"
check "a new temperature is reported: temp=-3.5C" wait_status ' temp=-3\.5C$' 5
: >"$TEMPF"
check "a temperature that cannot be read is reported: temp=unavailable" wait_status ' temp=unavailable$' 5
echo 27.5 >"$TEMPF"

check "the station has run for 3 s, the -S limit" wait_status ' station_uptime=([3-9]|[0-9]{2,})s ' 10
old=$(status | field station_pid)
kill -KILL "$old"
t0=$(date +%s.%N)
back=1
wait_status ' station=running station_pid=[0-9]+ station_uptime=[0-9]+s station_restarts=1 station_fails=0 ' 5 && back=0
elapsed=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
line=$(status)
echo "    status: $line"
new=$(field station_pid <<<"$line")
check "after kill -9 the station is running again within 5 s ($elapsed s), station_restarts=1" [ "$back" = 0 ]
check "it is a new process (pid $old, now $new)" [ -n "$new" -a "$new" != "$old" ]
check "the exit is in the syslog output" grep -q "station (pid $old) was killed by signal 9" "$TMP/stderr.log"
check "the delay after a run longer than -S is 1 s" grep -q "restarting station in 1 s\$" "$TMP/stderr.log"
check "the restart is in the syslog output" grep -q "station restart 1: started $STATION, pid $new" "$TMP/stderr.log"

# A run that ends before the -S limit is a failed start. The count is 0 again once a run reaches -S.
station_ready "$new"
kill -KILL "$new"
check "a station killed before the -S limit is a failed start: station_fails=1" wait_status \
	' station=running .* station_restarts=2 station_fails=1 ' 5
check "the delay after one failed start is 2 s" grep -q "restarting station in 2 s (failed start 1 of 5)\$" "$TMP/stderr.log"
check "station_fails is 0 again once the station has run for 3 s" wait_status \
	' station_uptime=[3-9]s station_restarts=2 station_fails=0 ' 6
new=$(status | field station_pid)

station_ready "$new"
stop_gwmon
check "gwmon stopped the station with SIGTERM" grep -q TERM "$SIGNALS"
check "the station is gone" gone "$new"
show_logs

echo "== 7. Five failed starts in a row: backoff, then gwmon stops feeding the watchdog"
reset_station_files
check "gwmon starts and listens" start_foreground "${SUP_ARGS[@]}" -S 2
check "the station has run for 2 s, the -S limit" wait_status ' station=running .* station_uptime=([2-9]|[0-9]{2,})s ' 10
echo fail >"$MODE" # from now on the fake station exits with status 1 as soon as it is started
kill -KILL "$(status | field station_pid)"
tkill=$(date +%s.%N)
check "gwmon gives up: station=failed (31 s of delays)" wait_status ' station=failed ' 60
line=$(status)
echo "    status: $line"
check "the status shows 5 restarts, 5 failed starts and a starving watchdog" grep -Eq \
	' watchdog=starving .* station=failed station_pid=0 station_uptime=0s station_restarts=5 station_fails=5 ' <<<"$line"
# Delay before each restart: from the kill to the 1st restart, then from one start to the next.
gaps=$(awk -v t0="$tkill" 'NR > 1 { printf "%.1f ", $2 - prev; prev = $2 } NR == 1 { prev = t0 }' "$STARTS")
gaps_ok() {
	awk -v t0="$tkill" 'BEGIN { split("1 2 4 8 16", want, " "); ok = 1 }
		NR == 1 { prev = t0 }
		NR > 1 { gap = $2 - prev; prev = $2; if (gap < want[NR - 1] - 0.3 || gap > want[NR - 1] + 2.5) ok = 0 }
		END { exit !(ok && NR == 6) }' "$STARTS"
}
check "the delays before the 5 restarts are 1, 2, 4, 8 and 16 s (measured: ${gaps% } s)" gaps_ok
check "every failed start is in the syslog output" [ "$(grep -c "exited with status 1 after" "$TMP/stderr.log")" = 5 ]
check "every restart is in the syslog output" [ "$(grep -c "station restart [0-9]*: started" "$TMP/stderr.log")" = 5 ]
check "giving up is in the syslog output" grep -q "station failed 5 starts in a row: giving up" "$TMP/stderr.log"
size1=$(fake_size)
sleep 2.5
size2=$(fake_size)
check "the watchdog is no longer fed ($size1 bytes, and $size2 bytes 2.5 s later)" [ "$size1" = "$size2" ]
check "the fake station is not started again" [ "$(wc -l <"$STARTS")" = 6 ]
stop_gwmon
show_logs

echo "== 8. A station with nothing to run (exit status 78) is not restarted and does not stop the feeds"
reset_station_files
echo unconfigured >"$MODE"
check "gwmon starts and listens" start_foreground "${SUP_ARGS[@]}"
check "station=unconfigured, no restart, no failed start" wait_status \
	' station=unconfigured station_pid=0 station_uptime=0s station_restarts=0 station_fails=0 ' 5
feeds1=$(status | field wd_feeds)
sleep 3.2
line=$(status)
echo "    status: $line"
feeds2=$(field wd_feeds <<<"$line")
check "the watchdog is still fed (wd_feeds $feeds1, then $feeds2)" [ "${feeds2:-0}" -gt "${feeds1:-0}" ]
check "the state is still unconfigured and the watchdog is not starving" grep -Eq ' watchdog=fake .* station=unconfigured ' <<<"$line"
check "the station was started once only" [ "$(wc -l <"$STARTS")" = 1 ]
stop_gwmon
show_logs

echo "== 9. A program that cannot be run counts as a failed start (-r 2)"
check "gwmon starts and listens" start_foreground -w "$FAKE" -s "$TMP/no-such-program" -r 2
check "station=failed after 2 failed starts and 1 restart" wait_status ' station=failed .* station_restarts=1 station_fails=2$' 10
echo "    status: $(status)"
check "the exit status is in the syslog output" grep -Eq "station \(pid [0-9]+\) exited with status [0-9]+ after 0 s" "$TMP/stderr.log"
stop_gwmon
show_logs

echo "== 10. kill -9 of gwmon: the station does not outlive it"
reset_station_files
check "gwmon starts and listens" start_foreground "${SUP_ARGS[@]}"
check "gwmon has started the fake station" wait_status ' station=running ' 5
SPID=$(status | field station_pid)
station_ready "$SPID"
kill -KILL "$PID"
wait "$PID" 2>/dev/null
PID=""
check "the station (pid $SPID) exits when gwmon is killed" wait_for_exit "$SPID"
check "it was ended by SIGTERM (PR_SET_PDEATHSIG)" grep -q TERM "$SIGNALS"
SPID=""
check "no 'V' was written" [ "$(tr -d '\0' <"$FAKE" | wc -c)" = 0 ]
rm -f "$TMP"/valgrind.*.log # a killed process has no leak report

[ "${VALGRIND:-0}" = 1 ] && echo && echo "Valgrind logs checked: $VG_LOGS"
echo
if [ "$FAILS" = 0 ]; then
	echo "RESULT: all checks passed$([ "${VALGRIND:-0}" = 1 ] && echo ' under Valgrind')"
	exit 0
fi
echo "RESULT: $FAILS check(s) FAILED"
exit 1
