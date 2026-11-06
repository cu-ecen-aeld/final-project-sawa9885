# Issue #3: sx1302_hal receive test

These results show that the WM1302 concentrator, driven by the image's `sx1302-hal` package, receives real LoRa packets sent over the air from a node on the bench. They also show RSSI and SNR for each packet.

The full `lora_pkt_fwd` output is in [logs/issue3-lora_pkt_fwd-rx.log](logs/issue3-lora_pkt_fwd-rx.log).

## Setup

- **Gateway:** Pi 5 with the Seeed WM1302 Pi HAT (SPI, US915), running the Buildroot image from commit 0e329bf. Tools: `/usr/bin/util_chip_id`, `/usr/bin/lora_pkt_fwd` and `/usr/bin/reset_lgw.sh` (which calls `wm1302-reset.sh`).
- **Concentrator:** `util_chip_id` reads EUI `0x0016c001f1135844` and finds the STTS751 temperature sensor at 0x39 on `/dev/i2c-1`.
- **Channel plan:** `/etc/lora_pkt_fwd/global_conf.json`, US915 sub-band 2. Eight 125 kHz multi-SF channels at 903.9–905.3 MHz, plus 904.6 MHz at 500 kHz.
- **Transmitter:** a LoRa node near the gateway, powered over USB. It sent raw LoRa packets on 905.3 MHz (sub-band 2, channel 7) at SF9, BW125, CR 4/7, preamble 8 and sync word 0x12, with a 4-byte test payload.
  - It sent 4 runs, starting at 05:11:59, 05:12:22, 05:12:45 and 05:13:08 UTC on 2026-11-06.
  - Each run was 4 packets at −9, 0, +5 and +10 dBm.
- **Gateway setting for the test:** the node isn't provisioned with a LoRaWAN identity, so it sent plain LoRa frames with the private sync word (0x12) instead of LoRaWAN frames. For this capture the gateway ran a copy of the config with `"lorawan_public": false`, which makes the SX1302 match sync word 0x12. It also had `"forward_crc_error": true`, so that failed packets would show up too. Nothing else changed. The image's config keeps `lorawan_public: true` for LoRaWAN.

Command on the Pi:

```sh
sed 's/"lorawan_public": true/"lorawan_public": false/; s/"forward_crc_error": false/"forward_crc_error": true/' \
    /etc/lora_pkt_fwd/global_conf.json > /tmp/global_conf_private.json
cd /tmp && lora_pkt_fwd -c /tmp/global_conf_private.json > /tmp/pktfwd-private.log 2>&1
```

## Results

The gateway received all 16 packets, with CRC OK on every one. It reported 8 in the 05:12:29 statistics block, 4 at 05:12:59 and 4 at 05:13:29.

| Run (start, UTC) | −9 dBm | 0 dBm | +5 dBm | +10 dBm |
|---|---|---|---|---|
| 05:11:59 | −88 dBm / 12.5 dB | −78 / 12.5 | −73 / 11.8 | −71 / 12.0 |
| 05:12:22 | −88 / 12.2 | −78 / 12.0 | −74 / 11.5 | −71 / 12.5 |
| 05:12:45 | −89 / 11.8 | −79 / 12.0 | −74 / 11.8 | −72 / 11.2 |
| 05:13:08 | −90 / 11.5 | −79 / 9.8 | −75 / 12.5 | −72 / 12.0 |

Each cell gives RSSI / SNR, from the `rssis` and `lsnr` fields of `rxpk`.

- RSSI rises with each step in transmit power, about 10, 5 and 2–3 dB.
- The +5 and +10 dBm steps are closer together than the power steps, which is typical for a strong signal at short range.
- SNR is about 12 dB throughout, as expected for a strong signal at short range.
- The frequency offset (`foff`) was 190–235 Hz.

Excerpt (start-up, the first run, and its statistics):

```
*** Packet Forwarder ***
Version: 2.1.0
INFO: com_type SPI, com_path /dev/spidev0.0, lorawan_public 0, clksrc 0, full_duplex 0
INFO: radio 0 enabled (type SX1250), center frequency 904300000, RSSI offset -215.399994, tx enabled 1, single input mode 0
INFO: radio 1 enabled (type SX1250), center frequency 905000000, RSSI offset -215.399994, tx enabled 0, single input mode 0
INFO: Lora multi-SF channel 7>  radio 1, IF 300000 Hz, 125 kHz bw, SF 5 to 12
INFO: gateway MAC address is configured to 0016C001F1135844
INFO: found temperature sensor on port 0x39
INFO: [main] concentrator started, packet can now be received
INFO: concentrator EUI: 0x0016c001f1135844
...
JSON up: {"rxpk":[{"jver":1,"tmst":210931878,"chan":7,"rfch":1,"freq":905.300000,"mid": 8,"stat":1,"modu":"LORA","datr":"SF9BW125","codr":"4/7","rssis":-88,"lsnr":12.5,"foff":193,"rssi":-88,"size":4,"data":"U0RUWA=="}]}
JSON up: {"rxpk":[{"jver":1,"tmst":211608855,"chan":7,"rfch":1,"freq":905.300000,"mid": 8,"stat":1,"modu":"LORA","datr":"SF9BW125","codr":"4/7","rssis":-78,"lsnr":12.5,"foff":193,"rssi":-78,"size":4,"data":"U0RUWA=="}]}
JSON up: {"rxpk":[{"jver":1,"tmst":212285858,"chan":7,"rfch":1,"freq":905.300000,"mid": 8,"stat":1,"modu":"LORA","datr":"SF9BW125","codr":"4/7","rssis":-73,"lsnr":11.8,"foff":193,"rssi":-73,"size":4,"data":"U0RUWA=="}]}
JSON up: {"rxpk":[{"jver":1,"tmst":212962875,"chan":7,"rfch":1,"freq":905.300000,"mid": 8,"stat":1,"modu":"LORA","datr":"SF9BW125","codr":"4/7","rssis":-71,"lsnr":12.0,"foff":193,"rssi":-71,"size":4,"data":"U0RUWA=="}]}
...
##### 2026-11-06 05:12:29 GMT #####
### [UPSTREAM] ###
# RF packets received by concentrator: 8
# CRC_OK: 100.00%, CRC_FAIL: 0.00%, NO_CRC: 0.00%
### Concentrator temperature: 30 C ###
```

The "PUSH_DATA acknowledged: 0.00%" lines in the full log are expected. The config sends to `localhost:1730`, where no network server runs. Basics Station replaces `lora_pkt_fwd` in issue #4.

## Deviation from the DoD

The DoD asks for "uplinks from a powered LoRaWAN node". The node on hand wasn't provisioned with a LoRaWAN identity, so it sent raw LoRa frames on the private sync word instead of LoRaWAN join requests. These frames exercise the same radio path as LoRaWAN uplinks: the SX1250 front end, the SX1302 multi-SF demodulator on a sub-band 2 channel, and libloragw/`lora_pkt_fwd` reporting RSSI and SNR. The only difference is the sync word the correlator matches. Before this capture, the gateway logged no packets during three captures with `lorawan_public: true` (04:48–05:08 UTC). The node had no firmware on it then, so it wasn't transmitting.

LoRaWAN frames will be received end-to-end in issue #4, through Basics Station and AWS IoT Core for LoRaWAN.

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #3): https://claude.ai/code/cshk_01CSAPnwU8kGpRLfK6nchbsXUG2a95em6aXdDoBJsXAhS9 -->
