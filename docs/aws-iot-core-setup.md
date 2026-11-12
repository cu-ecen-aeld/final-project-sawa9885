# Register the gateway in AWS IoT Core for LoRaWAN

How the Pi 5 gateway was registered, and how to do it again for another board or account. Everything here is done by hand in the AWS console. The files it produces are secrets: they go on the microSD boot partition and never into this repo (`.gitignore` excludes their names).

<!-- This file was partially generated using Claude Code using the chat session at:
     Link to chat session (issue #4): https://claude.ai/code/cshk_01CSAPnz8sDPokK7N8rieHo1BXzy3XPsziDucST29D43Kh -->

## 1. Gateway EUI

The gateway EUI is the SX1302's own EUI. `S60station` reads it at every start and logs it:

```
# grep 'gateway EUI' /var/log/messages
... station: gateway EUI 0016c001f1135844, starting when the clock is set
# util_chip_id -d /dev/spidev0.0 | grep EUI      (only while Station is stopped)
INFO: concentrator EUI: 0x0016c001f1135844
```

This board: `0016C001F1135844`.

## 2. Add the gateway

AWS console → **IoT Core** → **LPWAN devices** → **Gateways** → **Add gateway**. Pick the AWS Region first (top right); the endpoints belong to that Region.

1. **Gateway's EUI**: `0016C001F1135844`.
2. **Frequency band (RFRegion)**: `US915`.
3. **Name**: for example `aesd-pi5`. Leave the sub-band and filter fields empty. The thing association is optional.
4. **Add gateway**. The console moves on to **Configure your gateway**.
5. **Gateway certificate** → **Create certificate** → **Download certificate files**. You get `<id>.cert.pem` and `<id>.private.key`. The private key can't be downloaded again later.
6. **Provisioning credentials** → **Copy** the **CUPS endpoint** (`https://<id>.cups.lorawan.<region>.amazonaws.com:443`) → **Download server trust certificates**. You get `cups.trust` and `lns.trust`.
7. **Gateway permissions**: choose the role **IoTWirelessGatewayCertManagerRole**, or **Create role** if the account doesn't have it yet. It lets CUPS hand the gateway its LNS credentials.
8. **Submit**.

### The same with the AWS CLI

This board was registered with the AWS CLI instead of the console (signed in with `aws login`). The certificate and key go straight into files, so they are never shown on screen. The `--query` on the second command matters: without it the CLI prints the private key.

```sh
aws iotwireless create-wireless-gateway --lorawan GatewayEui=0016c001f1135844,RfRegion=US915 --name aesd-pi5 --query Id --output text
aws iot create-keys-and-certificate --set-as-active --certificate-pem-outfile cups.crt --private-key-outfile cups.key --query certificateId --output text
aws iotwireless associate-wireless-gateway-with-certificate --id <gateway Id> --iot-certificate-id <certificateId>
aws iotwireless get-service-endpoint --service-type CUPS      # ServiceEndpoint -> cups.uri, ServerTrust -> cups.trust
aws iam get-role --role-name IoTWirelessGatewayCertManagerRole   # must exist; the docs say how to create it
aws iotwireless get-wireless-gateway-statistics --wireless-gateway-id <gateway Id>   # ConnectionStatus
```

## 3. Put the four files on the boot partition

Copy these to the top level of the card's FAT partition (`BOOT`), with exactly these names:

| Downloaded from AWS | Name on the boot partition |
|---|---|
| `<id>.cert.pem` | `cups.crt` |
| `<id>.private.key` | `cups.key` |
| `cups.trust` | `cups.trust` (unchanged) |
| the CUPS endpoint you copied | `cups.uri`: a text file with that one line, `https://...:443` |

`lns.trust` is not needed: Station asks CUPS for the LNS address and its trust certificate, and stores them as `tc.uri` and `tc.trust` (with `tc.crt` and `tc.key`) in `/etc/station`.

Windows hides known extensions, so check that `cups.uri` isn't really `cups.uri.txt` (Explorer → **View** → **Show** → **File name extensions**). A byte order mark or CRLF line ending in `cups.uri` is fine: `S35provision` strips both.

At the next boot `S35provision` moves the four files into `/etc/station` with mode 0600 and deletes them from the boot partition, and `S60station` starts Basics Station. Then delete the downloaded copies from the PC, or keep them somewhere safe outside any repo.

## 4. Check the connection

On the Pi:

```
# /etc/init.d/S60station status
# grep -E 'CUPS|INFOS|Infos|Concentrator started|ERRO' /var/log/station.log
```

In the console, **Gateways** → the gateway → **LoRaWAN specific details** shows **Connection status: Connected** and a **Last uplink received** time.

## 5. Add a device and see its uplinks

1. **LPWAN devices** → **Destinations** → **Add destination**. **Destination name**: for example `aesd_uplinks`. Choose **Publish to AWS IoT message broker** and enter a topic, for example `aesd/lorawan/uplink`. Under permissions, **Create a new service role**. **Add destination**.
2. **LPWAN devices** → **Profiles** → **Service profiles** → **Add service profile**. Give it a name and turn on **AddGWMetaData**, so each uplink lists the gateways that received it.
3. **LPWAN devices** → **Devices** → **Add wireless device**. **Wireless device specification**: `OTAA v1.0.x`. Enter the node's **DevEUI**, **AppKey** and **AppEUI** (JoinEUI). **Device profile**: `US915-A-OTAA`. **Service profile**: the one from step 2. **Destination**: the one from step 1. **Add device**.
4. **IoT Core** → **MQTT test client** → **Subscribe to a topic** → `aesd/lorawan/uplink` → **Subscribe**.
5. Power the node. After its join, each uplink appears as a JSON message. `WirelessMetadata.LoRaWAN.Gateways[].GatewayEui` is this gateway's EUI, with the `Rssi` and `Snr` it measured.

The AppKey is a secret too: it stays in the node firmware and in AWS, never in this repo or in a screenshot.
