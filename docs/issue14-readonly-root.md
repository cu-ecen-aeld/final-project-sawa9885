# Issue #14: read-only root filesystem with a writable data partition

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #14): ISSUE14_SESSION_LINK -->

A gateway in the field loses power without warning. With a read-write ext4 root, a cut at the wrong moment can corrupt the card. Since this issue the root filesystem is never written: everything that has to persist is on a small third partition, and everything else is in RAM.

## Card layout

| # | Partition | Size | Filesystem | Mounted | How |
|---|---|---|---|---|---|
| 1 | boot | 128 MB | FAT32 | `/boot`, **read-only** | `mount -a` (fstab). `S35provision` and `S41wifi` remount it read-write only for the moment they write. |
| 2 | rootfs | 256 MB | ext4 | `/`, **read-only** | The kernel mounts root read-only by default (`root_mountflags = MS_RDONLY` in `init/do_mounts.c`), and `inittab` no longer remounts it (`BR2_TARGET_GENERIC_REMOUNT_ROOTFS_RW` off). |
| 3 | data | 64 MB | ext4, label `data` | `/data`, read-write, `noatime` | `S00datafs`, the first init script. |

genimage creates and formats partition 3 at build time (`image data.ext4` in `base_external/board/pi5/genimage.cfg.in`), so a freshly flashed card needs no manual step.

## What writes to the root filesystem, and where it goes now

Found with a read-only look at the running gateway (image of `6c2014d`, issue #10 card) on 2026-11-20: `mount`, `/etc/fstab`, `/etc/inittab`, and `find / -xdev -newer /etc/os-release`, which lists every file on the root filesystem changed since the image was built. The list had `/var/lib/chrony/drift`, `/var/lib/seedrng/seed.credit`, `/etc/dropbear/dropbear_ed25519_host_key`, 20 files in `/etc/station`, `/etc/gateway-provision/` and `/crond.reboot`. The rest of the table comes from reading the init scripts.

| Writer | File(s) | Before | Now | How |
|---|---|---|---|---|
| `S35provision` (issue #5) | `cups.*`, `tc.*` from the boot partition | `/etc/station` | `/data/station` | `/etc/station` is a symlink to `../data/station` |
| `gateway-provision` (issue #10) | `cups.{uri,trust,crt,key}` from the function, its work directory | `/etc/station`, `/etc/gateway-provision` | `/data/station`, `/data/gateway-provision` | symlinks; the scripts are unchanged |
| `S35provision` | `provision.secret`, `provision.url` | `/etc/gateway-provision` | `/data/gateway-provision` | symlink |
| `S35provision` (issue #13) | `health.{endpoint,crt,key}` | `/etc/gwmon-health` | `/data/gwmon-health` | symlink; `gwmon-publish.sh` only reads them and writes its error file to `/var/run` |
| `S35provision` (issue #15) | `tunnel.{cert.pem,key.pem,endpoint,thing}` | `/etc/aws-iot-device-client` | `/data/aws-iot-device-client` | symlink; `S00datafs` makes the directory 0700, which the client requires. The client writes only its lock file (`/var/run`); with SDK logging off it creates nothing in `~/.aws-iot-device-client` (checked in its v1.10.1 source) |
| Basics Station itself | `cups-bak.*`, `tc-bak.*`, `*.done`, new `cups.*`/`tc.*` when CUPS rotates credentials | `/etc/station` (its `--home`) | `/data/station` | symlink. `station.conf` and `version.txt` now ship in `/usr/share/basicstation`; `S00datafs` links them into `/data/station` at every boot, so a new image brings its own `station.conf` |
| Basics Station | `station.pid`, temp files | `/tmp` | `/tmp` (tmpfs) | unchanged |
| Basics Station | `station.log` (3 × 2 MB) | `/var/log` → `/tmp` | tmpfs | unchanged |
| `S35provision` | `wpa_supplicant.conf` (optional Wi-Fi) | `/etc/wpa_supplicant.conf` | `/data/wpa_supplicant.conf` | path changed in `S35provision` and `S41wifi` (its install writes a `.new` file next to the target, which a symlink in a read-only `/etc` would not allow) |
| `dropbear -R` | SSH host key, generated at the first boot | `/etc/dropbear` | `/data/dropbear` | Buildroot links `/etc/dropbear` to `/var/run/dropbear` (a new key at every boot) when the root is read-only; `post-build.sh` points it at `../data/dropbear` so the key, and the fingerprint in `known_hosts`, survive reboots |
| `chronyd` | `drift` | `/var/lib/chrony` | `/data/chrony/drift` | `driftfile` in `/etc/chrony.conf`; `S00datafs` makes the directory owned by `chrony` |
| `seedrng` (`S01seedrng`) | the random seed carried across boots | `/var/lib/seedrng` | `/data/seedrng` | `SEEDRNG_ARGS="-d /data/seedrng"` in `/etc/default/seedrng` |
| `syslogd` | `/var/log/messages` | `/var/log` → `/tmp` | tmpfs | unchanged |
| `S41wifi` | `aesd-net.log`, 30 s after every boot | `/boot` (FAT, every boot) | `/var/log/aesd-net.log`; copied to `/boot` only when Wi-Fi is configured | FAT has no journal, so an Ethernet gateway no longer writes it at all |
| `udhcpc`, `ifupdown`, `wpa_supplicant`, `start-stop-daemon` | PID files, `ifstate`, control sockets | `/var/run` → `/run` | tmpfs | unchanged |
| `udhcpc` | `/etc/resolv.conf` | → `/run/resolv.conf` | tmpfs | unchanged (Buildroot's symlink) |
| `mount` | `/etc/mtab` | → `/proc/self/mounts` | – | unchanged |
| DHCP leases | none: BusyBox `udhcpc` keeps no lease file | – | – | – |
| BusyBox `crond` | `/crond.reboot` (marks the first start since boot for `@reboot` jobs) | `/` | not written | `CONFIG_PID_FILE_PATH` is empty, so the path is `/crond.reboot`. On a read-only root the create fails silently; it only matters for `@reboot` jobs, and there are no cron jobs |
| BusyBox `ash` | `/root/.ash_history` at logout | `/root` | not written | history is not kept across logins; harmless |
| `/var/cache`, `/var/spool`, `/var/tmp`, `/var/lib/misc` | | → `/tmp` | tmpfs | unchanged (Buildroot's symlinks) |
| `boot-report` (new, this issue) | `boots.csv`, `boot-count` | – | `/data/log` | one line per boot, for the power-cut test |
| `gwmon` | nothing: it reads the watchdog, the I2C sensor and `station.log` | – | – | – |
| `S00datafs` (new) | `datafs.status`, `datafs.log` | – | `/run` | tmpfs |

`/tmp` and `/run` are tmpfs (Buildroot's fstab); `/var/run` → `/run` and `/var/log` → `/tmp` are Buildroot's symlinks. So `/tmp`, `/var/run` and `/var/log` were already in RAM before this issue; the work here was everything else in the table.

## S00datafs: mounting /data, and what happens when it is damaged

`S00datafs` runs first in `rcS`, before `S01seedrng`, so every later script finds `/data` in place.

1. **Reset.** If `/boot/data.reset` exists, the partition is formatted again and the file deleted. This is how `/data` is reset (README, "Data partition").
2. **Blank partition.** If `blkid` finds no filesystem at all, there is nothing to lose: it is formatted.
3. **Check.** `e2fsck -p` (preen) fixes what a power cut can leave without asking; ext4's journal makes this quick. If preen leaves errors, `e2fsck -y`.
4. **Mount** with `noatime`.
5. **Failure mode.** If the partition is missing (an old two-partition card), cannot be repaired, or does not mount, a 16 MB tmpfs is mounted on `/data` instead. The gateway still boots, SSH works (with a new host key, so `known_hosts` complains), gwmon feeds the watchdog and reports `station=unconfigured`, because Station has no credentials. Nothing persists. The partition is **not** formatted automatically in that case: a repair by hand might still save the credentials, and with zero-touch provisioning the secret has been used, so a format means flashing the card again. `/run/datafs.status` says `tmpfs` and `/run/datafs.log` has the `e2fsck` output.
6. **Populate.** Creates `station`, `gateway-provision`, `dropbear`, `seedrng` (mode 0700), `chrony` (owner `chrony`) and `log`, and links `station.conf` and `version.txt` into `station`.

The outcome is one word in `/run/datafs.status`: `ok`, `repaired`, `formatted`, `reset` or `tmpfs`. `boot-report` copies it into `/data/log/boots.csv`.

The root filesystem gets no `fsck`: it is never mounted read-write, so a power cut cannot leave it inconsistent.

## Zero-touch provisioning still works

`flash-gateway.ps1` (issue #10) writes `provision.secret` and `provision.url` to the boot partition, as before. At the first boot `S35provision` finds them, remounts `/boot` read-write, moves them to `/etc/gateway-provision` (now `/data/gateway-provision`), and remounts `/boot` read-only. `gateway-provision` then writes the credentials to `/etc/station` (now `/data/station`). Neither script's paths changed; only `S35provision` got the remount and the Wi-Fi path. `flash-gateway.ps1` needs no change: it erases the whole card, and Windows does not mount the two `0x83` (Linux) partitions.

## Build and image checks

Built on 2026-11-20 from commit `b3d3db8` in a fresh clone of the branch under WSL (`~/aesd/issue14-tree`), with the repo's own `./build.sh` and nothing else: no `.config`, no manual step. The only shortcut was sharing the download directory (`buildroot/dl` is a symlink to the main tree's). 34.5 minutes, under the shared build lock. Log excerpt: [logs/issue14-build.log](logs/issue14-build.log).

`sdcard.img`, 456 MiB, SHA-256 `484f550a3694eda999a84c2ba8cd62a0f7af46284e4b5776e094c4914519f55f`.

Checked offline with the build's own `fdisk`, `debugfs`, `dumpe2fs`, `e2fsck -n` and `mtools` (no root, nothing mounted): [logs/issue14-image-check.log](logs/issue14-image-check.log).

| Check | Result |
|---|---|
| Partitions | 1: FAT32 128 MiB at sector 16384; 2: Linux 256 MiB; 3: Linux 64 MiB |
| `data.ext4` | label `data`, ext4 with journal, 0 reserved blocks, state clean, `e2fsck -fn` clean, empty apart from `lost+found` |
| `/etc/fstab` | `/dev/root / ext4 ro,noauto`, `/boot vfat ro,noatime`, `/data ext4 noauto,noatime`, tmpfs on `/tmp` and `/run` |
| `/etc/inittab` | `#::sysinit:/bin/mount -o remount,rw /` (commented out by Buildroot) |
| Kernel | `cmdline.txt` has neither `ro` nor `rw`; the kernel's default is read-only (`root_mountflags = MS_RDONLY \| MS_SILENT`) |
| Symlinks | `/etc/station`, `/etc/gateway-provision`, `/etc/dropbear` → `../data/...`; `/var/log` → `../tmp`; `/var/run` → `../run`; `/etc/resolv.conf` → `../run/resolv.conf`; no `/etc/wpa_supplicant.conf` |
| `/data` in the rootfs | empty mount point |
| `/usr/share/basicstation` | `station.conf`, `version.txt` |
| Tools | `/sbin/e2fsck`, `/sbin/mke2fs`, `blkid`, `/usr/sbin/boot-report` (0755) |
| Init scripts | `S00datafs` first, `S90boot-report` before `S99gwmon` |
| `chrony.conf`, `/etc/default/seedrng` | `driftfile /data/chrony/drift`, `SEEDRNG_ARGS="-d /data/seedrng"` |
| `rootfs.ext4` | `e2fsck -fn` clean |

`boot-report` was also run three times on the build host with a fake Station log: it wrote the header and lines 1, 2, 3 with the running boot number.

**Not tested: a boot.** QEMU is not installed on this host, and the Pi 5 kernel (`bcm2712_defconfig`) has no virtio drivers, so a QEMU boot would need a different kernel and different device names (`/dev/vda` instead of `/dev/mmcblk0`), which would test something else. The live Pi could not be used: the layout change needs a reflash. So `S00datafs`, the remounts in `S35provision`, and Station on `/data` have not run yet.

## On the hardware

The layout change cannot be tried on a running card: the card has to be flashed. The test card is the spare, which ran the combined Sprint 3 image before; the original gateway card is not touched.

### 1. Flash (Sam: about 5 minutes)

Power the Pi down, put the spare card in the PC, and in an elevated PowerShell:

```powershell
& C:\dev\aesd\images\flash-issue14.ps1
```

It lists the disks, and `flash-gateway.ps1` asks before it erases the one it names (disk 2 by default; `-DiskNumber <n>` otherwise): answer only if it is the spare card. The image is `C:\dev\aesd\images\issue14-main-sdcard.img`, `main` plus this issue (IMAGE_PATH). After the write, `copy-boot-files.ps1` (from the issue #9 session) puts the `health.*` and `tunnel.*` files on the boot partition next to the new provisioning secret, and prints only names and sizes. Card back in the Pi, power on.

This is the normal zero-touch flash, so the first boot also tests box 3: `S35provision` moves the secret and the `health.*` and `tunnel.*` files from the read-only `/boot` to `/data`, and `gateway-provision` writes Station's credentials there. For a registered EUI the provisioning function makes a new certificate and revokes the old one (issue #10), so the certificate of the card's previous flash stops working; that is the same card.

### 2. First boot: what to check

Ethernet in, power on, wait about a minute, then (the host key is new, so use a scratch `known_hosts` or remove the old line):

```powershell
ssh -i $HOME\.ssh\aesd_pi5_ed25519 root@<pi-address> "mount; cat /run/datafs.status /run/datafs.log; ls -la /etc/station /data /data/station; touch /x"
```

Expected:

- [ ] `/dev/root on / type ext4 (ro,...)`, `/dev/mmcblk0p1 on /boot type vfat (ro,...)`, `/dev/mmcblk0p3 on /data type ext4 (rw,noatime,...)`, `tmpfs on /tmp`, `tmpfs on /run`.
- [ ] `/run/datafs.status` is `ok`.
- [ ] `/etc/station -> ../data/station`; `/data/station` has `cups.*` (and, a few seconds after Station starts, `tc.*` and the `-bak` files), `station.conf -> /usr/share/basicstation/station.conf`.
- [ ] `touch /x` fails with "Read-only file system".
- [ ] `nc <pi-address> 9000` shows `station=running`, and AWS shows the gateway Connected.
- [ ] Reboot once (`reboot`), log in again: the SSH host key is the same (no warning), `grep gateway-provision /var/log/messages` says "credentials are in place, no provisioning request", Station reconnects.
- [ ] `cat /data/log/boots.csv`: two lines, `ro`, `ok`, a `station_s` value, `fs_errors` 0.

### 3. Forced resets and one power pull

The issue's box was reworded at the owner's request from 20 pulls by hand to 10 automated forced resets plus 1 real power pull.

**10 forced resets (automated, about 15 minutes).** `scripts/test/forced-reset-test.sh <pi-address> 10` runs from the PC over SSH. Each reset is `echo b > /proc/sysrq-trigger`: the kernel restarts the board at once, with no shutdown, no unmount and no sync. Resets 1-4 come 5-60 s after Station connected, 5-7 as soon as SSH answers on a fresh boot (about 5 s in: `/data` just mounted, Station not started), and 8-10 at 3-20 s after SSH (Station resetting the radio, waiting for the clock, talking to CUPS, writing its `-bak` files). Before a reset of the last two kinds the Pi is rebooted cleanly to get a fresh boot to cut. After every reset the script waits for SSH and for Station's "Connected to MUXS", then checks: `/` mounted `ro`, `/data` `rw`, `/run/datafs.status` `ok` or `repaired`, and no filesystem or SD card error in `dmesg`.

**1 real power pull (Sam, 1 minute).** While Station is connected: pull the USB-C power cable, count to 5, plug it back. The same checks are then made over SSH.

**What this does not cover.** A forced reset stops the CPU at once but leaves the SD card powered, so a write the card has already accepted still completes inside the card. A real power cut can also interrupt the card's own controller in the middle of a flash write, and only the one real pull tests that, once. Moments earlier than SSH (firmware, kernel, `e2fsck` in `S00datafs`) are not reached by the resets; the root filesystem is never written, so a cut there can only leave `/data`'s journal to replay, which is what the resets at 5 s exercise.

Results: `docs/logs/issue14-forced-resets.log` and `docs/logs/issue14-power-pull.log`.

### 4. Reset test (optional)

Put an empty file named `data.reset` on the card's boot partition (from the PC), boot: `/run/datafs.status` says `reset`, `/data` is empty apart from the directories, and Station is `unconfigured` until the card is flashed again (the provisioning secret was used at the first boot).

## Status

| Definition of done | Status |
|---|---|
| `/` is mounted read-only | Built, untested on hardware: fstab, inittab and kernel default checked in the image |
| `genimage` creates `/data`; `./build.sh` with no manual steps | Done: partition 3 in the image; fresh-clone `./build.sh` |
| Credentials and Wi-Fi on `/data`, installed by `S35provision`, found by Station | Built, untested on hardware: symlinks and paths checked in the image; section 2 above |
| `/tmp`, `/var/run`, `/var/log` are tmpfs | Done in the image (Buildroot fstab and symlinks); confirm with `mount` in section 2 |
| Power-cut test: 10 forced resets + 1 real pull | Section 3 above |
| README: what is on `/data`, how to reset it | Done: README, "Data partition" |
