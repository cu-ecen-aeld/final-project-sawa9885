# Demo day: phone hotspot rehearsal and checklist

For the in-class demo on Dec 2. There the gateway has no Ethernet: the Pi joins a phone hotspot over Wi-Fi, and the laptop joins the same hotspot for port 9000, SSH and the AWS console. The test node hangs off the laptop's USB port.

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #9): ISSUE9_SESSION_LINK -->

**What has been tested on Wi-Fi, and what has not.** Wi-Fi itself works on this Pi 5 with this image's Wi-Fi setup: issue #1 got a lease and pinged out over `wlan0` only, and issue #5 showed `wlan0` associated at 2412 MHz with a lease and the clock set. Both were a home router, not a phone hotspot, and both were before Basics Station, gwmon v2 and zero-touch provisioning. Every test since issue #4 ran on Ethernet with no Wi-Fi file. So **a Wi-Fi-only gateway with Station connected to AWS has never run.** Everything in sections 2 and 3 below comes from reading the code, not from a test. The rehearsal of section 1 is the test.

The hotspot's name and password never go in the repo, in a log that is committed, or in a chat session. Section 2, item 8, says where the image itself writes the name.

## 1. Rehearsal (about 20 minutes, Nov 29 or later)

Do it on the hotspot and the laptop that will be used on Dec 2.

**Phone.** Turn the hotspot on. Set it to **2.4 GHz** and **WPA2** if the phone offers the choice: on an iPhone, turn on "Maximize Compatibility"; on Android, pick the 2.4 GHz band and WPA2-Personal. Section 2 says why. An iPhone only shows its hotspot to other devices while the Personal Hotspot screen is open, so leave that screen open until the Pi has joined.

**Laptop.** Join the hotspot.

**Card.** The Wi-Fi file goes on the card's boot partition and is moved into the root filesystem at the next boot (`S35provision`). It works on the card that is in the Pi now, and on a card just written by `flash-gateway.ps1`, whose boot partition is still mounted when the script ends.

1. Pi off. Card in the PC's reader. Its boot partition shows as a drive labelled `BOOT`.
2. Copy `base_external\board\pi5\wpa_supplicant.conf.example` from the repo to the **top level of that drive**, and rename the copy to exactly `wpa_supplicant.conf`. In Explorer, turn on "File name extensions" first, so it does not become `wpa_supplicant.conf.txt`.
3. Open the copy on the card in Notepad. Replace `YOUR_SSID` and `YOUR_PASSPHRASE` with the hotspot's name and password, keeping the quotes. Leave `country=US` and `key_mgmt=WPA-PSK`. Save. Do not save it anywhere else, and do not paste it into a chat.
4. Optional, and recommended: add a second network block below the first for the fallback network (a travel router, section 4), with `priority=1` in it and `priority=2` in the hotspot's block. The Pi joins whichever of the two it can see.
5. Eject the drive, card into the Pi. **Antenna on**, no Ethernet cable, then power.

**Checks, in order.** `<pi>` is the Pi's address, found in step a.

| | Check | How | Good result | Expect it by |
|---|---|---|---|---|
| a | `wlan0` has an address | On the laptop, in the repo: `.\scripts\demo\find-gateway.ps1`. It tries port 9000 on every address of the laptop's Wi-Fi network | One line: `<pi>: gwmon 2.0.0 uptime=...` | about 60 s after power-on |
| b | The clock is set | `ssh root@<pi> 'chronyc tracking \| head -n 5; grep ntp-hook /var/log/messages'` | `Leap status : Normal` (not `Not synchronised`), and `ntp-hook: wlan0 has a DHCP lease` followed within seconds by `clock synchronised by NTP` | a few seconds after the lease |
| c | Station is connected to AWS | `ssh root@<pi> "grep -E 'ed to MUXS\|Concentrator started' /var/log/station.log \| tail -n 2"`, and the AWS console, IoT Core, LPWAN devices, Gateways: `gateway-0016c001f1135844` Connected | `Connected to MUXS.` and `Concentrator started` | about 20 s after the clock |
| d | Port 9000 | Step a already printed the line. Read it again with `.\scripts\demo\find-gateway.ps1` | `watchdog=active station=running station_fails=0` | |
| e | One uplink | Section 5 | `uplinks=1`, a `RX` line in Station's log, the uplink in AWS with this gateway's EUI | 10 s after the node sends |

If check a finds nothing after 2 minutes, power off, put the card in the PC and open `aesd-net.log` on the boot partition. `S41wifi` writes it 30 s after it starts Wi-Fi: addresses, routes, `iw dev wlan0 link` and the `wpa_supplicant` log. Read it yourself; it contains the hotspot's name (section 2, item 8), so do not paste it into a session or commit it.

**If check b fails** (`Not synchronised` a minute after the lease). The Pi has no clock battery, and until the date is right TLS rejects the AWS server certificates, so Station cannot connect. `station-run.sh` waits 60 s and then starts Station anyway, which then retries. If the carrier blocks NTP (UDP port 123), set the date from the laptop, in PowerShell:

```powershell
ssh root@<pi> "date -u -s '$((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))' && kill `$(pidof station)"
```

gwmon starts Station again 1 s later, now with a correct date. chronyd steps the clock again if NTP gets through later. The Pi 5 keeps the time across a reboot, as long as it stays powered, so a watchdog reset does not lose it.

**Write down** after the rehearsal: how long from power-on to check a, b and c; whether the laptop could reach the Pi at all (section 2, item 2); and which band the hotspot used (`ssh root@<pi> "iw dev wlan0 link | grep freq"`, which prints only the frequency).

## 2. What may fail on Wi-Fi only, from reading the code

Nothing here was tested. "Sure" means the code says so; "likely" and "possible" are guesses about phones and networks. None is fixed yet; the proposed fixes need Sam's approval and a rebuild.

| # | What | Where | How sure | Effect on the demo | Proposed fix |
|---|---|---|---|---|---|
| 1 | **The Pi has no name on Wi-Fi.** `udhcpc` for `wlan0` is started without `-x hostname:`, so the Pi does not send `aesd-pi5` in its DHCP request (on `eth0` it does, through `hostname $(hostname)` in `/etc/network/interfaces`). The image has no mDNS responder either. A phone's list of hotspot clients shows no name, and an iPhone shows no list at all | `rootfs_overlay/etc/init.d/S41wifi`, line 43; `rootfs_overlay/etc/network/interfaces`, line 14 | Sure | Finding `<pi>` takes a scan: `scripts\demo\find-gateway.ps1` | Add `-x hostname:$(hostname)` to the `udhcpc` line in `S41wifi`. mDNS (Avahi) would be a new package; not worth it for one demo |
| 2 | **The hotspot may block traffic between its clients.** Some phones and carriers isolate hotspot clients from each other. Then the laptop cannot reach port 9000 or SSH, although the Pi is online and connected to AWS | not in the repo | Possible; depends on the phone | No status line and no SSH in the demo; AWS still shows Connected | None in the image. Find out in the rehearsal. Fallback: section 4 |
| 3 | **5 GHz is untested.** Issue #5 associated at 2412 MHz only. The image has `country=US` in the example file, the regulatory database (`wireless-regdb`) and the Broadcom firmware, so 5 GHz should work, but newer iPhones put the hotspot on 5 GHz unless "Maximize Compatibility" is on | `board/pi5/wpa_supplicant.conf.example`, line 6 | Possible | `wlan0` never associates | Use 2.4 GHz (section 1). Test 5 GHz once, separately |
| 4 | **WPA3-only hotspots.** The example uses `key_mgmt=WPA-PSK`, which works with WPA2 and with WPA2/WPA3 transition mode, not with WPA3 only. `wpa_supplicant` is built with WPA3 (`BR2_PACKAGE_WPA_SUPPLICANT_WPA3=y`), but whether the Pi's Wi-Fi firmware does SAE this way was never tried | `board/pi5/wpa_supplicant.conf.example`, lines 11 and 12 | Possible | `wlan0` never associates | Set the hotspot to WPA2 (section 1). The example's comment already says what to change for WPA3 only |
| 5 | **Wi-Fi power saving.** Nothing turns off the Broadcom driver's power saving, which is on by default. Incoming connections (SSH, port 9000) can then be slow to answer; Station's own connection is outgoing and keeps the link busy | `rootfs_overlay/etc/init.d/S41wifi`, after line 41 | Possible | A slow `ssh` or a `find-gateway.ps1` timeout | Add `iw dev wlan0 set power_save off` to `S41wifi` once `wlan0` exists; raise `-TimeoutMs` of the finder meanwhile |
| 6 | **Nothing restarts DHCP when Wi-Fi comes back.** `ifplugd` watches `eth0` only. If the hotspot goes away and comes back, `wpa_supplicant` joins it again by itself, and `udhcpc` keeps its old address until it renews. With the same phone that is the same network, so it works; if the hotspot comes back with another subnet (some Android phones do this when the hotspot is restarted), the Pi keeps a dead address until the lease runs out | `rootfs_overlay/etc/init.d/S41ifplugd`, line 19; `S41wifi`, line 43 | Sure about the code; the effect needs a phone that changes subnet | No network until a power cycle | Have `udhcpc` renew when `wpa_supplicant` reconnects (`wpa_cli -a` action script sending `SIGUSR1` to `udhcpc`). Meanwhile: keep the hotspot on, and power-cycle the Pi if it drops |
| 7 | **Only one time source, over NTP.** `chrony.conf` names `pool.ntp.org` only. If the network blocks UDP port 123, the clock stays wrong after a cold boot, and Station fails TLS. `station-run.sh` waits 60 s, then starts Station anyway, which keeps failing until the date is right | `rootfs_overlay/etc/chrony.conf`, line 8; `basicstation/station-run.sh`, lines 87 to 89 | Unlikely on a phone hotspot; possible on a campus network | Station never connects | Set the date by hand (section 1, "If check b fails"). A second source does not help if UDP 123 is blocked; an HTTPS date fallback in `station-run.sh` would, but is new code |
| 8 | **The hotspot's name is written to the boot partition and to syslog.** `S41wifi` writes `iw dev wlan0 link`, which prints the SSID, and the `wpa_supplicant` log lines, which name the SSID when associating, into `/boot/aesd-net.log` 30 s after every boot. The same lines are in `/var/log/messages`. The password is not logged | `rootfs_overlay/etc/init.d/S41wifi`, lines 55 and 58 | Sure | None for the demo. For the public video and sessions: never show or paste `aesd-net.log` or `grep wpa_supplicant /var/log/messages` | Filter the `SSID` lines in `report()`, or stop writing `aesd-net.log` now that SSH works |
| 9 | **The Wi-Fi file has to be named and written exactly.** `S35provision` installs only a file named `wpa_supplicant.conf` at the top of the boot partition. It removes Windows line endings and a byte order mark, so Notepad is fine, but Windows hides `.txt` by default, and a password that contains `"` or `\` breaks the quoted `psk=` line | `rootfs_overlay/etc/init.d/S35provision`, line 69 | Likely, as a mistake while preparing | `wlan0` never starts (`aesd-net.log` then says `wpa_supplicant.conf present: no`) | Section 1, step 2. A hotspot password with letters and digits only |
| 10 | **Two networks at once** (Wi-Fi and the Ethernet fallback) give two default routes, one per DHCP client. Which one wins depends on the order of the leases | BusyBox `udhcpc` default script; `S41wifi`, line 43 | Possible, only with both up | Only during a fallback | Unplug one, or remove the Wi-Fi file for an Ethernet-only fallback |

Checked and **not** a Wi-Fi problem:

- `S40network` (`ifup -a`) brings up only the loopback, and `S41ifplugd` on an Ethernet port with no cable does nothing (`-f` treats a failed link query as "link down"). Nothing waits for `eth0`.
- `S41wifi` waits up to 10 s for `wlan0` to appear and loads `brcmfmac` itself (lines 18 to 27). That part worked in issues #1 and #5.
- The time hook `50-chrony` runs for any interface's lease, `wlan0` included, and tells chronyd to try at once.
- gwmon listens on all IPv4 interfaces (`AI_PASSIVE`, `gwmon.c` line 1021) and does not care which one is up. Station, `station-run.sh` and `gateway-provision` use whatever route there is.

## 3. Zero-touch provisioning on a Wi-Fi-only first boot

From reading the code, not tested.

`flash-gateway.ps1` writes `provision.secret` and `provision.url` to the boot partition and leaves the partition mounted when it ends. Copy `wpa_supplicant.conf` there too (section 1, steps 2 and 3) before ejecting. That is what the README means by "Wi-Fi-only gateways still need a `wpa_supplicant.conf` copied to the card": the flash script does not write it, because the Wi-Fi password must not pass through it.

At the first boot `S35provision` installs all three files in one pass, before any network script runs. `S41wifi` then starts Wi-Fi, and `gateway-provision` (started by `S45gateway-provision`, in the background) does not care which interface carries the request:

1. It waits for chronyd to set the clock, in checks 2 s apart, up to 60 s. On Wi-Fi the lease comes later than on Ethernet, so this wait is longer.
2. If the clock is still not set, it tries anyway. A failed try (no network, no clock, no answer) is retried after 5, 10, 20, 40 and then every 60 s, plus up to a quarter at random. It never gives up while the failure can pass.
3. Meanwhile gwmon reports `station=unconfigured` and keeps feeding the watchdog, so the board stays up.

So a Wi-Fi-only first boot should end Connected within about a minute of the Pi joining the hotspot, as on Ethernet (issue #10: 14.5 s after the lease). If the Wi-Fi file was forgotten, nothing is lost: the secret has already been moved to `/etc/gateway-provision` and is still unused. Power off, put `wpa_supplicant.conf` on the boot partition, power on, and provisioning carries on.

The demo gateway is already provisioned. A fresh flash makes AWS give the same gateway record a new certificate (README, "Zero-touch provisioning"), so flashing the clean image of issue #9 with the Wi-Fi file on the card would test the clean build, zero-touch provisioning and Wi-Fi in one rehearsal.

## 4. Fallbacks if Wi-Fi fails in the room

In order of preference. The first two put the Pi on Ethernet, which is the tested path; the Wi-Fi file can stay on the card.

**A. Travel router.** Set the travel router up once at home as a Wi-Fi client of the phone hotspot (its "repeater", "WISP" or "hotspot" mode, depending on the make), and check that its own Wi-Fi or LAN works. In the room: Pi to a LAN port of the router by Ethernet, laptop on the router's Wi-Fi or another LAN port. Both are then on the router's network, so a hotspot that isolates its clients does not matter. Find the Pi with `.\scripts\demo\find-gateway.ps1` on the laptop.

**B. The laptop shares its hotspot connection over Ethernet** (Windows Internet Connection Sharing). Needs an Ethernet port or a USB Ethernet adapter on the laptop, and a cable.

1. Laptop on the phone hotspot. Cable from the laptop's Ethernet port to the Pi.
2. Run `ncpa.cpl`. Right-click the **Wi-Fi** adapter, Properties, Sharing tab.
3. Tick "Allow other network users to connect through this computer's Internet connection". Under "Home networking connection" pick the **Ethernet** adapter the cable is in (not a VirtualBox, Hyper-V or WSL adapter). OK.
4. Power the Pi, or unplug and replug its cable: `ifplugd` starts DHCP on the new link. Windows gives the Pi an address in `192.168.137.x`.
5. `.\scripts\demo\find-gateway.ps1 -Subnet 192.168.137`.
6. Afterwards untick the sharing box again: it stays on otherwise.

**C. The laptop as the Wi-Fi network.** Windows "Mobile hotspot" (Settings, Network & internet) can share the laptop's own connection over Wi-Fi, if its adapter supports it. Its name and password then go into the second network block of `wpa_supplicant.conf` (section 1, step 4), so that has to be done before the demo, on the card.

**D. Nothing in the room works.** Show the recorded video for the parts that need the network, and show on the Pi over the Ethernet fallback what does not: gwmon's status, the watchdog reset, Station's restart.

## 5. The test node

The test node (`aesd-test-node`, DevEUI `A0F262FFFE507C7C`) does not transmit on a schedule. It sends one confirmed, empty uplink on FPort 13 when it gets a command over its USB serial port. Its keys are on the node and are not needed here.

**Send one uplink** from the laptop, in the repo:

```powershell
.\scripts\demo\send-uplink.ps1 -List
.\scripts\demo\send-uplink.ps1 -Port COM<n> -Command "<NODE_UPLINK_COMMAND>"
```

`-List` shows the serial ports; the node's is the one that appears when it is plugged in. The script sends the one command line, then prints what the node answers for 15 s. Close any serial monitor first, since only one program can hold the port.

`<NODE_UPLINK_COMMAND>`, the baud rate and the line ending still have to be filled in here: the commands that triggered the uplinks of issues #4 and #7 were sent from outside this repo. The script's defaults are 115200 baud and CRLF.

**Confirm the uplink**, within about 10 s:

1. **gwmon:** `.\scripts\demo\find-gateway.ps1` shows `uplinks` one higher and `last_uplink_age` of a few seconds.
2. **Station's log:** `ssh root@<pi> "grep 'S2E:VERB] RX' /var/log/station.log | tail -n 2"` shows `RX ... DevAddr=... FCnt=<n>` with RSSI and SNR, followed by a `TX` line, the acknowledgement sent to the node.
3. **AWS, from the laptop** (read-only):

   ```powershell
   $id = aws iotwireless get-wireless-device --identifier A0F262FFFE507C7C --identifier-type DevEui --query Id --output text
   aws iotwireless get-wireless-device-statistics --wireless-device-id $id --query "[LastUplinkReceivedAt, LoRaWAN.Gateways]"
   ```

   `LastUplinkReceivedAt` is the time just sent, and the gateway list holds `GatewayEui 0016c001f1135844` with the same RSSI and SNR as Station's log.
4. **AWS console, for the audience:** IoT Core, MQTT test client, subscribe to `aesd/lorawan/uplink` before sending. The message lists this gateway under `WirelessMetadata.LoRaWAN.Gateways` ([issue4-basicstation-aws.md](issue4-basicstation-aws.md), section 3).

The node transmits at 0 dBm because of a fault on that board, so keep it within a few metres of the gateway, and do not present its RSSI as a range figure.

## 6. Demo-day checklist (one page)

**Pack.** Pi 5 with the WM1302 HAT and the Active Cooler · 915 MHz antenna (on the HAT) · the provisioned microSD card, in the Pi · 27 W USB-C PD supply · Ethernet cable · USB Ethernet adapter if the laptop has no port · travel router and its power, set up at home (section 4) · laptop and charger · phone and charger (a hotspot drains it) · test node and its USB cable · USB microSD reader.

**Before leaving.** Rehearsal (section 1) done on this phone and this laptop. `aws sts get-caller-identity` works on the laptop. AWS console signed in, in `us-east-1`, with the Gateways page and the MQTT test client (subscribed to `aesd/lorawan/uplink`) open in two tabs. The node's serial command tested with `send-uplink.ps1`. The video recorded, in case nothing in the room works.

**Power-up order** (about 2 minutes):

1. Phone: hotspot on, settings screen open (iPhone).
2. Laptop: join the hotspot.
3. Pi: antenna on, then power. **Never power the Pi without the antenna**: Station transmits the acknowledgements to the node at up to 26 dBm.
4. After about 60 s: `.\scripts\demo\find-gateway.ps1`. Note `<pi>`.
5. AWS Gateways page: Connected. If not yet, wait for check c (section 1).
6. Node: plug into the laptop.

**What to show** (the order of the video outline on the wiki):

| Feature | Show | If it fails |
|---|---|---|
| Build from a clean clone | `docs/logs/issue9-clean-build.log`: the commands, 37 min, the image's SHA-256 | Nothing can fail: it is a log |
| Zero-touch provisioning | AWS Gateways page, Connected. Over SSH: `grep gateway-provision /var/log/messages` | Show `docs/issue10-provisioning.md`, section 3 |
| Status on port 9000 | `.\scripts\demo\find-gateway.ps1`: one status line, field by field | Hotspot isolation (section 2, item 2): fallback A or B |
| An uplink reaches AWS | `send-uplink.ps1`, then the MQTT test client and `uplinks` one higher | Send again (the node may miss a downlink window); check that the antenna is on and the node near |
| Station restarted by gwmon | `ssh root@<pi> 'kill -9 $(pidof station); sleep 8; grep gwmon /var/log/messages \| tail -n 3'`, then the status line: `station_restarts=1` | gwmon gives up only after 5 failed starts; the Pi then resets and comes back by itself |
| Watchdog | `ssh root@<pi> 'kill -9 $(pidof gwmon)'`. The Pi resets about 10 s later and is back, Connected, about a minute later. The clock survives the reset | If it does not come back in 2 minutes: power-cycle |

**If the whole Pi seems dead** (no answer on port 9000 after 2 minutes): check the hotspot has the Pi in its client list (Android) or that the iPhone screen is open; power-cycle once; then fallback A or B; then card into the laptop and read `aesd-net.log` privately.

**During the demo and in the video**, nothing secret on screen: no hotspot password, no `wpa_supplicant.conf`, no `aesd-net.log`, no `grep wpa_supplicant` output (it shows the hotspot's name), no AWS account menu, and Station's log only through the `grep` lines above (its full log names the account-specific AWS endpoints).
