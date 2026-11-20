# Issue #10: zero-touch gateway provisioning

Flash a card, power the gateway on, and it is connected: the gateway registers itself in AWS IoT Core for LoRaWAN the first time it boots. This page has the design decisions and the results for the issue's definition of done. The README section "Zero-touch provisioning" is the user's view: how to flash, what is stored where, how to deploy the function and how to revoke a gateway.

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #10): https://claude.ai/code/cshk_01CSAPnw19XXA81xkir2Ei316vsRvZPpL3YkJGDGzNdFWr -->

These are the results for the issue's definition of done, measured on 2026-11-19 UTC (the evening of 2026-11-18 local time) on the Pi 5 with the WM1302, on Ethernet. The card was flashed by `scripts/flash-gateway.ps1` with the image built from commit `6c2014d` (`sdcard.img`, SHA-256 `5179b1d4…4917`), and the function ran the code of commit `a3f065c`.

| Definition of done (issue #10) | Result |
|---|---|
| The flash script writes the image and a per-gateway secret and records the fingerprint. It prints nothing secret, and it has a non-interactive mode with documented exit codes | **Pass**, as `scripts/flash-gateway.ps1 -DiskNumber <n>` instead of `flash-gateway.sh <device>` ([why](#the-flash-script-is-powershell-not-a-shell-script)). One real card flashed with `-Force`: exit code 0, image read back, fingerprint recorded as `unused`. 23 host checks cover the exit codes and that the secret is in no output |
| `provisioning/` holds the handler and a deployment template. Its IAM role allows only the gateway and certificate actions it needs. A host test runs the handler against a fake AWS and a fake allow-list | **Pass.** 23 handler tests: valid, reused and unknown secret, AWS failing at each step, an EUI that is already registered. The stack was deployed from the template, and the role did everything the tests on AWS needed |
| The first-boot request is made by Station's CUPS bootstrap or by a short init script, and `docs/` says which and why. A gateway that already has credentials makes no request | **Pass.** An init script ([why](#who-makes-the-first-boot-request-an-init-script-not-stations-cups-bootstrap)). At the second boot the gateway logged `no provisioning request`, and the function received 0 requests |
| End to end: a card flashed by the script and booted in a Pi that was never registered shows as Connected in AWS within 2 minutes of getting a network, with nothing typed and no file copied by hand | **Pass.** Connected **14.5 s after the DHCP lease**, 28 s after the kernel started. AWS had no gateway with this EUI before the boot |
| A second request with the same secret is refused and logged. A request with an unknown secret is refused. Neither creates anything in AWS | **Pass.** HTTP 409 and HTTP 403, sent from the PC and by the gateway itself. Each is one `refused` line in the function's log. The numbers of gateways and certificates did not change |
| If the network or the function is unavailable at first boot, the gateway retries with backoff, and gwmon keeps the board up meanwhile | **Pass for the network, on the Pi, with a simulated outage.** 5 failed tries 6, 11, 24, 44 and 70 s apart while gwmon reported `station=unconfigured watchdog=active`, then Connected 57 s after the lease. **A function that fails was tested on the host only** (HTTP 503 and 502 from a fake function) |
| No secret, key or certificate is in the repo or in the committed logs, and the function never logs the secret or a private key | **Pass.** The `git grep` of the issue prints nothing. The function's log was searched for the two secrets that the tests knew: 0 matches |
| The README documents flashing, what is stored where, how to revoke a gateway, and the IAM permissions needed to deploy | **Pass.** README, "Flash and first boot" and "Zero-touch provisioning" |
| The results say plainly which allow-list was used | **The stand-in DynamoDB table**, `aesd-gateway-provisioning-allowlist`. The SoilData API was not used: its endpoints do not exist yet |

Things to know about these results:

- **The allow-list was the stand-in table**, not the SoilData API.
- **This Pi had been registered before.** Its EUI was registered by hand in issue #4. To test a gateway that AWS does not know, that registration (gateway `92f4b2e8-…` and its two certificates) was deleted before the card was flashed, with the owner's approval. The gateway now has a new ID, `ae8306e1-46c0-4467-89c8-334985a906ae`, and the name `gateway-0016c001f1135844`.
- **The network outage was simulated on a running Pi.** A script on the Pi stopped `ifplugd`, ran `ifdown eth0`, removed the Station credentials, installed a second secret and started `gateway-provision` the way the boot does. It was not a cold boot and not a pulled cable.
- **"The function is unavailable" was not produced on AWS.** The gateway's handling of HTTP 503 and 502 is tested on the host against a fake function, and the function's own failure path against a fake AWS.
- **The image was built again after the tests**, when the session link went into the header comments: commit `26fccd6`, `sdcard.img` SHA-256 `edd4a301…820e`. It differs from the tested image in comments only and has not been booted. The Pi still runs the tested image.
- **The function on AWS still runs the code of `a3f065c`.** The later commits changed only comments in `provisioning/src` (the session link). `provisioning/deploy.sh` uploads the current code.
- **AWS makes one certificate more than it uses.** Each time a gateway first asked AWS's CUPS server for its LNS credentials, two certificates appeared in the account within 0.2 s, and only one of them is the gateway's LNS certificate. The other stays active and unused. One is left from issue #4 and two from these tests. The function does not create them and does not know them, so it leaves them alone.

## Design

```
 PC, once per card                  gateway, first boot                 AWS (us-east-1)
 ----------------                   -------------------                 ---------------
 flash-gateway.ps1
   writes sdcard.img
   makes a random secret ---------> provision.secret, provision.url
   records SHA-256(secret) ------------------------------------------> allow-list (DynamoDB table)
                                    S35provision moves both files
                                    to /etc/gateway-provision
                                    gateway-provision:
                                      POST {gateway_eui, secret} ----> provisioning function (Lambda)
                                                                         consume the fingerprint
                                                                         register the gateway (US915)
                                                                         create its certificate
                                      cups.uri, cups.trust, <--------- the four files
                                      cups.crt, cups.key
                                      to /etc/station, restart gwmon
                                    Basics Station ------------------> CUPS, then the LNS: Connected
```

### Who makes the first-boot request: an init script, not Station's CUPS bootstrap

The issue left this open: either Basics Station's own CUPS bootstrap (a set of `cups-boot.*` files) or a short init script. The choice is **the init script**, `/usr/sbin/gateway-provision`, started by `S45gateway-provision`. This is what the Station v2.0.6 source says about the bootstrap, and why it lost.

**What Station could do.**

- *Make the first request itself: yes.* Station knows three sets of each credential file: regular (`cups.*`), backup (`cups-bak.*`) and boot (`cups-boot.*`). With only `cups-boot.uri` present it starts, and `cups.c` posts to `<that address>/update-info`.
- *Carry the per-gateway secret: yes.* With a `cups-boot.trust` and a `cups-boot.key` but no `cups-boot.crt`, `sys_cred()` in `sys.c` reports token authentication, and `net.c` (`validateAuthToken`) sends the content of the key file as HTTP header lines, for example `Authorization: <secret>`. The gateway EUI is the `router` field of the JSON body.
- *What the server must return: the CUPS wire format, not JSON.* `cups_update_info()` in `cups.c` reads a binary body: a 1-byte length and the CUPS address, a 1-byte length and the LNS address, a 2-byte length and the CUPS credentials, a 2-byte length and the LNS credentials, then 4-byte lengths for a signature and an update file. The credentials are the trust certificate, the gateway certificate and the key in DER, one after the other (`sys_credComplete()` splits them at their ASN.1 sequence headers). The reply needs HTTP status 200 and a `Content-Length` header: Station's HTTP client treats a reply without one as empty.

**Why the init script was chosen anyway.**

1. *Station keeps the boot set and comes back to it.* In `cups_ondone()`, after a rejected request or more than 6 failed ones (`FAIL_CNT_THRES`), Station moves on to the next credential set: regular, backup, boot, and around again. The 12-minute outage in issue #4 shows the precondition: with the network down Station tried CUPS once a minute. So a gateway that was provisioned long ago would send its secret to the provisioning function again after any long outage. The definition of done says that a gateway with credentials makes no request. Deleting `cups-boot.*` after the first success would fix that, but it takes a script that watches for the success, which is the script this option was meant to avoid.
2. *No backoff.* Station retries a failed CUPS request every minute (`CUPS_RESYNC_INTV`), at a fixed interval. The definition of done asks for backoff.
3. *The function would have to speak CUPS.* It would build the binary reply and convert the certificate and key from PEM to DER, and a mistake would show on the gateway only as `CUPS Protocol error`. With the script, the function returns plain JSON, the gateway logs the HTTP status and the function's error word, and the same request can be made by hand with `curl`.
4. *The allow-list is going to move.* The function is the piece that will later talk to the SoilData API. A JSON request that carries the secret in its body is easier to keep stable than a header inside Station's key file.

**What the script costs.** The image gains `curl` (with OpenSSL, which was already in the image) and `jq`: `curl`, `libcurl`, `jq` and `libjq` add 1.3 MB to a root filesystem of 74 MB. Basics Station's own TLS library could not be used for this, because it is linked statically into `station`.

### The request and the function

`gateway-provision` sends one HTTPS request, `POST <address>/provision` with `{"gateway_eui": "...", "secret": "..."}`. The secret goes to `curl` on standard input, so it is never on a command line. `curl` checks the server certificate against the image's CA bundle and is told to refuse any protocol but HTTPS.

The function ([provisioning/src/handler.py](../provisioning/src/handler.py)) answers:

| Status | Body | Meaning | What the gateway does |
|---|---|---|---|
| 200 | the four files as JSON strings | Registered. The secret is now used | Installs them, deletes the secret, restarts gwmon |
| 400 | `{"error": "bad_request"}` | Not JSON, or a malformed EUI or secret | Gives up until the next boot |
| 403 | `{"error": "unknown_secret"}` | The fingerprint is not in the allow-list | Gives up until the next boot |
| 409 | `{"error": "secret_already_used"}` | The fingerprint was consumed before | Gives up until the next boot |
| 503 | `{"error": "try_again"}` | The allow-list or AWS IoT failed. The secret is unused again | Retries with backoff |
| anything else, or no answer | | Network down, clock not set, AWS in front of the function | Retries with backoff |

The order inside the function is what keeps a refusal from creating anything: it asks the allow-list first, and only an `ok` lets it call AWS IoT. Registration is the four calls of [aws-iot-core-setup.md](aws-iot-core-setup.md): `GetServiceEndpoint`, `CreateWirelessGateway`, `CreateKeysAndCertificate` and `AssociateWirelessGatewayWithCertificate` ([gateway_registry.py](../provisioning/src/gateway_registry.py)). If one of them fails, the certificate made in that request is deleted again, the secret is released, and the gateway's next try starts clean.

The function logs one JSON line per request: the outcome, the EUI and the first 8 characters of the fingerprint. It never logs the request, the secret or the key, and it catches every exception so that the runtime prints no traceback.

### The allow-list interface

The function knows the allow-list only through two methods ([allowlist.py](../provisioning/src/allowlist.py)):

- `consume(fingerprint, gateway_eui, now)` returns `ok`, `unknown` or `used`. It is one atomic step, so two requests with the same secret can never both get `ok`.
- `release(fingerprint)` undoes a `consume()` whose registration then failed.

The flash script has the third operation, "record a new fingerprint as unused", as its own pair of functions (`Test-AllowList` and `Add-AllowListFingerprint` in [flash-gateway.ps1](../scripts/flash-gateway.ps1)).

`DynamoDbAllowList` implements the two methods with one conditional `UpdateItem` each on the table `aesd-gateway-provisioning-allowlist`. The condition `state = unused` is false for a missing item too, so `consume()` cannot create an entry, and the function's role has no permission to add one. **This table is a stand-in.** The allow-list belongs in the SoilData API, the company's backend, whose two endpoints (record a fingerprint, check and consume a fingerprint) do not exist yet. An HTTP class with the same two methods replaces `DynamoDbAllowList` in one place, `_default_deps()` in `handler.py`. If that API has no "release", `release()` can do nothing there: a gateway whose registration failed then needs its card flashed again.

### An EUI that is already registered

A card can be flashed again for a gateway that is already registered: the card died, or the gateway was revoked. The function then keeps the gateway record, with its ID and name, creates a new certificate, and revokes and deletes the certificate the gateway had before. A gateway has one working certificate at a time, the one on its newest card. If the new certificate cannot be associated, the old one is put back.

The EUI in the request is not proven. Whoever holds a valid, unused secret can name any EUI, including that of somebody else's registered gateway, and would take that gateway's place in AWS. Secrets exist only on cards that we flashed, so this is a limit to know, not a hole that a stranger can use. Binding a gateway to an owner is the later step that this issue leaves out.

### Retry and backoff

`gateway-provision` waits 5 s after the first failed try and doubles the wait each time, up to 60 s, with up to a quarter more at random so that a batch of gateways powered on together does not ask in step. The cap is low on purpose, the same as in Station's own reconnect backoff: however long the network was away, the next try comes within about a minute of its return, which keeps "connected within 2 minutes of getting a network" true after an outage too. It never stops trying while the failure is one that can pass: no network, no clock, no answer, a 5xx status. It stops, until the next boot, when the function itself refuses the secret.

Before the first try it waits up to 60 s for chronyd to set the clock, as `station-run.sh` does: the Pi has no RTC battery, and with a wrong date TLS rejects the server.

While this goes on the gateway is up. `station-run.sh` exits with status 78 because there is no `cups.uri`, gwmon reports `station=unconfigured` and keeps feeding the watchdog (issue #7), and SSH works. When the files arrive, `gateway-provision` runs `/etc/init.d/S99gwmon restart`, because gwmon does not start an unconfigured Station again by itself.

### The flash script is PowerShell, not a shell script

The issue named `scripts/flash-gateway.sh <device>`. What was built is `scripts/flash-gateway.ps1 -DiskNumber <n>`. The image is built in WSL2, and WSL2 cannot open the PC's card reader as a block device (`wsl --mount` does not support removable media). Writing a card on this PC means Windows' own disk interfaces from an elevated process, which is PowerShell's ground. The issue text was changed to match.

- It refuses any disk that is not a removable USB, SD or MMC disk, the system or boot disk, and disks over 128 GB.
- It erases the partition table first (`diskpart clean`), then writes the image except its first 4 MiB, reads that back, and writes the first 4 MiB, with the partition table, last. Until that moment Windows sees an empty disk and does not mount, lock or write to the boot partition.
- It has a non-interactive mode (`-Force`), exit codes 0 to 10 that are listed in its header, and a last output line `RESULT ok ...` or `RESULT error code=<n>` for a production test script.
- It never prints the secret. The secret exists in one variable for a few lines, and on the card.

### Limits

- **A lost answer costs a reflash.** If the function registers the gateway and the answer does not reach it (power cut in that second), the secret is used and the key is gone. The gateway is refused at its next try. Flashing the card again fixes it; the stale certificate is replaced then.
- **The secret is on the card in the clear** until first boot, and FAT deletion does not wipe it. Someone who copies a card before its first boot can provision in its place, once. After first boot the secret is worthless.
- **The function's address is public.** Anyone can post to it. A request without a listed, unused secret costs one conditional write that fails and one log line. Guessing a 256-bit secret is not feasible. There is no rate limit of our own in front of it.
- **Wi-Fi-only gateways** still need a `wpa_supplicant.conf` copied to the card.

## Results on the Pi and on AWS

Logs: [flash](logs/issue10-flash.log), first boot ([syslog](logs/issue10-first-boot-syslog.log), [Station](logs/issue10-first-boot-station.log), [AWS](logs/issue10-first-boot-aws.log)), [second boot](logs/issue10-second-boot.log), [network outage](logs/issue10-network-outage.log), [reused and unknown secret](logs/issue10-reused-secret.log), [refusals before the first gateway](logs/issue10-function-refusals.log), [host tests](logs/issue10-host-tests.log), [build](logs/issue10-build.log). In the logs the account-specific host names of the AWS endpoints and of the function are replaced by `<id>` and `<function-url>`, and the PC's address by `<pc>`. Certificate IDs are cut to 8 characters. No secret, key or certificate content is in them.

### 1. Flashing

`flash-gateway.ps1 -DiskNumber 2 -Force` in an elevated PowerShell, with the card in the PC's reader ([logs/issue10-flash.log](logs/issue10-flash.log)):

```
flash-gateway: image SHA-256 5179b1d49234984ba9e287040c21f5feb68d7e3f9d203d5954ceaed628554917, 411041792 bytes
flash-gateway: target disk 2: Generic STORAGE DEVICE, 58.6 GB
flash-gateway: image written and read back
flash-gateway: provision.secret and provision.url written to the boot partition
flash-gateway: fingerprint 36e2e205e5ed9d0b8217fe68efdd094ba558da6e67fcf808e98c0d7d1fb76176 recorded as unused (dynamodb allow-list, table aesd-gateway-provisioning-allowlist)
RESULT ok fingerprint=36e2e205... image_sha256=5179b1d4...
```

The process exit code was 0. Afterwards the boot partition held `provision.secret` (65 bytes: 64 characters and a line end) and `provision.url` next to the image's own files, and no `cups.*` file. They were listed by name and size only. The allow-list had the fingerprint with `state` `unused`.

The exit codes and the "never prints the secret" rule are checked by `scripts/test/flash-gateway-test.ps1`, which runs the script with a file in place of the card: 23 checks, all passed ([logs/issue10-host-tests.log](logs/issue10-host-tests.log)). The same test mode was also run once against the real allow-list table. What only the real card tested is the Windows disk handling: `diskpart clean`, the raw write, and waiting for the boot partition.

### 2. The function and its role

`provisioning/deploy.sh` created the stack `aesd-gateway-provisioning` in `us-east-1` with 7 resources: the function, its URL, two permission statements that make the URL public, the role, the table and the log group. The role's statements are in [template.yaml](../provisioning/template.yaml), each with a comment on why it is there. Everything below ran with that role, so it is at least sufficient. It has no action that the code does not call.

Before any gateway was provisioned, seven bad requests were sent from the PC ([logs/issue10-function-refusals.log](logs/issue10-function-refusals.log)): an unknown secret (403), malformed bodies (400), `GET` (405) and Station's own `/update-info` path (404). The account had 2 gateways, 6 certificates and 0 allow-list entries before and after.

The host tests ([logs/issue10-host-tests.log](logs/issue10-host-tests.log)) run the handler against a fake AWS that keeps gateways and certificates in memory and can be told to fail one operation:

| Case | What the test checks |
|---|---|
| Valid secret | 200 with the four files, one gateway with one active certificate, the secret marked used by this EUI |
| Reused secret | 409, logged, no new write to AWS, also when it comes with another EUI |
| Unknown secret | 403, logged, no write to AWS, no allow-list entry created |
| AWS fails (endpoint, gateway, certificate, association) | 503, no certificate left behind, the secret unused again, and the retry succeeds |
| Allow-list fails | 503, no write to AWS |
| EUI already registered | The gateway record is kept, the new certificate replaces both old ones; if the new one cannot be set, the old one is put back and nothing is deleted |
| Malformed request, other path or method | 400, 404, 405, no write |
| Every case | Neither the secret nor the key is in what the function logged |

### 3. The first boot

The card went from the reader into the Pi, and the Pi was powered on with Ethernet connected. Nothing else was done. From [logs/issue10-first-boot-syslog.log](logs/issue10-first-boot-syslog.log), [logs/issue10-first-boot-station.log](logs/issue10-first-boot-station.log) and [logs/issue10-first-boot-aws.log](logs/issue10-first-boot-aws.log):

| UTC | Uptime | Event |
|---|---|---|
| 02:32:57 | 3 s | `provision: installed /etc/gateway-provision/secret` and `url` (S35provision) |
| 02:32:57 | 3 s | gwmon starts. `station has nothing to run (exit status 78): not restarting it, the watchdog is still fed` |
| 02:33:08 | 13.74 s | `ntp-hook: eth0 has a DHCP lease` |
| 02:33:14 | 19.75 s | `ntp-hook: clock synchronised by NTP` |
| 02:33:15 | | `gateway-provision: gateway EUI 0016c001f1135844, secret fingerprint 36e2e205..., asking the provisioning function` |
| 02:33:19 | 25.17 s | The four files installed. `provisioned after 1 tries`. gwmon restarted |
| 02:33:21.1 | 26.66 s | Station starts and asks AWS's CUPS server, which answers with the LNS address and credentials |
| 02:33:22.6 | 28.2 s | `Connected to MUXS.` |
| 02:33:25.3 | | `Concentrator started`, `Configuring for region: US915` |

AWS, polled from the PC every 3 s, changed from `not registered` to `registered: ae8306e1-… gateway-0016c001f1135844, Connected` with `LastUplinkReceivedAt` 02:33:22.675. That is **14.5 s after the lease** (uptime 28.2 s against 13.74 s) and about 28 s after the kernel started.

The function logged one line for it:

```
{"certificate_replaced": false, "event": "provisioned", "fingerprint": "36e2e205", "gateway_created": true, "gateway_eui": "0016c001f1135844", "gateway_id": "ae8306e1-46c0-4467-89c8-334985a906ae"}
```

Afterwards the allow-list entry was `used`, with `used_at` 02:33:18Z and this EUI. `/etc/station` held the four `cups.*` files and Station's `tc.*` files, all with mode 0600. `/etc/gateway-provision` was empty, and nothing was left on the boot partition.

### 4. A gateway that has credentials makes no request

The Pi was rebooted ([logs/issue10-second-boot.log](logs/issue10-second-boot.log)):

```
02:34:52 gateway-provision: Basics Station credentials are in place, no provisioning request
02:35:08 station: starting /usr/bin/station, uptime 18.65 s
02:35:08.944 [TCE:VERB] Connected to MUXS.
```

The function's log group received 0 events between the reboot and the check 40 s later, and the account still had the same gateway and certificates.

### 5. No network at first boot: retry with backoff, and the board stays up

A second secret was listed with the flash script's test mode and copied to the Pi. Then a script on the Pi took the network away for 100 s, removed the Station credentials and started `gateway-provision` as the boot does ([logs/issue10-network-outage.log](logs/issue10-network-outage.log)).

| UTC | Event |
|---|---|
| 02:36:08 | `ifplugd` stopped, `ifdown eth0` |
| 02:36:10 | gwmon restarted without credentials: `station=unconfigured` |
| 02:36:11 | Try 1: `no answer: curl: (6) Could not resolve host`. `next try in 6 s` |
| 02:36:17, 02:36:28, 02:36:52, 02:37:36 | Tries 2 to 5 fail the same way. Next try in 11, 24, 44 and 70 s (5, 10, 20, 40 and 60 s, each plus up to a quarter) |
| 02:37:48 | `ifplugd` started again |
| 02:37:59 | `eth0 has a DHCP lease` |
| 02:38:46 | Try 6 reaches the function. 02:38:47: the four files installed, `provisioned after 6 tries`, gwmon restarted |
| 02:38:55.97 | `Connected to MUXS.` AWS: Connected, 02:38:56.03 |

So the gateway was connected **57 s after the lease**, inside the 2 minutes, after an outage long enough to reach the 60 s cap.

During the outage the script read gwmon's status line every 10 s. All ten readings were alike but for the counters, which went up:

```
02:36:20 uptime 90.62 s, eth0 down: uptime=90s watchdog=active wd_feeds=6 station=unconfigured
02:37:50 uptime 180.70 s, eth0 down: uptime=180s watchdog=active wd_feeds=51 station=unconfigured
```

The uptime runs on through the whole test: the watchdog did not reset the board.

This run was also the test of an **EUI that is already registered**, on AWS itself. The function logged `"certificate_replaced": true, "gateway_created": false` for the same gateway ID. The gateway's two old certificates (`aa1a8ff7`, `56ef4a42`) were gone from the account afterwards, and the gateway had a new pair (`6e6e1bc4`, `0e6b8c90`).

### 6. A used secret and an unknown secret

After that run the second secret was used. It was sent again, and so was a random one ([logs/issue10-reused-secret.log](logs/issue10-reused-secret.log)):

| Request | Answer |
|---|---|
| From the PC: the used secret with the gateway's own EUI | `{"error": "secret_already_used"}`, HTTP 409 |
| From the PC: the used secret with another EUI | `{"error": "secret_already_used"}`, HTTP 409 |
| From the gateway: `gateway-provision` with the used secret | `refused by the provisioning function: HTTP 409 secret_already_used`, `giving up until the next boot`, exit status 1 |
| From the gateway: `gateway-provision` with a random secret | `refused by the provisioning function: HTTP 403 unknown_secret`, exit status 1 |

Before and after: 2 gateways, 8 certificates, the gateway's certificate pair unchanged, 2 allow-list entries, both `used`. The gateway stayed Connected. On the gateway the two runs used a directory in `/tmp`, so its real files were not touched, and they installed nothing. The function logged four lines:

```
{"event": "refused", "fingerprint": "da65712c", "gateway_eui": "0016c001f1135844", "reason": "secret_already_used"}
{"event": "refused", "fingerprint": "da65712c", "gateway_eui": "00000000000000aa", "reason": "secret_already_used"}
{"event": "refused", "fingerprint": "da65712c", "gateway_eui": "0016c001f1135844", "reason": "secret_already_used"}
{"event": "refused", "fingerprint": "6f8dbb02", "gateway_eui": "0016c001f1135844", "reason": "unknown_secret"}
```

### 7. No secret in the repo, the committed logs or the function's log

- The check from the issue, `git grep -l` for the PEM private-key marker, prints nothing and exits with status 1 on this branch. The pattern is not written out here, because this file would then match it. The fake key in the two test files is put together from two lines for the same reason.
- `.gitignore` now also excludes `provision.secret` and `provision.url`.
- The card's secret was never on the PC's screen or disk: the flash script makes it, writes it to the card and forgets it. The second secret, for the tests of sections 5 and 6, was made the same way into a scratch directory, copied to the Pi without being shown, and deleted from the PC after the tests.
- The function's log was searched for the two secrets that the PC knew during the tests, that second secret and the random one of the first refusal test: 0 matches each.

### What revoking a gateway does

Removing the issue #4 registration was done while that gateway was connected, which showed what the README's "Revoke a gateway" steps do:

| UTC | Step | Effect |
|---|---|---|
| 02:25:58 | The gateway's certificate disassociated, set inactive and deleted | AWS dropped the LNS certificate from the gateway record too. The open connection stayed: AWS still reported Connected 14 s later |
| 02:26:18 | Station restarted on the Pi | CUPS: `SSL - A fatal alert message was received from our peer`. The LNS did not accept the connection either. Station went on retrying with its own backoff |
| 02:27:05 | The LNS certificate and the gateway record deleted | `GetWirelessGateway` by EUI: `ResourceNotFoundException` |

So a revoked gateway keeps the connection it has, and is out at its next reconnect at the latest.
