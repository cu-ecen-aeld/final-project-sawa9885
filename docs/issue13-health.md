# Issue #13: gateway health reports to AWS IoT Core

gwmon's status line (TCP 9000, issue #7) only answers on the gateway's LAN. Since gwmon 2.1.0 the same report also goes to AWS IoT Core every 5 minutes, as one JSON message on `aesd/gateway/<gateway EUI>/health`.

This document was partially generated using Claude Code using the chat session at:
Link to chat session (issue #13): ISSUE13_SESSION_LINK

## Design

### Who does what

```
gwmon (main loop, feeds /dev/watchdog every 2 s)
  │ every 300 s (-I): pipe2() + one write() of the JSON report, fork(), exec
  ▼
/usr/bin/gwmon-publish.sh  ── report on stdin ──▶  mosquitto_pub -q 1 -s  ── MQTT over TLS, port 8883 ──▶  AWS IoT Core
  ▲                                                       (client certificate from /etc/gwmon-health)
  └── gwmon kills the whole process group if it is still running after 30 s (-O)
```

- **gwmon** builds the report and starts the publish program as a short-lived child, exactly the way it starts Station: `fork()` and `exec`, a one-shot `timerfd` for the time limit, `waitpid(WNOHANG)` on every pass of the loop. It never opens a socket to AWS, never resolves a name and never touches TLS.
- **`gwmon-publish.sh`** (installed by the gwmon package) reads the endpoint, certificate and key from `/etc/gwmon-health` and the gateway EUI from `/var/run/station.eui` (written by `station-run.sh`), then `exec`s `mosquitto_pub`.
- **`mosquitto_pub`** makes one TLS connection, publishes with QoS 1 and the retain flag, waits for the PUBACK and exits. AWS IoT keeps the last report of each gateway as a retained message, so the latest health can be read at any time (`aws iot-data get-retained-message`, or "Retained messages" in the console's MQTT test client). Nothing stays connected between two reports.

### Why a separate process and not a thread

The DoD item that matters most is "a publish that fails or hangs never delays gwmon's watchdog feed". The things that can hang are DNS (`getaddrinfo` cannot be cancelled), the TCP connect, the TLS handshake and the wait for the broker's acknowledgement.

- A **thread** in gwmon would keep those calls off the main loop, but a thread stuck in `getaddrinfo` or `SSL_connect` cannot be stopped safely: `pthread_cancel` in the middle of OpenSSL or glibc's resolver leaks locks and memory. Shared state with the TLS library would also be the first code in gwmon that can corrupt the process the watchdog depends on.
- A **child process** can always be ended with `SIGKILL`, whatever it is blocked in, and its memory is gone with it. A crash in the MQTT or TLS code cannot touch gwmon. gwmon already has every piece this needs (the supervision code of issue #7), so the new code in `gwmon.c` is small and follows the same rules: nothing in the loop blocks.

The one step in gwmon that talks to the child is the write of the report into the pipe. It is done before the fork into a new, empty pipe, and the report is at most 1024 bytes (below `PIPE_BUF`, 4096), so it cannot block. The child gets the report and then end-of-file on stdin.

### Why mosquitto_pub

- It is in Buildroot already (`package/mosquitto`, 2.0.x) and needs only OpenSSL, which the image has for curl. Only the client is installed: the defconfig turns `BR2_PACKAGE_MOSQUITTO_BROKER` off.
- It does MQTT 3.1.1 over TLS with a client certificate, which is what AWS IoT Core asks for, and `-q 1` makes its exit status mean "the broker has the message".
- Alternatives: linking `libmosquitto` or the AWS IoT Device SDK into gwmon puts TLS into the watchdog process (see above). The AWS SDK is also not in Buildroot and is much larger. `curl` can publish over HTTPS to AWS IoT, but HTTPS publishing needs either SigV4 credentials or the same client certificate on port 8443, and leaves no MQTT client for other tests.

### Settings

| Setting | Default | Where |
|---|---|---|
| Interval | 300 s | `gwmon -I`, `GWMON_PUBLISH_INTERVAL` in `/etc/default/gwmon` |
| Time limit of one attempt | 30 s | `gwmon -O`, `GWMON_PUBLISH_TIMEOUT`; must be below the interval |
| First report | 30 s after gwmon starts (or one interval, if that is shorter) | `PUB_FIRST_DELAY_S` in `gwmon.c` |
| Off | | `GWMON_PUBLISH=""` |

### Failures and logging

- An attempt fails when the program exits with any status but 0 or 78, is killed by a signal, or is killed by gwmon at the time limit.
- gwmon logs **changes only**: the first failure (`health publish failed: ... exited with status 5. Trying again every 300 s; further failures are not logged until a publish works`), and the first success after failures (`health publish works again after N failed attempts`). With the network down for a day, syslog gets one line.
- Exit status 78 (`EX_CONFIG`, as for Station in issue #7) means "no credentials in `/etc/gwmon-health`". gwmon logs it once and stops the publish timer, so a gateway without the publisher's certificate is not a failure.
- What `mosquitto_pub` said on the last attempt is in `/var/run/gwmon-publish.err`.
- Each attempt is a new connection, so after an outage the first attempt that finds the network works: publishing resumes within one interval.
- The status line has four new fields at the end: `publish=never|ok|failing|unconfigured publishes=N publish_fails=N last_publish_age=Ns|never`.

### The report

One JSON object on one line. Every report has the same 17 keys; a value gwmon does not have is `null`.

```json
{"gwmon_version":"2.1.0","time":1795211192,"uptime_s":305,"daemon_uptime_s":3,"watchdog":"active",
 "wd_timeout_s":10,"wd_feeds":4,"wd_last_feed_age_s":0,"station":"running","station_uptime_s":3,
 "station_restarts":0,"station_fails":0,"uplinks":2,"last_uplink_age_s":1,"temp_c":27.5,
 "publishes":0,"publish_fails":0}
```

`time` is the gateway's clock (Unix seconds). `uptime_s` is the time since boot, `daemon_uptime_s` the time since gwmon started. The rest are the fields of the status line of issue #7.

### Credentials

The publisher has its own AWS IoT identity, separate from Station's (which belongs to AWS IoT Core for LoRaWAN):

| AWS resource | Name | Allows |
|---|---|---|
| IoT thing | `aesd-gateway-<eui>-health` | |
| IoT policy | `aesd-gateway-<eui>-health` | `iot:Connect` as client ID `aesd-gateway-<eui>-health`; `iot:Publish` and `iot:RetainPublish` to `aesd/gateway/<eui>/health`. Nothing else. |
| Certificate | (AWS-generated ID) | active, policy and thing attached |

`scripts/create-health-thing.sh create <eui> <dir>` makes the three and writes `health.endpoint`, `health.crt` and `health.key` into `<dir>` (outside the repo). These go on the SD card's boot partition. At the next boot `S35provision` moves them to `/etc/gwmon-health/{endpoint,crt,key}` (mode 0600, directory 0700) and deletes them from the boot partition, as it does for Station's files (issue #5). `scripts/create-health-thing.sh delete <eui>` removes them from AWS.

The endpoint is the account's `iot:Data-ATS` host name. It is treated as a secret here only because the course rule keeps account identifiers out of the public session; it is not a credential.

## Results

### Host tests (no AWS)

| Test | Result | Log |
|---|---|---|
| `make -C gwmon check`: issues #6 and #7 sections 1 to 10 unchanged, plus sections 11 to 16 for the publish, with a fake publish program | 143/143 | [issue13-gwmon-host-test.log](logs/issue13-gwmon-host-test.log) |
| `make -C gwmon valgrind`: the same under Valgrind, 17 gwmon processes | 144/144, 0 errors, no leaks | [issue13-gwmon-valgrind.log](logs/issue13-gwmon-valgrind.log) |
| `make -C gwmon publish-check`: the real `gwmon-publish.sh` and `mosquitto_pub` against a local mosquitto 2.0.18 broker with TLS and a required client certificate | 19/19 | [issue13-publish-test.log](logs/issue13-publish-test.log) |

What they show, per DoD item:

- **JSON content and the 5-minute setting (1):** the report is one JSON object on one line with all the status fields; `-I 3` gives reports 3.0, 3.0, 3.0 s apart; without `-I` gwmon logs `health report every 300 s`. With `-w none` and no Station, log or sensor the same 17 keys are there with `null` values.
- **A publish that hangs (4):** with a fake publish program that never ends (and has a child of its own), the longest time between two watchdog feeds was 1.01 s, against 1.00 s before any publish (feed interval 1 s); 11 feeds in 11.2 s. gwmon killed the program and its child at the 2 s limit. With the real client, a server that accepts the TCP connection and never answers: both attempts killed at the limit, no `mosquitto_pub` left, `wd_last_feed_age=0s`.
- **Log once (4):** four failed attempts give one syslog line; recovery gives one more (`health publish works again after 4 failed attempts`); a second outage gives one more `failed` line. With the real broker stopped: five failures (`Error: Connection refused` in `/var/run/gwmon-publish.err`), one line.
- **Resume (5):** after the broker came back, the next attempt worked 1.0 s later (interval 2 s).
- **Other:** exit status 78 (no credentials) stops the timer after one line; a missing program is a failed attempt; `kill -9` of gwmon takes a running publish with it (`PR_SET_PDEATHSIG`); a clean stop kills it too.

### AWS identity, tried from the PC

[issue13-aws-pc-test.log](logs/issue13-aws-pc-test.log). `scripts/create-health-thing.sh create` made the thing, the policy and certificate `e73c3daa…`. `gwmon-publish.sh` with `mosquitto_pub` published from WSL, and `aws iot-data get-retained-message` read the message back. The policy refuses a publish to another topic and a connect with another client ID (AWS closes the connection, exit status 7).

### S35provision, run by hand on the Pi

[issue13-s35provision-pi.log](logs/issue13-s35provision-pi.log). The script from this branch, run from `/tmp` with `PROVISION_BOOT` pointing at a tmpfs that held only the three `health.*` files: it installed `/etc/gwmon-health/{endpoint,crt,key}` (0600, directory 0700), deleted them from the fake boot partition and removed the CR the Windows AWS CLI had put in the endpoint file. `/etc/station` and the real `/boot` were not changed. Not tested: the script at a real boot (no reboot while nobody is home).

### On the Pi

The SD card was not reflashed and the Pi was not rebooted. The files come from this branch's Buildroot build (`make gwmon mosquitto` in an output directory of its own); SHA-256 on the Pi = in the build's `target/`:

| File on the Pi | SHA-256 (first 16) | Was there before? |
|---|---|---|
| `/usr/bin/gwmon` (2.1.0) | `6e7d72e90a80b515` | replaced; 2.0.0 kept in `/root/issue13-backup/gwmon.2.0.0` |
| `/etc/init.d/S99gwmon` | `5568ff73dada050d` | replaced; old one in `/root/issue13-backup/S99gwmon.2.0.0` |
| `/usr/bin/gwmon-publish.sh` | `52c36bf6f9cc7526` | new |
| `/usr/bin/mosquitto_pub` (2.0.22) | `14dc9515100d4fb0` | new |
| `/usr/lib/libmosquitto.so.1` | `18d263c80bd3bb9c` | new |
| `/etc/gwmon-health/{endpoint,crt,key}` | (secret) | new, installed by `S35provision` run by hand |

`/root/issue13-backup/revert.sh` puts gwmon 2.0.0 and its init script back. The card's `S35provision` was not changed; the image built from this branch has the new one.

1. **Phase A, next to the live gwmon** (`/tmp/i13/gwmon -p 9013 -w none -I 60`): first report 36 s after start, the second 60 s later, read back from AWS (`temp_c` 31.4).
2. **Swap.** A detached script stopped gwmon 2.0.0 with `S99gwmon stop` (magic close), installed the files and started gwmon 2.1.0 with `S99gwmon start`. Swap took under 1 s; Station started again and connected; the watchdog was armed again (`timeout 10 s, fed every 2 s`). First report 30 s after the start.
3. **Outage** ([issue13-network-outage.log](logs/issue13-network-outage.log)). Default route deleted at 22:39:24 UTC. udhcpc put it back at about 22:49:00 to 22:49:05, so the outage was 9 min 36 s to 9 min 41 s (not quite 10 min).
   - Reports due at 22:43:51 and 22:48:51 failed. syslog has **one** line: `health publish failed: /usr/bin/gwmon-publish.sh exited with status 1. Trying again every 300 s; further failures are not logged until a publish works`.
   - The watchdog was fed all through: `wd_feeds` rose by 31 every minute, `wd_last_feed_age` was never above 1 s in 86 samples.
   - The next report, at 22:53:56, worked, 4 min 51 s after the route was back (interval 5 min): `health publish works again after 2 failed attempts`. AWS has it as the retained message, `publish_fails` 2.
   - Station reconnected to its LNS at 22:49:08 by itself.

## Definition of done

| # | Item | Status |
|---|---|---|
| 1 | Every 5 minutes (a setting) one JSON message on `aesd/gateway/<EUI>/health` with the status fields | **Pass.** Default 300 s, `GWMON_PUBLISH_INTERVAL` / `-I`. Messages from the Pi read back from AWS IoT Core. |
| 2 | Own certificate, provisioned from the boot partition by `S35provision`, not in the repo | **Pass, with one gap:** own thing, policy and certificate; `S35provision` installs them, tested by hand on the Pi against a copy of the boot files, not at a real boot. Nothing secret in the repo. |
| 3 | The message in the AWS IoT MQTT test client, screenshot in `docs/` | **Needs Sam:** the screenshot needs the AWS console. Read back with `aws iot-data get-retained-message` meanwhile. |
| 4 | A failed or hung publish never delays the watchdog feed; with the network down, one syslog line | **Pass:** host tests (hang: longest feed gap 1.01 s vs 1.00 s) and the Pi outage (one line, feed age never above 1 s). |
| 5 | After 10 minutes without Ethernet, publishing resumes within one interval | **Simulated, pass:** 9 min 40 s without the internet (route removed, link up), resumed 4 min 51 s after. **The real cable pull needs Sam** (Nov 29). |

### Outage test on the Pi: method, risk and recovery (written before it ran)

Nobody can touch the Pi from 2026-11-21 to 2026-11-29, so the 10-minute outage is simulated without taking the Ethernet link down. `gwmon/test/pi-outage-test.sh`, started on the Pi with `setsid` so it does not depend on the SSH session, deletes the default route, waits 600 s, and puts the same route back.

- **What it simulates:** the gateway loses the internet. Every connection to AWS fails (Station's and the publisher's), as with a pulled WAN cable. The LAN route stays, so SSH from the LAN keeps working throughout.
- **Difference from a pulled cable:** the link stays up, so `ifplugd` does not run `ifdown`/`ifup` and DHCP does not restart. Pulling the real cable for 10 minutes is left for Sam on 2026-11-29 (DoD item 5 asks for it).
- **Risk:** if the script died between the two steps, the gateway would stay off the internet. It would still answer SSH on the LAN.
- **Recovery:** the exact command to put the route back is in `/tmp/pi-outage-test.restore` on the Pi. udhcpc also adds the default route again at its next lease renewal, and a reboot by the watchdog would too.
- **No risk to the watchdog:** gwmon does not depend on the network; the test checks that `wd_feeds` keeps rising.
