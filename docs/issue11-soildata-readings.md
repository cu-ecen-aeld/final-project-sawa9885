# Issue #11: sensor readings reach the SoilData API through this gateway
This document was partially generated using Claude Code using the chat session at: https://claude.ai/code/cshk_01CSAPnvLCUHW6djnp5K19mA6Jjr4s6zEaqsQpq9xFyAZz

The path is node → this gateway → AWS IoT Core for LoRaWAN → SoilData forwarder → SoilData API, and the API's receipt goes back to the node as a downlink sent by this gateway. The SoilData API, the forwarder and the node firmware are existing BioSensor Solutions work, private, and not part of this repo. This issue adds only the registration script, a log helper and the checks on this gateway.

Nodes are named here by the last four hex digits of their DevEUI.

## Outcome (2026-11-21): closed as not planned

The delivery into the SoilData API was not done. The only SoilData forwarder is the production one, and the production forwarder is not changed for a course test. Everything short of the API was tested: the script on the host and against AWS, and the node → gateway → AWS uplink (issues #4 and #9).

| # | Box | Status |
|---|---|---|
| 1 | `scripts/register-node.sh` registers a node, idempotent, never prints the AppKey | **Pass.** Host test with a fake `aws`, 41 checks ([logs/issue11-register-node-test.log](logs/issue11-register-node-test.log)). Against AWS on 2026-11-21 with a throwaway identity (`...57b2`, destination `aesd_uplinks`): dry run, registration, and a second run that said "already registered ... Nothing changed."; the device was deleted afterwards ([logs/issue11-register-node-aws.log](logs/issue11-register-node-aws.log)) |
| 2 | Test node registered with the script, in a test company of the SoilData API | Not done: no SoilData test path exists without changing the production forwarder |
| 3 | Reading in the SoilData dashboard within one transmit interval, screenshot | Not done, same reason |
| 4 | Station log shows the uplink and `dntxed`, node reports the reading delivered | Not done for a SoilData reading. The uplink and `dntxed` through this gateway are shown in [issue4-basicstation-aws.md](issue4-basicstation-aws.md) and in the issue #9 check |
| 5 | AWS uplink metadata lists this gateway's EUI | Not done for a SoilData reading; shown for the issue #4 uplink |
| 6 | No keys or secrets in the repo or committed logs | **Pass.** `git grep -l` for the PEM private-key marker finds nothing in the files of this issue. On `main` it matches only the made-up test key of issue #15 in `scripts/test/tunnel-host-test.sh` (its body is the word "fake" in base64); the two new logs were read by eye and hold no 32-hex-digit value |
| 7 | Project Overview lists the SoilData API, forwarder and firmware as shared material | Not done: the sentence to add is at the end of this page |

### The real AWS run

The hidden prompt did not work in a Terminal tab of the Claude desktop app on Windows (Git Bash with `aws.exe`). Every try stopped before AWS was called, with exit 2:

- Enter arrives there as CR LF, so the NwkKey prompt read the leftover empty line. The script now skips empty lines and drops CR characters.
- Pasted keys were still refused after that; most likely the terminal wrapped them in bracketed-paste markers. The script now strips those markers and other control characters. A refused key is reported as the number of hex digits and the character codes of anything else, never the digits themselves.

Both cases are now in the host test, and the CR LF case failed on the old script. The registration itself was then run in WSL under a pseudo-terminal (a Python `pty` harness kept out of the repo) that answered each prompt with a fresh random key that was never printed. The terminal check in the script was not changed.

## `scripts/register-node.sh`

```
register-node.sh [-c] [-n NAME] [-p DEVICE_PROFILE] [-s SERVICE_PROFILE] [-d DESTINATION] <DevEUI> <JoinEUI>
```

- The profiles (name or id) and the destination (name) come from the options or from `REGISTER_NODE_DEVICE_PROFILE`, `REGISTER_NODE_SERVICE_PROFILE` and `REGISTER_NODE_DESTINATION`. Nothing about the AWS account is in the repo.
- DevEUI and JoinEUI must be 16 hex digits (`:` and `-` allowed). The device name defaults to `node-<last 4>`.
- If a device with that DevEUI exists, it prints `already registered ... Nothing changed.` and exits 0 without asking for a key. If that device has another destination it warns, and still changes nothing.
- Otherwise it checks that the profiles and the destination exist, reads the device profile's LoRaWAN version, and asks for the AppKey (and for LoRaWAN 1.1 also the NwkKey) at a hidden prompt. It refuses (exit 3) when standard input is not a terminal, so a key cannot come from a pipe, an argument or the environment.
- The request goes to `aws iotwireless create-wireless-device --cli-input-json file://...`. The file is in a directory created with `umask 077` (mode 600) and is deleted right after the call and by an `EXIT` trap. The key is never on a command line, so it is not in `ps` or the shell history; tracing is switched off; if AWS answers with an error, any copy of the key in it is replaced by `[key removed]`.
- `-c` does every lookup and stops before the prompt: a safe dry run.
- Exit status: 0 registered or already registered (or `-c` passed), 1 AWS call failed, 2 wrong usage or bad hex, 3 no terminal for the key, 4 profile or destination not found.

AWS error text is passed through. An access-denied message can contain the account number: read it before pasting it anywhere public.

### Host test

`bash scripts/test/register-node-test.sh` (Linux or WSL; needs `script` from util-linux for a pseudo-terminal). It puts a fake `aws` first on the `PATH` that logs its arguments and answers from state files, and types made-up test keys into the hidden prompt. It checks the argument validation, the "already registered" path (one read-only call, no create), the lookups and their exit codes, `-c`, the refusal without a terminal, registration for LoRaWAN 1.0.x and 1.1 (the request file has the right keys and destination, mode 600, and is gone afterwards), a malformed key, an AWS error that echoes the request back, and Ctrl-C at the prompt. In each case the keys appear neither in what the terminal showed nor in the fake's logged arguments, and the temporary directory is empty afterwards.

To check that the test can fail, it was also run against a copy of the script with one added line that prints the AppKey to stderr: 3 checks failed, as they should.

Not tested: typing keys by hand in a Windows terminal after the CR LF and paste fixes (see the outcome above).

## `scripts/station-log-node.sh`

Prints the Station log lines of one node from the gateway, with everything else left out. It runs only `cat` on the Pi over SSH.

```
scripts/station-log-node.sh -i ~/.ssh/aesd_pi5_ed25519 -a <DevAddr> root@<pi-address> <last 4 of DevEUI>
```

It prints the `jreq` lines of that DevEUI, the `updf` lines of that DevAddr (Station's data lines name the DevAddr, not the DevEUI), and the first `dntxed` within 6.5 s after a join request or 2.5 s after an uplink. It masks the DevEUI and JoinEUI to their last 4 digits, the downlink `frame=` bytes and the MIC values. `-f FILE` reads a local copy instead; on the issue #4 log it printed the node's join, three uplinks and the four downlinks. It has not been run against the Pi yet.

A `dntxed` line names no device, so with other nodes in range a downlink of another node in the same window would be printed too. With this gateway and one node, as in step 3, there are none.

## Future work: steps for a SoilData test path

Not done (see the outcome above). Kept for when a SoilData test forwarder or dev environment exists.

About 45 minutes if the test node's keys are at hand and the test company exists in the SoilData dashboard. Each step that creates something in AWS is yours to run.

1. **Pick the node.** Use a SoilData V2 node with SoilData firmware that is **not yet registered in AWS**, so that the script really registers it. The bench node of issue #4 (`...7c7c`) is already registered with the `aesd_uplinks` destination: the script would only say "already registered" and warn about the destination. In the SoilData dashboard, put the node in a test company, not a customer account (box 2).
2. **Register it**, in your own terminal (WSL or Git Bash, AWS CLI default profile):

   ```
   export REGISTER_NODE_DEVICE_PROFILE=<profile> REGISTER_NODE_SERVICE_PROFILE=<profile with gateway metadata on> REGISTER_NODE_DESTINATION=<SoilData destination>
   scripts/register-node.sh -c <DevEUI> <JoinEUI>     # dry run: all found, nothing changed
   scripts/register-node.sh <DevEUI> <JoinEUI>        # type the AppKey at the hidden prompt
   scripts/register-node.sh <DevEUI> <JoinEUI>        # again: "already registered ... Nothing changed."
   ```

   Save the terminal text of the three runs as `docs/logs/issue11-register-node-aws.log` after checking it holds no key and no account number.
3. **Make this gateway the only one in range.** Power off the reference gateway (and any other gateway of the company within reach) for the test. In AWS, check that only this gateway (EUI ending `5844`) shows a recent uplink.
4. **Join and send.** Power the node (or reset it) next to the gateway. Wait one transmit interval after the join.
5. **Capture the evidence:**
   - **Box 3:** screenshot of the reading in the SoilData dashboard, with its time, cropped to the test company and that node; save as `docs/issue11-dashboard.png`.
   - **Box 4:** `scripts/station-log-node.sh -i ~/.ssh/aesd_pi5_ed25519 -a <DevAddr> root@<pi-address> <last 4>` > `docs/logs/issue11-station-node.log` (the DevAddr is in the `updf` line, or in AWS after the join). It must show the `jreq`, the `updf` of the reading and the `dntxed` right after it. Then the node's own report that the reading was delivered (its serial console or the dashboard's delivery status), as text or a photo in `docs/`.
   - **Box 5:** `aws iotwireless get-wireless-device-statistics --wireless-device-id <id> --query 'LoRaWAN.{Time:Timestamp,FPort:FPort,Gateways:Gateways[].GatewayEui}'`, saved as `docs/logs/issue11-uplink-metadata.json`. The gateway list must hold this gateway's EUI and nothing else. The `--query` keeps the payload, the DevEUI and the ids out.
6. **Box 6:** run the check below over everything you add, then power the reference gateway back on.
7. **Box 7:** add the sentence at the end of this page to the Project Overview, if the issue #9 rewrite has not.

## Box 6: keys and secrets

Before each commit:

```
git grep -l "BEGIN"".*PRIVATE KEY"          # the issue's check, quoted in two parts so this page does not match it; must print nothing
git grep -n -i -E "appkey|nwkkey|webhook|api[_-]?key|secret" -- docs/logs
```

and read every new log by eye. A committed log may hold: gateway EUI, last 4 digits of a DevEUI, DevAddr, frequencies, SNR/RSSI, FCnt, timestamps. It may not hold: an AppKey or NwkKey (32 hex digits), a full DevEUI of a company node, payload bytes or decoded readings beyond what the screenshot shows, webhook URLs or secrets, API tokens, AWS account numbers, endpoint prefixes, ARNs, or customer or company names other than the test company. `station-log-node.sh` and the `--query` above already cut most of this.

The test keys in `scripts/test/register-node-test.sh` are made up for the fake `aws` and belong to no device.

## Box 7: sentence for the Project Overview

To add under **Shared Material**, after the first paragraph:

> Issue #11 sends readings from this gateway into existing BioSensor Solutions software that I did not write for this course and that stays private: the SoilData node firmware on the test node, the SoilData forwarder that receives uplinks from AWS IoT Core for LoRaWAN, and the SoilData API with its dashboard. None of their code is in this repo. The course work for that issue is `scripts/register-node.sh`, `scripts/station-log-node.sh` and the checks on this gateway.
