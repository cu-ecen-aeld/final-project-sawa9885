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

- Buildroot is a submodule pinned to the 2026.02.3 LTS release. The image starts from Buildroot's `raspberrypi5_defconfig`.
- `base_external/` is the `BR2_EXTERNAL` tree: the defconfig, board scripts and the rootfs overlay.
- On top of `raspberrypi5_defconfig`, the defconfig installs `bcm2712-d-rpi-5-b.dtb` and the firmware overlays. Current Pi 5 firmware loads that device tree on D-stepping boards, and without it our Pi 5 never started Linux. `base_external/board/pi5/genimage.cfg.in` lays the card out like Raspberry Pi OS: a 128 MB FAT32 boot partition at 8 MiB.
- `base_external/board/pi5/config.txt` replaces Buildroot's `config_5.txt`. It adds `dtparam=spi=on` and `dtparam=i2c_arm=on` for the WM1302 HAT: the SX1302 is on `/dev/spidev0.0` and its temperature sensor is at 0x39 on `/dev/i2c-1`. `/etc/modules-load.d/wm1302.conf` loads `i2c-dev` at boot.
- `/usr/bin/wm1302-reset.sh` resets the WM1302 (GPIO17 for the SX1302, GPIO5 for the SX1261) with libgpiod's `gpioset` on the RP1 chip (`pinctrl-rp1`, `gpiochip0`), not sysfs GPIO. The image has libgpiod 1.6 rather than 2.x, because the Bootlin stable toolchain has 5.4 kernel headers and `libgpiod2` needs 5.10. The kernel still has the v1 GPIO uAPI (`CONFIG_GPIO_CDEV_V1=y`).

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

## Basics Station

`base_external/package/basicstation` builds [LoRa Basics Station](https://github.com/lorabasics/basicstation) v2.0.6 for its `corecell` platform (SX1302), `std` variant. `station` is linked statically with Station's own patched copy of sx1302_hal V2.1.0 and with mbedtls 2.28.10. Buildroot downloads both and checks their hashes, in place of the `git clone` that upstream's makefiles run. The comments in `basicstation.mk` say why the Buildroot `mbedtls` and our `sx1302-hal` library can't be used.

- **Start at boot:** `/etc/init.d/S60station`. It reads the SX1302's EUI with `util_chip_id` (which also resets the WM1302), writes it to `/var/run/station.eui`, waits up to 60 s for chronyd to set the clock, then runs `station --daemon --home /etc/station`. With no `cups.uri` or `tc.uri` in `/etc/station` it logs one line and does nothing.
- **Gateway EUI:** the concentrator's EUI. `station.conf` names `/var/run/station.eui` as its `routerid`, so the image isn't tied to one board. `grep 'gateway EUI' /var/log/messages` shows it.
- **Configuration:** `/etc/station/station.conf` (radio settings for the WM1302, no secrets). The channel plan comes from the network server. The credentials are the `cups.*` files from "Flash and first boot"; Station fetches the LNS address and credentials from CUPS and saves them as `tc.*` in the same directory.
- **Log:** `/var/log/station.log` (tmpfs, 3 x 2 MB at most). `/etc/init.d/S60station status|stop|restart`.
- **AWS IoT Core for LoRaWAN:** [docs/aws-iot-core-setup.md](docs/aws-iot-core-setup.md) has the console steps to register the gateway and a device, and which downloaded file gets which name.
- **Results:** [docs/issue4-basicstation-aws.md](docs/issue4-basicstation-aws.md).
- Station's remote shell (`rmtsh`) is compiled out. The gateway is managed over SSH.

## AI use

Code written with LLM help carries a comment linking the shared chat sessions, following the course [HOWTO](https://github.com/cu-ecen-aeld/aesd-assignments/wiki/HOWTO-Reference-Use-of-ChatGPT-or-Other-Web-Content-in-Source-Code).

| Issue | Shared session |
|---|---|
| #1 Buildroot base image | https://claude.ai/code/cshk_01CSAPnyaYmJc1hcbrUg8bScPJ4y3B8gaWrv83AucuEYdA |
| #2 SPI, I2C and WM1302 reset | https://claude.ai/code/cshk_01CSAPnvczn7U1rhz8Wn7mvALHP1X5aHUucnKHJGvS8E1v |
| #3 sx1302_hal package and lora_pkt_fwd | https://claude.ai/code/cshk_01CSAPnwU8kGpRLfK6nchbsXUG2a95em6aXdDoBJsXAhS9 |
| #4 Basics Station and AWS IoT Core for LoRaWAN | https://claude.ai/code/cshk_01CSAPnz8sDPokK7N8rieHo1BXzy3XPsziDucST29D43Kh |
| #5 Network, time and credential provisioning | https://claude.ai/code/cshk_01CSAPnyKYshomy4KcvdEtyKAXn5vdMngjU3SW9R1aadXg |
