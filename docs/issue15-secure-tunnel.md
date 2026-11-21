# Issue #15: remote shell through AWS IoT secure tunneling

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #15): ISSUE15_SESSION_LINK -->

A support engineer opens a tunnel in AWS and gets an SSH session on one gateway, wherever it is,
with no port open on the customer's network. The gateway only makes outbound TLS connections to
AWS (TCP 443).

```
support PC                       AWS (us-east-1)                          gateway (Pi 5)
ssh -p 5555 root@localhost       secure tunneling service                 aws-iot-device-client
   |                               ^             ^                          |        |
localproxy (source mode) --wss--> |             | <---------- wss --------- +        |
                                   IoT Core: "tunnel opened" on             MQTT ----+
                                   $aws/things/<thing>/tunnels/notify       (TLS 443)
                                                                            |
                                                              127.0.0.1:22 dropbear (key from #1)
```

1. The device client keeps one MQTT connection to AWS IoT Core as the thing
   `gateway-<EUI>-tunnel` and listens on the thing's tunnel topic.
2. Someone with the IAM permission opens a tunnel for that thing with service `SSH`. AWS
   publishes the destination token on the topic.
3. The client connects out to the tunneling service with the token and forwards the tunnel to
   `127.0.0.1:22`.
4. The engineer runs AWS's `localproxy` in source mode with the source token. It listens on a
   port of the engineer's own PC; `ssh` to that port reaches the gateway's dropbear, which still
   accepts only the key from issue #1 (`/root/.ssh/authorized_keys`, no passwords).

## Choice: AWS IoT Device Client v1.10.1, secure tunneling only

| | AWS IoT Device Client | `localproxy` alone |
|---|---|---|
| Receives the "tunnel opened" message | Yes, its own MQTT connection | No. Needs a separate MQTT program to subscribe and start it with the token |
| Dependencies | AWS IoT Device SDK for C++ v2 and the Common Runtime (C, built from source, about 15 libraries), OpenSSL | Boost (several compiled libraries), protobuf, OpenSSL, plus the MQTT program |
| Pinned release | v1.10.1 (May 2025, the latest release; the repository is maintained, last commit Jan 2026) | v3.3.1 (Aug 2026) |
| Features to switch off | Jobs (runs commands from AWS), Device Defender, Fleet Provisioning, shadows, samples, sensor publish: all excluded at build time with `-DEXCLUDE_*=ON` | none |

The device client was chosen: one program, one CMake build, and no code of ours on the MQTT side.
`localproxy` would need Boost and protobuf cross-built (Buildroot has both, but Boost's build is
the longer one) and a small MQTT agent to write and maintain. `localproxy` is still what the
**support PC** runs, as a prebuilt download or Docker image; nothing of it goes on the gateway.

The device client's own build clones the SDK with git while CMake configures. In Buildroot that
would download during the build, with no hash check. So the SDK is a package of its own,
[`aws-iot-device-sdk-cpp-v2`](../base_external/package/aws-iot-device-sdk-cpp-v2/), at the commit
that device client v1.10.1 pins (`74c8b683`, tag v1.30.3), downloaded once by Buildroot as a git
archive with its submodules and checked against a hash. It is built as static libraries into
staging only, with Buildroot's OpenSSL instead of the bundled aws-lc. The device client package
[`aws-iot-device-client`](../base_external/package/aws-iot-device-client/) builds against it with
`BUILD_SDK=OFF` and carries one patch (no `git config --global` during configure, no `-Werror`,
shared OpenSSL).

Both packages need `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`: the SDK asks for CMake 3.1, which the
CMake 4 of Buildroot 2026.02 otherwise refuses.

## On the gateway

| File | From | What |
|---|---|---|
| `/usr/bin/aws-iot-device-client` | package | the client, tunneling only |
| `/usr/bin/tunnel-run.sh` | package | respawn loop: restarts the client with a delay of 5 s doubling to 5 min while it keeps failing, back to 5 s after a run of 60 s; `nice 10`; output to syslog tag `tunnel` |
| `/etc/init.d/S99tunnel` | package | starts the loop in the background after `S99gwmon`; never fails the boot; does nothing without credentials or with `tunnel.disable` on the boot partition |
| `/etc/aws-iot-device-client/{cert.pem,key.pem,endpoint,thing}` | boot partition, by `S35provision` | the thing's certificate (644), key (600), the account's IoT endpoint and the thing name; directory 700, as the client requires |

The tunnel client is **not** supervised by gwmon. gwmon resets the Pi through the hardware
watchdog when Station fails five times in a row; a remote-shell client that cannot reach AWS must
never do that. The two only share the CPU and the network.

To provision a gateway, put four files on the FAT boot partition next to the other first-boot
files: `tunnel.cert.pem`, `tunnel.key.pem`, `tunnel.endpoint`, `tunnel.thing`. `S35provision`
moves them into `/etc/aws-iot-device-client` at the next boot and deletes them from the card.
When issue #10's provisioning function issues this certificate too, it can return the same four
files.

## AWS side

One thing per gateway, `gateway-<EUI>-tunnel`, with its own certificate, separate from the
LoRaWAN gateway's CUPS/LNS certificates (those belong to IoT Core for LoRaWAN and cannot be used
for MQTT). The policy [`issue15-tunnel-policy.json`](issue15-tunnel-policy.json),
`aesd-tunnel-policy`, allows exactly:

- `iot:Connect` with the client ID equal to the thing name, only for a certificate attached to
  that thing;
- `iot:Subscribe` and `iot:Receive` on `$aws/things/<own thing>/tunnels/notify`.

No publish, no other topic, no shadows or jobs. A stolen gateway certificate can only wait for
tunnel notifications for its own thing.

### Who can open a session

Anyone whose IAM identity in the account is allowed `iot:OpenTunnel` (and, to get a new source
token, `iot:RotateTunnelAccessToken`) for the thing's ARN. In this account that is the
administrator SSO role only. For a support team, a role with only these actions, limited to
`arn:aws:iot:us-east-1:<account>:thing/gateway-*-tunnel`, plus `iot:DescribeTunnel`,
`iot:ListTunnels` and `iot:CloseTunnel`, is enough. CloudTrail records every `OpenTunnel` with the
caller's identity.

Opening a tunnel is not the whole of it: the engineer also needs an SSH private key in the
gateway's `authorized_keys`. A tunnel without the key gets a dropbear login prompt that accepts
nothing.

### What a session costs

AWS IoT Device Management bills **$1.00 per tunnel opened** (us-east-1), whatever the duration
(up to 12 h) and however many times the ends reconnect
([pricing](https://aws.amazon.com/iot-device-management/pricing/)). The client's idle MQTT
connection costs IoT Core connectivity minutes and keep-alives, a few cents per gateway per month.

### What a session is

**A root shell on a device on a customer's network.** From it, the engineer can reach anything the
gateway can reach on that network, and can stop Station, change credentials or brick the card.
Open a tunnel only with the customer's agreement, close it when done
(`aws iotsecuretunneling close-tunnel`), and keep the list of IAM identities above short.

## Open a session (support engineer)

On a PC with the AWS CLI signed in to the account and the gateway's SSH key from issue #1, and
AWS's `localproxy` v3.3.1 built (see below):

```bash
THING=gateway-0016c001f1135844-tunnel
# 1. Open the tunnel ($1.00). AWS sends the destination token to the gateway by MQTT.
aws iotsecuretunneling open-tunnel \
    --destination-config thingName=$THING,services=SSH \
    --timeout-config maxLifetimeTimeoutMinutes=30 > tunnel.json
# 2. Start the source end on this PC: it listens on localhost:5555.
#    Keep the token out of the command line: localproxy reads it from AWSIOT_TUNNEL_ACCESS_TOKEN.
export AWSIOT_TUNNEL_ACCESS_TOKEN=$(jq -r .sourceAccessToken tunnel.json)
#    --destination-client-type V1 is required: the device client speaks the older tunnel protocol,
#    and without it the TCP connection opens but SSH hangs before the banner.
localproxy -r us-east-1 -s 5555 -b 127.0.0.1 --destination-client-type V1 &
# 3. SSH through it. Only the issue #1 key is accepted.
ssh -i ~/.ssh/aesd_pi5_ed25519 -p 5555 root@localhost
# 4. Close it when done, and delete the token file.
aws iotsecuretunneling close-tunnel --tunnel-id $(jq -r .tunnelId tunnel.json)
rm tunnel.json
```

The AWS IoT console can do the same from a browser: *Remote operations, Secure tunnels, Create
tunnel*, quick setup, service SSH, the thing above.

Building `localproxy` on Ubuntu (WSL): it needs the OpenSSL and zlib headers
(`sudo apt install libssl-dev zlib1g-dev`) and CMake 3.31 or newer with HTTPS (Kitware's release
tarball works; Buildroot's host CMake has no HTTPS). Then
`cmake -S . -B build -DLOCALPROXY_DEP_MODE=fetch -DBUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release && cmake --build build -j`
in a clone of tag v3.3.1: it downloads and checks its own Boost and protobuf (about 4 min).
Without sudo, `apt-get download libssl-dev libssl3t64 zlib1g-dev zlib1g` and `dpkg -x` into a
local prefix work too, with `OPENSSL_ROOT_DIR`/`ZLIB_ROOT` pointed at it; that is how it was built
for the test below.

## Results

| DoD box | Result | Evidence |
|---|---|---|
| 1. Package, pinned release, tunneling only, init script | Pass | [logs/issue15-build.log](logs/issue15-build.log): only `tunneling/` and the core are compiled; `S99tunnel` and the client are in the image (`sdcard.img` `5b29989d…11a0`, not flashed yet) |
| 2. Own thing and certificate, from the boot partition by `S35provision`, nothing secret in the repo, minimal policy | Pass, except a cold boot | AWS: thing, certificate and `aesd-tunnel-policy` created 2026-11-21. [logs/issue15-s35provision.log](logs/issue15-s35provision.log): host test 23/23, and the script run on the Pi from `/tmp` against fake boot files. The client connected with that policy. A boot of the new image with real `tunnel.*` files on the card waits for the reflash |
| 3. SSH through a tunnel from another network | LAN: pass. Other network: waits for Sam | [logs/issue15-tunnel-ssh.log](logs/issue15-tunnel-ssh.log): a tunnel opened in AWS gave a root shell on `aesd-pi5` through localproxy on the PC, with the gateway's host key checked; logins with no key or another key were refused. The PC was on the same LAN, but the path is PC → AWS → gateway's outbound connection (dropbear sees `127.0.0.1`). The hotspot run waits for Sam |
| 4. No new inbound port | Pass | [logs/issue15-netstat.log](logs/issue15-netstat.log): with the client connected, the listening sockets are the same as before (22, 9000, chrony on localhost). The client only has an outbound connection to port 443 |
| 5. Client crash or AWS unreachable: Station and gwmon unaffected, client comes back | Pass | [logs/issue15-crash-outage.log](logs/issue15-crash-outage.log) |
| 6. Who, cost, root shell | Pass | the sections above |

Tests on the Pi ran with the client and its files in `/tmp` (lost at the next reboot), started by
hand with `tunnel-run.sh`, on the card that issue #10 flashed. Nothing outside `/tmp` was changed.
The outage was made with a blackhole route for the IoT endpoint's address only, removed by the
same script after the set time.

What the tests showed:

- `kill -9` of the client: `tunnel-run.sh` starts it again 5 s later and it reconnects within 1 s.
  Station keeps its PID, gwmon's `station_restarts` stays 0, the watchdog stays active.
- Client restarted while the endpoint is unreachable (blackhole route, 180 s): it does not exit,
  it retries by itself after 10, 20, 40 and 80 s (the SDK maps the refused connect to
  `AWS_ERROR_FILE_INVALID_PATH`, a misleading name) and is connected and "Running Secure
  Tunneling" again on the next try that reaches AWS. That try came 22 s before the route was
  removed: the endpoint name resolves to several addresses and only the one DNS returned at the
  start was blocked, so this shows the retry, not the exact moment AWS came back. Station kept its
  PID and gwmon counted no restart throughout.
- A 150 s blackhole of an established connection went unnoticed: the client's MQTT keep-alive is
  the SDK default, 1200 s, and the connection carried on afterwards. A longer outage is seen at the
  next keep-alive, after which the client reconnects as above (15 s to 240 s between attempts;
  from the code, not tested with a 20-minute outage). So for up to about 20 min after a network
  outage a tunnel notification can be missed; opening the tunnel again then works.

### Problems found on the way

- The device client's build clones the SDK during configure, edits `~/.gitconfig`, uses `-Werror`,
  links OpenSSL statically, always builds its googletest tests, links the static SDK in an order
  that does not resolve, and prints an empty version without git. The patch in the package fixes
  each (its commit message lists them).
- CMake 4 refuses the SDK's `cmake_minimum_required(3.1)`: `CMAKE_POLICY_VERSION_MINIMUM=3.5`.
- An `endpoint` file written by the Windows AWS CLI ends in CR LF, which the client passed to DNS
  ("Host name was invalid"). `S35provision` already strips CR from text files; `tunnel-run.sh`
  now does too.
- `localproxy` for the support PC: this PC's WSL has no system CMake, Buildroot's host CMake has
  no HTTPS for its downloads, and the OpenSSL development headers are missing. Solved with
  Kitware's CMake and the headers unpacked without sudo (above).
- localproxy v3 against device client v1.10.1: the first tunnel connected both ends, but SSH
  timed out at the banner and the client logged `errorCode=13339`
  (`..._SECURE_TUNNELING_INACTIVE_SERVICE_ID`). `--destination-client-type V1` on the source fixes
  it, as AWS's local proxy guide says for the device client. Two tunnels, $2.00 in all.

## For Sam on Nov 29 (box 3)

1. `localproxy` is built in WSL: `~/aesd/research/issue15/localproxy/build/bin/localproxy`.
2. Connect this PC to the phone hotspot (not the home LAN). Check: `ping 192.168.0.103` must fail.
3. Run "Open a session" above. Expected: the dropbear banner, a root prompt on `aesd-pi5`.
   Also try `ssh -p 5555 root@localhost` **without** the key: it must be refused.
4. Copy the terminal output into `docs/logs/issue15-hotspot-ssh.log` (no token, no endpoint),
   then `close-tunnel`.
5. With the new image flashed: put the four `tunnel.*` files from
   `%USERPROFILE%\aesd-secrets\issue15-tunnel\` on the boot partition (`thing`, `endpoint`,
   `cert.pem`, `key.pem` renamed to `tunnel.thing` and so on), boot, and check
   `logread`/`/var/log/messages` for `tunnel: ... Running Secure Tunneling!`.
