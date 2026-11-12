# Issue #6: gwmon v1, TCP status server and hardware watchdog

**Status, 2026-11-12: code written and tested on the build host only.** The Raspberry Pi and the Buildroot build tree were in use for issue #4, so nothing here has run on the Pi or been built by Buildroot yet. The [bench checklist](#bench-checklist-not-yet-run) lists what is left.

| Definition of done (issue #6) | State |
|---|---|
| `gwmon/` has C source and a Makefile; `base_external/package/gwmon/` cross-builds it into the image | Source and Makefile done. Package written, **not yet built** |
| `gwmon -d` runs as a daemon; `S99gwmon` starts and stops it with start-stop-daemon | Daemon mode passes on the host. `S99gwmon` **not yet run** |
| `nc <pi-address> 9000` returns one status line with version, uptime and watchdog state | Passes on the host (`127.0.0.1`). **Not yet run** against the Pi |
| gwmon opens `/dev/watchdog` and feeds it on a timer; the Pi reboots within 15 s of `kill -9` | Feeding passes against a fake watchdog file. The reset is **not yet tested** |
| SIGTERM closes the watchdog with the magic close | Passes against the fake file (`V` is the last byte written). **Not yet tested** on the real driver |
| A host build under Valgrind shows no leaks | **Not yet run**: Valgrind is not installed on the build host. AddressSanitizer, LeakSanitizer, UBSan and ThreadSanitizer runs are clean |

## Design

`gwmon/gwmon.c` follows the course's aesdsocket:

- `-d` forks into the background after the listening socket is bound, so a start failure (port in use) is the exit status that `S99gwmon` sees.
- SIGINT and SIGTERM handlers only set a flag. The signals are blocked except while the main thread waits in `ppoll()`, so a signal can't be missed between the loop test and the wait.
- Each client gets a thread that sends the status line and closes. The threads are kept in a list and joined by the main thread. At most 8 run at once.
- Messages go to syslog (`grep gwmon /var/log/messages`), and to stderr as well when gwmon runs in the foreground.

The watchdog part:

- `/dev/watchdog` is opened once, after the fork. Opening it starts the watchdog. gwmon then sets the timeout with `WDIOC_SETTIMEOUT` (10 s) and feeds the watchdog by writing one NUL byte, every 2 s.
- The feed is driven by a `timerfd` in the same `ppoll()` loop that accepts clients, not by a thread of its own. If the main loop hangs, the feeds stop and the Pi resets.
- On SIGINT or SIGTERM, gwmon writes the magic close character `V` and closes the device before any other cleanup. That stops the watchdog.
- Anything else that ends the process leaves the watchdog running on purpose: `kill -9`, a crash, SIGHUP, or a fatal error in the main loop. The kernel logs `watchdog0: watchdog did not stop!` and the Pi resets when the timeout runs out. Note that closing an SSH session in which gwmon runs in the foreground sends it SIGHUP.
- Port, device, timeout and interval are options (`-p`, `-w`, `-t`, `-i`) with build-time defaults (`GWMON_DEFAULT_*`). `-w none` runs without a watchdog. A path that is not a character device is reported as `watchdog=fake`. gwmon never creates the device file.

### What the Pi 5's watchdog is expected to be

Read from the kernel source that the image pins (raspberrypi/linux `21b41014`, 6.12.61), not from the board:

| Item | Expected | Source |
|---|---|---|
| Driver | `bcm2835-wdt`, built in (`CONFIG_BCM2835_WDT=y`) | `arch/arm64/configs/bcm2712_defconfig` |
| Device tree | `watchdog@7d200000`, `compatible = "brcm,bcm2712-pm"` | `bcm2712-ds.dtsi`, `drivers/mfd/bcm2835-pm.c` |
| Identity | `Broadcom BCM2835 Watchdog timer` | `drivers/watchdog/bcm2835_wdt.c` |
| Options | `WDIOF_SETTIMEOUT`, `WDIOF_MAGICCLOSE`, `WDIOF_KEEPALIVEPING` (0x8180) | same |
| Timeout | default 15 s, minimum 1 s. The hardware counter holds 15.999 s at most; the watchdog core accepts longer timeouts and pings the hardware itself | same |
| `CONFIG_WATCHDOG_NOWAYOUT` | not set, so the magic close stops the watchdog | `bcm2712_defconfig` |
| Sysfs | `/sys/class/watchdog/watchdog0/` (`CONFIG_WATCHDOG_SYSFS=y`) | `bcm2712_defconfig` |

Still to confirm on the board: the driver name and identity, the timeout that `WDIOC_SETTIMEOUT` reports back, that `nowayout` is 0, and that a watchdog reset reboots the Pi 5 rather than halting it.

## Host results

Run in WSL2 Ubuntu 24.04 (gcc 13.3.0) in a directory of its own. `gwmon/test/host-test.sh` starts gwmon on port 19000 with a regular file as the watchdog, so no real `/dev/watchdog` is opened. Each feed appends a NUL byte to that file and the magic close appends `V`.

| Run | Result | Log |
|---|---|---|
| `make check` (`-O2 -Wall -Wextra -Werror`) | 29 of 29 checks pass | [logs/issue6-gwmon-host-test.log](logs/issue6-gwmon-host-test.log) |
| AddressSanitizer + LeakSanitizer + UBSan build | 29 of 29, no reports | [logs/issue6-gwmon-host-sanitizers.log](logs/issue6-gwmon-host-sanitizers.log) |
| ThreadSanitizer build | 29 of 29, no reports | same log |
| `make valgrind` | **not run**, Valgrind is not installed (`sudo apt-get install valgrind`) | to be `logs/issue6-gwmon-valgrind.log` |

The checks cover: the status line format; five clients at once; a client that sends data before reading; feeds arriving on the timer; exit status 0 and a final `V` after SIGTERM and after SIGINT; no `V` after `kill -9`; daemon mode (the caller gets 0, the daemon is a session leader and answers); `watchdog=disabled` and `watchdog=unavailable`; a second instance on the same port failing to start; and a feed interval that isn't below the timeout being rejected.

## Buildroot package (not yet built)

- `base_external/package/gwmon/gwmon.mk` is a `generic-package` with `GWMON_SITE_METHOD = local`, pointing at `gwmon/` in this repository. Buildroot copies the directory to `output/build/gwmon-custom`, builds it with `$(TARGET_CONFIGURE_OPTS)` and installs `/usr/bin/gwmon`. `GWMON_INSTALL_INIT_SYSV` installs `S99gwmon` from the package directory. A host build left in `gwmon/` is excluded from the copy.
- `BR2_PACKAGE_GWMON=y` is in `aesd_pi5_defconfig`, and `base_external/Config.in` sources the package's `Config.in`.
- It was checked against `sx1302-hal.mk` and Buildroot 2026.02.3's `package/pkg-generic.mk`, and the BusyBox applets that `S99gwmon` uses (`start-stop-daemon`, `pidof`, fractional `sleep`) are on in Buildroot's `busybox.config`. None of that replaces a build.

## Bench checklist (not yet run)

Run it once issue #4 is merged. `<pi>` is the Pi's address.

**0. Merge and build** (WSL build tree)

```bash
git fetch origin && git checkout issue-6-gwmon-v1 && git merge origin/main
make -C buildroot BR2_EXTERNAL=../base_external aesd_pi5_defconfig
make -C buildroot gwmon 2>&1 | tee ~/aesd/issue6-gwmon-pkg.log
file buildroot/output/build/gwmon-custom/gwmon
ls -l buildroot/output/target/usr/bin/gwmon buildroot/output/target/etc/init.d/S99gwmon
./build.sh
```

The merge is expected to conflict in `README.md` only, where both branches add a section before "AI use" and a row to its table: keep both. The second command reloads the defconfig, which `build.sh` skips when `buildroot/.config` exists. Expect `ELF 64-bit LSB ... ARM aarch64` and both files present, mode 0755. Then flash `sdcard.img` and boot. Proves DoD 1.

**1. Watchdog driver and boot start** (on the Pi)

```sh
ps | grep '[g]wmon'
grep gwmon /var/log/messages
ls -l /dev/watchdog /dev/watchdog0
cd /sys/class/watchdog/watchdog0 && grep . identity timeout nowayout state
dmesg | grep -i -E 'watchdog|wdt'
```

Expect `gwmon -d` running, and in the log `watchdog /dev/watchdog: "Broadcom BCM2835 Watchdog timer", options 0x8180 (magic close)`, `watchdog armed: timeout 10 s, fed every 2 s` and `gwmon 1.0.0 started, status on TCP port 9000`. Sysfs: `timeout:10`, `nowayout:0`, `state:active`. Proves DoD 2 (start) and the driver assumptions.

**2. Status line from the LAN** (on the PC, in WSL)

```bash
nc -w 3 <pi> 9000 </dev/null; sleep 5; nc -w 3 <pi> 9000 </dev/null
```

Expect two lines like `gwmon 1.0.0 uptime=...s daemon_uptime=...s watchdog=active wd_timeout=10s wd_interval=2s wd_feeds=N wd_last_feed_age=...s`, with `wd_feeds` 2 or 3 higher in the second and `wd_last_feed_age` at most 2. Proves DoD 3 and the feeding half of DoD 4.

**3. Clean stop, the magic close** (on the Pi; do this before step 4)

```sh
/etc/init.d/S99gwmon stop
cat /sys/class/watchdog/watchdog0/state
grep -E 'Caught signal|magic close' /var/log/messages | tail -n 2
dmesg | grep 'did not stop'
sleep 30; cut -d' ' -f1 /proc/uptime
/etc/init.d/S99gwmon start && /etc/init.d/S99gwmon restart && ps | grep '[g]wmon'
```

Expect `inactive`, the two log lines, nothing from the `dmesg` line, and the Pi still up after 30 s with an uptime that kept counting. Proves DoD 5 and DoD 2 (stop, restart).

**4. `kill -9`, time to reset** (on the PC; the Pi resets)

```bash
ssh root@<pi> 'sync; cut -d" " -f1 /proc/uptime; kill -9 $(pidof gwmon); dmesg | tail -n 1; while true; do cut -d" " -f1 /proc/uptime; sleep 0.5; done'
```

The first number is the uptime at the kill. The `dmesg` line should be `watchdog: watchdog0: watchdog did not stop!`. Numbers keep printing until the Pi resets and the connection drops. Last number minus first is the time to reset: expect about 10 s, and it must be under 15 s. Then confirm the Pi comes back by itself with a small uptime and gwmon running again:

```bash
ssh root@<pi> 'cut -d" " -f1 /proc/uptime; ps | grep "[g]wmon"; cat /sys/class/watchdog/watchdog0/bootstatus'
```

Proves the reset half of DoD 4.

**5. Optional**

- A hung daemon: `kill -STOP $(pidof gwmon)` should reset the Pi the same way, since the feed comes from the main loop.
- `reboot` should restart the Pi normally (S99gwmon stops gwmon first).
- The safety catch: with an empty `gwmon.disable` on the boot partition, `S99gwmon start` prints `/boot/gwmon.disable exists, not starting`.

**6. Valgrind** (WSL, needs `sudo apt-get install valgrind` once)

```bash
make -C gwmon clean && make -C gwmon valgrind 2>&1 | tee docs/logs/issue6-gwmon-valgrind.log
```

Expect `RESULT: all checks passed under Valgrind`, and in each Valgrind log `All heap blocks were freed -- no leaks are possible` and `ERROR SUMMARY: 0 errors`. Proves DoD 6. Run it from a copy of `gwmon/` outside `/mnt/c` if the worktree is on the Windows drive.

**7. Before closing the issue:** replace `TODO(issue-6-session-link)` (`git grep -l 'TODO(issue-6-session-link)'`), update the status table at the top of this file and the note in the README's gwmon section, and remove the "not yet built" note from `gwmon.mk`.
