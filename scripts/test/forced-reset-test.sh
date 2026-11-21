#!/bin/bash
#
# Issue #14: forced resets of the gateway at random moments, from the PC over SSH.
#
#   scripts/test/forced-reset-test.sh <pi-address> [count] [known_hosts file]
#
# Each reset is "echo b > /proc/sysrq-trigger": the kernel restarts the board at once, with no
# shutdown, no unmount and no sync, so whatever was in flight to the SD card is lost, as in a
# power cut. (It does not cut power to the card itself; the one real power pull covers that.)
#
# The moments, in this order (count 10):
#   1-3   "boot"       as soon as SSH answers, about 5 s into the boot: S00datafs has just
#                      mounted /data, S35provision ran, Station has not started yet
#   4-6   "starting"   3-20 s after SSH answers (random): Station resets the radio, waits for the
#                      clock, talks to CUPS and writes its -bak credential files
#   7-10  "connected"  5-60 s after Station connected (random)
#
# Before a "boot" or "starting" reset the Pi is rebooted cleanly, to have a fresh boot to cut.
# After every reset it waits for SSH (180 s at most) and for "Connected to MUXS" in Station's
# log (300 s at most), then records: how / , /data and /boot are mounted, /run/datafs.status,
# and every dmesg line that reports a filesystem or SD card error (the same list as boot-report).
# A reset passes when the Pi comes back, / is ro, /data is rw with status ok or repaired, Station
# reconnects, and there is no error line. Nothing secret is printed: mounts, a status word, dmesg
# lines and /data/log/boots.csv.
#
# Exit status: 0 all passed, 1 at least one failed.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #14): https://claude.ai/code/cshk_01CSAPnw8JdnxyUhwWGJBPcSLfcF3QEhzhBNyWzKEnnQbG

PI=${1:?usage: $0 <pi-address> [count] [known_hosts]}
COUNT=${2:-10}
KH=${3:-$HOME/.ssh/known_hosts}
KEY=${AESD_SSH_KEY:-$HOME/.ssh/aesd_pi5_ed25519}

FS_ERR='EXT4-fs error|EXT4-fs warning|EXT4-fs \(.*\): (corrupt|bad|failed)|FAT-fs .*(error|corrupt|invalid|not properly unmounted)|JBD2.*(error|abort)|Buffer I/O error|I/O error, dev mmcblk|mmc[0-9]+: .*(error|timeout)|Remounting filesystem read-only'

ssh_pi() {
	ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=2 \
		-o ServerAliveCountMax=2 -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=accept-new \
		-o LogLevel=ERROR "root@$PI" "$@"
}

log() {
	echo "$(date -u +%H:%M:%S) $*"
}

# wait_for MAX CMD...: run CMD every 2 s until it succeeds; print the seconds it took.
wait_for() {
	max=$1; shift
	start=$SECONDS
	while [ $((SECONDS - start)) -lt "$max" ]; do
		"$@" >/dev/null 2>&1 && { echo $((SECONDS - start)); return 0; }
		sleep 2
	done
	return 1
}

connected() {
	ssh_pi "grep -q 'Connected to MUXS' /var/log/station.log"
}

# The Pi stays up until it resets, so the SSH session is cut, not ended: give it 5 s.
reset_now() {
	ssh_pi 'echo b > /proc/sysrq-trigger' >/dev/null 2>&1 &
	pid=$!
	sleep 5
	kill $pid 2>/dev/null
	wait $pid 2>/dev/null
}

# Prints the state and returns 0 if it passes.
check() {
	out=$(ssh_pi "mount | grep -E ' on (/|/data|/boot) type '; echo status=\$(cat /run/datafs.status 2>/dev/null)
		echo errors:; dmesg | grep -E -i '$FS_ERR'; echo end
		dmesg | grep -q 'EXT4-fs (mmcblk0p3): recovery complete' && echo journal=replayed || echo journal=-")
	echo "$out" | sed 's/^/    /'
	echo "$out" | grep -q ' on / type ext4 (ro' || return 1
	echo "$out" | grep -q ' on /data type ext4 (rw' || return 1
	echo "$out" | grep -q -E '^status=(ok|repaired)$' || return 1
	# Nothing between "errors:" and "end".
	[ "$(echo "$out" | sed -n '/^errors:$/,/^end$/p' | wc -l)" -eq 2 ] || return 1
	return 0
}

fail=0
log "forced-reset test on $PI, $COUNT resets"
log "baseline"
wait_for 10 ssh_pi true >/dev/null || { log "FAIL: no SSH to $PI"; exit 1; }
check || { log "FAIL: baseline does not pass"; fail=1; }
ssh_pi 'tail -n 3 /data/log/boots.csv' | sed 's/^/    /'

for i in $(seq 1 "$COUNT"); do
	if [ "$i" -le 3 ]; then
		phase=boot; delay=0
	elif [ "$i" -le 6 ]; then
		phase=starting; delay=$((3 + RANDOM % 18))
	else
		phase=connected; delay=$((5 + RANDOM % 56))
	fi

	# Get to the moment. "boot" and "starting" need a fresh boot: a clean reboot first (not a
	# test reset), then the reset at SSH + delay. "connected": Station is connected already.
	if [ "$phase" = connected ]; then
		wait_for 300 connected >/dev/null || { log "reset $i: Station not connected before the reset"; fail=1; }
	else
		ssh_pi 'reboot' >/dev/null 2>&1
		sleep 6
		wait_for 180 ssh_pi true >/dev/null || { log "reset $i: no SSH after the clean reboot"; fail=1; continue; }
	fi
	sleep "$delay"
	log "reset $i ($phase, +${delay} s)"
	reset_now

	# The board takes a few seconds to go down; do not mistake the old SSH server for the new one.
	sleep 4
	if ! ssh_s=$(wait_for 180 ssh_pi true); then
		log "reset $i: FAIL, no SSH after 180 s"
		fail=1
		continue
	fi
	uptime=$(ssh_pi "cut -d' ' -f1 /proc/uptime")
	log "reset $i: SSH back after ~$((ssh_s + 9)) s (uptime $uptime s)"
	if st_s=$(wait_for 300 connected); then
		log "reset $i: Station connected $st_s s after SSH"
	else
		log "reset $i: FAIL, Station not connected 300 s after SSH"
		fail=1
	fi
	if check; then
		log "reset $i: PASS"
	else
		log "reset $i: FAIL"
		fail=1
	fi
done

log "boots.csv at the end"
ssh_pi 'cat /data/log/boots.csv; ls /data/log' | sed 's/^/    /'
[ $fail -eq 0 ] && log "ALL PASSED" || log "SOME FAILED"
exit $fail
