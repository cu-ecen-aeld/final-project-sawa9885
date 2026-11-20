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

See the sections below, filled in as the tests ran.
