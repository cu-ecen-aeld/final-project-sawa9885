# Raspberry Pi 5 LoRaWAN Gateway (ECEN 5713 Final Project)

An 8-channel LoRaWAN gateway built from a Raspberry Pi 5 and a Seeed WM1302 (Semtech SX1302) concentrator. It runs a custom Buildroot image with LoRa Basics Station, which forwards to AWS IoT Core for LoRaWAN. A gateway monitor daemon, `gwmon`, supervises the forwarder, feeds the hardware watchdog and reports health over TCP.

- **Project Overview:** [Project Overview wiki page](https://github.com/cu-ecen-aeld/final-project-sawa9885/wiki/Project-Overview)
- **Schedule:** [Project-Schedule](https://github.com/users/sawa9885/projects/1/views/1?groupedBy%5BcolumnId%5D=435387974)

## Build

On an Ubuntu host (24.04 under WSL2 works) with the [Buildroot host packages](https://buildroot.org/downloads/manual/manual.html#requirement-mandatory) installed:

```bash
git clone --recursive https://github.com/cu-ecen-aeld/final-project-sawa9885.git
cd final-project-sawa9885
./build.sh
```

Under WSL2, build in the Linux filesystem (not `/mnt/c`) and drop the Windows entries from `PATH` first, since Buildroot refuses a `PATH` with spaces: `export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.

The image is `buildroot/output/images/sdcard.img`. `./clean.sh` removes the build output, and `./save_config.sh` saves `menuconfig` changes to `base_external/configs/aesd_pi5_defconfig`.

- `base_external/` is the `BR2_EXTERNAL` tree: the defconfig, board scripts, the packages (`sx1302-hal`, `basicstation`, `gwmon`) and the rootfs overlay.
- `base_external/board/pi5/genimage.cfg.in` lays the card out like Raspberry Pi OS: a 128 MB FAT32 boot partition at 8 MiB. With Buildroot's stock layout (a 32 MB FAT16 partition at sector 1) our Pi 5 did not start Linux.
- `base_external/board/pi5/config.txt` replaces Buildroot's `config_5.txt`. It adds `dtparam=spi=on` and `dtparam=i2c_arm=on` for the WM1302 HAT: the SX1302 is on `/dev/spidev0.0` and its temperature sensor is at 0x39 on `/dev/i2c-1`. `/etc/modules-load.d/wm1302.conf` loads `i2c-dev` at boot.
- `/usr/bin/wm1302-reset.sh` resets the WM1302 (GPIO17 for the SX1302, GPIO5 for the SX1261) with libgpiod's `gpioset` on the RP1 chip (`pinctrl-rp1`, `gpiochip0`), not sysfs GPIO. The `sx1302-hal` package installs it, next to the `reset_lgw.sh` that the HAL tools call, because those tools are what need it (it was in the rootfs overlay until issue #12). [Boot order](#boot-order) says when it runs. The image has libgpiod 1.6 rather than 2.x, because the Bootlin stable toolchain has 5.4 kernel headers and `libgpiod2` needs 5.10. The kernel still has the v1 GPIO uAPI (`CONFIG_GPIO_CDEV_V1=y`).

### Buildroot version

Buildroot is the `buildroot/` submodule, pinned to commit [`679b9ead7620bbf193620d1ebf56f53c1764d37a`](https://gitlab.com/buildroot.org/buildroot/-/commit/679b9ead7620bbf193620d1ebf56f53c1764d37a). That commit is the tag `2026.02.3`, on the `2026.02.x` long-term support branch. `git -C buildroot describe --tags` prints the tag, and `git submodule status` prints the commit.

The image starts from that release's `raspberrypi5_defconfig`. Two changes to it were needed before our board, a Pi 5 Rev 1.1 with the bootloader EEPROM of 2026-05-11, started Linux at all (issue #1):

- **`bcm2712-d-rpi-5-b.dtb`.** The first Pi 5 boards have the C1 stepping of the BCM2712, and newer ones have the D0 stepping, which needs a device tree of its own. The stock defconfig builds `bcm2712-rpi-5-b.dtb`, `bcm2712d0-rpi-5-b.dtb` and `bcm2712-rpi-500.dtb`. The firmware on our board asks for the D0 device tree under the name `bcm2712-d-rpi-5-b.dtb`, which is not in that list. So it found no device tree and Linux never started: the root filesystem's mount count stayed 0. The same kernel booted from a Raspberry Pi OS card, which has that file. `BR2_LINUX_KERNEL_INTREE_DTS_NAME` in `aesd_pi5_defconfig` now adds `broadcom/bcm2712-d-rpi-5-b`, and `post-image.sh` copies every built `.dtb` to the boot partition, so the image has the device tree for either stepping.
- **The firmware overlays.** `BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTB_OVERLAYS=y` puts the `overlays/` directory of the Raspberry Pi firmware on the boot partition; the stock defconfig leaves it out. It holds `overlay_map.dtb`, which the Pi 5 firmware reads to choose the overlay variant for the BCM2712, and the overlays that `dtoverlay=` lines in `config.txt` load. This was added in the same debugging session, right after the device tree, to give the firmware everything it looks for on a Raspberry Pi OS card. `config.txt` uses only `dtparam=` lines today, which the base device tree handles. The history has no boot test with the device tree but without the overlays, so they are part of the configuration that works, not a proven requirement.

The commits are `206ef0e` (card layout), `d78c27d` (device tree) and `36a9f8e` (overlays).

## Flash and first boot

1. Write `sdcard.img` to the microSD (Raspberry Pi Imager → "Use custom", or balenaEtcher).
2. Copy the gateway's secrets to the top level of the card's boot partition (the FAT partition that Windows and macOS mount). None of them is ever in the repo or the image, and `.gitignore` excludes their names.

   | File on the boot partition | Installed as | Contents |
   |---|---|---|
   | `wpa_supplicant.conf` (optional) | `/etc/wpa_supplicant.conf` | Wi-Fi network. Start from `base_external/board/pi5/wpa_supplicant.conf.example`. |
   | `cups.uri` | `/etc/station/cups.uri` | One line: the CUPS endpoint, `https://<id>.cups.lorawan.<region>.amazonaws.com:443`. |
   | `cups.trust` | `/etc/station/cups.trust` | CUPS server trust certificate, as downloaded from AWS. |
   | `cups.crt` | `/etc/station/cups.crt` | Gateway certificate (AWS names it `<id>.cert.pem`). |
   | `cups.key` | `/etc/station/cups.key` | Gateway private key (AWS names it `<id>.private.key`). |
   | `tc.uri`, `tc.trust`, `tc.crt`, `tc.key` (optional) | `/etc/station/tc.*` | The same four for a direct LNS connection (`wss://<id>.lns.lorawan.<region>.amazonaws.com:443`, `lns.trust`). Not needed with CUPS, which fetches them. |

   At boot, `S35provision` installs each file it finds with mode 0600 (`/etc/station` is 0700) and deletes it from the boot partition. To change a file later, put the new one on the boot partition and reboot.
   [docs/aws-iot-core-setup.md](docs/aws-iot-core-setup.md) says where each `cups.*` file comes from in the AWS console.
3. Boot the Pi and log in over SSH as `root`. Dropbear accepts only the public key that the overlay installs in `/root/.ssh/authorized_keys`; password logins are off.

## Network and time

- Ethernet (`eth0`) uses DHCP and needs no file. BusyBox `ifplugd` (`S41ifplugd`) watches the link: it runs `ifup eth0` when the cable is plugged in, at boot or later, and `ifdown eth0` when it is pulled out, so the address and the default route go away with the cable. `grep ifplugd /var/log/messages` shows each event with the uptime.
- Wi-Fi (`wlan0`) starts only when `/etc/wpa_supplicant.conf` exists. The image has no such file until `S35provision` installs one: Buildroot's default file, which joins any open network, is removed in `post-build.sh`.
- The Pi 5 has no RTC battery here, so the clock is wrong after a cold boot. `chronyd` sets it from `pool.ntp.org`. A udhcpc hook (`/usr/share/udhcpc/default.script.d/50-chrony`) tells chronyd when an interface gets a lease, and logs the uptime of the lease and of the first sync: `grep ntp-hook /var/log/messages`. `chronyc tracking` shows the current state, and `chronyc waitsync` blocks until the clock is set.
- The `ca-certificates` bundle is `/etc/ssl/certs/ca-certificates.crt`.

## Boot order

1. **Firmware.** The Pi 5 bootloader reads `config.txt` from the boot partition, loads the device tree for the board (see [Buildroot version](#buildroot-version)), turns on SPI and I2C in it (`dtparam=spi=on`, `dtparam=i2c_arm=on`) and starts the kernel `Image` with `root=/dev/mmcblk0p2`.
2. **Kernel and init.** The kernel mounts the root filesystem and starts BusyBox `init`. `/etc/inittab` mounts `/proc` and everything in `/etc/fstab`, which includes the boot partition on `/boot`, and then runs `/etc/init.d/rcS`.
3. **Init scripts.** `rcS` runs every `/etc/init.d/S*` script with `start`, in the order of their names, one at a time: a script starts only when the one before it has returned.

| Script | From | What it does at boot |
|---|---|---|
| `S01seedrng` | Buildroot (`urandom-scripts`) | Seeds the kernel's random number generator. |
| `S01syslogd`, `S02klogd` | Buildroot (BusyBox) | Start logging to `/var/log/messages`. |
| `S02sysctl` | Buildroot (BusyBox) | Applies `/etc/sysctl.conf`. |
| `S10udevd` | Buildroot (`eudev`) | Creates the device nodes and loads the drivers named in the device tree. After it, `/dev/spidev0.0` and the RP1 `gpiochip0` exist. |
| `S11modules` | Buildroot (`initscripts`) | Loads the modules in `/etc/modules-load.d/wm1302.conf`: `i2c-dev`, for `/dev/i2c-1`, and `spidev`. |
| `S35provision` | this repo, rootfs overlay | Installs the Wi-Fi and Basics Station credentials it finds on the boot partition, then deletes them there. |
| `S40network` | Buildroot (`ifupdown-scripts`) | `ifup -a`: only the loopback interface, since `eth0` is not `auto`. |
| `S41ifplugd` | this repo, rootfs overlay | Starts `ifplugd`, which brings `eth0` up with DHCP when the cable has a link. |
| `S41wifi` | this repo, rootfs overlay | Starts Wi-Fi if `/etc/wpa_supplicant.conf` exists. |
| `S49chronyd` | Buildroot (`chrony`) | Starts `chronyd`, which sets the clock once an interface has a lease. |
| `S50crond` | Buildroot (BusyBox) | Starts `crond`. No cron jobs are installed. |
| `S50dropbear` | Buildroot (`dropbear`) | Starts the SSH server. |
| `S99gwmon` | this repo, `gwmon` package | Starts [gwmon](#gwmon), which arms the watchdog and starts Basics Station through `/usr/bin/station-run.sh`. |

The network scripts only start daemons. The DHCP lease and the clock arrive later, in the background, so `S99gwmon` runs about 3 s after the kernel starts, before either is there.

### When the concentrator is reset

No init script resets the WM1302 on its own, and nothing before `S99gwmon` touches its reset pins. Until the first reset the pins sit at the Pi's default pulls: GPIO17 low, so the SX1302 is not held in reset, and GPIO5 high. The reset is done by the programs that open the concentrator, each time just before they open it, always with `/usr/bin/wm1302-reset.sh`. It holds both chips in reset for 100 ms and then waits another 100 ms.

At boot that happens twice, both times below `S99gwmon`:

1. **`util_chip_id`, about 3 to 5 s after the kernel starts.** `S99gwmon` starts `gwmon`, gwmon starts `station-run.sh`, and that script reads the SX1302's EUI with `util_chip_id`. Like all the sx1302-hal tools, `util_chip_id` runs `reset_lgw.sh start` first, and `reset_lgw.sh` runs `wm1302-reset.sh`. This needs only what `S10udevd` and `S11modules` set up (the GPIO chip and `/dev/spidev0.0`), not the network or the clock. It is skipped on a gateway with no `cups.uri` or `tc.uri`: `station-run.sh` exits before it, since there is nothing to start.
2. **Basics Station, just before it starts the radio.** `station-run.sh` then waits up to 60 s for the clock and execs `station`. Station runs its `radio_init` program, which `station.conf` sets to `/usr/bin/wm1302-reset.sh`, before each start of the concentrator. That is after it has connected to the network server and received the channel plan.

The times of one boot, from [docs/issue7-gwmon-v2.md](docs/issue7-gwmon-v2.md):

| Uptime | Event |
|---|---|
| about 3 s | `S99gwmon` starts gwmon, and gwmon starts `station-run.sh` |
| about 5 s | first reset done, EUI read: `station: gateway EUI ..., starting when the clock is set` |
| 13.5 s | `eth0` has a DHCP lease; chronyd then sets the clock |
| 18.7 s | `station-run.sh` execs `station` |
| 22.3 s | Station has connected to AWS, reset the concentrator again and started it |

When gwmon restarts Station later, both resets run again in the same order. `lora_pkt_fwd`, the test forwarder from issue #3, is not started at boot. Run by hand, it resets the concentrator through `reset_lgw.sh` as `util_chip_id` does.

## Basics Station

`base_external/package/basicstation` builds [LoRa Basics Station](https://github.com/lorabasics/basicstation) v2.0.6 for its `corecell` platform (SX1302), `std` variant. `station` is linked statically with Station's own patched copy of sx1302_hal V2.1.0 and with mbedtls 2.28.10. Buildroot downloads both and checks their hashes, in place of the `git clone` that upstream's makefiles run. The comments in `basicstation.mk` say why the Buildroot `mbedtls` and our `sx1302-hal` library can't be used.

- **Start at boot:** `gwmon` starts Station and restarts it when it exits (see [gwmon](#gwmon)). Station has no init script of its own. gwmon runs `/usr/bin/station-run.sh`, which reads the SX1302's EUI with `util_chip_id` (which also resets the WM1302), writes it to `/var/run/station.eui`, waits up to 60 s for chronyd to set the clock, then execs `station --home /etc/station` in the foreground. With no `cups.uri` or `tc.uri` in `/etc/station` it logs one line and exits with status 78, which tells gwmon that there is nothing to run.
- **Boot order:** `S99gwmon` is the last init script, after the credentials, the network daemons, chronyd and SSH. [Boot order](#boot-order) has the whole sequence and the concentrator resets.
- **Gateway EUI:** the concentrator's EUI. `station.conf` names `/var/run/station.eui` as its `routerid`, so the image isn't tied to one board. `grep 'gateway EUI' /var/log/messages` shows it.
- **Configuration:** `/etc/station/station.conf` (radio settings for the WM1302, no secrets). The channel plan comes from the network server. The credentials are the `cups.*` files from "Flash and first boot"; Station fetches the LNS address and credentials from CUPS and saves them as `tc.*` in the same directory.
- **Log:** `/var/log/station.log` (tmpfs, 3 x 2 MB at most). The log level is `INFO`, with the `S2E` and `TCE` modules at `VERBOSE`: one `RX` line per received frame, which gwmon counts, and `Connected to MUXS.` when the network server connection is up.
- **Stop, start, restart:** `/etc/init.d/S99gwmon stop|start|restart` acts on gwmon and Station together. To restart Station alone, `kill $(pidof station)`: gwmon starts it again after 1 s and counts the restart.
- **AWS IoT Core for LoRaWAN:** [docs/aws-iot-core-setup.md](docs/aws-iot-core-setup.md) has the console steps to register the gateway and a device, and which downloaded file gets which name.
- **Results:** [docs/issue4-basicstation-aws.md](docs/issue4-basicstation-aws.md) (it describes the `S60station` init script that issue #7 replaced).
- Station's remote shell (`rmtsh`) is compiled out. The gateway is managed over SSH.

## gwmon

`gwmon` is the gateway monitor daemon. Its source is in [gwmon/](gwmon/), and `base_external/package/gwmon` builds it into the image. It is a TCP status server that owns the hardware watchdog (version 1, [docs/issue6-gwmon.md](docs/issue6-gwmon.md)), and since version 2 it also starts Basics Station, keeps it running and reports gateway health ([docs/issue7-gwmon-v2.md](docs/issue7-gwmon-v2.md)).

- **Start at boot:** `/etc/init.d/S99gwmon` runs `gwmon -d -s /usr/bin/station-run.sh -l /var/log/station.log -T /dev/i2c-1`. `/etc/init.d/S99gwmon stop|restart` also work, and act on Station too. Settings go in `/etc/default/gwmon`: `GWMON_ARGS` for more options, `GWMON_STATION=""` to run gwmon without Station.
- **Status:** `nc <pi-address> 9000` prints one line and closes:

  ```
  gwmon 2.0.0 uptime=1234s daemon_uptime=1200s watchdog=active wd_timeout=10s wd_interval=2s wd_feeds=600 wd_last_feed_age=1s station=running station_pid=301 station_uptime=1190s station_restarts=0 station_fails=0 uplinks=12 last_uplink_age=37s temp=31.5C
  ```

  | Field | Meaning |
  |---|---|
  | `uptime`, `daemon_uptime` | Time since boot, and since gwmon started. |
  | `watchdog` | `active`, `disabled` (`-w none`), `unavailable` (the device could not be opened), `error` (the last feed failed), `starving` (gwmon has given up on Station and no longer feeds it) or `fake` (host test). The `wd_*` fields follow when a device is open. |
  | `station` | `running`, `backoff` (it exited; gwmon is waiting before the next start), `failed` (5 failed starts in a row), `unconfigured` (no `cups.uri` or `tc.uri`: nothing to run) or `off`. |
  | `station_pid`, `station_uptime` | The running Station process and how long ago gwmon started it. |
  | `station_restarts` | How many times gwmon has started Station again since gwmon itself started. |
  | `station_fails` | Failed starts in a row: starts that ended within 30 s. It is 0 again once Station has run for 30 s. |
  | `uplinks` | Frames that Station received and passed on to the network server since gwmon started, counted from the `RX` lines in `/var/log/station.log`. |
  | `last_uplink_age` | Time since the last of those lines was read, or `never`. |
  | `temp` | Temperature of the WM1302 board, from its STTS751 sensor on `/dev/i2c-1`, or `unavailable`. |

  [docs/issue7-gwmon-v2.md](docs/issue7-gwmon-v2.md) says where each field comes from and what its limits are.
- **Watchdog:** gwmon opens `/dev/watchdog`, sets a 10 s timeout and feeds it every 2 s from its main loop. If gwmon is killed or hangs, the Pi resets about 10 s later. On SIGTERM or SIGINT it writes the magic close character first, so `S99gwmon stop` and a normal shutdown don't reset the Pi.
- **Station supervision:** gwmon starts Station as a child process and learns of its exit at once (SIGCHLD). It starts Station again after 1 s. If a start ends within 30 s, it counts as failed and the delay doubles: 2, 4, 8, 16 s. After the 5th failed start in a row gwmon logs that it gives up and stops feeding the watchdog, so the Pi resets about 10 s later. Every exit and every restart is in syslog: `grep gwmon /var/log/messages`. A gateway with no credentials is not a failure: gwmon reports `station=unconfigured` and keeps feeding the watchdog.
- **If the Pi ever resets in a loop:** put an empty file named `gwmon.disable` on the SD card's boot partition. `S99gwmon` then leaves gwmon, the watchdog and Station off. To run Station by hand in that state: `/usr/bin/station-run.sh &`.
- **Options:** `gwmon [-d] [-p port] [-w device] [-t timeout] [-i interval] [-s program] [-r count] [-S seconds] [-l logfile] [-T i2c-device]`. `make -C gwmon check` builds it for the host and tests it against a fake watchdog file and a fake Station script. `make -C gwmon valgrind` does the same under Valgrind.

## AI use

Code written with LLM help carries a comment linking the shared chat sessions, following the course [HOWTO](https://github.com/cu-ecen-aeld/aesd-assignments/wiki/HOWTO-Reference-Use-of-ChatGPT-or-Other-Web-Content-in-Source-Code).

| Issue | Shared session |
|---|---|
| #1 Buildroot base image | https://claude.ai/code/cshk_01CSAPnyaYmJc1hcbrUg8bScPJ4y3B8gaWrv83AucuEYdA |
| #2 SPI, I2C and WM1302 reset | https://claude.ai/code/cshk_01CSAPnvczn7U1rhz8Wn7mvALHP1X5aHUucnKHJGvS8E1v |
| #3 sx1302_hal package and lora_pkt_fwd | https://claude.ai/code/cshk_01CSAPnwU8kGpRLfK6nchbsXUG2a95em6aXdDoBJsXAhS9 |
| #4 Basics Station and AWS IoT Core for LoRaWAN | https://claude.ai/code/cshk_01CSAPnz8sDPokK7N8rieHo1BXzy3XPsziDucST29D43Kh |
| #5 Network, time and credential provisioning | https://claude.ai/code/cshk_01CSAPnyKYshomy4KcvdEtyKAXn5vdMngjU3SW9R1aadXg |
| #6 gwmon v1: TCP status server and hardware watchdog | https://claude.ai/code/cshk_01CSAPnx7BhY3Nsk5bW261b3NkPKAXvdTJyxZN6b8vcSPT |
| #7 gwmon v2: Basics Station supervision and gateway health | https://claude.ai/code/cshk_01CSAPnyUYrsMvoThgHLYdiX7npiZ7nu2SeVLaZKVhC3Lx |
| #12 Reset script in the sx1302-hal package, boot order and Buildroot version | https://claude.ai/code/cshk_01CSAPnyB6NYsQjh8cnLyFAbCunAiAa9mYaAhYh9v1jy8o |
