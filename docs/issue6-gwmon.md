# Issue #6: gwmon v1, TCP status server and hardware watchdog

`gwmon` runs on the Pi 5, answers `nc <pi-address> 9000` with one status line, and owns the hardware watchdog. These are the results for the issue's definition of done, measured on 2026-11-12.

| Definition of done (issue #6) | Result |
|---|---|
| `gwmon/` has C source and a Makefile; `base_external/package/gwmon/` cross-builds it into the image | **Pass.** Buildroot built the package and the image; `rootfs.ext2` holds `/usr/bin/gwmon` and `/etc/init.d/S99gwmon` |
| `gwmon -d` runs as a daemon; `S99gwmon` starts and stops it with start-stop-daemon | **Pass.** Started at boot, `stop`, `start` and `restart` work |
| `nc <pi-address> 9000` returns one status line with version, uptime and watchdog state | **Pass** from a PC on the LAN |
| gwmon opens `/dev/watchdog` and feeds it on a timer; the Pi reboots within 15 s of `kill -9` | **Pass.** Fed every 2 s; reset 10.0 to 10.5 s after the kill |
| SIGTERM closes the watchdog with the magic close | **Pass.** Watchdog `inactive` after `S99gwmon stop`, Pi still up 30 s later |
| A host build under Valgrind shows no leaks | **Pass.** Valgrind 3.22.0: 0 errors and no leaks in all 7 gwmon processes of the host test. The AddressSanitizer, LeakSanitizer, UBSan and ThreadSanitizer runs are clean too |

One caveat on the first row: the SD card was not reflashed with the new image. The card holds the image flashed for issue #4 (commit `a611da7`), and the two files this issue adds were copied to it over SSH from the Buildroot output. Their SHA-256 on the Pi equals that of the same files inside the new `rootfs.ext2`. (`S99gwmon` was copied once more after the session link was added to its header comment.) Apart from them, the new image differs from the card only in comment lines (the issue #4 session link).

## Design

`gwmon/gwmon.c` follows the course's aesdsocket:

- `-d` forks into the background after the listening socket is bound, so a start failure (port in use) is the exit status that `S99gwmon` sees.
- SIGINT and SIGTERM handlers only set a flag. The signals are blocked except while the main thread waits in `ppoll()`, so a signal can't be missed between the loop test and the wait.
- Each client gets a thread that sends the status line and closes. The threads are kept in a list and joined by the main thread. At most 8 run at once.
- Messages go to syslog (`grep gwmon /var/log/messages`), and to stderr as well when gwmon runs in the foreground.

The watchdog part:

- `/dev/watchdog` is opened once, after the fork. Opening it starts the watchdog. gwmon then sets the timeout with `WDIOC_SETTIMEOUT` (10 s) and feeds the watchdog by writing one NUL byte, every 2 s. The driver's default of 15 s would put the reset right at the issue's 15 s limit.
- The feed is driven by a `timerfd` in the same `ppoll()` loop that accepts clients, not by a thread of its own. If the main loop hangs, the feeds stop and the Pi resets.
- On SIGINT or SIGTERM, gwmon writes the magic close character `V` and closes the device before any other cleanup. That stops the watchdog.
- Anything else that ends the process leaves the watchdog running on purpose: `kill -9`, a crash, SIGHUP, or a fatal error in the main loop. The kernel logs `watchdog0: watchdog left running` and the Pi resets when the timeout runs out. Note that closing an SSH session in which gwmon runs in the foreground sends it SIGHUP.
- Port, device, timeout and interval are options (`-p`, `-w`, `-t`, `-i`) with build-time defaults (`GWMON_DEFAULT_*`). `-w none` runs without a watchdog. A path that is not a character device is reported as `watchdog=fake`. gwmon never creates the device file.
- `S99gwmon` does not start gwmon when a file named `gwmon.disable` is on the SD card's boot partition. That is the way out if a fault ever made gwmon die at every boot.

### The Pi 5's watchdog

Read from the kernel source that the image pins (raspberrypi/linux `21b41014`, 6.12.61) and then checked on the board:

| Item | From the source | On the board |
|---|---|---|
| Driver | `bcm2835-wdt`, built in (`CONFIG_BCM2835_WDT=y` in `bcm2712_defconfig`), on the `brcm,bcm2712-pm` node | `bcm2835-wdt bcm2835-wdt: Broadcom BCM2835 watchdog timer` in `dmesg`; `/dev/watchdog` (10, 130) and `/dev/watchdog0` |
| Identity | `Broadcom BCM2835 Watchdog timer` | the same, from `WDIOC_GETSUPPORT` and sysfs |
| Options | `WDIOF_SETTIMEOUT`, `WDIOF_MAGICCLOSE`, `WDIOF_KEEPALIVEPING` | `0x8180`, which is those three |
| Timeout | default 15 s, minimum 1 s; the hardware counter holds 15.999 s at most | `timeout` 15 before gwmon, 10 after `WDIOC_SETTIMEOUT`; `min_timeout` 1; `max_timeout` 0 (no limit set) |
| `CONFIG_WATCHDOG_NOWAYOUT` | not set | sysfs `nowayout` is 0, and the magic close stops the watchdog |
| Reset | full reset through the PM block | the Pi reboots by itself and is back on SSH with about 14 s of uptime |

After a watchdog reset, sysfs `bootstatus` is 0: this driver does not report that the last boot was caused by the watchdog.

## Results on the Pi

Full output: [logs/issue6-bench-pi.log](logs/issue6-bench-pi.log). Package build: [logs/issue6-gwmon-buildroot-pkg.log](logs/issue6-gwmon-buildroot-pkg.log).

**Build.** `make -C buildroot gwmon` cross-compiled `gwmon.c` with `aarch64-linux-gcc` and installed both files; the full `make` then built `sdcard.img`. Later commits changed comments only, and a rebuild from them gives the same `gwmon` binary, byte for byte, as the one tested here (SHA-256 `5f937cca…8569`). The binary is an `ELF 64-bit LSB pie executable, ARM aarch64`, 18 kB stripped.

**Boot start.** After a clean `reboot`, `S99gwmon` had started `/usr/bin/gwmon -d`, and syslog showed:

```
gwmon[264]: watchdog /dev/watchdog: "Broadcom BCM2835 Watchdog timer", options 0x8180 (magic close)
gwmon[264]: watchdog armed: timeout 10 s, fed every 2 s
gwmon[264]: gwmon 1.0.0 started, status on TCP port 9000
```

Sysfs: `timeout:10`, `nowayout:0`, `state:active`, `timeleft:9`.

**Status line**, from a PC on the LAN, twice, 5 s apart:

```
gwmon 1.0.0 uptime=30s daemon_uptime=25s watchdog=active wd_timeout=10s wd_interval=2s wd_feeds=13 wd_last_feed_age=1s
gwmon 1.0.0 uptime=35s daemon_uptime=31s watchdog=active wd_timeout=10s wd_interval=2s wd_feeds=16 wd_last_feed_age=1s
```

`wd_feeds` went up by 3 in 5 to 6 s, which is the 2 s timer.

**Clean stop.** `/etc/init.d/S99gwmon stop` printed `OK`, sysfs `state` became `inactive`, and syslog showed `Caught signal 15, exiting` and `watchdog closed with the magic close after 16 feeds`. The uptime was 36.25 s at the stop and 66.25 s after a 30 s wait, so the Pi did not reset. `start` and `restart` then worked. A second `start` while gwmon runs prints `FAIL` and leaves the running daemon alone.

**`kill -9`.** One SSH command printed the uptime, killed gwmon and kept printing the uptime every 0.5 s:

| Event | Uptime |
|---|---|
| `kill -9 $(pidof gwmon)` | 80.28 s |
| Kernel: `watchdog: watchdog0: watchdog left running` | at the kill |
| Last uptime printed before the reset | 90.32 s |

The next line was due at 90.82 s and never came, so the reset was 10.0 to 10.5 s after the kill. The Pi booted by itself, and 14 s into the new boot gwmon was running again with the watchdog `active`. After the last reset of the session, Basics Station was running again as well, with its concentrator started.

**A hung gwmon.** `kill -STOP $(pidof gwmon)` at 25.51 s: last uptime printed 35.03 s, then the same reset. The feed stops when the main loop stops, not only when the process dies.

**Safety catch.** With `/boot/gwmon.disable` present, `S99gwmon start` printed `gwmon: /boot/gwmon.disable exists, not starting`. With the file removed it started.

## Host results

Run in WSL2 Ubuntu 24.04 (gcc 13.3.0) in a directory of its own. `gwmon/test/host-test.sh` starts gwmon on port 19000 with a regular file as the watchdog, so no real `/dev/watchdog` is opened. Each feed appends a NUL byte to that file and the magic close appends `V`.

| Run | Result | Log |
|---|---|---|
| `make check` (`-O2 -Wall -Wextra -Werror`) | 29 of 29 checks pass | [logs/issue6-gwmon-host-test.log](logs/issue6-gwmon-host-test.log) |
| AddressSanitizer + LeakSanitizer + UBSan build | 29 of 29, no reports | [logs/issue6-gwmon-host-sanitizers.log](logs/issue6-gwmon-host-sanitizers.log) |
| ThreadSanitizer build | 29 of 29, no reports | same log |
| `make valgrind` (Valgrind 3.22.0, `--leak-check=full --show-leak-kinds=all --track-fds=yes`) | 30 of 30, no errors, no leaks | [logs/issue6-gwmon-valgrind.log](logs/issue6-gwmon-valgrind.log) |

Under Valgrind, each of the 7 gwmon processes that exit normally reports `All heap blocks were freed -- no leaks are possible` and `ERROR SUMMARY: 0 errors`. The run has one check more than the others: that every Valgrind log ends with 0 errors. The file descriptors listed as open at exit are inherited from the test (Valgrind's own log and the terminal). The one exception is the listening socket in the short-lived parent of `gwmon -d`, which exits right after the fork and leaves the socket to the daemon.

The checks cover: the status line format; five clients at once; a client that sends data before reading; feeds arriving on the timer; exit status 0 and a final `V` after SIGTERM and after SIGINT; no `V` after `kill -9`; daemon mode (the caller gets 0, the daemon is a session leader and answers); `watchdog=disabled` and `watchdog=unavailable`; a second instance on the same port failing to start; and a feed interval that isn't below the timeout being rejected.

## Not done

**A full reflash** with the new `sdcard.img`, to boot the image as built rather than the issue #4 card with two files added. The AWS credential files have to be copied to the boot partition again afterwards (README, "Flash and first boot").

## How to repeat the bench tests

`<pi>` is the Pi's address. Steps 3 and 4 are on the PC; step 4 resets the Pi.

```sh
# 1. Boot start and driver (on the Pi)
ps | grep '[g]wmon'; grep gwmon /var/log/messages
cd /sys/class/watchdog/watchdog0 && grep . identity timeout nowayout state

# 2. Clean stop (on the Pi)
/etc/init.d/S99gwmon stop; cat /sys/class/watchdog/watchdog0/state
sleep 30; cut -d' ' -f1 /proc/uptime; /etc/init.d/S99gwmon start
```

```bash
# 3. Status line (PC)
nc -w 3 <pi> 9000 </dev/null

# 4. kill -9 and the time to reset (PC): first number = uptime at the kill, last number = just before the reset
ssh root@<pi> 'sync; cut -d" " -f1 /proc/uptime; kill -9 $(pidof gwmon); dmesg | tail -n 1; while true; do cut -d" " -f1 /proc/uptime; sleep 0.5; done'
```
