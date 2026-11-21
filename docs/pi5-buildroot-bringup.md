# Bring-up guide: Buildroot on a current Raspberry Pi 5 (D0 stepping)

Issue #16. Buildroot's stock `raspberrypi5_defconfig` did not start Linux on our board. This guide says what went wrong, what fixed it, how to check your own board, and what to change if you start from the stock defconfig.

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #16): ISSUE16_SESSION_LINK -->

**Our board and versions**

| | |
|---|---|
| Board | Raspberry Pi 5 Model B Rev 1.1, revision code `c04171` (4 GB) |
| Bootloader EEPROM | build timestamp 2026-05-11 11:20:02 UTC, version hash `66f33f7e651cf482…` |
| Buildroot | `2026.02.3` LTS, commit `679b9ead7620bbf193620d1ebf56f53c1764d37a` (the `buildroot/` submodule) |
| Kernel | `raspberrypi/linux` commit `21b410140c47ffab5668399f6f143c7d7b935c8b` (Linux 6.12.61), as in the stock defconfig |
| Firmware package | `rpi-firmware` commit `063bcab6c8a90efb0d19f69d88cbbc7ec79cab68` |

The board facts in the first two rows were read on 2026-11-20 from the running gateway, read-only, from `/proc/device-tree/model`, `/proc/cpuinfo` and `/proc/device-tree/chosen/bootloader/` (see [Check your own board](#check-your-own-board)).

**Summary**

| # | Problem in the stock image | Fix | Commit | Proven necessary? |
|---|---|---|---|---|
| 1 | No `bcm2712-d-rpi-5-b.dtb` on the boot partition | Build it in `BR2_LINUX_KERNEL_INTREE_DTS_NAME` | [`d78c27d`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/d78c27d) | Yes, by the order of the fixes (see 1). To be reproduced on Nov 29. |
| 2 | No `overlays/` directory, so no `overlay_map.dtb` | `BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTB_OVERLAYS=y` | [`36a9f8e`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/36a9f8e) | No: never tested without it. To be captured on Nov 29. |
| 3 | 32 MB FAT16 boot partition at sector 1 | Raspberry Pi OS-style layout: 128 MB FAT32 at 8 MiB | [`206ef0e`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/206ef0e), finished in [`d78c27d`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/d78c27d) | No: on its own it did not fix the boot. To be captured on Nov 29. |

The order of events on 2026-11-04 (issue #1): the layout was changed first (`206ef0e`, 12:37) and the board still did not boot. The device tree was added next (`d78c27d`, 14:09) and the card booted on the first try. The overlays were added six minutes later (`36a9f8e`, 14:15). The [issue #1 close-out comment](https://github.com/cu-ecen-aeld/final-project-sawa9885/issues/1) says the same: `206ef0e`'s message names the layout as the boot fix, and that was wrong.

## 1. The device tree for the D0 stepping

**Symptom, as recorded.** Linux never started. The root filesystem's mount count stayed 0, so the kernel never mounted it, and even an initramfs build never ran userspace. The same kernel `Image`, DTBs, initramfs and `config.txt` booted when started via `tryboot` from a Raspberry Pi OS card (commit messages of `206ef0e` and `d78c27d`, issue #1 comment). What the HDMI screen, the debug UART and the status LED showed was not recorded: **to be captured on Nov 29.**

**Cause.** The BCM2712 exists in two steppings, C1 (the first Pi 5 boards) and D0 (newer boards). The pinned kernel has two D0 device tree sources, and they are not the same file:

- `arch/arm64/boot/dts/broadcom/bcm2712d0-rpi-5-b.dts` (in the `dtb-$(CONFIG_ARCH_BCM2835)` list, Makefile line 27): it changes `&gio` and sets the `brcm,bcm2712d0-pinctrl`, `brcm,bcm2712d0-aon-pinctrl` and `brcm,bcm2712d0-vc6` compatibles.
- `arch/arm64/boot/dts/broadcom/bcm2712-d-rpi-5-b.dts` (Makefile line 10, the upstream name): it changes `&gio_aon`.

The Raspberry Pi firmware tree at the pinned commit also ships both as prebuilt files in `boot/`, and they differ (78,740 and 78,748 bytes). The stock defconfig builds only `bcm2712-rpi-5-b`, `bcm2712d0-rpi-5-b` and `bcm2712-rpi-500`, and Buildroot's `board/raspberrypi/readme.txt` lists the same three for the Pi 5. The card booted once `bcm2712-d-rpi-5-b.dtb` was added and nothing else changed, and the Raspberry Pi OS card that booted the same kernel has that file at its root. So the firmware on our board loads `bcm2712-d-rpi-5-b.dtb`.

That last step is inferred from what fixed the boot. No log in this repo shows the firmware naming the file it loads. **To be captured on Nov 29** with the bootloader's UART log (see the checklist). Other people have reported the same naming confusion: an [Ubuntu bug report](https://lists.snapcraft.io/archives/foundations-bugs/2025-February/531795.html) says Rev 1.1 boards have the D0 stepping and got the wrong DTB, and a [March 2026 U-Boot patch series](https://lists.denx.de/pipermail/u-boot/2026-March/612147.html) adds a D0 device tree because Rev 1.1 boards could not boot Linux properly without it. Both are third-party sources, not Raspberry Pi documentation.

**Fix** ([`d78c27d`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/d78c27d)), in `base_external/configs/aesd_pi5_defconfig`:

```diff
-BR2_LINUX_KERNEL_INTREE_DTS_NAME="broadcom/bcm2712-rpi-5-b broadcom/bcm2712d0-rpi-5-b broadcom/bcm2712-rpi-500"
+BR2_LINUX_KERNEL_INTREE_DTS_NAME="broadcom/bcm2712-rpi-5-b broadcom/bcm2712d0-rpi-5-b broadcom/bcm2712-d-rpi-5-b broadcom/bcm2712-rpi-500"
```

`post-image.sh` copies every built `.dtb` to the boot partition, so the card has the device tree for either stepping and for either name. (Buildroot's `BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTBS` would copy the firmware's prebuilt DTBs instead. We did not use it, because those are built from a different kernel tree than the one in the image.)

## 2. The firmware overlays and `overlay_map.dtb`

**Symptom, as recorded.** None of its own. The overlays went in six minutes after the device tree fix, in the same debugging session, to give the firmware everything a Raspberry Pi OS card has. The history has no boot with the device tree but without the overlays (README, "Buildroot version"). **To be captured on Nov 29.**

**Cause.** The stock defconfig has `# BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTB_OVERLAYS is not set`. Without it, `package/rpi-firmware/rpi-firmware.mk` (lines 55 to 61) installs neither the `*.dtbo` overlays nor `overlays/overlay_map.dtb`. The firmware looks for overlays under `overlays/`: our running board reports `overlay_prefix` = `overlays/` in `/proc/device-tree/chosen`. `overlay_map.dtb` tells the firmware which variant of an overlay to use on each SoC family. Decompiled from the pinned firmware, it maps for example `disable-bt` to `disable-bt-pi5` and `disable-wifi` to `disable-wifi-pi5` on `bcm2712` (Raspberry Pi's [configuration documentation](https://www.raspberrypi.com/documentation/computers/configuration.html), "The overlay map file", describes the same purpose). Our `config.txt` uses only `dtparam=` lines (`spi=on`, `i2c_arm=on`), which the base device tree handles, so the overlays may not be needed for our image to boot.

**Fix** ([`36a9f8e`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/36a9f8e)), in `aesd_pi5_defconfig`:

```diff
-# BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTB_OVERLAYS is not set
+BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTB_OVERLAYS=y
```

This puts 361 `.dtbo` files, `overlay_map.dtb` and an empty `README` under `overlays/` on the boot partition. It also selects `BR2_LINUX_KERNEL_DTB_OVERLAY_SUPPORT` (`package/rpi-firmware/Config.in`).

## 3. The SD card layout

**Symptom, as recorded.** The same as in section 1. `206ef0e` was made while the device tree was still missing, so the card did not boot with the new layout either, and that commit's message is wrong to call the layout the fix (issue #1 comment). Whether the stock layout boots once the device tree and overlays are present was never tested. **To be captured on Nov 29.** Raspberry Pi's [`config.txt` documentation](https://www.raspberrypi.com/documentation/computers/config_txt.html#autoboot-txt) says bootable partitions may be FAT12, FAT16 or FAT32 and need a `config.txt` on the Pi 5, so the stock FAT16 partition may well be fine.

**Cause (suspected).** Buildroot's stock `board/raspberrypi/genimage.cfg.in` makes a 32 MB FAT16 boot partition that starts at sector 1, with the MBR boot flag set and no disk signature. Raspberry Pi OS uses a FAT32 boot partition at sector 16384 (8 MiB). While debugging we made our card match the card that booted.

**Fix.** `base_external/board/pi5/genimage.cfg.in` (new in [`206ef0e`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/206ef0e), changed in [`d78c27d`](https://github.com/cu-ecen-aeld/final-project-sawa9885/commit/d78c27d)):

- 128 MB FAT32 boot partition (`-F 32 -n BOOT`) at `offset = 8M`, partitions aligned to 1 MiB.
- `-h 16384` (`d78c27d`): genimage builds `boot.vfat` as a separate file, so `mkfs.fat` cannot know the partition offset. `-h` writes it into the boot sector's "hidden sectors" field, as `mkfs.fat` does on a real partition.
- No `bootable` flag, and `disk-signature = 0x41455344` (`d78c27d`), as on Raspberry Pi OS.

Buildroot's `board/raspberrypi/post-image.sh` only takes a genimage template from its own board directory, so `206ef0e` also adds `base_external/board/pi5/post-image.sh` (the same file list, our template) and points `BR2_ROOTFS_POST_IMAGE_SCRIPT` at it.

## Check your own board

**Stepping.** Read the board revision code: `grep Revision /proc/cpuinfo` on Linux, or `cat /proc/device-tree/model` for the name. In the new-style code, bits 0 to 3 are the board revision (0 for Rev 1.0, 1 for Rev 1.1), bits 4 to 11 the type (0x17 is the Pi 5), bits 12 to 15 the processor (4 is the BCM2712) and bits 20 to 22 the memory size ([revision codes](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-revision-codes)). Ours is `c04171`: Pi 5, BCM2712, 4 GB, Rev 1.1. Raspberry Pi's documentation names no stepping per revision ([processors page](https://www.raspberrypi.com/documentation/computers/processors.html#bcm2712) only says the BCM2712 is used in the Pi 5, 500 and CM5). That Rev 1.1 means D0 comes from the third-party reports cited in section 1. The D0 compatibles (`brcm,bcm2712d0-*`) in `/proc/device-tree` are not a reliable check: only `bcm2712d0-rpi-5-b.dtb` sets them, not the `bcm2712-d-rpi-5-b.dtb` that our board loads.

**Bootloader EEPROM version.**

- No OS needed: boot with no card (or a card the bootloader rejects) and an HDMI screen attached. The bootloader's diagnostics screen shows its version and date ([boot diagnostics](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#boot-diagnostics)).
- On Raspberry Pi OS: `vcgencmd bootloader_version` or `rpi-eeprom-update` (same page, "Reading the current bootloader version").
- On our Buildroot image, which has neither tool: the firmware leaves its details in the device tree.

  ```sh
  tr -d '\0' < /proc/device-tree/chosen/bootloader/version; echo     # git hash of the bootloader build
  od -An -tx1 /proc/device-tree/chosen/bootloader/build-timestamp     # Unix time, 32-bit big-endian
  ```

  On our board the second line prints `6a 01 bb 62`; `date -u -d @$((0x6a01bb62))` on the PC gives `Mon May 11 11:20:02 UTC 2026`, the 2026-05-11 EEPROM. These properties are not described in Raspberry Pi's documentation (it only describes `tryboot` and `partition` under `chosen/bootloader`), so treat their meaning as observed, not specified.

**Which device tree the firmware asks for.** Neither the documentation we read nor the running Linux system says it: `/proc/device-tree` shows the tree after the firmware merged it, not the file name. The bootloader's own log does. Add `uart_2ndstage=1` to `config.txt` (it must be in `config.txt` itself, not in an `include`d file; see [`uart_2ndstage`](https://www.raspberrypi.com/documentation/computers/config_txt.html)) and connect the Pi 5's three-pin `UART` debug connector at 115200 8N1 ([debug UART](https://www.raspberrypi.com/documentation/computers/configuration.html#primary-and-secondary-uart)). The log lists the files the firmware loads. The exact wording of those lines on our board is **to be captured on Nov 29**.

## Start here: changes to the stock config (Buildroot 2026.02.3)

Starting from `make raspberrypi5_defconfig` in a `BR2_EXTERNAL` tree:

1. **`raspberrypi5_defconfig`** (save your copy as `configs/<name>_defconfig` in the external tree):

   ```
   BR2_LINUX_KERNEL_INTREE_DTS_NAME="broadcom/bcm2712-rpi-5-b broadcom/bcm2712d0-rpi-5-b broadcom/bcm2712-d-rpi-5-b broadcom/bcm2712-rpi-500"
   BR2_PACKAGE_RPI_FIRMWARE_INSTALL_DTB_OVERLAYS=y
   BR2_ROOTFS_POST_IMAGE_SCRIPT="$(BR2_EXTERNAL_<name>_PATH)/board/pi5/post-image.sh"
   ```

   The first line is the one that made our board boot. The post-image script is a copy of Buildroot's `board/raspberrypi/post-image.sh` that reads the template from its own directory; ours is [base_external/board/pi5/post-image.sh](../base_external/board/pi5/post-image.sh).
2. **`genimage.cfg.in`**: copy [base_external/board/pi5/genimage.cfg.in](../base_external/board/pi5/genimage.cfg.in). Compared with `board/raspberrypi/genimage.cfg.in` it changes `size = 32M` to `128M`, adds `extraargs = "-F 32 -n BOOT -h 16384"`, `align = 1M`, `disk-signature` and `offset = 8M`, and drops `bootable = "true"`. Until the Nov 29 test, this layout is the tested one, not a proven requirement.
3. **`config.txt`**: Buildroot's `board/raspberrypi/config_5.txt` (`kernel=Image`, `disable_overscan=1`) boots unchanged; nothing in it needed fixing. Add only what your hardware needs (we add `dtparam=spi=on` and `dtparam=i2c_arm=on` for the WM1302 HAT, [base_external/board/pi5/config.txt](../base_external/board/pi5/config.txt)). While bringing up a new board, also add `uart_2ndstage=1` to get the bootloader log on the debug UART.

After flashing, check that the boot partition has `bcm2712-d-rpi-5-b.dtb` and `overlays/overlay_map.dtb`, and that `fdisk -l` shows the boot partition at sector 16384.

## Reproduce on Nov 29

Goal (definition of done, box 4): with each fix taken out the board fails as described, and with it back it boots. About **35 minutes** in all: no Buildroot rebuild is needed. Fixes 1 and 2 are tested by renaming files on the boot partition of one flashed card. That is faithful: those fixes only add files to the boot partition, and the kernel, rootfs and `config.txt` are the same with and without them. Fix 3 changes the layout, so it needs a second image, which `scripts/pi5-bringup/stock-layout-image.sh` repacks in about a second from the clean build's own files (tried on 2026-11-20).

Do this **before** the issue #9 flash, on the same card: write the card with Raspberry Pi Imager, not `flash-gateway.ps1`. Imager puts no provisioning secret and no AWS credentials on the card, so none of these boots changes anything in AWS. `flash-gateway.ps1` for issue #9 then erases the card.

You need: the Pi with the HAT, an HDMI screen (no keyboard), Ethernet, a phone camera. Optional: a Raspberry Pi Debug Probe (or any 3.3 V USB serial adapter with the Pi 5 debug connector cable) for the UART log. Evidence goes in `docs/logs/` of this branch. Photos are fine as `.jpg`.

**0. Baseline (5 min).** Flash `C:\dev\aesd\images\issue9-clean-sdcard.img` (the issue #9 clean build) with Raspberry Pi Imager ("Use custom", no OS customisation). If you have the debug probe, open the card's boot partition in Explorer and add the line `uart_2ndstage=1` at the end of `config.txt`, and start a serial terminal at 115200 that logs to a file. Boot with Ethernet and HDMI. Within about a minute the HDMI screen shows the `aesd-pi5 login:` prompt. Then, from PowerShell (the card has a new host key, hence the throwaway known-hosts file):

```powershell
$pi = '<pi-address>'   # from the router's DHCP list
ssh -i $HOME\.ssh\aesd_pi5_ed25519 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no root@$pi 'tr -d "\0" </proc/device-tree/model; echo; uname -r; ls /boot /boot/overlays | head; ls -l /dev/spidev0.0 /dev/i2c-1' | Tee-Object docs\logs\issue16-baseline.log
```

Save: `docs/logs/issue16-baseline.log`, and `issue16-baseline-uart.log` if you captured the UART. In the UART log, find the line that names the `.dtb` it loads: that settles which name the firmware asks for (section 1).

**1. Device tree removed (7 min).** Power off, card into the PC. On the boot partition rename `bcm2712-d-rpi-5-b.dtb` to `bcm2712-d-rpi-5-b.dtb.off`. The partition now has exactly the stock DTB set (`bcm2712-rpi-5-b.dtb`, `bcm2712d0-rpi-5-b.dtb`, `bcm2712-rpi-500.dtb`). Eject, boot. Expected, from the record: Linux does not start, no login prompt, no answer to `ping $pi` after 3 minutes. Photograph the HDMI screen (any diagnostics screen or the last text shown) and note the green/red LED pattern. Save: `issue16-no-d-dtb-hdmi.jpg`, `issue16-no-d-dtb.txt` (what you saw, LED pattern, ping result), and `issue16-no-d-dtb-uart.log`. Then rename the file back, boot, and confirm the login prompt again (one line in the `.txt`).

**2. Overlays removed (7 min).** Card into the PC, rename the `overlays` folder to `overlays.off`, eject, boot. Expected: **unknown**, the record has no such test. If it boots, run the baseline `ssh` command again and save it as `issue16-no-overlays.log`: `/dev/spidev0.0` and `/dev/i2c-1` show whether the `dtparam=` lines still worked. If it does not boot, save the photo, notes and UART log as in step 1 (`issue16-no-overlays-*`). Rename the folder back.

**3. Stock card layout (15 min).** In WSL (the script path is this branch's worktree; once merged, use `scripts/pi5-bringup/` in any checkout):

```sh
cd ~/aesd/issue9-clean/final-project-sawa9885
bash /mnt/c/dev/aesd/final-project-sawa9885/.claude/worktrees/issue-16-pi5-bringup-guide-917bcb/scripts/pi5-bringup/stock-layout-image.sh \
    buildroot/output ~/aesd/issue16-stock-layout
/sbin/fdisk -l ~/aesd/issue16-stock-layout/sdcard-stock-layout.img
```

`fdisk` must show the boot partition at sector 1, 32M, with the `*` boot flag. The image has the same kernel, DTBs (including `bcm2712-d-rpi-5-b.dtb`), overlays and rootfs as the clean build, so only the layout differs. Flash `\\wsl.localhost\Ubuntu\home\<user>\aesd\issue16-stock-layout\sdcard-stock-layout.img` with Imager, add `uart_2ndstage=1` again if you use the probe, boot. Expected: **unknown** (section 3). Save the `fdisk` output and the result as `issue16-stock-layout.log` (plus `-hdmi.jpg` / `-uart.log`). Then go on with the issue #9 flash, which rewrites the card with the real layout. Its first boot is the "with it back" check for fix 3.

**Afterwards.** Fill in the "to be captured on Nov 29" places in this guide from the evidence, change "Proven necessary?" in the summary table, and tick box 4 of issue #16 only if each removed fix really made the board fail. If the overlays or the layout turn out not to matter, say so here and leave box 4 for the instructor to judge against the evidence.
