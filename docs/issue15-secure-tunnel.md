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

## Results

To be completed.
