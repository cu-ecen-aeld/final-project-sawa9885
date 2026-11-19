# Issue #12: the WM1302 reset script in the sx1302-hal package

From the Sprint 1 code review (Nov 11). The review asked three things:

| Question | Answer |
|---|---|
| Why is `wm1302-reset.sh` in the rootfs overlay when only the sx1302-hal tools use it? | It no longer is. The `sx1302-hal` package installs it. |
| When does the concentrator reset run, relative to the rest of the boot? | README, [Boot order](../README.md#boot-order). |
| Which Buildroot version is the project on? | README, [Buildroot version](../README.md#buildroot-version). |

## What changed

- `base_external/rootfs_overlay/usr/bin/wm1302-reset.sh` moved to `base_external/package/sx1302-hal/wm1302-reset.sh`. The file itself is unchanged, byte for byte.
- `sx1302-hal.mk` installs it as `/usr/bin/wm1302-reset.sh`, the same path as before, next to `reset_lgw.sh`.
- `reset_lgw.sh` still runs `/usr/bin/wm1302-reset.sh`, and `station.conf` still names the same path as Station's `radio_init`. The `basicstation` package selects `sx1302-hal`, so an image with Station always has the script.

## What was checked

Built on 2026-11-18 in WSL2 Ubuntu 24.04, in the Buildroot output tree of the earlier issues, with the branch as `BR2_EXTERNAL`. The log is [logs/issue12-reset-script-build.log](logs/issue12-reset-script-build.log).

```
rm output/target/usr/bin/wm1302-reset.sh    # the copy that the overlay had put there
make sx1302-hal-rebuild                      # the package builds, and installs the script
make                                         # root filesystem and sdcard.img
```

| Check | Result |
|---|---|
| The overlay no longer supplies the script | No `wm1302-reset.sh` under `base_external/rootfs_overlay/` |
| The package builds and installs it | `sx1302-hal-rebuild` ends with `install -D -m 0755 .../package/sx1302-hal/wm1302-reset.sh .../target/usr/bin/wm1302-reset.sh`. The file is back in the target directory before the overlay is applied |
| It is in the root filesystem | `debugfs` on `rootfs.ext2`: `/usr/bin/wm1302-reset.sh`, mode 0755, owner root, 1804 bytes |
| It is the same file as on the gateway | SHA-256 `e4d2df669962881002efd794eebfa3fd5bb9891480987f3a62322c0a252b4a3d` in `rootfs.ext2`, in the repo, and for `/usr/bin/wm1302-reset.sh` on the running Pi (`sha256sum` over SSH) |
| `reset_lgw.sh` finds it | `reset_lgw.sh` in `rootfs.ext2` runs `exec /usr/bin/wm1302-reset.sh`. On the Pi, `which wm1302-reset.sh` prints `/usr/bin/wm1302-reset.sh` with `PATH=/usr/sbin:/usr/bin:/sbin:/bin` |

## What was not checked

**The new image was not flashed, and nothing was run on the concentrator.** The Pi was running gwmon and Station for another issue, and `util_chip_id` cannot run while Station holds the SPI bus. So "after a clean build and a flash, `util_chip_id` prints the EUI and Station connects to AWS" is not shown here. It is part of the clean-build check of issue #9.

The risk is small: the script on the card is the same file at the same path. The gateway that is running now already boots with this exact script and reads the EUI through it at each start of Station ([issue7-gwmon-v2.md](issue7-gwmon-v2.md)). The only installed file that differs from the card is `reset_lgw.sh`, and only in its comment lines.

The build was also not a clean one: only the `sx1302-hal` package was rebuilt, and the rest of the output tree was reused.
