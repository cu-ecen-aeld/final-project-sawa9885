# Issue #7: gwmon v2, Basics Station supervision and gateway health

`gwmon` now starts LoRa Basics Station itself, restarts it when it exits, and adds gateway health to the status line on port 9000. These are the results for the issue's definition of done, measured on the Pi 5 on 2026-11-19 UTC (the evening of 2026-11-18 local time) with the code of commit `ab08d87`.

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #7): https://claude.ai/code/cshk_01CSAPnyUYrsMvoThgHLYdiX7npiZ7nu2SeVLaZKVhC3Lx -->

| Definition of done (issue #7) | Result |
|---|---|
| gwmon starts `station`, sees it exit within 5 s, and restarts it with backoff. After `kill -9 $(pidof station)`, Station is back and connected to AWS within 60 s | **Pass.** gwmon logged the exit in the same second, started Station again 1 s later, and Station logged `Connected to MUXS.` 3.4 s after the kill. The backoff delays measured on the Pi were 1, 2, 4, 8 and 16 s |
| Each restart is logged to syslog | **Pass.** One line for the exit, one for the delay and one for the restart, with its number |
| If Station can't be restarted after 5 tries, gwmon stops feeding the watchdog and the Pi reboots | **Pass.** After the 5th failed start gwmon logged that it gives up, 38 s after the kill. The Pi reset 10 s later and came back by itself with Station connected |
| `nc <pi-address> 9000` also reports uplinks received, time since the last uplink, concentrator temperature and the Station restart count | **Pass.** Three uplinks from the test node: `uplinks` went 0, 1, 2, 3, the same as the `RX` lines in Station's log, with `last_uplink_age` counting from each one. `temp=29.9C`, and `station_restarts` went from 0 to 1 at the `kill -9` |
| Only gwmon's init script starts Station. Station's own init script is removed | **Pass.** `S60station` is gone from the package, from the built image and from the Pi. Station's parent process is gwmon, at boot and after every restart |

Two things to know about these results:

- **The SD card was not reflashed.** The card holds the image flashed for issue #4 with the issue #6 files. Four files from this branch's Buildroot build were copied to it over SSH (`/usr/bin/gwmon`, `/usr/bin/station-run.sh`, `/etc/init.d/S99gwmon`, `/etc/station/station.conf`), and `/etc/init.d/S60station` was deleted by hand. The SHA-256 of each file on the Pi equals that of the same file inside the new `rootfs.ext2`, and `/usr/bin/station` is the same binary in both. The image itself (`sdcard.img`, SHA-256 `3115d14c…b005`) was built but has not been booted.
- **"Connected to AWS" is taken from Station's log**, the line `Connected to MUXS.` followed by `Concentrator started`. The AWS console was not checked.

## Design

### Supervision

gwmon gets one new option for this, `-s program`. It starts the program as a child process and keeps it running. The program is `/usr/bin/station-run.sh`, which ends by exec'ing `station`, so the process gwmon started becomes Station itself.

- **One loop.** The key property of version 1 is kept: the watchdog is fed from the same `ppoll()` loop that serves the status port. The supervision is in that loop too and never waits for the child. `fork()` and `exec` return at once. The child's exit arrives as SIGCHLD, which ends the `ppoll()` wait, and `waitpid(WNOHANG)` then reads the exit status. The delay before a restart is a one-shot `timerfd` in the same `ppoll()` set. SIGCHLD is blocked except during `ppoll()`, like SIGINT and SIGTERM, so an exit cannot be missed between the check and the wait.
- **Backoff.** After a run of 30 s or more, Station is started again after 1 s. A start that ends in less than 30 s counts as failed, and the delay doubles with each failed start in a row: 2, 4, 8, 16 s. The count goes back to 0 at the next exit that follows a run of 30 s or more.
- **Giving up.** The 5th failed start in a row ends the supervision. gwmon logs it at level `crit`, reports `station=failed watchdog=starving`, and stops feeding the watchdog. It keeps answering on port 9000 until the watchdog resets the board, at most 10 s later. A clean `S99gwmon stop` in that window still closes the watchdog properly.
- **Nothing to run.** Exit status 78 (`EX_CONFIG` in `sysexits.h`) from the child means "there is nothing to run". `station-run.sh` exits with it when `/etc/station` has no `cups.uri` or `tc.uri`. gwmon then reports `station=unconfigured`, does not restart the child, does not count a failure, and keeps feeding the watchdog. A gateway without credentials stays up and reachable.
- **The child process.** It runs in a process group of its own, with the default signal dispositions and an empty signal mask. `PR_SET_PDEATHSIG` makes the kernel send it SIGTERM if gwmon dies, so no Station outlives its supervisor. The watchdog, the sockets and the timers are opened with close-on-exec, so Station inherits none of them.
- **Stopping.** On SIGTERM or SIGINT gwmon closes the watchdog with the magic close first, then sends SIGTERM to Station's process group and waits up to 5 s before it uses SIGKILL. Station ends on SIGTERM in well under a second.
- **Options.** `-r count` sets the number of failed starts (default 5) and `-S seconds` the length of a run that is not a failure (default 30). The host test uses them to keep its run short.

### What replaced `S60station`

`S60station` did three things besides starting Station. They are now in `station-run.sh`, which gwmon runs before every start:

1. With no `cups.uri` or `tc.uri` it logs one line and exits with status 78 (see above).
2. It reads the SX1302's EUI with `util_chip_id` and writes it to `/var/run/station.eui`. If the concentrator does not answer, it exits with status 1, which gwmon counts as a failed start.
3. It waits up to 60 s for chronyd to set the clock, then execs `station --home /etc/station`.

Station runs without `--daemon` now: one foreground process whose parent is gwmon. With `--daemon`, Station forks a daemon of its own that restarts its worker, which would hide every exit from gwmon. Station still writes `/var/log/station.log` itself.

`S99gwmon` builds the command line: `gwmon -d -s /usr/bin/station-run.sh -l /var/log/station.log -T /dev/i2c-1`. A file named `gwmon.disable` on the boot partition still keeps gwmon off, and now Station with it.

### Where the new status fields come from, and their limits

```
gwmon 2.0.0 uptime=1234s daemon_uptime=1200s watchdog=active wd_timeout=10s wd_interval=2s wd_feeds=600 wd_last_feed_age=1s station=running station_pid=301 station_uptime=1190s station_restarts=0 station_fails=0 uplinks=12 last_uplink_age=37s temp=31.5C
```

The version 1 fields come first and are unchanged. Each new group appears only when its option is given (`-s`, `-l`, `-T`), so `gwmon` without them prints the version 1 line.

| Field | Source | Limits |
|---|---|---|
| `station` | gwmon's supervisor state: `running`, `backoff`, `failed`, `unconfigured`, `off` | `running` means the process exists. It does not say that Station is connected to AWS, and a Station that hangs without exiting is not noticed |
| `station_pid`, `station_uptime` | The child's PID, and the time since gwmon started it | The time includes what `station-run.sh` does first: about 1.5 s for the EUI, and up to 60 s waiting for the clock at boot |
| `station_restarts` | A counter in gwmon: starts after the first one | Since gwmon started. It is 0 again after a reboot or `S99gwmon restart`. A restart that fails at once is counted too |
| `station_fails` | A counter in gwmon: starts in a row that ended within 30 s | A restarted Station still shows the old count during its first 30 s, then 0 |
| `uplinks` | The number of lines with `[S2E:VERB] RX ` that gwmon has read from `/var/log/station.log`. Station writes one such line for each received frame that passes its frame checks and that it hands to the network server connection (`s2e_flushRxjobs()` in Station's `s2e.c`) | Since gwmon started; lines already in the log at that time are skipped. Needs the `S2E` module at log level `VERBOSE`, which `station.conf` now sets; at `INFO` the count stays 0. It counts frames from every LoRaWAN device in range, not only ours. A frame that Station receives while the server connection is down is logged when Station passes it on, not when it arrives. `uplinks=unavailable` until the log file exists |
| `last_uplink_age` | The time since gwmon read the last of those lines (`CLOCK_MONOTONIC`) | gwmon reads the log every 2 s (the feed interval), so the age can be up to 2 s short. `never` until the first line |
| `temp` | The ST STTS751 temperature sensor on the WM1302, at address 0x39 on `/dev/i2c-1`. gwmon reads registers 0x00 and 0x02 every 2 s. It is the sensor that the HAL inside Station reads for its RSSI temperature compensation (`found temperature sensor on port 0x39` in Station's log) | It is the temperature of the concentrator board next to the SX1302, not of the chip itself. The resolution is 1/16 °C with the 12-bit setting that the HAL writes when Station starts (configuration register 0x8C, read on the board), and the field shows one decimal. No reference thermometer was used, so its accuracy is the sensor's own. `temp=unavailable` when a read fails or no STTS751 answers |

gwmon and Station share the sensor. gwmon never writes to it, so the HAL's configuration is left alone. Each register read is one combined I2C transfer (`I2C_RDWR`: write the register number, read one byte), which is also how the HAL reads, so the two cannot mix up each other's steps. gwmon reads the integer register before and after the fraction register and uses the value only when both integer reads agree.

The log is read with plain `read()` calls on the open file, at most 1 MiB per pass. Station rotates its log by renaming it. gwmon notices that the path names another file, reads the old file to its end and then the new one from its start.

### Limits of the supervision

- **A fault that outlasts a reboot gives a reboot loop.** If Station can never start, for example because the concentrator is dead, every boot ends with the 5 failed starts and a reset, about a minute per cycle. SSH is reachable during each cycle, and `gwmon.disable` on the boot partition stops the loop. gwmon keeps no count across reboots.
- **A slow failure is not a failed start.** A Station that exits after more than 30 s every time is restarted after 1 s each time, without limit and without a reset. Each restart is in syslog and in `station_restarts`.
- **The network is not Station's fault.** With the cable out, Station keeps running and retries by itself (issue #4), so gwmon does nothing. That is intended: a reboot does not bring a network back.

## Results on the Pi

Full output: [logs/issue7-bench-pi.log](logs/issue7-bench-pi.log). Package build and the contents of the image: [logs/issue7-gwmon-buildroot-pkg.log](logs/issue7-gwmon-buildroot-pkg.log).

The Pi is at 192.168.0.123 now (DHCP gave it a new address; it was .103 in issue #6). The status lines were read from a PC on the LAN.

### Started by gwmon, at boot and from the init script (DoD 5)

`/etc/init.d` on the Pi, and the same list inside the new `rootfs.ext2`:

```
S01seedrng S01syslogd S02klogd S02sysctl S10udevd S11modules S35provision S40network S41ifplugd S41wifi S49chronyd S50crond S50dropbear S99gwmon rcK rcS
```

After a boot, `ps` shows Station as a child of gwmon (the second column is the parent's PID), and syslog shows gwmon starting it:

```
  250     1 /usr/bin/gwmon -d -s /usr/bin/station-run.sh -l /var/log/station.log -T /dev/i2c-1
  253   250 /usr/bin/station --home /etc/station

01:05:45 gwmon[250]: watchdog armed: timeout 10 s, fed every 2 s
01:05:45 gwmon[250]: gwmon 2.0.0 started, status on TCP port 9000
01:05:45 gwmon[250]: station started: /usr/bin/station-run.sh, pid 253
01:05:47 station: gateway EUI 0016c001f1135844, starting when the clock is set
01:05:55 ntp-hook: eth0 has a DHCP lease, uptime 13.45 s
01:06:01 station: starting /usr/bin/station, uptime 18.74 s
```

Station logged `Connected to MUXS.` at 01:06:02.0 and `Concentrator started` at 22.3 s of uptime. With `S99gwmon stop` then `start` on a running system, where the clock is already set, the concentrator was started 5.0 s after the start. `stop` took 0.1 s and left neither process behind.

### `kill -9` of Station (DoD 1 and 2)

Station had been running for 35 s. One script on the Pi killed it and watched Station's log:

| Event | Time after the kill |
|---|---|
| gwmon logs the exit and the 1 s delay | same second (syslog has 1 s resolution) |
| gwmon starts `station-run.sh` again | 1 s |
| A new `station` process is running | 2.5 s |
| `Connected to MUXS.` in Station's log | 3.4 s |
| `Concentrator started` in Station's log | 6.0 s |

```
01:03:05 gwmon[420]: station (pid 424) was killed by signal 9 after 35 s
01:03:05 gwmon[420]: restarting station in 1 s
01:03:06 gwmon[420]: station restart 1: started /usr/bin/station-run.sh, pid 660
01:03:07 station: gateway EUI 0016c001f1135844, starting when the clock is set
01:03:07 station: starting /usr/bin/station, uptime 590.22 s

01:03:07.809 [TCE:INFO] Connecting to INFOS: wss://<id>.lns.lorawan.us-east-1.amazonaws.com:443
01:03:08.432 [TCE:VERB] Connected to MUXS.
01:03:11.049 [RAL:INFO] Concentrator started (2s365ms)
```

The status line before and after, shortened to the Station fields:

```
station=running station_pid=424 station_uptime=35s station_restarts=0 station_fails=0
station=running station_pid=660 station_uptime=5s station_restarts=1 station_fails=0
```

### Five failed starts (DoD 3)

To make Station impossible to start without changing the card, a script that only does `exit 1` was bind-mounted over `/usr/bin/station`. A bind mount is gone after a reboot. Then the running Station was killed. A second SSH command printed the uptime every 0.5 s, and the PC read the status line once a second.

| Event | Syslog time (UTC) | After the kill |
|---|---|---|
| `kill -9` of Station, which had run for 35 s | 01:04:46 | 0 |
| restart 1, after the 1 s delay; exits with status 1 | 01:04:47 | 1 s |
| restart 2, `restarting station in 2 s (failed start 1 of 5)` | 01:04:51 | 5 s |
| restart 3, after 4 s | 01:04:56 | 10 s |
| restart 4, after 8 s | 01:05:06 | 20 s |
| restart 5, after 16 s | 01:05:23 | 37 s |
| `station failed 5 starts in a row: giving up. The watchdog is no longer fed and resets the board within 10 s` | 01:05:25 | 38.4 s |
| Last uptime line the Pi printed | | 48.5 s |
| Port 9000 answers again, `uptime=14s` | 01:05:56 | |
| Station logs `Connected to MUXS.` in the new boot | 01:06:02 | |

Each start took about 1.5 s to fail, because `station-run.sh` reads the EUI from the concentrator before it runs `station`. The status line in the last seconds before the reset, and the first one after it:

```
01:05:24  ... watchdog=active ... wd_feeds=37 ... station=running station_pid=1819 station_uptime=0s station_restarts=5 station_fails=4 ...
01:05:25  ... watchdog=starving ... wd_feeds=38 wd_last_feed_age=0s station=failed station_pid=0 station_uptime=0s station_restarts=5 station_fails=5 ...
01:05:35  (no answer on port 9000)
01:05:56  gwmon 2.0.0 uptime=14s daemon_uptime=11s watchdog=active ... station=running station_pid=253 station_uptime=11s station_restarts=0 station_fails=0 ...
```

Nobody ran `reboot`: the reset came from the watchdog, 10 s after the last feed. After the reset the bind mount was gone, gwmon started Station as at any boot, and the restart count was 0 again.

### Status fields (DoD 4)

The test node (`aesd-test-node`, DevAddr `00BC32BD`) sent three confirmed, empty uplinks, about 28 s apart. It only transmits when it is triggered, which the session that coordinates the project did on request. gwmon and Station had been running untouched since the last boot. The PC read the status line every 10 s. These are the lines where the count changed, shortened to the new fields:

```
01:10:51  ... station=running station_pid=251 station_uptime=223s station_restarts=0 station_fails=0 uplinks=0 last_uplink_age=never temp=29.9C
01:11:22  ... station=running station_pid=251 station_uptime=253s station_restarts=0 station_fails=0 uplinks=1 last_uplink_age=1s temp=29.9C
01:11:52  ... station=running station_pid=251 station_uptime=284s station_restarts=0 station_fails=0 uplinks=2 last_uplink_age=4s temp=29.9C
01:12:23  ... station=running station_pid=251 station_uptime=315s station_restarts=0 station_fails=0 uplinks=3 last_uplink_age=7s temp=30.0C
01:12:48  ... station=running station_pid=251 station_uptime=340s station_restarts=0 station_fails=0 uplinks=3 last_uplink_age=32s temp=30.0C
```

Station's log has exactly three `RX` lines for the same boot, each followed by a downlink that acknowledges the frame (the first one is shown):

```
01:11:19.240 [S2E:VERB] RX 904.5MHz DR3 SF7/BW125 snr=13.8 rssi=-79 ... - updf mhdr=80 DevAddr=00BC32BD FCtrl=80 FCnt=5 ... (13 bytes)
01:11:20.241 [S2E:INFO] TX ::1 diid=40565 [ant#0] - dntxed: 925.1MHz 26.0dBm ant#0(0) DR13 SF7/BW500 (12 bytes)
01:11:47.876 [S2E:VERB] RX 905.1MHz DR3 SF7/BW125 snr=13.8 rssi=-80 ... - updf mhdr=80 DevAddr=00BC32BD FCtrl=80 FCnt=6 ... (13 bytes)
01:12:16.514 [S2E:VERB] RX 904.7MHz DR3 SF7/BW125 snr=13.5 rssi=-78 ... - updf mhdr=80 DevAddr=00BC32BD FCtrl=80 FCnt=7 ... (13 bytes)
```

- **Uplinks received:** 3 in the status line, 3 `RX` lines in the log, frame counters 5, 6 and 7. On the node's side the three transmissions were at about 01:11:18, 01:11:47 and 01:12:16, and the node received a downlink in its first receive window each time.
- **Time since the last uplink:** the last frame was logged at 01:12:16.5, and at 01:12:48 the status line read `last_uplink_age=32s`. The line read at 01:11:22 shows `1s` for a frame logged at 01:11:19.2: gwmon reads the log every 2 s, so the age starts up to 2 s late.
- **Restart count:** 0 before the `kill -9` above and 1 after it, and it counted to 5 in the five-failures test.
- **Temperature:** 29.1 to 30.0 °C during the tests, with the board in open air on the bench. Read by hand with `i2cget`, the sensor's two registers gave 0x1d and 0xc0, which is 29.75 °C. Station's log has `found temperature sensor on port 0x39` at each start, so both programs were reading the sensor at the same time.

Before the node was triggered the fields showed `uplinks=0 last_uplink_age=never`, and `uplinks=unavailable` in the first seconds of a boot, before Station has created its log.

### No credentials, and the safety file

Neither is in the definition of done, but both were conditions for removing `S60station`.

- **No credentials.** An empty directory was bind-mounted over `/etc/station`, so the real files were not touched, and gwmon was started. `station-run.sh` logged `no cups.uri or tc.uri in /etc/station, not starting` and exited with status 78. gwmon logged `station has nothing to run (exit status 78): not restarting it, the watchdog is still fed`. A minute later the status line still read `watchdog=active ... wd_feeds=30 ... station=unconfigured ... station_restarts=0 station_fails=0`, and the Pi had not reset.
- **`gwmon.disable`.** With the file on the boot partition, `S99gwmon start` printed `gwmon: /boot/gwmon.disable exists, not starting`. Neither gwmon nor Station ran, and the watchdog stayed `inactive`.

### Version 1's watchdog behaviour is unchanged

| Test | Result |
|---|---|
| `kill -STOP $(pidof gwmon)`: the main loop hangs | Station kept running. The last uptime line came 8.6 s after the signal, then the Pi reset: 10 s after the last feed, which is up to 2 s before the signal |
| `kill -9 $(pidof gwmon)` | The kernel logged `watchdog0: watchdog left running`. Station was gone 1 s later (SIGTERM from `PR_SET_PDEATHSIG`). The last uptime line came 10.1 s after the kill, then the Pi reset |

After both resets the Pi came back with gwmon and Station running.

## Host results

Run in WSL2 Ubuntu 24.04 (gcc 13.3.0) in a directory of its own. `gwmon/test/host-test.sh` runs gwmon with a regular file as the watchdog, as in issue #6. For the supervision it writes a fake `station`: a shell script that, at each start, reads from a file whether to keep running, to exit with status 1, or to exit with status 78. Uplinks are lines appended to a fake Station log, and the temperature is a number in a text file given to `-T`.

| Run | Result | Log |
|---|---|---|
| `make check` (`-O2 -Wall -Wextra -Werror`) | 79 of 79 checks pass | [logs/issue7-gwmon-host-test.log](logs/issue7-gwmon-host-test.log) |
| AddressSanitizer + LeakSanitizer + UBSan build | 79 of 79, no reports | [logs/issue7-gwmon-host-sanitizers.log](logs/issue7-gwmon-host-sanitizers.log) |
| ThreadSanitizer build | 79 of 79, no reports | same log |
| `make valgrind` (Valgrind 3.22.0, `--leak-check=full --show-leak-kinds=all --track-fds=yes`) | 80 of 80, no errors, no leaks | [logs/issue7-gwmon-valgrind.log](logs/issue7-gwmon-valgrind.log) |

Under Valgrind, each of the 10 gwmon processes that exit normally reports `All heap blocks were freed -- no leaks are possible` and `ERROR SUMMARY: 0 errors`. The file descriptors listed as open at exit are the same as in issue #6: Valgrind's own log, the terminal, and the listening socket in the short-lived parent of `gwmon -d`.

The 29 checks of issue #6 (sections 1 to 5) pass unchanged. The 50 new ones:

| Section | What is checked |
|---|---|
| 6. Supervision | The status line keeps the version 1 fields and adds the new ones. Lines already in the log are not counted. Uplink lines are counted, a line that arrives in two parts once, and lines on both sides of a log rotation. A changed and an unreadable temperature. After `kill -9` of the fake station: running again within 5 s with a new PID, `station_restarts=1`, the exit, the 1 s delay and the restart in the syslog output. A station killed before the `-S` limit gives `station_fails=1` and a 2 s delay, and the count reads 0 again once the next run reaches the limit. On SIGTERM gwmon stops the station with SIGTERM |
| 7. Five failed starts | `station=failed`, `watchdog=starving`, 5 restarts and 5 failed starts in the status. The delays before the restarts were 1.0, 2.0, 4.0, 8.0 and 16.0 s. Every exit and restart is in the syslog output. The fake watchdog file stops growing. The station is not started a 7th time. A clean stop still writes the magic `V` |
| 8. Exit status 78 | `station=unconfigured`, started once only, and the watchdog is still fed |
| 9. A program that does not exist | Counted as a failed start; `station=failed` after `-r 2` |
| 10. `kill -9` of gwmon | The station gets SIGTERM and exits; no magic `V` is written |

## Not done

- **A full reflash** with the new `sdcard.img`, to boot the image as built instead of the issue #4 card with files copied onto it. The AWS credential files have to be put on the boot partition again afterwards (README, "Flash and first boot").
- **A card that really has no credentials.** That case was tested with an empty directory mounted over `/etc/station`.
- **A Station that fails by itself.** The five failed starts were forced with a script in place of `/usr/bin/station`.

## How to repeat the bench tests

`<pi>` is the Pi's address. The Pi has no `nc`, so the status line is read from a PC. Tests 3 and 4 reset the Pi.

```bash
# Status line (PC)
nc -w 3 <pi> 9000 </dev/null
```

```sh
# 1. Who started Station (on the Pi)
ls /etc/init.d; ps -o pid,ppid,args | grep -E '[g]wmon|[s]tation'; grep -E 'gwmon|station' /var/log/messages

# 2. kill -9 of Station, then the restart in syslog and the reconnect in Station's log (on the Pi)
kill -9 $(pidof station); sleep 10
grep gwmon /var/log/messages | tail -n 4; grep -E 'ed to MUXS|Concentrator started' /var/log/station.log | tail -n 2

# 3. Five failed starts: Station becomes a script that fails, until the next boot (on the Pi)
printf '#!/bin/sh\nexit 1\n' > /tmp/station-broken; chmod +x /tmp/station-broken
mount -o bind /tmp/station-broken /usr/bin/station
tail -f /var/log/messages & kill -9 $(pidof station)
while true; do cut -d' ' -f1 /proc/uptime; sleep 0.5; done

# 4. A hung gwmon (on the Pi)
kill -STOP $(pidof gwmon); while true; do cut -d' ' -f1 /proc/uptime; sleep 0.5; done

# 5. No credentials, without touching them (on the Pi)
/etc/init.d/S99gwmon stop; mkdir /tmp/empty; mount -o bind /tmp/empty /etc/station
/etc/init.d/S99gwmon start; sleep 60; grep gwmon /var/log/messages | tail -n 3
/etc/init.d/S99gwmon stop; umount /etc/station; /etc/init.d/S99gwmon start
```
