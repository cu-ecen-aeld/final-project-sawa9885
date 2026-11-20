# Issue #8: bench comparison with the reference gateway
This document was partially generated using Claude Code using the chat session at: ISSUE8_SESSION_LINK

The Pi 5 gateway of this project and an existing commercial LoRaWAN gateway (the "reference gateway") are registered in the same AWS IoT Core for LoRaWAN account. This page says how their reception is compared from AWS uplink metadata, what the method cannot show, and where the comparison stands.

**Status (2026-11-20): not done.** The method and the script are finished and tested. The 24-hour side-by-side run has not happened yet: the two gateways are in different places and have no node in common (section 4).

## 1. Where the data comes from

Nothing was added to AWS for this. The account already had what is needed:

- The devices' service profile has **AddGwMetaData** on, so AWS keeps, for each uplink, the list of gateways that received it with the RSSI and SNR each one measured ([aws-iot-core-setup.md](aws-iot-core-setup.md), section 5).
- AWS IoT Core for LoRaWAN logs at level INFO to the CloudWatch log group `/aws/iotwireless`. For each uplink it writes an `Uplink_Data` entry whose text ends in `Uplink metadata: {...}`. That JSON holds `DevEui`, `FCnt`, `Timestamp`, `DataRate`, `Frequency` and `Gateways: [{GatewayEui, Rssi, Snr}]`. It holds no payload.
- The log group keeps entries for **3 days**. A comparison has to be run, or saved with `--save`, within 3 days of the end of its window.

AWS removes duplicates before it logs: when both gateways receive a frame there is one entry with two gateways in its list. RSSI and SNR are logged as whole numbers.

The existing destinations and rules of the account were only read, never changed. They are not used here.

## 2. The script

[`scripts/gateway-comparison.py`](../scripts/gateway-comparison.py) needs Python 3 and, to read from AWS, the AWS CLI signed in with permission for `logs:FilterLogEvents`. It makes no other AWS call and changes nothing.

```sh
# the last 24 hours, with a name for each gateway (last four hex digits of its EUI)
python scripts/gateway-comparison.py --hours 24 --gateway 5844=Pi --gateway 7de2=Reference

# a fixed window, as Markdown for the wiki, keeping a reduced copy of the data
python scripts/gateway-comparison.py --start 2026-11-29T18:00Z --end 2026-11-30T18:00Z \
    --gateway 5844=Pi --gateway 7de2=Reference --node 7be0 --node 7bc4 --markdown --save capture.jsonl

# later, from the saved copy
python scripts/gateway-comparison.py --file capture.jsonl --gateway 5844=Pi --gateway 7de2=Reference
```

`--node` limits the comparison to the named nodes (last four hex digits of the DevEUI). Without it every node in the log group counts, also nodes that only one gateway can reach.

**Privacy.** The script prints and saves only the last four hex digits of a DevEUI or gateway EUI. It never reads a payload. A `--save` file holds, for each uplink, the node's four digits, the frame counter, the time, and each gateway's four digits, RSSI and SNR. Keep such a file out of the repo anyway: it is traffic data of real devices.

### How each column is computed

| Column | Meaning |
|---|---|
| Uplinks received | Frames whose gateway list names this gateway. A frame that a node sent twice with the same counter (a confirmed uplink that was not acknowledged) counts once |
| Node frames heard | Uplinks received, divided by the frames the nodes sent in the window |
| Mean RSSI, mean SNR | The plain average of the dBm and dB values this gateway reported for the frames it received. Frames it missed are not in the average, so a gateway that only hears the strong frames gets a better mean |
| Nodes heard | Nodes with at least one frame received by this gateway |

**Frames sent** is not known directly, so it is taken from each node's frame counter (`FCnt`), which goes up by one for every frame the node sends. For each node the frames are put in time order, and:

- a step up of 1 to 1000 adds that many frames. A step of 3 means two frames that no gateway received;
- a step backwards, or one larger than 1000 (`--max-gap`), is taken as a **counter reset**: the node rejoined or restarted. Counting starts again with that frame. Frames lost across the reset cannot be counted, and the output says how many resets there were;
- the same counter value twice in a row is one frame.

A second table lists the same numbers for each node.

### Host test

`scripts/test/gateway-comparison-test.py` runs the script on `scripts/test/gateway-comparison-sample.jsonl`, a made-up file with two gateways and two nodes (no real device or measurement). It covers the four input forms, a lost frame, a repeated frame, a counter reset, a node that one gateway never hears, the window and node filters, and `--save`. It needs no AWS access:

```
$ python scripts/test/gateway-comparison-test.py
...
Ran 9 tests in 0.017s

OK
$ python scripts/gateway-comparison.py --file scripts/test/gateway-comparison-sample.jsonl --gateway 11aa=Pi --gateway 22bb=Reference
Window: 2026-01-01 00:00 UTC to 2026-01-01 00:35 UTC
First and last uplink in it: 2026-01-01 00:00 UTC, 2026-01-01 00:35 UTC
Nodes: 2 (heard by every gateway: 1). Frames sent by them, from frame counters: 11. Counter resets: 1.

Gateway            Uplinks received  Node frames heard  Mean RSSI  Mean SNR  Nodes heard
Pi (…11aa)         5                 45.5 %             -84.0 dBm  8.0 dB    1
Reference (…22bb)  8                 72.7 %             -83.0 dBm  7.9 dB    2

Node            Frames sent  Resets  Pi (…11aa)  Reference (…22bb)
node A (…0a01)  7            1       5 (71.4 %)  5 (71.4 %)
node B (…0b02)  4            0       0 (0.0 %)   3 (75.0 %)
```

## 3. Limits

This is a functional check, not an RF characterisation.

- **Antennas are not controlled.** The two gateways have different antennas, in different positions, with unknown cable loss and gain. A difference in RSSI or in frames heard can come from any of these and says little about the receivers.
- **A frame that no gateway received is only seen as a counter gap.** Frames lost before a node's first logged frame in the window, after its last one, or across a counter reset are not counted. With two gateways that miss the same frames (the node was simply out of range), both look better than they were.
- **The means are over received frames only**, and RSSI and SNR arrive as whole numbers.
- **Different front ends report RSSI differently.** A fixed offset of a few dB between two gateway models is normal and is not calibrated out here.
- **The nodes are whatever is transmitting.** Their positions, power and data rates are not set by this test. The course test node transmits at 0 dBm and only on command ([issue4-basicstation-aws.md](issue4-basicstation-aws.md), section 3), so it is not a useful source for a 24-hour run.
- **Gaps in one gateway's uptime count against it.** Restarts of Station on the Pi during the window must be read from `/var/log/station.log` or port 9000 (`station_restarts`) and stated with the table.
- **Downlinks are not compared**, only reception.

## 4. Where it stands on 2026-11-20

Read-only checks, 21:25 to 21:45 UTC:

- Both gateways show `ConnectionStatus=Connected` in AWS.
- The Pi's status port reported `uptime=94977s station_restarts=0 uplinks=0 last_uplink_age=never`: in the 26 hours since its last boot Station had passed on no frame at all, with `RX` logging on.
- The script on the last 72 hours (the whole log group). Node labels are the last four hex digits of the DevEUI; `…7c7c` is the course test node:

```
Window: 2026-11-17 21:43 UTC to 2026-11-20 21:43 UTC
First and last uplink in it: 2026-11-17 21:45 UTC, 2026-11-20 21:24 UTC
Nodes: 6 (heard by every gateway: 0). Frames sent by them, from frame counters: 595. Counter resets: 0.

Gateway            Uplinks received  Node frames heard  Mean RSSI  Mean SNR  Nodes heard
Pi (…5844)         3                 0.5 %              -79.0 dBm  13.7 dB   1
Reference (…7de2)  584               98.2 %             -78.9 dBm  11.9 dB   5

Node            Frames sent  Resets  Pi (…5844)   Reference (…7de2)
node A (…7bc4)  162          0       0 (0.0 %)    157 (96.9 %)
node B (…7bcc)  5            0       0 (0.0 %)    5 (100.0 %)
node C (…7be0)  321          0       0 (0.0 %)    321 (100.0 %)
node D (…7c40)  5            0       0 (0.0 %)    5 (100.0 %)
node E (…7c7c)  3            0       3 (100.0 %)  0 (0.0 %)
node F (…821c)  99           0       0 (0.0 %)    96 (97.0 %)
```

**This table is not the comparison.** It shows that the gateways are not side by side: the reference gateway hears five nodes that send on a schedule, the Pi hears none of them, and the only node the Pi heard (the test node, three frames on command on Nov 19) did not reach the reference gateway. No node is heard by both, so the percentages compare two different places, not two gateways.

What the run needs: the Pi within range of at least one of the scheduled nodes that the reference gateway hears (in practice, the Pi next to the reference gateway, powered and on Ethernet), left there for 24 hours. Nodes A, C and F send often enough (about 30 to 110 frames a day each) to give a usable table in one day. Then:

```sh
python scripts/gateway-comparison.py --start <start>Z --end <start + 24 h>Z \
    --gateway 5844=Pi --gateway 7de2=Reference --markdown --save <a file outside the repo>
```

run within 3 days of the end of the window, with `--node` for the nodes both gateways can reach, and the Pi's `station_restarts` and `uptime` from port 9000 noted beside the table.
