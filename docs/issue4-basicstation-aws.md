# Issue #4: Basics Station on the Pi, connected to AWS IoT Core for LoRaWAN

Results for the five "definition of done" items of issue #4, measured on the Pi 5 with the image built from commit `a611da7` (`sdcard.img` SHA-256 `793aac4c…00a6`, written to the card from the PC and verified by read-back).

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #4): TODO(issue-4-session-link) -->

- Gateway: Pi 5 with the Seeed WM1302 Pi HAT (SX1302, US915), Ethernet only. No Wi-Fi file was provisioned, so `wlan0` stays down.
- Gateway EUI: `0016C001F1135844`, the SX1302's EUI.
- Network server: AWS IoT Core for LoRaWAN, `us-east-1`, gateway ID `92f4b2e8-b047-46a1-859b-b15ad06d79a2`, RfRegion `US915`.
- In the logs here, the account-specific host IDs of the CUPS and LNS endpoints are replaced by `<id>`, and the certificate detail dumps that Station prints are removed. No certificate or key content appears anywhere.

## 1. The package builds, and `station --version` runs on the Pi

`base_external/package/basicstation/` builds Basics Station v2.0.6 for the `corecell` platform, `std` variant. The complete `make basicstation` log is [logs/issue4-basicstation-build.log](logs/issue4-basicstation-build.log). It shows the three hash checks (Station, sx1302_hal V2.1.0, mbedtls 2.28.10), Station's libloragw patch being applied, and the last lines:

```
 [arm-linux-gnueabihf] CC   ../bin/station
 platform=corecell variant=std STATION EXE built
>>> basicstation v2.0.6 Installing to target
/usr/bin/install -D -m 0755 <repo>/buildroot/output/build/basicstation-v2.0.6/build-corecell-std/bin/station <repo>/buildroot/output/target/usr/bin/station
```

`arm-linux-gnueabihf` is only upstream's label for the corecell platform. The compiler is Buildroot's `aarch64-linux-gcc`, and the binary is an aarch64 executable that needs only `libc` and `libm`.

On the Pi:

```
# station --version
Station: 2.0.6(corecell/std) 2026-11-12 16:50:47
Package: (null)
# cd /etc/station && station --version | tail -n 1
Package: 2.0.6
```

The package version is read from `version.txt` in the home directory, so it is only shown when Station runs with `/etc/station` as its home, as `S60station` runs it.

## 2. The gateway is registered in AWS and shows Connected

The gateway was added to AWS IoT Core for LoRaWAN with EUI `0016C001F1135844` and RfRegion `US915` ([aws-iot-core-setup.md](aws-iot-core-setup.md) has the steps). Its certificate, key, trust certificate and CUPS endpoint went onto the boot partition as `cups.crt`, `cups.key`, `cups.trust` and `cups.uri`.

First boot of the flashed card, from [logs/issue4-first-boot-syslog.log](logs/issue4-first-boot-syslog.log):

```
17:11:22 provision: installed /etc/station/cups.uri            (and cups.trust, cups.crt, cups.key)
17:11:24 station: gateway EUI 0016c001f1135844, starting when the clock is set
17:11:26 ifplugd.action: eth0 link up, uptime 7.30 s: ifup
17:11:32 ntp-hook: eth0 has a DHCP lease, uptime 13.58 s
17:11:42 ntp-hook: clock synchronised by NTP, uptime 23.59 s
17:11:44 station: starting /usr/bin/station, uptime 24.82 s
```

Station then fetched the LNS address and credentials from CUPS and connected, from [logs/issue4-first-boot-station.log](logs/issue4-first-boot-station.log):

```
17:11:44.420 [CUP:INFO] Connecting to CUPS ... https://<id>.cups.lorawan.us-east-1.amazonaws.com:443 (try #1)
17:11:50.596 [CUP:INFO] [Segment] TC URI: wss://<id>.lns.lorawan.us-east-1.amazonaws.com:443
17:11:50.596 [CUP:INFO] [Segment] TC Credentials update completed (3228 bytes)
17:11:50.620 [TCE:INFO] Connecting to INFOS: wss://<id>.lns.lorawan.us-east-1.amazonaws.com:443
17:11:51.083 [TCE:INFO] Infos: 0016:c001:f113:5844 0016:c001:f113:5844 wss://<id>.lns.lorawan.us-east-1.amazonaws.com:443/gateway/0016c001f1135844
17:11:54.025 [RAL:INFO] Concentrator started (2s363ms)
17:11:54.025 [S2E:INFO] Configuring for region: US915 -- 902.0MHz..928.0MHz
```

So the gateway was connected, with the concentrator running on the channel plan AWS sent, about 34 s after power-on. `/etc/station` then holds the four `cups.*` files (mode 0600), the `tc.*` files Station saved (mode 0640, in a 0700 directory), `station.conf` and `version.txt`. Nothing is left on the boot partition.

AWS reports the same. `aws iotwireless get-wireless-gateway-statistics` 23 s later:

```
UTC now: 2026-11-12 17:12:17
gateway 92f4b2e8-b047-46a1-859b-b15ad06d79a2 (EUI 0016c001f1135844): ConnectionStatus=Connected LastUplinkReceivedAt=2026-11-12T17:11:51.436146234Z
```

