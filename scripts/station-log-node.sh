#!/usr/bin/env bash
# station-log-node.sh: print the Basics Station log lines of one LoRaWAN node,
# with every other line left out. Read-only: it only runs `cat` on the gateway.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #11): https://claude.ai/code/cshk_01CSAPnvLCUHW6djnp5K19mA6Jjr4s6zEaqsQpq9xFyAZz
#
# Usage:
#   station-log-node.sh [-a DEVADDR] [-i SSH_KEY] USER@GATEWAY DEVEUI_SUFFIX
#   station-log-node.sh [-a DEVADDR] -f LOCAL_LOG DEVEUI_SUFFIX
#
#   DEVEUI_SUFFIX  last 4 hex digits of the node's DevEUI (more are allowed).
#   -a DEVADDR     the node's DevAddr (8 hex digits) after its last join; the
#                  AWS uplink metadata and the jreq/updf lines show it. Without
#                  it only join requests are printed, because Station's data
#                  uplink lines name the DevAddr, not the DevEUI.
#   -i SSH_KEY     private key file for ssh (default: ssh's own choice).
#   -f LOCAL_LOG   read a copy of station.log instead of the gateway.
#
# What is printed, from /var/log/station.log.1 and /var/log/station.log:
#   - jreq lines whose DevEUI ends in DEVEUI_SUFFIX,
#   - updf lines whose DevAddr is DEVADDR,
#   - the first dntxed line within 6.5 s after a jreq (join accept, RX1/RX2)
#     or within 2.5 s after an updf (data downlink, RX1/RX2).
#   Station's dntxed line names no device, so a downlink of another node in
#   the same window would be printed too; with one node in range there is none.
# Masked in what is printed: DevEUI and JoinEUI down to their last 4 hex
# digits, the frame= bytes of downlinks and the MIC values. Station at
# S2E:VERBOSE (station.conf) prints no uplink payload bytes.
#
# Exit status: 0 lines printed, 1 nothing matched, 2 wrong usage, 3 ssh failed.

set -u -o pipefail
prog=${0##*/}
usage() { echo "usage: $prog [-a DEVADDR] [-i SSH_KEY] (USER@GATEWAY | -f LOCAL_LOG) DEVEUI_SUFFIX" >&2; exit 2; }

devaddr= key= file=
while getopts ':a:i:f:' o; do
    case $o in a) devaddr=$OPTARG ;; i) key=$OPTARG ;; f) file=$OPTARG ;; *) usage ;; esac
done
shift $((OPTIND - 1))
if [ -n "$file" ]; then [ $# -eq 1 ] || usage; suffix=$1
else [ $# -eq 2 ] || usage; host=$1; suffix=$2; fi

[[ $suffix =~ ^[0-9A-Fa-f]{4,16}$ ]] || { echo "$prog: DEVEUI_SUFFIX must be 4 to 16 hex digits" >&2; exit 2; }
[ -z "$devaddr" ] || [[ $devaddr =~ ^[0-9A-Fa-f]{8}$ ]] || { echo "$prog: DEVADDR must be 8 hex digits" >&2; exit 2; }

if [ -n "$file" ]; then
    log=$(cat -- "$file") || exit 2
else
    ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)
    [ -n "$key" ] && ssh_opts+=(-i "$key")
    log=$(ssh "${ssh_opts[@]}" "$host" 'cat /var/log/station.log.1 /var/log/station.log 2>/dev/null') \
        || { echo "$prog: could not read the Station log over ssh" >&2; exit 3; }
fi

printf '%s\n' "$log" | tr -d '\r' | awk -v sfx="$(tr 'A-F' 'a-f' <<<"$suffix")" -v da="$(tr 'a-f' 'A-F' <<<"$devaddr")" '
function secs(t,  p) { split(t, p, ":"); return p[1]*3600 + p[2]*60 + p[3] }
function mask(s,  v, h) {
    # DevEUI=a0f2:62ff:fe50:7c7c -> DevEUI=...7c7c, the same for JoinEUI
    while (match(s, /(DevEUI|JoinEUI)=[0-9A-Fa-f:]+/)) {
        v = substr(s, RSTART, RLENGTH); h = v; sub(/^[A-Za-z]+=/, "", h); gsub(":", "", h)
        sub(/=.*/, "", v)
        s = substr(s, 1, RSTART - 1) v "=_" substr(h, length(h) - 3) substr(s, RSTART + RLENGTH)
    }
    gsub(/=_/, "=...", s)
    gsub(/frame=[0-9A-Fa-f.]+/, "frame=[removed]", s)
    gsub(/(MIC|mic)=-?[0-9]+/, "mic=[removed]", s)
    return s
}
{
    t = ($2 ~ /^[0-9]+:[0-9]+:[0-9.]+$/) ? secs($2) : -1
    if (t >= 0 && t < last) t += 86400            # past midnight
    if ($0 ~ / - jreq / && match($0, /DevEUI=[0-9A-Fa-f:]+/)) {
        e = substr($0, RSTART + 7, RLENGTH - 7); gsub(":", "", e); e = tolower(e)
        if (substr(e, length(e) - length(sfx) + 1) == sfx) { print mask($0); until = t + 6.5; n++; next }
    }
    if (da != "" && $0 ~ / - updf / && match($0, /DevAddr=[0-9A-Fa-f]+/)) {
        if (toupper(substr($0, RSTART + 8, RLENGTH - 8)) == da) { print mask($0); until = t + 2.5; n++; next }
    }
    if ($0 ~ /dntxed/ && t >= 0 && t <= until) { print mask($0); until = 0; n++ }
    if (t >= 0) last = t
}
END { exit (n > 0) ? 0 : 1 }'
