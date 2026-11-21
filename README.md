# Raspberry Pi 5 LoRaWAN Gateway (ECEN 5713 Final Project)

An 8-channel LoRaWAN gateway built from a Raspberry Pi 5 and a Seeed WM1302 (Semtech SX1302) concentrator. It runs a custom Buildroot image with LoRa Basics Station, which forwards to AWS IoT Core for LoRaWAN. A gateway monitor daemon, `gwmon`, supervises the forwarder, feeds the hardware watchdog and reports health over TCP.

- **Project Overview:** [Project Overview wiki page](https://github.com/cu-ecen-aeld/final-project-sawa9885/wiki/Project-Overview)
- **Video:** [Sam Walker Final Project Video](https://github.com/cu-ecen-aeld/final-project-sawa9885/wiki/Sam-Walker-Final-Project-Video) (outline, challenges and lessons learned)
- **Schedule:** [Project-Schedule](https://github.com/users/sawa9885/projects/1/views/1?groupedBy%5BcolumnId%5D=435387974)

## Build

On an Ubuntu host (24.04 under WSL2 works) with the [Buildroot host packages](https://buildroot.org/downloads/manual/manual.html#requirement-mandatory) installed:

```bash
git clone --recursive https://github.com/cu-ecen-aeld/final-project-sawa9885.git
cd final-project-sawa9885
./build.sh
```

Under WSL2, build in the Linux filesystem (not `/mnt/c`) and drop the Windows entries from `PATH` first, since Buildroot refuses a `PATH` with spaces: `export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.

The image is `buildroot/output/images/sdcard.img`. [docs/issue9-final-check.md](docs/issue9-final-check.md) has the check of exactly these steps from a fresh clone (issue #9), with the build time. `./clean.sh` removes the build output, and `./save_config.sh` saves `menuconfig` changes to `base_external/configs/aesd_pi5_defconfig`.

- `base_external/` is the `BR2_EXTERNAL` tree: the defconfig, board scripts, the packages (`sx1302-hal`, `basicstation`, `gwmon`) and the rootfs overlay.
- `base_external/board/pi5/genimage.cfg.in` lays the card out like Raspberry Pi OS: a 128 MB FAT32 boot partition at 8 MiB. With Buildroot's stock layout (a 32 MB FAT16 partition at sector 1) our Pi 5 did not start Linux.
- `base_external/board/pi5/config.txt` replaces Buildroot's `config_5.txt`. It adds `dtparam=spi=on` and `dtparam=i2c_arm=on` for the WM1302 HAT: the SX1302 is on `/dev/spidev0.0` and its temperature sensor is at 0x39 on `/dev/i2c-1`. `/etc/modules-load.d/wm1302.conf` loads `i2c-dev` at boot.
- `/usr/bin/wm1302-reset.sh` resets the WM1302 (GPIO17 for the SX1302, GPIO5 for the SX1261) with libgpiod's `gpioset` on the RP1 chip (`pinctrl-rp1`, `gpiochip0`), not sysfs GPIO. The `sx1302-hal` package installs it, next to the `reset_lgw.sh` that the HAL tools call, because those tools are what need it (it was in the rootfs overlay until issue #12). [Boot order](#boot-order) says when it runs. The image has libgpiod 1.6 rather than 2.x, because the Bootlin stable toolchain has 5.4 kernel headers and `libgpiod2` needs 5.10. The kernel still has the v1 GPIO uAPI (`CONFIG_GPIO_CDEV_V1=y`).

### Buildroot version

Buildroot is the `buildroot/` submodule, pinned to commit [`679b9ead7620bbf193620d1ebf56f53c1764d37a`](https://gitlab.com/buildroot.org/buildroot/-/commit/679b9ead7620bbf193620d1ebf56f53c1764d37a). That commit is the tag `2026.02.3`, on the `2026.02.x` long-term support branch. `git -C buildroot describe --tags` prints the tag, and `git submodule status` prints the commit.

The image starts from that release's `raspberrypi5_defconfig`. On our board, a Pi 5 Rev 1.1 with the bootloader EEPROM of 2026-05-11, the stock image never started Linux: the root filesystem's mount count stayed 0 (issue #1). Issue #1 changed three things, and the tests of issue #16 on 2026-11-21 took each one out again ([docs/pi5-buildroot-bringup.md](docs/pi5-buildroot-bringup.md)):

- **The FAT boot sector (the fix).** genimage builds the boot filesystem as a separate file, so `mkfs.fat` writes 0 into the boot sector's "hidden sectors" field even though the partition starts at sector 16384. With that field at 0 the board does not boot. `genimage.cfg.in` passes `-h 16384` (commit `d78c27d`), and lays the card out like Raspberry Pi OS: a 128 MB FAT32 boot partition at 8 MiB (commit `206ef0e`). Buildroot's stock layout, 32 MB FAT16 at sector 1 with the field at 0, does not boot either.
- **`bcm2712-d-rpi-5-b.dtb` (not needed).** `aesd_pi5_defconfig` also builds this D0 device tree (`d78c27d`), because issue #1 thought it was the fix. The test showed that the firmware on our board loads `bcm2712d0-rpi-5-b.dtb`, which the stock defconfig already builds, and boots fine without the extra file. It is kept; it costs 77 KB.
- **The firmware overlays (not needed to boot).** `BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTB_OVERLAYS=y` (`36a9f8e`) puts `overlays/` with `overlay_map.dtb` on the boot partition. The board boots without it, and `dtparam=spi=on` and `dtparam=i2c_arm=on` still work. It is kept for any later `dtoverlay=` line.

The guide also says how to check a board's stepping and bootloader and what to change in the stock defconfig (issue #16).

## Flash and first boot

The only per-gateway step is flashing a card. Every gateway gets the same image, and a flashed gateway registers itself in AWS the first time it boots ([Zero-touch provisioning](#zero-touch-provisioning) says how).

1. Put the microSD in the PC's card reader and open an elevated PowerShell (Run as administrator) in the repo. Find the card's disk number, then flash it:

   ```powershell
   .\scripts\flash-gateway.ps1 -List
   .\scripts\flash-gateway.ps1 -DiskNumber 3 -Image \\wsl.localhost\Ubuntu\home\<user>\final-project-sawa9885\buildroot\output\images\sdcard.img
   ```

   The script writes the image and reads it back, puts a new random secret on the card and records the secret's fingerprint in the allow-list. It asks before it erases the card; `-Force` skips the question. It needs the AWS CLI, signed in (`aws login`), and the provisioning function deployed once (below).
2. Put the card in the Pi, connect Ethernet and power it on. Nothing is typed and no file is copied: about 40 s later the gateway shows as Connected in AWS IoT Core for LoRaWAN, under the name `gateway-<EUI>`.
3. Log in over SSH as `root` if you want to look. Dropbear accepts only the public key that the overlay installs in `/root/.ssh/authorized_keys`; password logins are off. `grep gateway-provision /var/log/messages` shows what the first boot did.

For Wi-Fi instead of Ethernet, copy a `wpa_supplicant.conf` to the top level of the card's boot partition after flashing (start from `base_external/board/pi5/wpa_supplicant.conf.example`).

### By hand, without the provisioning function

A gateway can still be given its credentials as files, as in issues #4 and #5. Write `sdcard.img` with Raspberry Pi Imager ("Use custom") or balenaEtcher, then copy the files to the top level of the card's boot partition (the FAT partition that Windows and macOS mount). None of them is ever in the repo or the image, and `.gitignore` excludes their names.

| File on the boot partition | Installed as | Contents |
|---|---|---|
| `wpa_supplicant.conf` (optional) | `/etc/wpa_supplicant.conf` | Wi-Fi network. Start from `base_external/board/pi5/wpa_supplicant.conf.example`. |
| `cups.uri` | `/etc/station/cups.uri` | One line: the CUPS endpoint, `https://<id>.cups.lorawan.<region>.amazonaws.com:443`. |
| `cups.trust` | `/etc/station/cups.trust` | CUPS server trust certificate, as downloaded from AWS. |
| `cups.crt` | `/etc/station/cups.crt` | Gateway certificate (AWS names it `<id>.cert.pem`). |
| `cups.key` | `/etc/station/cups.key` | Gateway private key (AWS names it `<id>.private.key`). |
| `health.endpoint`, `health.crt`, `health.key` (optional) | `/etc/gwmon-health/{endpoint,crt,key}` | gwmon's own AWS IoT identity for its health reports ([issue #13](docs/issue13-health.md)). `scripts/create-health-thing.sh create <EUI> <dir>` makes them. |
| `tc.uri`, `tc.trust`, `tc.crt`, `tc.key` (optional) | `/etc/station/tc.*` | The same four for a direct LNS connection (`wss://<id>.lns.lorawan.<region>.amazonaws.com:443`, `lns.trust`). Not needed with CUPS, which fetches them. |

At boot, `S35provision` installs each file it finds with mode 0600 (`/etc/station` is 0700) and deletes it from the boot partition. To change a file later, put the new one on the boot partition and reboot.

[docs/aws-iot-core-setup.md](docs/aws-iot-core-setup.md) says where each `cups.*` file comes from in the AWS console. A gateway that finds `cups.uri` or `tc.uri` in `/etc/station` never asks the provisioning function.

## Zero-touch provisioning

Issue #10. The design and the test results are in [docs/issue10-provisioning.md](docs/issue10-provisioning.md).

1. **Flash.** `scripts/flash-gateway.ps1` writes two small files to the card's boot partition next to the image's own: `provision.secret`, 64 random hex characters made for this card, and `provision.url`, the address of the provisioning function. It records the SHA-256 fingerprint of the secret in the allow-list as unused. The secret itself is never shown or kept on the PC.
2. **First boot.** `S35provision` moves the two files into `/etc/gateway-provision` (mode 0600). `S45gateway-provision` starts `/usr/sbin/gateway-provision` in the background. On a gateway with no Basics Station credentials it reads the concentrator's EUI, waits for the clock and posts the EUI and the secret to the function over HTTPS (`curl`, checked against the CA bundle). If the network or the function is not there, it tries again after 5 s, 10 s, 20 s, 40 s and then every 60 s. Meanwhile gwmon reports `station=unconfigured` and keeps the board up.
3. **The function** ([provisioning/](provisioning/)) is an AWS Lambda function with a public HTTPS address. It hashes the secret and asks the allow-list to consume the fingerprint. For a fingerprint that is listed and unused, it registers the gateway in AWS IoT Core for LoRaWAN (US915), creates its certificate and returns `cups.uri`, `cups.trust`, `cups.crt` and `cups.key`. An unknown secret gets HTTP 403 and a used one HTTP 409, both are logged, and neither creates anything in AWS.
4. **Connected.** `gateway-provision` installs the four files in `/etc/station` (mode 0600), deletes the used secret and restarts gwmon, which starts Basics Station. From then on the gateway has credentials, and `gateway-provision` exits at every boot without a request.

Who owns a gateway is not part of this: the function registers any gateway that shows a valid secret.

### What is stored where

| What | Where | Notes |
|---|---|---|
| The gateway's secret | On the card only: `provision.secret` on the boot partition, then `/etc/gateway-provision/secret` (0600) | Deleted when the gateway is provisioned. Never on the PC, in AWS or in a log |
| The secret's fingerprint (SHA-256) | The allow-list: the DynamoDB table `aesd-gateway-provisioning-allowlist` | With `state` (`unused` or `used`), `created_at` and an optional `label`; after use also `used_at` and `gateway_eui`. Not secret |
| The function's address | `provision.url` on the card, then `/etc/gateway-provision/url` | Deleted with the secret. It is an output of the CloudFormation stack |
| The gateway's private key | `/etc/station/cups.key` (0600) on the gateway | AWS IoT creates it inside the function, which returns it once over HTTPS and neither stores nor logs it |
| The gateway's certificate, the CUPS address and its trust certificate | `/etc/station/cups.crt`, `cups.uri`, `cups.trust` | The certificate is also in AWS IoT, associated with the gateway |
| The LNS address and credentials | `/etc/station/tc.*` | Basics Station fetches them from CUPS, as before |
| The function's log | CloudWatch log group `/aws/lambda/aesd-gateway-provisioning`, kept 90 days | One line per request: the outcome, the EUI and the first 8 characters of the fingerprint |

The allow-list is a stand-in. It belongs in the SoilData API, the company's own backend, and sits behind a two-method interface ([provisioning/src/allowlist.py](provisioning/src/allowlist.py)) so that an HTTP implementation can replace the table.

### Deploy the function

Once per AWS account and region, from Git Bash or a Linux shell, with the AWS CLI signed in:

```bash
provisioning/deploy.sh
```

It runs the host tests, creates the CloudFormation stack `aesd-gateway-provisioning` from [provisioning/template.yaml](provisioning/template.yaml) and uploads `provisioning/src` as the function's code. The stack holds the function, its public address, its IAM role, the allow-list table and the log group, and nothing else. The account must already have the role `IoTWirelessGatewayCertManagerRole` ([docs/aws-iot-core-setup.md](docs/aws-iot-core-setup.md), step 2.7).

The function's own role allows only what it does: write its log, `dynamodb:UpdateItem` on the allow-list table, `iotwireless:GetServiceEndpoint`, `CreateWirelessGateway`, `GetWirelessGateway`, `GetWirelessGatewayCertificate`, `AssociateWirelessGatewayWithCertificate` and `DisassociateWirelessGatewayFromCertificate`, and `iot:CreateKeysAndCertificate`, `UpdateCertificate` and `DeleteCertificate`. It cannot delete or list gateways, and it cannot add fingerprints.

IAM permissions that the person who deploys needs:

| For | Actions |
|---|---|
| The stack | `cloudformation:CreateChangeSet`, `DescribeChangeSet`, `ExecuteChangeSet`, `DescribeStacks`, `DescribeStackEvents`, `GetTemplateSummary`, and `DeleteStack` to remove it |
| The function's role | `iam:CreateRole`, `GetRole`, `PutRolePolicy`, `GetRolePolicy`, `DeleteRolePolicy`, `DeleteRole`, and `iam:PassRole` for that role to `lambda.amazonaws.com` |
| The function and its address | `lambda:CreateFunction`, `GetFunction`, `GetFunctionConfiguration`, `UpdateFunctionCode`, `UpdateFunctionConfiguration`, `DeleteFunction`, `CreateFunctionUrlConfig`, `GetFunctionUrlConfig`, `DeleteFunctionUrlConfig`, `AddPermission`, `RemovePermission` |
| The table | `dynamodb:CreateTable`, `DescribeTable`, `DeleteTable` |
| The log group | `logs:CreateLogGroup`, `PutRetentionPolicy`, `DescribeLogGroups`, `DeleteLogGroup` |

Flashing needs less: `cloudformation:DescribeStacks` on the stack, and `dynamodb:DescribeTable` and `dynamodb:PutItem` on the table.

### Revoke a gateway

To cut a gateway off, take its certificates away. It has two: its own (`cups.crt`), and the LNS certificate that AWS's CUPS server made for it when it first connected (`tc.crt`). `<EUI>` is the gateway EUI, which is in the gateway's name in the console.

```bash
aws iotwireless get-wireless-gateway --identifier <EUI> --identifier-type GatewayEui --query Id --output text
aws iotwireless get-wireless-gateway-certificate --id <gateway Id> --query "[IotCertificateId,LoRaWANNetworkServerCertificateId]" --output text
aws iotwireless disassociate-wireless-gateway-from-certificate --id <gateway Id>
aws iot update-certificate --certificate-id <certificate Id> --new-status INACTIVE     # for each of the two
aws iot delete-certificate --certificate-id <certificate Id>                           # for each of the two
aws iotwireless delete-wireless-gateway --id <gateway Id>      # only to remove the gateway record as well
```

Read the two certificate IDs before the `disassociate` step: it drops both from the gateway record and leaves them active in the account. This was done to the issue #4 registration of our Pi while it was connected ([docs/issue10-provisioning.md](docs/issue10-provisioning.md)). The connection that was open stayed open. When Basics Station was restarted, both CUPS and the LNS refused it, so a revoked gateway is out at its next reconnect at the latest.

A revoked gateway cannot provision itself again: its secret is used, and the function refuses it. To bring the hardware back, flash its card again. The new card's first boot gives the same gateway record a new certificate.

To cancel a card that was flashed but never booted (lost, or flashed by mistake), delete its fingerprint from the allow-list. `flash-gateway.ps1` prints the fingerprint when it flashes the card. From Git Bash:

```bash
aws dynamodb delete-item --table-name aesd-gateway-provisioning-allowlist --key '{"fingerprint":{"S":"<fingerprint>"}}'
```

### Tests

- `python -m unittest discover -s provisioning/test -v` runs the function's handler against a fake AWS and a fake allow-list (valid, reused and unknown secret, AWS failures, an EUI that is already registered), and, on a Linux host with `curl` and `jq`, the gateway's `gateway-provision` script against a fake function (retry, refusal, a gateway that already has credentials).
- `powershell -ExecutionPolicy Bypass -File scripts\test\flash-gateway-test.ps1` runs the flash script with a file in place of the card. Its header lists the exit codes of `flash-gateway.ps1`.

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
| `S35provision` | this repo, rootfs overlay | Installs the Wi-Fi and Basics Station credentials and the provisioning secret it finds on the boot partition, then deletes them there. |
| `S40network` | Buildroot (`ifupdown-scripts`) | `ifup -a`: only the loopback interface, since `eth0` is not `auto`. |
| `S41ifplugd` | this repo, rootfs overlay | Starts `ifplugd`, which brings `eth0` up with DHCP when the cable has a link. |
| `S41wifi` | this repo, rootfs overlay | Starts Wi-Fi if `/etc/wpa_supplicant.conf` exists. |
| `S45gateway-provision` | this repo, rootfs overlay | Starts `gateway-provision` in the background. Without Basics Station credentials it asks the provisioning function for them ([Zero-touch provisioning](#zero-touch-provisioning)); with them it exits at once. |
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

A gateway that has no credentials yet is the one exception. There `station-run.sh` stops before either reset, and `gateway-provision` (started by `S45gateway-provision`) resets the concentrator once, through the same `util_chip_id`, to read the EUI it sends to the provisioning function. When the credentials arrive it restarts gwmon, and the two resets above follow.

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

`gwmon` is the gateway monitor daemon. Its source is in [gwmon/](gwmon/), and `base_external/package/gwmon` builds it into the image. It is a TCP status server that owns the hardware watchdog (version 1, [docs/issue6-gwmon.md](docs/issue6-gwmon.md)), and since version 2 it also starts Basics Station, keeps it running and reports gateway health ([docs/issue7-gwmon-v2.md](docs/issue7-gwmon-v2.md)). Version 2.1 publishes that report to AWS IoT Core every 5 minutes ([docs/issue13-health.md](docs/issue13-health.md)).

- **Start at boot:** `/etc/init.d/S99gwmon` runs `gwmon -d -s /usr/bin/station-run.sh -l /var/log/station.log -T /dev/i2c-1 -P /usr/bin/gwmon-publish.sh -I 300 -O 30`. `/etc/init.d/S99gwmon stop|restart` also work, and act on Station too. Settings go in `/etc/default/gwmon`: `GWMON_ARGS` for more options, `GWMON_STATION=""` to run gwmon without Station.
- **Status:** `nc <pi-address> 9000` prints one line and closes:

  ```
  gwmon 2.1.0 uptime=1234s daemon_uptime=1200s watchdog=active wd_timeout=10s wd_interval=2s wd_feeds=600 wd_last_feed_age=1s station=running station_pid=301 station_uptime=1190s station_restarts=0 station_fails=0 uplinks=12 last_uplink_age=37s temp=31.5C publish=ok publishes=4 publish_fails=0 last_publish_age=95s
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
  | `publish` | The last health report to AWS IoT Core: `ok`, `failing`, `never` (none tried yet), `unconfigured` (no credentials in `/etc/gwmon-health`) or, without `-P`, absent. `publishes` and `publish_fails` count reports sent and attempts that failed; `last_publish_age` is the time since the last report sent. |

  [docs/issue7-gwmon-v2.md](docs/issue7-gwmon-v2.md) says where each field comes from and what its limits are.
- **Watchdog:** gwmon opens `/dev/watchdog`, sets a 10 s timeout and feeds it every 2 s from its main loop. If gwmon is killed or hangs, the Pi resets about 10 s later. On SIGTERM or SIGINT it writes the magic close character first, so `S99gwmon stop` and a normal shutdown don't reset the Pi.
- **Station supervision:** gwmon starts Station as a child process and learns of its exit at once (SIGCHLD). It starts Station again after 1 s. If a start ends within 30 s, it counts as failed and the delay doubles: 2, 4, 8, 16 s. After the 5th failed start in a row gwmon logs that it gives up and stops feeding the watchdog, so the Pi resets about 10 s later. Every exit and every restart is in syslog: `grep gwmon /var/log/messages`. A gateway with no credentials is not a failure: gwmon reports `station=unconfigured` and keeps feeding the watchdog.
- **Health reports (issue #13):** every 5 minutes gwmon runs `/usr/bin/gwmon-publish.sh` as a child, with the report as JSON on its standard input. The script publishes it with `mosquitto_pub` (QoS 1, retained) to `aesd/gateway/<EUI>/health` in AWS IoT Core, using its own certificate from `/etc/gwmon-health`. gwmon kills an attempt that has not finished after 30 s, so a hung connection never delays the watchdog. syslog gets one line when publishing starts failing and one when it works again. `GWMON_PUBLISH_INTERVAL` and `GWMON_PUBLISH_TIMEOUT` in `/etc/default/gwmon` change the timing, `GWMON_PUBLISH=""` turns it off. The latest report can be read with `aws iot-data get-retained-message --topic aesd/gateway/<EUI>/health`.
- **If the Pi ever resets in a loop:** put an empty file named `gwmon.disable` on the SD card's boot partition. `S99gwmon` then leaves gwmon, the watchdog and Station off. To run Station by hand in that state: `/usr/bin/station-run.sh &`.
- **Options:** `gwmon [-d] [-p port] [-w device] [-t timeout] [-i interval] [-s program] [-r count] [-S seconds] [-l logfile] [-T i2c-device] [-P program] [-I seconds] [-O seconds]`. `make -C gwmon check` builds it for the host and tests it against a fake watchdog file, a fake Station script and a fake publish program. `make -C gwmon valgrind` does the same under Valgrind. `make -C gwmon publish-check` runs the real `gwmon-publish.sh` and `mosquitto_pub` against a local mosquitto broker with TLS (needs `mosquitto`, `mosquitto-clients` and `openssl`).

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
| #9 Clean-build check, final docs and demo video outline | https://claude.ai/code/cshk_01CSAPnzsPKVdxh1B9DwcKyTH5somisBTRS2fF3ChsBWUS |
| #10 Zero-touch gateway provisioning | https://claude.ai/code/cshk_01CSAPnw19XXA81xkir2Ei316vsRvZPpL3YkJGDGzNdFWr |
| #12 Reset script in the sx1302-hal package, boot order and Buildroot version | https://claude.ai/code/cshk_01CSAPnyB6NYsQjh8cnLyFAbCunAiAa9mYaAhYh9v1jy8o |
| #11 Sensor readings reach the SoilData API (node registration script, Station log helper) | https://claude.ai/code/cshk_01CSAPnvLCUHW6djnp5K19mA6Jjr4s6zEaqsQpq9xFyAZz |
| #13 Gateway health reports to AWS IoT Core | https://claude.ai/code/cshk_01CSAPnymCy5ytzpd5YbDkk7GDXruVUH4TTxff71FBWGSW |
| #15 Remote shell through AWS IoT secure tunneling | https://claude.ai/code/cshk_01CSAPnxBTBTRh5jk4ugaU6pVi3LQF38pioZ4gsNNQDvGQ |
| #16 Bring-up guide: Buildroot on a current Raspberry Pi 5 | https://claude.ai/code/cshk_01CSAPnxDBboMaxHaJjdAn7c8T4sFdVoroq8wMccpHTtHo |
