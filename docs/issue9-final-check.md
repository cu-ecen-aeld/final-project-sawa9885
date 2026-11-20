# Issue #9: clean-build check, final docs and demo video outline

The last issue of Sprint 3: build the image from a fresh clone and check it, bring the wiki up to date with what was built, and check that every issue is closed with its evidence.

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #9): ISSUE9_SESSION_LINK -->

| Definition of done (issue #9) | Result |
|---|---|
| A fresh clone on a clean host builds with `./build.sh` | **Pass.** A new clone of `main` (`3d2ebb0`) in a new empty directory built `sdcard.img` in 37 min with no step besides the README's. [Section 1](#1-clean-clone-build) |
| The image boots, an uplink reaches AWS, and port 9000 returns status | **Not done for this image: it has not been flashed.** The gateway was running the issue #10 card on 2026-11-20: Connected in AWS, status on port 9000. That card differs from this image in 39 of 2258 files, none of them in behaviour as far as was checked. No uplink was sent. [Section 2](#2-the-image-on-the-pi) |
| The Project Overview page matches what was built | **Done.** [Section 3](#3-project-overview-wiki-page) lists what was changed |
| Every issue is closed, with a "DoD verified" comment and links to its commits | **Done for the nine Sprint 1 to 3 issues.** Five stretch-goal issues are open and were not built. [Section 4](#4-issues) |
| A "Final Project Video" wiki page has an outline, including challenges and lessons learned, linked from the overview page under Student Video Demos | **Done**: [Sam Walker Final Project Video](https://github.com/cu-ecen-aeld/final-project-sawa9885/wiki/Sam-Walker-Final-Project-Video). The video itself is not recorded yet |

## 1. Clean-clone build

Log summary: [logs/issue9-clean-build.log](logs/issue9-clean-build.log). The raw build log has 70164 lines and is not committed.

| | |
|---|---|
| Host | WSL2 on a Windows 11 laptop: Ubuntu 24.04.3 LTS, kernel 6.6.87.2, 16 CPUs, 15 GB RAM, gcc 13.3.0, GNU Make 4.3. The same host as the earlier issues |
| Directory | A new, empty directory in the Linux filesystem, not a tree that had been built in before |
| Commit | `3d2ebb05ca78f804c4cf01e1e67454e8d4d626fa`, the head of `main` on 2026-11-20. Buildroot `2026.02.3` (`679b9ead`) |
| Commands | The README's "Build" section and nothing else: the `PATH` line for WSL2, `git clone --recursive`, `cd`, `./build.sh` |
| Start | 2026-11-20 20:35:26 UTC. The clone, with the Buildroot submodule, was done at 20:35:48 |
| End | 2026-11-20 21:12:35 UTC: **37 min 9 s** from the start of the clone, `build.sh` exit status 0 |
| Image | `buildroot/output/images/sdcard.img`, 411041792 bytes, SHA-256 `dd5252d81ddbec0f822b0f84fc48e6e51a4c368f2d099268ace3db5406886a00` |

**No cache was used.** No `BR2_*` variable was set in the environment, so the download directory was the clone's own `buildroot/dl`, which did not exist before the build. The build downloaded all 49 source packages (661 MB) and checked their hashes (`BR2_DOWNLOAD_FORCE_CHECK_HASHES=y`). The defconfig does not enable ccache. This differs from the clean-clone build of issue #1, which took its sources from an existing download cache.

**How clean the host is.** The clone and the build directory were new. The host was not: it is the WSL2 installation that built every earlier issue, so the Buildroot host packages (compiler, `make`, `rsync`, `bc` and so on) were already installed. A machine without them was not tried.

**Warnings and errors.** The log has three `Error ... (ignored)` lines, all from installing the documentation of host-e2fsprogs, the same three that issue #1 recorded. Nothing else failed.

**The clone after the build.** `git status --short` printed nothing in the clone and nothing in the `buildroot` submodule: the build changes no tracked file and leaves no untracked file outside `.gitignore`.

### What is in the image

Read from `rootfs.ext2` with `debugfs`, and from `boot.vfat` with `mdir`:

- **Init scripts:** `S01seedrng S01syslogd S02klogd S02sysctl S10udevd S11modules S35provision S40network S41ifplugd S41wifi S45gateway-provision S49chronyd S50crond S50dropbear S99gwmon`, the 15 of the README's "Boot order" table. There is no `S60station`.
- **Boot partition:** the four device trees, among them `bcm2712-d-rpi-5-b.dtb`, `cmdline.txt`, `config.txt`, `overlays/` and `Image`.
- **This project's programs** are all there with mode 0755: `gwmon`, `station`, `station-run.sh`, `util_chip_id`, `lora_pkt_fwd`, `reset_lgw.sh`, `wm1302-reset.sh`, `gateway-provision`. The log summary has the size and SHA-256 of each.
- **`wm1302-reset.sh`** has SHA-256 `e4d2df66…4a3d`, the same as the file in the repo and as in issue #12. In a clean build only the `sx1302-hal` package can have put it there, since the overlay no longer has it: `packages-file-list.txt` lists it under `sx1302-hal`, with `reset_lgw.sh`, `util_chip_id`, `lora_pkt_fwd` and `global_conf.json`. That closes the point issue #12 left open about its build, which reused an output tree.
- **`gwmon`** has SHA-256 `192e8d24…3523`, the same binary as in the two builds of issue #7.

The image is not byte-for-byte the image of the earlier output tree (`edd4a301…820e`, built from `26fccd6` for issue #10). The two root filesystem trees hold the same 2288 files. 36 of them differ, all compiled programs and libraries (BusyBox, `station`, `curl`, `jq`, chrony, eudev, kmod, xz, libgpiod, libnl, `libcrypto`) and one gdb helper script of the toolchain. No script, configuration file or init script differs. Why those binaries differ was not looked into; the two trees were built in different directories and at different times.

### Host tests, run from the clean clone

[logs/issue9-host-tests.log](logs/issue9-host-tests.log)

| Test | Result |
|---|---|
| `make -C gwmon check` | 79 of 79 checks pass |
| `python3 -m unittest discover -s provisioning/test` | 32 tests pass, none skipped. The 9 first-boot tests need `jq` on the host. The host has none, so they ran with the one that `make host-jq` builds in the same Buildroot tree; without it they are skipped. `make host-jq` did not change `sdcard.img` |
| `git grep -l` for the PEM private-key marker | No match (exit status 1) |

`scripts/test/flash-gateway-test.ps1` and the Valgrind and sanitizer runs of gwmon were not repeated here. Their results are in the pages of issues #10 and #7, and the code has not changed since.

## 2. The image on the Pi

### The card that is running now

The Pi was found running at a new DHCP address, with the card that issue #10 flashed (image of commit `6c2014d`) and provisioned. These checks only read: nothing on the Pi or in AWS was changed, and the Pi was not rebooted. Log: [logs/issue9-pi-running-card.log](logs/issue9-pi-running-card.log).

| Check | Result on 2026-11-20, about 21:23 UTC |
|---|---|
| Port 9000, from a PC on the LAN | `gwmon 2.0.0 uptime=93953s ... watchdog=active ... station=running station_pid=255 station_uptime=93950s station_restarts=0 station_fails=0 uplinks=0 last_uplink_age=never temp=31.2C`: up for 26 hours, Station never restarted |
| AWS, `get-wireless-gateway-statistics` | `Connected`, `LastUplinkReceivedAt` 15:44:42 UTC, the time of Station's last `Connected to MUXS.` |
| Boot | Buildroot 2026.02.3, kernel 6.12.61, the 15 init scripts, Station's parent process is gwmon, `gateway EUI 0016c001f1135844` read through `util_chip_id` 2 s after gwmon started |
| Uplink | **None.** No node transmitted: Station's log has no uplink frame, so `uplinks=0` is right, but this check shows nothing about an uplink reaching AWS |

**How far that card is from the clean build.** Every regular file under `/bin`, `/sbin`, `/lib`, `/usr` and `/etc` on the Pi was hashed over SSH (without the gateway's credentials, the SSH host keys and Wi-Fi settings) and compared with the same file inside the clean build's `rootfs.ext2`:

- 2219 of 2258 files are identical, among them `gwmon`, `util_chip_id`, `lora_pkt_fwd`, `wm1302-reset.sh`, `reset_lgw.sh`, `station-run.sh`, `station.conf`, `S99gwmon` and every other script and configuration file but three.
- 36 differ and are the compiled programs and libraries that also differ between the two builds on the PC (section 1), `station` among them.
- 3 differ in one comment line each, the session link of issue #10: `S35provision`, `S45gateway-provision` and `gateway-provision`.
- The Pi has 4 files more, the `cups-bak.*` copies that Station makes of its credentials. The image has no file that the Pi lacks.

The kernel and the boot partition were not compared.

So the running gateway already shows the boot, the AWS connection and the status port with the same scripts and configuration, and with `reset_lgw.sh` from the package, which answers the point of issue #12. What it does not show is that **this** image boots: its rebuilt kernel, BusyBox and `station` have not run.

### Flashing the clean build: not done yet

Nothing was flashed. The clean-build image is ready, and these are the steps and the checks.

1. Put the Pi's microSD card in the PC's reader. In an elevated PowerShell in the repo, with the AWS CLI signed in:

   ```powershell
   .\scripts\flash-gateway.ps1 -List
   .\scripts\flash-gateway.ps1 -DiskNumber <n> -Image <path to the clean build's sdcard.img>
   ```

   The script must print `image SHA-256 dd5252d8…6a00`, `image written and read back` and `RESULT ok`.
2. Put the card in the Pi, connect Ethernet, power it on. Type nothing.
3. Within 2 minutes the gateway `gateway-0016c001f1135844` must show as Connected in AWS IoT Core for LoRaWAN. The Pi is already registered there from issue #10, so the provisioning function gives the same gateway record a new certificate.
4. From a PC on the LAN, `nc <pi-address> 9000` must print one status line with `station=running`.
5. Trigger an uplink from the test node. `uplinks` in the status line must go up, Station's log must have the `RX` line, and AWS must record the uplink with this gateway's EUI.
6. On the Pi, `util_chip_id` must have printed the EUI (`grep 'gateway EUI' /var/log/messages`), which is the check that issue #12 moved here, and the SHA-256 of `/usr/bin/gwmon` and `/usr/bin/station` must equal those in the log summary, which shows that the card runs this build.

## 3. Project Overview wiki page

The [Project Overview](https://github.com/cu-ecen-aeld/final-project-sawa9885/wiki/Project-Overview) page was last edited for issue #3. It was compared with `main` section by section. What changed:

| Section | Was | Now |
|---|---|---|
| Overview | gwmon "supervises the packet forwarder" | Adds that gwmon starts Basics Station, and zero-touch provisioning |
| Goals | Five goals, as planned | A table with the result of each. Goal 5, the bench comparison with the commercial gateway, is marked not done (issue #8). Zero-touch provisioning (issue #10) is added as goal 6 |
| Stretch goals | "A read-only root filesystem, and an LTE modem" | The five open stretch-goal issues, with the statement that none was built. The LTE modem was dropped and has no issue |
| Block diagram | A reference commercial gateway hearing the same uplinks; `sx1302_hal` feeding Basics Station | The provisioning function and its allow-list, the flash script and the per-card secret. The reference gateway is gone. Basics Station is shown with its own copy of the HAL, and the HAL package as tools. [block-diagram.svg](block-diagram.svg) was redrawn the same way |
| Target Build System | "Buildroot" | The release, `2026.02.3` |
| Hardware Platform | "Networking is Wi-Fi first"; the outdoor antenna "for range tests and the bench comparison" | Issue #1 on Wi-Fi and Ethernet, everything later on Ethernet. All tests on the bench, no range test. The GNSS receiver and the commercial gateway were not used. Two more Pi 5 details: no RTC, and the watchdog |
| Open Source Projects Used | Basics Station: "I'll package it" | Versions of everything, Mbed TLS, the Buildroot packages in the image, and the AWS services the provisioning function uses |
| Previously Discussed Content | Init scripts "start and stop the forwarder and gwmon" | Only gwmon has an init script; it starts Station |
| New Content | Nothing on supervision or provisioning | Process supervision, `ifplugd` and chrony, the watchdog ioctls, and the three parts of zero-touch provisioning |
| Shared Material | Company nodes and AWS account as test equipment | The same, plus: the allow-list was planned for the company's SoilData API, that part was not built, and no SoilData code is used |
| Source Code Organization | `basicstation` and `gwmon` "added in later issues"; `wm1302-reset.sh` in the overlay | The tree as it is, with `provisioning/` and `scripts/` |
| Student Video Demos | "TBD" | A link to the video page |

The schedule link and the hardware photos were checked and left as they were.

## 4. Issues

State on 2026-11-20:

| Issue | State | "DoD verified" comment | DoD boxes | Commit links |
|---|---|---|---|---|
| #1 Buildroot base image | Closed | Yes | All ticked | In the comment |
| #2 SPI, I2C and WM1302 reset | Closed | Yes | All ticked | In the comment |
| #3 sx1302_hal package and `lora_pkt_fwd` | Closed | Yes | All ticked | In the comment |
| #4 Basics Station and AWS | Closed | Yes | All ticked | **Added** in a second comment |
| #5 Network, time and credentials | Closed | Yes | All ticked | **Added** in a second comment |
| #6 gwmon v1 | Closed | Yes | All ticked | **Added** in a second comment |
| #7 gwmon v2 | Closed | Yes | All ticked | **Added** in a second comment |
| #10 Zero-touch provisioning | Closed | Yes | All ticked | **Added** in a second comment |
| #12 Reset script, boot order | Closed | Yes, "except the flash check", which moved here | All ticked, one reworded | **Added** in a second comment |

The comments of issues #4 to #7, #10 and #12 named their commits by short hash, mostly as code text, which GitHub does not turn into links. Each of those issues got one more comment that lists its commits as links. Nothing else in a closed issue was changed.

**Open, not built:** the five issues with the `stretch goal` label, #8 (bench comparison with the reference gateway), #11 (sensor readings reach the SoilData API), #13 (publish gateway health to AWS IoT Core), #14 (read-only root filesystem) and #15 (remote shell through AWS IoT secure tunneling). Whether they are closed as not planned or stay open for after the course is the owner's decision and was not made in this issue. Until then "every issue is closed" is true of the planned work only.

## Not done

- **The clean-build image has not been booted**, and **no uplink was sent** (section 2). That is the open part of this issue's first definition-of-done box.
- **The demo video is not recorded.** The wiki page has its outline.
- **The stretch-goal issues are open**, and the Project board was not edited.
- **A host without the Buildroot host packages** was not tried.
