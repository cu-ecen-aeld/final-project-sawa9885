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

## On the hardware: procedure for Sam (Nov 29 or later)

This cannot be tested on the live card: the layout changes, so the card has to be flashed. **The current card is the known-good demo card. Use a second microSD card** if you have one, and keep the demo card as it is until the tests below pass.

### 1. Flash the spare card (about 10 minutes)

Keep the original card as it is: it is the fallback for the demo. **Do not use the normal zero-touch flash for this test.** The Pi's EUI is already registered, and for a registered EUI the provisioning function creates a new certificate and revokes the old one (`docs/issue10-provisioning.md`, "An EUI that is already registered"). The original card would then stop connecting until it is flashed again. Instead, the spare card gets a copy of the original card's Station credentials, so no request is made and nothing in AWS changes.

1. With the **original** card in the Pi, booted and on the LAN, put the **spare** card in the PC.
2. Elevated PowerShell in the repo. The allow-list goes to a local file and the address is a dummy, so this makes no AWS call; the secret it writes is never used, because the card will already have credentials:

   ```powershell
   .\scripts\flash-gateway.ps1 -List
   .\scripts\flash-gateway.ps1 -DiskNumber <n> -Image IMAGE_PATH -AllowList file -AllowListFile $env:TEMP\issue14-allowlist.jsonl -ProvisionUrl https://example.invalid/
   ```

3. Copy the Station credentials from the running Pi straight onto the spare card's boot partition (drive letter from step 2, here `E:`). Nothing is printed:

   ```powershell
   scp -i $HOME\.ssh\aesd_pi5_ed25519 "root@<pi-address>:/etc/station/cups.*" E:\
   ```

   If the original card has `/etc/gwmon-health` or `/etc/aws-iot-device-client` (issues #13, #15), copy those too, renamed to `health.endpoint`, `health.crt`, `health.key` and `tunnel.cert.pem`, `tunnel.key.pem`, `tunnel.endpoint`, `tunnel.thing`. They are not needed for this test.
4. Eject, shut the Pi down (`poweroff`), swap cards: spare card in the Pi.

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

### 3. Power-cut test (20 cuts, about 25 minutes)

`boot-report` records every boot by itself in `/data/log/boots.csv`, and counts the boot as soon as it starts, so a boot that was cut early shows as a missing number. Sam only pulls the plug and writes down the moment.

Each cut: pull the USB-C power cable, count to 5, plug it back in, and pull again at the moment in the table, counted from plugging in. Writing the moment down is enough: for example "cut 3 at 6 s".

| Cuts | Pull at | What the Pi is doing | One cycle |
|---|---|---|---|
| 1–7 | 3–10 s | Firmware, kernel, `S00datafs` (`e2fsck`, mount), `S35provision` | ~15 s |
| 8–14 | 20–35 s | Station starting; on the first boots, Station writing the `tc.*` and `-bak` files from CUPS | ~40 s |
| 15–20 | 90 s or later | Station connected; chrony writing its drift file | ~2 min |

After cut 20, plug in and leave it alone for 2 minutes. Then the checks:

```powershell
ssh -i $HOME\.sshesd_pi5_ed25519 root@<pi-address> "cat /data/log/boots.csv; ls /data/log; cat /run/datafs.status; dmesg | grep -i -E 'ext4|fat-fs|mmc0|i/o error'; mount | grep -E ' / | /data | /boot '"
```

**Pass**, for every line in `boots.csv`: `root` is `ro`, `data` is `ok` or `repaired`, `fs_errors` is 0; the last boot has a number in `station_s` and AWS shows the gateway Connected. Missing boot numbers are the cuts that came before `S90boot-report` started or before Station connected; they pass if the next boot passes. Any `boot-<n>-dmesg.txt` in `/data/log` is a failure and holds the error lines. `journal` = `replayed` is the normal, safe outcome of a cut while `/data` was open.

Copy the output into `docs/logs/issue14-power-cut.log`, with the list of moments.

**Total for Sam: about 45 minutes** (flash 10, first-boot checks 5, cuts 25, final checks 5).

**Back to the original card:** power off, swap cards. Nothing on it or in AWS was changed.

### 4. Reset test (optional)

Put an empty file named `data.reset` on the card's boot partition (from the PC), boot: `/run/datafs.status` says `reset`, `/data` is empty apart from the directories, and Station is `unconfigured` until the card is flashed again (the provisioning secret was used at the first boot).

## Status

| Definition of done | Status |
|---|---|
| `/` is mounted read-only | Built, untested on hardware: fstab, inittab and kernel default checked in the image |
| `genimage` creates `/data`; `./build.sh` with no manual steps | Done: partition 3 in the image; fresh-clone `./build.sh` |
| Credentials and Wi-Fi on `/data`, installed by `S35provision`, found by Station | Built, untested on hardware: symlinks and paths checked in the image; section 2 above |
| `/tmp`, `/var/run`, `/var/log` are tmpfs | Done in the image (Buildroot fstab and symlinks); confirm with `mount` in section 2 |
| Power-cut test, 20 cuts | Needs Sam: section 3 above |
| README: what is on `/data`, how to reset it | Done: README, "Data partition" |
