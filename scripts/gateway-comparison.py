#!/usr/bin/env python3
"""Compare what two (or more) LoRaWAN gateways received, from AWS uplink metadata.

AWS IoT Core for LoRaWAN writes one "Uplink_Data" log event per uplink to the
CloudWatch log group /aws/iotwireless when the device log level is INFO. The
event carries the uplink metadata: DevEui, FCnt, Timestamp and the list of
gateways that received the frame, each with its RSSI and SNR. This script reads
those events for a time window and prints, for each gateway: uplinks received,
percent of node frames heard, mean RSSI and mean SNR.

    # from AWS (read-only: logs:FilterLogEvents), last 24 hours
    python scripts/gateway-comparison.py --hours 24 --gateway 5844=Pi --gateway 7de2=Reference

    # a fixed window, keeping a reduced copy (the log group only keeps 3 days)
    python scripts/gateway-comparison.py --start 2026-11-29T18:00Z --end 2026-11-30T18:00Z \
        --save capture.jsonl --markdown

    # from a file (a saved capture, or the made-up sample of the host test)
    python scripts/gateway-comparison.py --file scripts/test/gateway-comparison-sample.jsonl

Privacy: only the last four hex digits of a DevEUI or gateway EUI are ever
printed or saved, and payloads are never read (the log events do not hold them).

This file was partially generated using Claude Code using the chat session at:
Link to chat session (issue #8): ISSUE8_SESSION_LINK
"""

import argparse
import datetime as dt
import json
import subprocess
import sys

LOG_GROUP = "/aws/iotwireless"
MARKER = "Uplink metadata:"
# A frame-counter step larger than this (or a step backwards) is taken as a
# counter reset (the node rejoined or restarted), not as that many lost frames.
MAX_GAP = 1000


def parse_time(text):
    """ISO 8601 time to an aware UTC datetime. AWS writes nanoseconds; cut to microseconds."""
    t = text.strip().replace("Z", "+00:00")
    if "." in t:
        head, rest = t.split(".", 1)
        cut = len(rest)
        for i, ch in enumerate(rest):
            if not ch.isdigit():
                cut = i
                break
        t = head + "." + rest[:cut][:6].ljust(6, "0") + rest[cut:]
    d = dt.datetime.fromisoformat(t)
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.astimezone(dt.timezone.utc)


def reduce_metadata(meta, fallback_time=None):
    """AWS LoRaWAN uplink metadata -> the reduced record this script works on."""
    if "DevEui" not in meta or "FCnt" not in meta:
        return None
    when = meta.get("Timestamp")
    when = parse_time(when) if when else fallback_time
    if when is None:
        return None
    gws = []
    for g in meta.get("Gateways") or []:
        if "GatewayEui" in g:
            gws.append({"gw": str(g["GatewayEui"]).lower()[-4:], "rssi": g.get("Rssi"), "snr": g.get("Snr")})
    return {"node": str(meta["DevEui"]).lower()[-4:], "fcnt": int(meta["FCnt"]),
            "time": when.isoformat().replace("+00:00", "Z"), "gateways": gws}


def parse_record(obj):
    """One JSON object in any accepted form -> reduced record, or None if it is not an uplink.

    Accepted forms:
      1. a reduced record written by --save: {"node", "fcnt", "time", "gateways": [{"gw", "rssi", "snr"}]}
      2. a CloudWatch event: {"timestamp": ms, "message": "<json text of form 3>"}
      3. the iotwireless log entry: {"event": "Uplink_Data", "message": "... Uplink metadata: {...}"}
      4. the message a destination publishes: {"WirelessMetadata": {"LoRaWAN": {...}}}
    """
    if not isinstance(obj, dict):
        return None
    if "node" in obj and "fcnt" in obj and "gateways" in obj:
        return {"node": str(obj["node"]).lower()[-4:], "fcnt": int(obj["fcnt"]), "time": obj["time"],
                "gateways": [{"gw": str(g["gw"]).lower()[-4:], "rssi": g.get("rssi"), "snr": g.get("snr")}
                             for g in obj["gateways"]]}
    fallback = None
    if isinstance(obj.get("timestamp"), (int, float)):
        fallback = dt.datetime.fromtimestamp(obj["timestamp"] / 1000, dt.timezone.utc)
    if "WirelessMetadata" in obj:
        return reduce_metadata(obj["WirelessMetadata"].get("LoRaWAN", {}), fallback)
    msg = obj.get("message")
    if not isinstance(msg, str):
        return None
    if msg.lstrip().startswith("{"):
        try:
            inner = json.loads(msg)
        except ValueError:
            return None
        if isinstance(inner, dict) and isinstance(inner.get("timestamp"), str) and fallback is None:
            fallback = parse_time(inner["timestamp"])
        msg = inner.get("message") if isinstance(inner, dict) else None
        if not isinstance(msg, str):
            return None
    at = msg.find(MARKER)
    if at < 0:
        return None
    try:
        meta = json.loads(msg[at + len(MARKER):])
    except ValueError:
        return None
    return reduce_metadata(meta, fallback)


def read_file(path):
    records = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            rec = parse_record(json.loads(line))
            if rec:
                records.append(rec)
    return records


def read_aws(start, end, log_group, profile=None):
    """Read the Uplink_Data events of the window with the AWS CLI (logs:FilterLogEvents only)."""
    records, token = [], None
    while True:
        cmd = ["aws", "logs", "filter-log-events", "--log-group-name", log_group,
               "--start-time", str(int(start.timestamp() * 1000)),
               "--end-time", str(int(end.timestamp() * 1000)),
               "--filter-pattern", '{ $.event = "Uplink_Data" }', "--output", "json"]
        if profile:
            cmd += ["--profile", profile]
        if token:
            cmd += ["--next-token", token]
        run = subprocess.run(cmd, capture_output=True, text=True, shell=(sys.platform == "win32"))
        if run.returncode:
            # The CLI's error text can name the account, so only its first words are shown.
            sys.exit("aws logs filter-log-events failed: " + run.stderr.strip()[:60])
        page = json.loads(run.stdout)
        for ev in page.get("events", []):
            rec = parse_record(ev)
            if rec:
                records.append(rec)
        token = page.get("nextToken")
        if not token:
            return records


def merge_frames(records, start=None, end=None, nodes=None):
    """One entry per (node, FCnt run): repeats of a frame are merged, gateways united.

    Returns {node: [frame, ...]} in time order; a frame is {"fcnt", "time", "gateways": {gw: (rssi, snr)}}.
    A repeat is the same FCnt again from the same node right after the first copy (a confirmed
    uplink that was not acknowledged is sent again with the same counter).
    """
    per_node = {}
    for r in sorted(records, key=lambda r: parse_time(r["time"])):
        when = parse_time(r["time"])
        if (start and when < start) or (end and when > end):
            continue
        if nodes and r["node"] not in nodes:
            continue
        frames = per_node.setdefault(r["node"], [])
        if frames and frames[-1]["fcnt"] == r["fcnt"]:
            frame = frames[-1]
        else:
            frame = {"fcnt": r["fcnt"], "time": when, "gateways": {}}
            frames.append(frame)
        for g in r["gateways"]:
            frame["gateways"].setdefault(g["gw"], (g["rssi"], g["snr"]))
    return per_node


def frames_sent(frames, max_gap=MAX_GAP):
    """Frames a node sent between its first and last frame in the window, from FCnt gaps.

    Each step up of 1..max_gap adds that many frames (the gap is frames no gateway heard).
    A step backwards, or one larger than max_gap, is a counter reset: counting starts again
    with that frame, and frames lost across the reset cannot be counted.
    Returns (sent, resets).
    """
    if not frames:
        return 0, 0
    sent, resets = 1, 0
    for prev, cur in zip(frames, frames[1:]):
        step = cur["fcnt"] - prev["fcnt"]
        if 0 < step <= max_gap:
            sent += step
        else:
            sent += 1
            resets += 1
    return sent, resets


def compare(records, start=None, end=None, nodes=None, max_gap=MAX_GAP):
    per_node = merge_frames(records, start, end, nodes)
    result = {"nodes": {}, "gateways": {}, "sent": 0, "resets": 0, "first": None, "last": None}
    for node, frames in sorted(per_node.items()):
        sent, resets = frames_sent(frames, max_gap)
        heard = {}
        for f in frames:
            for gw, (rssi, snr) in f["gateways"].items():
                g = result["gateways"].setdefault(gw, {"uplinks": 0, "rssi": [], "snr": [], "nodes": set()})
                g["uplinks"] += 1
                g["nodes"].add(node)
                if rssi is not None:
                    g["rssi"].append(float(rssi))
                if snr is not None:
                    g["snr"].append(float(snr))
                heard[gw] = heard.get(gw, 0) + 1
        result["nodes"][node] = {"sent": sent, "resets": resets, "logged": len(frames), "heard": heard}
        result["sent"] += sent
        result["resets"] += resets
        for t in (frames[0]["time"], frames[-1]["time"]):
            result["first"] = t if result["first"] is None or t < result["first"] else result["first"]
            result["last"] = t if result["last"] is None or t > result["last"] else result["last"]
    return result


def mean(values):
    return sum(values) / len(values) if values else None


def fmt(value, unit):
    return "n/a" if value is None else "%.1f %s" % (value, unit)


def stamp(t):
    return t.strftime("%Y-%m-%d %H:%M UTC") if t else "n/a"


def render(result, labels, start, end, markdown=False):
    out = []
    gws = sorted(set(result["gateways"]) | set(labels))
    name = lambda gw: "%s (…%s)" % (labels[gw], gw) if gw in labels else "gateway …%s" % gw
    both = [n for n, d in result["nodes"].items() if gws and all(d["heard"].get(g) for g in gws)]
    out.append("Window: %s to %s" % (stamp(start or result["first"]), stamp(end or result["last"])))
    out.append("First and last uplink in it: %s, %s" % (stamp(result["first"]), stamp(result["last"])))
    out.append("Nodes: %d (heard by every gateway: %d). Frames sent by them, from frame counters: %d. "
               "Counter resets: %d." % (len(result["nodes"]), len(both), result["sent"], result["resets"]))
    out.append("")
    rows = [("Gateway", "Uplinks received", "Node frames heard", "Mean RSSI", "Mean SNR", "Nodes heard")]
    for gw in gws:
        g = result["gateways"].get(gw, {"uplinks": 0, "rssi": [], "snr": [], "nodes": set()})
        pct = "n/a" if not result["sent"] else "%.1f %%" % (100.0 * g["uplinks"] / result["sent"])
        rows.append((name(gw), str(g["uplinks"]), pct, fmt(mean(g["rssi"]), "dBm"), fmt(mean(g["snr"]), "dB"),
                     str(len(g["nodes"]))))
    out += table(rows, markdown)
    out.append("")
    rows = [("Node", "Frames sent", "Resets") + tuple(name(g) for g in gws)]
    for i, (node, d) in enumerate(result["nodes"].items()):
        label = "node %s (…%s)" % (chr(ord("A") + i) if i < 26 else str(i), node)
        cells = ["%d (%.1f %%)" % (d["heard"].get(g, 0), 100.0 * d["heard"].get(g, 0) / d["sent"]) for g in gws]
        rows.append((label, str(d["sent"]), str(d["resets"])) + tuple(cells))
    out += table(rows, markdown)
    return "\n".join(out)


def table(rows, markdown):
    if markdown:
        lines = ["| " + " | ".join(rows[0]) + " |", "|" + "---|" * len(rows[0])]
        return lines + ["| " + " | ".join(r) + " |" for r in rows[1:]]
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    return ["  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip() for r in rows]


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--file", action="append", help="read events from this JSON-lines file instead of AWS (repeatable)")
    p.add_argument("--log-group", default=LOG_GROUP)
    p.add_argument("--profile", help="AWS CLI profile (default: the CLI's default)")
    p.add_argument("--start", help="window start, ISO 8601 UTC, e.g. 2026-11-29T18:00Z")
    p.add_argument("--end", help="window end (default: now, or the last event of a file)")
    p.add_argument("--hours", type=float, help="window length in hours, ending at --end or now")
    p.add_argument("--gateway", action="append", default=[], metavar="LAST4=LABEL",
                   help="name a gateway by the last four hex digits of its EUI; it gets a row even if it heard nothing")
    p.add_argument("--node", action="append", default=[], metavar="LAST4",
                   help="only these nodes (last four hex digits of the DevEUI; repeatable)")
    p.add_argument("--max-gap", type=int, default=MAX_GAP, help="largest counter step counted as lost frames (default %d)" % MAX_GAP)
    p.add_argument("--save", help="write the reduced records of the window to this JSON-lines file")
    p.add_argument("--markdown", action="store_true", help="print the tables as Markdown (for the wiki)")
    a = p.parse_args(argv)

    end = parse_time(a.end) if a.end else None
    start = parse_time(a.start) if a.start else None
    if a.file:
        records = [r for path in a.file for r in read_file(path)]
        if a.hours and not start:
            end = end or max(parse_time(r["time"]) for r in records)
            start = end - dt.timedelta(hours=a.hours)
    else:
        end = end or dt.datetime.now(dt.timezone.utc)
        if not start:
            if not a.hours:
                p.error("give --start or --hours (or --file)")
            start = end - dt.timedelta(hours=a.hours)
        records = read_aws(start, end, a.log_group, a.profile)

    labels = {}
    for item in a.gateway:
        key, _, label = item.partition("=")
        labels[key.lower()[-4:]] = label or key
    nodes = {n.lower()[-4:] for n in a.node} or None

    if a.save:
        kept = [r for r in records
                if (not start or parse_time(r["time"]) >= start) and (not end or parse_time(r["time"]) <= end)
                and (not nodes or r["node"] in nodes)]
        with open(a.save, "w", encoding="utf-8") as f:
            for r in sorted(kept, key=lambda r: r["time"]):
                f.write(json.dumps(r) + "\n")

    result = compare(records, start, end, nodes, a.max_gap)
    text = render(result, labels, start, end, a.markdown)
    sys.stdout.buffer.write((text + "\n").encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
