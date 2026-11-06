# Issue #3: sx1302_hal receive test

These results show that the WM1302 concentrator, driven by the image's `sx1302-hal` package, receives LoRaWAN uplinks sent over the air from a node on the bench. They also show RSSI and SNR for each packet.

The full `lora_pkt_fwd` output is in two logs:
- [logs/issue3-lora_pkt_fwd-joins.log](logs/issue3-lora_pkt_fwd-joins.log): LoRaWAN join requests, with the image's stock config.
- [logs/issue3-lora_pkt_fwd-bursts.log](logs/issue3-lora_pkt_fwd-bursts.log): a raw LoRa power sweep.

## Setup

- **Gateway:** Pi 5 with the Seeed WM1302 Pi HAT (SPI, US915), running the Buildroot image from commit 0e329bf. Tools: `/usr/bin/util_chip_id`, `/usr/bin/lora_pkt_fwd` and `/usr/bin/reset_lgw.sh` (which calls `wm1302-reset.sh`).
- **Concentrator:** `util_chip_id` reads EUI `0x0016c001f1135844` and finds the STTS751 temperature sensor at 0x39 on `/dev/i2c-1`:

  ```
  # util_chip_id -d /dev/spidev0.0
  wm1302-reset: resetting the SX1302 (GPIO17) and SX1261 (GPIO5) on gpiochip0
  wm1302-reset: done
  Opening SPI communication interface
  Note: chip version is 0x10 (v1.0)
  INFO: using legacy timestamp
  ARB: dual demodulation disabled for all SF
  INFO: found temperature sensor on port 0x39

  INFO: concentrator EUI: 0x0016c001f1135844

  Closing SPI communication interface
  ```
- **Channel plan:** `/etc/lora_pkt_fwd/global_conf.json`, US915 sub-band 2. Eight 125 kHz multi-SF channels at 903.9–905.3 MHz, plus 904.6 MHz at 500 kHz (SF8).
- **Transmitter:** a LoRa node near the gateway, powered over USB.
- **No network server:** the forwarder sends to `localhost:1730`, where nothing listens. So the "PUSH_DATA acknowledged: 0.00%" lines in the logs are expected. Basics Station replaces `lora_pkt_fwd` in issue #4.

## Test 1: LoRaWAN join requests (DoD)

Command on the Pi, using the stock config with `lorawan_public: true`:

```sh
cd /tmp && lora_pkt_fwd -c /etc/lora_pkt_fwd/global_conf.json > /tmp/pktfwd-uplinks.log 2>&1
```

The node sent three LoRaWAN 1.0 OTAA join requests on US915 sub-band 2, between 05:16:45 and 05:17:17 UTC on 2026-11-06. It used a throwaway identity that no network server knows, so no join-accept was expected. The gateway logged all three, each 23 bytes with CRC OK. The first arrived within 61 s of the forwarder starting at 05:15:46.

| Time window (UTC) | Channel | Data rate | RSSI | SNR | DevNonce |
|---|---|---|---|---|---|
| 05:16:45–53 | 8: 904.6 MHz | SF8BW500 | −68 dBm | 15.2 dB | 0 |
| 05:16:57–17:05 | 7: 905.3 MHz | SF10BW125 | −69 dBm | 13.2 dB | 1 |
| 05:17:09–17 | 3: 904.5 MHz | SF10BW125 | −69 dBm | 13.0 dB | 2 |

Decoding the first `data` field (`base64 -d | od -tx1`) gives a valid LoRaWAN Join-request:

```
00                         MHDR: MType 000 = Join-request, Major 0 (LoRaWAN R1)
00 00 00 00 00 00 00 00    JoinEUI 0000000000000000 (little-endian)
24 82 50 fe ff 62 f2 a0    DevEUI A0F262FFFE508224 (little-endian)
00 00                      DevNonce 0
84 3d 68 6e                MIC
```

The DevNonce goes up by one in each request (0, 1, 2), which fits the counter-based DevNonce of LoRaWAN 1.0.4.

The 05:17:14 statistics block reports 5 packets received, 60 % with CRC OK. The two packets with CRC errors were not forwarded. They were probably the 500 kHz join also heard by the overlapping 125 kHz demodulators at 904.5 and 904.7 MHz. Packets with CRC errors are dropped by default (`forward_crc_error: false`).

Excerpt:

```
*** Packet Forwarder ***
Version: 2.1.0
INFO: com_type SPI, com_path /dev/spidev0.0, lorawan_public 1, clksrc 0, full_duplex 0
INFO: gateway MAC address is configured to 0016C001F1135844
INFO: found temperature sensor on port 0x39
INFO: [main] concentrator started, packet can now be received
INFO: concentrator EUI: 0x0016c001f1135844
...
##### 2026-11-06 05:16:44 GMT #####
...
INFO: Received pkt from mote: 00000000 (fcnt=0)
JSON up: {"rxpk":[{"jver":1,"tmst":62479295,"chan":8,"rfch":0,"freq":904.600000,"mid":16,"stat":1,"modu":"LORA","datr":"SF8BW500","codr":"4/5","rssis":-68,"lsnr":15.2,"foff":196,"rssi":-68,"size":23,"data":"AAAAAAAAAAAAJIJQ/v9i8qAAAIQ9aG4="}]}
INFO: Received pkt from mote: 00000000 (fcnt=0)
JSON up: {"rxpk":[{"jver":1,"tmst":74616639,"chan":7,"rfch":1,"freq":905.300000,"mid": 8,"stat":1,"modu":"LORA","datr":"SF10BW125","codr":"4/5","rssis":-69,"lsnr":13.2,"foff":242,"rssi":-69,"size":23,"data":"AAAAAAAAAAAAJIJQ/v9i8qABABd3mAU="}]}
INFO: Received pkt from mote: 00000000 (fcnt=0)
JSON up: {"rxpk":[{"jver":1,"tmst":86679689,"chan":3,"rfch":0,"freq":904.500000,"mid": 8,"stat":1,"modu":"LORA","datr":"SF10BW125","codr":"4/5","rssis":-69,"lsnr":13.0,"foff":227,"rssi":-69,"size":23,"data":"AAAAAAAAAAAAJIJQ/v9i8qACAO9no2o="}]}
##### 2026-11-06 05:17:14 GMT #####
### [UPSTREAM] ###
# RF packets received by concentrator: 5
# CRC_OK: 60.00%, CRC_FAIL: 40.00%, NO_CRC: 0.00%
# RF packets forwarded: 3 (69 bytes)
```

`lora_pkt_fwd` prints "mote: 00000000" because a join request has no DevAddr.

## Test 2: raw LoRa power sweep

Before the node had a LoRaWAN identity, it sent raw LoRa packets on 905.3 MHz (channel 7) at SF9, BW125, CR 4/7, preamble 8, with a 4-byte test payload and the private sync word 0x12. For this capture the gateway ran a copy of the config with `"lorawan_public": false`, so the SX1302 would match sync word 0x12. It also set `"forward_crc_error": true`. There were 4 runs, starting at 05:11:59, 05:12:22, 05:12:45 and 05:13:08 UTC, each of 4 packets at −9, 0, +5 and +10 dBm.

```sh
sed 's/"lorawan_public": true/"lorawan_public": false/; s/"forward_crc_error": false/"forward_crc_error": true/' \
    /etc/lora_pkt_fwd/global_conf.json > /tmp/global_conf_private.json
cd /tmp && lora_pkt_fwd -c /tmp/global_conf_private.json > /tmp/pktfwd-private.log 2>&1
```

The gateway received all 16 packets, with CRC OK on every one. Each cell below gives RSSI / SNR:

| Run (start, UTC) | −9 dBm | 0 dBm | +5 dBm | +10 dBm |
|---|---|---|---|---|
| 05:11:59 | −88 dBm / 12.5 dB | −78 / 12.5 | −73 / 11.8 | −71 / 12.0 |
| 05:12:22 | −88 / 12.2 | −78 / 12.0 | −74 / 11.5 | −71 / 12.5 |
| 05:12:45 | −89 / 11.8 | −79 / 12.0 | −74 / 11.8 | −72 / 11.2 |
| 05:13:08 | −90 / 11.5 | −79 / 9.8 | −75 / 12.5 | −72 / 12.0 |

RSSI rises with each step in transmit power, about 10, 5 and 2–3 dB. So the RSSI that libloragw reports follows the signal level.

## Earlier captures with no packets

From 04:48 to 05:08 UTC the gateway logged no packets at all, not even ones with CRC errors. The node had no firmware then, so it wasn't transmitting. The receiver was working, as the two tests above show.

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #3): https://claude.ai/code/cshk_01CSAPnwU8kGpRLfK6nchbsXUG2a95em6aXdDoBJsXAhS9 -->
