# Bring-up guide: Buildroot on a current Raspberry Pi 5 (D0 stepping)

Issue #16. Buildroot's stock `raspberrypi5_defconfig` did not start Linux on our board. This guide says what went wrong, what fixed it, how we proved it, how to check your own board, and what to change if you start from the stock defconfig.

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #16): https://claude.ai/code/cshk_01CSAPnxDBboMaxHaJjdAn7c8T4sFdVoroq8wMccpHTtHo -->

**Our board and versions**

| | |
|---|---|
| Board | Raspberry Pi 5 Model B Rev 1.1, revision code `c04171` (4 GB), BCM2712 D0 |
| Bootloader EEPROM | build timestamp 2026-05-11 11:20:02 UTC, version hash `66f33f7e651cf482…` |
| Buildroot | `2026.02.3` LTS, commit `679b9ead7620bbf193620d1ebf56f53c1764d37a` (the `buildroot/` submodule) |
| Kernel | `raspberrypi/linux` commit `21b410140c47ffab5668399f6f143c7d7b935c8b` (Linux 6.12.61), as in the stock defconfig |
| Firmware package | `rpi-firmware` commit `063bcab6c8a90efb0d19f69d88cbbc7ec79cab68` |

The board facts were read from the running gateway (see [Check your own board](#check-your-own-board)). "D0" is shown by the device tree the firmware chose (section 2).

## Summary

Issue #1 made three changes on 2026-11-04 and the card booted after them. On 2026-11-21 we took each one out again on the same board ([test record](#test-record-2026-11-21)):

| Change in issue #1 | Commit | Taken out on 2026-11-21 | Needed? |
|---|---|---|---|
| FAT boot sector "hidden sectors" = partition offset (`mkfs.fat -h 16384`) | [`d78c27d`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/d78c27d) | Does not boot, rootfs mount count 0 | **Yes: this is the fix** |
| Raspberry Pi OS-style card layout: 128 MB FAT32 at 8 MiB | [`206ef0e`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/206ef0e) | Stock layout does not boot, mount count 0 | Yes, as a whole (see section 1) |
| Build `bcm2712-d-rpi-5-b.dtb` | [`d78c27d`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/d78c27d) | Boots: the firmware loads `bcm2712d0-rpi-5-b.dtb` | No |
| Install firmware `overlays/` with `overlay_map.dtb` | [`36a9f8e`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/36a9f8e) | Boots, SPI and I2C still work | No (not to boot) |

This corrects the record. `206ef0e`'s message calls the layout the fix, and issue #1's close-out comment and `d78c27d`'s message call the device tree the fix. In fact `d78c27d` changed two things at once, the device tree and `mkfs.fat -h`, and the second one is what made the card boot.

## 1. The FAT boot sector and the card layout (the fix)

**Symptom.** Linux never started. The root filesystem's mount count stayed 0, so the kernel never mounted it, and even an initramfs build never ran userspace (commit messages of `206ef0e` and `d78c27d`, issue #1). The same kernel, DTBs and `config.txt` booted when started via `tryboot` from a Raspberry Pi OS card. Reproduced on 2026-11-21 (steps 4 and 5 below): no answer on the network within 100 s, where a good card answers in about 20 s, and mount count 0 read on the PC afterwards. The status LED shows the difference: a good boot is solid green at power-on, then flashing green after a few seconds; a failed boot repeats a slow cycle of a solid green pulse and a solid red pulse. The work was headless (no HDMI screen, no UART adapter), so the bootloader's screen and serial log were not captured. Without them we cannot say whether the firmware failed to load the kernel or the kernel failed later, and we did not match the LED cycle to an entry in Raspberry Pi's LED warning-code table.

**Cause.** A FAT boot sector has a "hidden sectors" field (offset 0x1C): the number of sectors on the disk before the partition. `mkfs.fat` fills it in when it formats a real partition. genimage builds `boot.vfat` as a separate file and copies it into the card image afterwards, so `mkfs.fat` writes 0. The card's own partition table says where the partition is; only the boot sector is wrong.

- Our card with only that field changed from 16384 to 0, everything else byte-for-byte the image that boots, does not boot (step 5). So on this board the field must be right.
- Buildroot's stock `board/raspberrypi/genimage.cfg.in` puts a 32 MB FAT16 boot partition at sector 1 with the field at 0 (one sector off), sets the MBR boot flag and no disk signature. That card does not boot either (step 4). We did not test which of those differences matter, so we can only say the stock layout as a whole fails; the hidden-sectors mismatch is the one difference we proved matters.
- An image from issue #1 that never booted, `aesd-pi5-sdcard-noboot.img` (kept on the build PC), has the partition at sector 16384 and the field at 0. Every image that booted has 16384.

Raspberry Pi's [`config.txt` documentation](https://www.raspberrypi.com/documentation/computers/config_txt.html#autoboot-txt) only says boot partitions may be FAT12, FAT16 or FAT32; it says nothing about the hidden-sectors field. That the Pi 5 bootloader needs it is our observation, not a documented rule.

**Fix.** `base_external/board/pi5/genimage.cfg.in`, new in [`206ef0e`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/206ef0e) and finished in [`d78c27d`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/d78c27d):

```
image boot.vfat {
	vfat {
		# -h must equal the boot partition's offset in 512-byte sectors (8 MiB = 16384).
		extraargs = "-F 32 -n BOOT -h 16384"
		...
	}
	size = 128M
}

image sdcard.img {
	hdimage {
		align = 1M
		disk-signature = 0x41455344
	}
	partition boot {
		partition-type = 0xC
		offset = 8M
		image = "boot.vfat"
	}
	...
}
```

`d78c27d` added `-h 16384`, the disk signature and dropped `bootable = "true"`; `206ef0e` made the rest. Buildroot's `board/raspberrypi/post-image.sh` only takes a genimage template from its own board directory, so `206ef0e` also adds `base_external/board/pi5/post-image.sh` (the same boot file list, our template) and points `BR2_ROOTFS_POST_IMAGE_SCRIPT` at it.

## 2. The device tree for the D0 stepping (not needed)

**What issue #1 thought.** The BCM2712 exists in two steppings, C1 (the first Pi 5 boards) and D0 (newer ones). The pinned kernel has two D0 device tree sources: `bcm2712d0-rpi-5-b.dts` (Makefile line 27, built by the stock defconfig) and the upstream-named `bcm2712-d-rpi-5-b.dts` (Makefile line 10, not built). Issue #1 concluded that the firmware asks for `bcm2712-d-rpi-5-b.dtb`, because the card booted once `d78c27d` added it. Third-party reports describe the same confusion over D0 file names ([Ubuntu bug](https://lists.snapcraft.io/archives/foundations-bugs/2025-February/531795.html), [U-Boot patch, March 2026](https://lists.denx.de/pipermail/u-boot/2026-March/612147.html)).

**What the test showed.** With `bcm2712-d-rpi-5-b.dtb` renamed away, leaving exactly the stock set (`bcm2712-rpi-5-b`, `bcm2712d0-rpi-5-b`, `bcm2712-rpi-500`), the board booted (step 2). In that boot, and also in step 3 where `bcm2712-d-rpi-5-b.dtb` was back on the card, the live device tree had the two `brcm,bcm2712d0-*pinctrl` compatibles that only `bcm2712d0-rpi-5-b.dtb` sets. So the firmware on our board loads `bcm2712d0-rpi-5-b.dtb`, which the stock defconfig already builds, and never uses `bcm2712-d-rpi-5-b.dtb`.

**In this repo.** `BR2_LINUX_KERNEL_INTREE_DTS_NAME` in `aesd_pi5_defconfig` still adds `broadcom/bcm2712-d-rpi-5-b` ([`d78c27d`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/d78c27d)). It is harmless (77 KB) and was left in, so the tested image stays the shipped one.

## 3. The firmware overlays and `overlay_map.dtb` (not needed to boot)

**What it is.** The stock defconfig has `# BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTB_OVERLAYS is not set`, so `package/rpi-firmware/rpi-firmware.mk` (lines 55 to 61) installs neither the `*.dtbo` overlays nor `overlays/overlay_map.dtb`. The firmware looks for overlays under `overlays/` (`overlay_prefix` in `/proc/device-tree/chosen`). `overlay_map.dtb` tells it which variant of an overlay to use per SoC family: decompiled from the pinned firmware, it maps for example `disable-bt` to `disable-bt-pi5` on `bcm2712` (see "The overlay map file" in Raspberry Pi's [configuration documentation](https://www.raspberrypi.com/documentation/computers/configuration.html)).

**What the test showed.** With `overlays/` renamed away, the board booted, and `/dev/spidev0.0` and `/dev/i2c-1` were present (step 3): `dtparam=spi=on` and `dtparam=i2c_arm=on` work on the base device tree. Overlays only matter once `config.txt` has a `dtoverlay=` line.

**In this repo.** `BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTB_OVERLAYS=y` ([`36a9f8e`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/36a9f8e)) is kept, so a later `dtoverlay=` line works.

## Check your own board

**Stepping and revision.** `grep Revision /proc/cpuinfo` and `cat /proc/device-tree/model`. In the new-style revision code, bits 0 to 3 are the board revision (1 = Rev 1.1), bits 4 to 11 the type (0x17 = Pi 5), bits 12 to 15 the processor (4 = BCM2712) and bits 20 to 22 the memory size ([revision codes](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-revision-codes)). Ours is `c04171`: Pi 5, BCM2712, 4 GB, Rev 1.1. Raspberry Pi's documentation names no stepping per revision ([processors page](https://www.raspberrypi.com/documentation/computers/processors.html#bcm2712)).

**Which device tree the firmware loaded.** The running system shows the merged tree, not the file name, but the D0 file leaves fingerprints. On our kernel:

```sh
B=/sys/firmware/devicetree/base     # not /proc/device-tree: that is a symlink, and find does not follow it
for f in $(find $B -name compatible); do tr '\0' ' ' < $f | grep -q bcm2712d0 && echo "${f#$B}"; done
find $B -name brcm,gpio-bank-widths | while read f; do echo "${f#$B}: $(od -An -tx1 $f)"; done
```

Two `bcm2712d0` pinctrl nodes mean `bcm2712d0-rpi-5-b.dtb`. The always-on GPIO block (`gpio@7d517c00`) has bank widths `0f 06` in both D0 files and `11 06` in the C1 file `bcm2712-rpi-5-b.dtb`. With a UART adapter on the Pi 5's three-pin `UART` connector (115200 8N1, [debug UART](https://www.raspberrypi.com/documentation/computers/configuration.html#primary-and-secondary-uart)) and `uart_2ndstage=1` in `config.txt` ([`uart_2ndstage`](https://www.raspberrypi.com/documentation/computers/config_txt.html)), the bootloader logs the files it loads; we had no adapter.

**Bootloader EEPROM version.**

- No OS needed: boot with no card and an HDMI screen attached; the diagnostics screen shows the bootloader version and date ([boot diagnostics](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#boot-diagnostics)).
- On Raspberry Pi OS: `vcgencmd bootloader_version` or `rpi-eeprom-update`.
- On our Buildroot image, which has neither tool, the firmware leaves its details in the device tree:

  ```sh
  tr -d '\0' < /proc/device-tree/chosen/bootloader/version; echo     # git hash of the bootloader build
  od -An -tx1 /proc/device-tree/chosen/bootloader/build-timestamp     # Unix time, 32-bit big-endian
  ```

  Ours prints `6a 01 bb 62`; `date -u -d @$((0x6a01bb62))` gives `Mon May 11 11:20:02 UTC 2026`. Raspberry Pi's documentation does not describe these two properties, so their meaning is observed, not specified.

**The boot sector of a card or image.** In Linux, with the boot partition's start sector `S` from `fdisk -l`:

```sh
dd if=sdcard.img bs=1 skip=$((S*512 + 0x1C)) count=4 2>/dev/null | od -An -tu4    # must print S
```

## Start here: changes to the stock config (Buildroot 2026.02.3)

From `make raspberrypi5_defconfig` in a `BR2_EXTERNAL` tree:

1. **`genimage.cfg.in`** (the one change that is needed): copy [base_external/board/pi5/genimage.cfg.in](../base_external/board/pi5/genimage.cfg.in). The essential line is `-h` equal to the boot partition's offset in sectors (`-h 16384` for `offset = 8M`). Compared with `board/raspberrypi/genimage.cfg.in` it also uses FAT32 (`-F 32`), `size = 128M`, `offset = 8M`, `align = 1M`, a `disk-signature`, and no `bootable` flag. That whole layout is what we tested; we did not test the stock layout with only a matching `-h`.
2. **`raspberrypi5_defconfig`**: point the post-image script at a copy that uses your template (Buildroot's own `board/raspberrypi/post-image.sh` only looks in its own directory; ours is [base_external/board/pi5/post-image.sh](../base_external/board/pi5/post-image.sh)):

   ```
   BR2_ROOTFS_POST_IMAGE_SCRIPT="$(BR2_EXTERNAL_<name>_PATH)/board/pi5/post-image.sh"
   ```

   The stock `BR2_LINUX_KERNEL_INTREE_DTS_NAME` is enough for a D0 board like ours. Add `BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTB_OVERLAYS=y` only if `config.txt` will use `dtoverlay=`.
3. **`config.txt`**: Buildroot's `board/raspberrypi/config_5.txt` (`kernel=Image`, `disable_overscan=1`) boots unchanged. Add what your hardware needs (we add `dtparam=spi=on` and `dtparam=i2c_arm=on` for the WM1302 HAT, [base_external/board/pi5/config.txt](../base_external/board/pi5/config.txt)), and `uart_2ndstage=1` while bringing up a board if you have a UART adapter.

After building, check the image's boot sector with the `dd` line above.

## Test record, 2026-11-21

Done at the bench in about 35 minutes, with no Buildroot rebuild, on a spare microSD card (the gateway's own card stayed out of the Pi). Every card was written with `scripts/flash-gateway.ps1` in its local allow-list mode, written and read back, and then `provision.secret` and `provision.url` were deleted from it, so no boot could change anything in AWS. There was no HDMI screen and no UART adapter, so a boot was judged by:

- **booted:** gwmon answered on TCP port 9000 within 100 s (`find-gateway.ps1` from issue #9 scans the LAN), then an SSH check;
- **failed:** no answer within 100 s, and the root filesystem's mount count, read on the PC afterwards straight from the ext4 superblock, had not moved.

| Step | Card | Result | Evidence |
|---|---|---|---|
| 1 | Issue #9 clean image (`dd5252d8…`), every fix in | Boots; gwmon up 24 s after power-on; mount count then 1 | [issue16-baseline.log](logs/issue16-baseline.log) |
| 2 | Same card, `bcm2712-d-rpi-5-b.dtb` renamed away | Boots; firmware loaded `bcm2712d0-rpi-5-b.dtb` | [issue16-no-d-dtb.log](logs/issue16-no-d-dtb.log) |
| 3 | Same card, DTB back, `overlays/` renamed away | Boots; SPI and I2C present; firmware again loaded `bcm2712d0-rpi-5-b.dtb` | [issue16-no-overlays.log](logs/issue16-no-overlays.log) |
| 4 | Stock layout (`scripts/pi5-bringup/stock-layout-image.sh`, same files) | **No boot**; mount count 0, never mounted | [issue16-stock-layout.log](logs/issue16-stock-layout.log) |
| 5 | Issue #9 clean image with only the FAT hidden-sectors field set to 0 | **No boot**; mount count 0, never mounted | [issue16-hidden-sectors-0.log](logs/issue16-hidden-sectors-0.log) |

Step 1 is the "fix back in" boot for steps 4 and 5: the same files on the fixed layout. Status LED, observed by eye: steps 1 to 3 solid green, then flashing green after a few seconds; steps 4 and 5 a slow repeating green pulse, red pulse.

### Doing it again

1. Flash the image you want to test (elevated PowerShell), then delete `provision.secret` and `provision.url` on the card's boot drive:

   ```powershell
   .\scripts\flash-gateway.ps1 -List
   .\scripts\flash-gateway.ps1 -DiskNumber <n> -Image <image> -AllowList file -AllowListFile $env:TEMP\issue16-allow.json -ProvisionUrl https://invalid.example/
   ```

2. Device tree or overlays: rename `bcm2712-d-rpi-5-b.dtb` or `overlays` on the boot drive in Explorer, boot, rename back.
3. Stock layout, in WSL from a built tree (about a second): `scripts/pi5-bringup/stock-layout-image.sh buildroot/output <out-dir>`.
4. Hidden sectors only, in WSL on a copy of a working image (FAT32 boot partition at sector 16384; its backup boot sector is partition sector 6):

   ```sh
   P=$((16384*512)); for s in 0 6; do printf '\0\0\0\0' | dd of=copy.img bs=1 seek=$((P + s*512 + 0x1C)) conv=notrunc; done
   ```

5. Reading the mount count on Windows: `wsl --mount` could not attach our USB card reader (error `0x8007000f`, and it left the disk offline until `Set-Disk -IsOffline $false`). Reading the superblock directly works: in an elevated PowerShell, open `\\.\PHYSICALDRIVE<n>` read-only, read 4096 bytes at the rootfs partition's offset (`Get-Partition`), and take the 16-bit little-endian value at byte 1024 + 0x34 (the superblock magic `0xEF53` is at 1024 + 0x38).
