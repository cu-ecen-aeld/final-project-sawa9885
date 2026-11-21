#!/usr/bin/env bash
# register-node.sh: register one LoRaWAN node (OTAA) in AWS IoT Core for LoRaWAN
# with an existing device profile, service profile and destination.
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #11): SESSION_LINK_PLACEHOLDER_ISSUE_11
#
# Usage:
#   register-node.sh [-c] [-n NAME] [-p DEVICE_PROFILE] [-s SERVICE_PROFILE]
#                    [-d DESTINATION] <DevEUI> <JoinEUI>
#
#   DevEUI, JoinEUI   16 hex digits each; ':' and '-' separators are allowed.
#   -p, -s            Name or id (UUID) of an existing device / service profile.
#                     Default: $REGISTER_NODE_DEVICE_PROFILE,
#                              $REGISTER_NODE_SERVICE_PROFILE.
#   -d                Name of an existing destination.
#                     Default: $REGISTER_NODE_DESTINATION.
#   -n                Name of the new device. Default: node-<last 4 of DevEUI>.
#   -c                Check only: do every lookup, then stop before asking for
#                     a key. Changes nothing.
#
# Nothing about the AWS account is stored in this file: the profiles and the
# destination come from the options or the environment.
#
# The AppKey is asked for at a hidden prompt on the terminal. It is not taken
# from an argument, the environment or a pipe, so it cannot end up in the
# shell history or in `ps`. It reaches the AWS CLI in a temporary file that
# only the user can read (--cli-input-json file://...), and the file is
# removed when the script exits, whatever the reason. The key is never
# printed: tracing is switched off, and it is cut out of any AWS error text.
# If the device profile is LoRaWAN 1.1, the NwkKey is asked for the same way.
#
# If a device with this DevEUI is already registered, the script says so and
# exits 0 without changing it, and without asking for a key.
#
# Exit status:
#   0  the node was registered, or it already was (nothing changed),
#      or -c found everything in place
#   1  an AWS call failed (credentials, network, refused request)
#   2  wrong usage, or a DevEUI, JoinEUI or key that is not valid hex
#   3  a key is needed but standard input is not a terminal
#   4  the device profile, service profile or destination was not found
#
# AWS error messages are passed through to stderr. They can name the account
# (for example in an access-denied message): read them before pasting them
# anywhere public.

set +x                  # never trace: a trace would show the key
set -u -o pipefail

prog=${0##*/}
die()  { local rc=$1; shift; printf '%s: %s\n' "$prog" "$*" >&2; exit "$rc"; }
usage() {
    printf 'usage: %s [-c] [-n NAME] [-p DEVICE_PROFILE] [-s SERVICE_PROFILE] [-d DESTINATION] <DevEUI> <JoinEUI>\n' "$prog" >&2
    exit 2
}

device_profile=${REGISTER_NODE_DEVICE_PROFILE:-}
service_profile=${REGISTER_NODE_SERVICE_PROFILE:-}
destination=${REGISTER_NODE_DESTINATION:-}
name=
check_only=0

while getopts ':cn:p:s:d:' opt; do
    case $opt in
        c) check_only=1 ;;
        n) name=$OPTARG ;;
        p) device_profile=$OPTARG ;;
        s) service_profile=$OPTARG ;;
        d) destination=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] || usage

# Prints the EUI as 16 lower-case hex digits, or fails.
norm_eui() {
    local v=${1//[:-]/}
    [[ $v =~ ^[0-9A-Fa-f]{16}$ ]] || return 1
    printf '%s' "$v" | tr 'A-F' 'a-f'
}

deveui=$(norm_eui "$1")  || die 2 "DevEUI must be 16 hex digits"
joineui=$(norm_eui "$2") || die 2 "JoinEUI must be 16 hex digits"
short=${deveui:12}
[ -n "$name" ] || name="node-$short"

name_re='^[A-Za-z0-9_. -]+$'
[ -n "$device_profile" ]  || die 2 "no device profile: use -p or REGISTER_NODE_DEVICE_PROFILE"
[ -n "$service_profile" ] || die 2 "no service profile: use -s or REGISTER_NODE_SERVICE_PROFILE"
[ -n "$destination" ]     || die 2 "no destination: use -d or REGISTER_NODE_DESTINATION"
for v in "$name" "$device_profile" "$service_profile" "$destination"; do
    [[ $v =~ $name_re ]] || die 2 "names may only contain letters, digits, space and _ . -"
done

command -v aws >/dev/null 2>&1 || die 1 "the AWS CLI (aws) is not on the PATH"

umask 077
tmpdir=$(mktemp -d) || die 1 "cannot create a temporary directory"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
trap 'stty echo 2>/dev/null; exit 1' HUP INT TERM
errf=$tmpdir/err

# aws_text ARGS...: run a read-only call, print its text output without CRs.
aws_text() { aws iotwireless "$@" --output text 2>"$errf" | tr -d '\r'; }
show_err() { sed 's/^/  aws: /' "$errf" >&2; }

# --- 1. Already registered? Then nothing to do. -----------------------------
existing=$(aws_text get-wireless-device --identifier-type DevEui --identifier "$deveui" \
           --query '[Name,DestinationName]')
rc=$?
if [ $rc -eq 0 ]; then
    ex_name=$(printf '%s' "$existing" | cut -f1)
    ex_dest=$(printf '%s' "$existing" | cut -f2)
    printf 'A device with DevEUI ...%s is already registered as "%s". Nothing changed.\n' "$short" "$ex_name"
    if [ "$ex_dest" != "$destination" ]; then
        printf 'WARNING: its destination is not "%s". This script does not change existing devices.\n' "$destination"
    fi
    exit 0
elif ! grep -q 'ResourceNotFoundException' "$errf"; then
    show_err
    die 1 "could not look the device up in AWS"
fi

# --- 2. The profiles and the destination must exist. ------------------------
uuid_re='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'

# resolve_profile KIND VALUE: KIND is "device" or "service". Prints the id.
resolve_profile() {
    local kind=$1 value=$2 list ids n
    if [[ $value =~ $uuid_re ]]; then
        aws_text "get-$kind-profile" --id "$value" --query Id || return 4
        return 0
    fi
    [ "$kind" = device ] && list=DeviceProfileList || list=ServiceProfileList
    ids=$(aws_text "list-$kind-profiles" --query "${list}[?Name=='$value'].Id") || return 1
    n=$(printf '%s' "$ids" | wc -w)
    [ "$n" -eq 1 ] || return 4
    printf '%s' "$ids" | tr -d '[:space:]'
}

lookup_failed() {     # KIND-LABEL VALUE RC
    [ -s "$errf" ] && show_err
    [ "$3" -eq 4 ] && die 4 "$1 \"$2\" was not found (or the name is used more than once)"
    die 1 "could not look up $1 \"$2\""
}

dp_id=$(resolve_profile device "$device_profile")   || lookup_failed "device profile" "$device_profile" $?
sp_id=$(resolve_profile service "$service_profile") || lookup_failed "service profile" "$service_profile" $?
dp_id=$(printf '%s' "$dp_id" | tr -d '[:space:]')
sp_id=$(printf '%s' "$sp_id" | tr -d '[:space:]')

if ! aws_text get-destination --name "$destination" --query Name >/dev/null; then
    if grep -q 'ResourceNotFoundException' "$errf"; then
        die 4 "destination \"$destination\" was not found"
    fi
    show_err
    die 1 "could not look up destination \"$destination\""
fi

mac=$(aws_text get-device-profile --id "$dp_id" --query LoRaWAN.MacVersion | tr -d '[:space:]')
[ -n "$mac" ] || { show_err; die 1 "could not read the LoRaWAN version of the device profile"; }

printf 'Node ...%s is not registered yet. Device profile, service profile and destination exist (LoRaWAN %s).\n' "$short" "$mac"
if [ $check_only -eq 1 ]; then
    printf 'Check only (-c): nothing changed.\n'
    exit 0
fi

# --- 3. The key(s): hidden prompt, terminal only. ---------------------------
[ -t 0 ] || die 3 "a key is needed and standard input is not a terminal; run this from a terminal"

# read_key LABEL VAR: reads 32 hex digits without echo into VAR.
read_key() {
    local label=$1 k=
    IFS= read -r -s -p "$label for ...$short (32 hex digits, input hidden): " k || k=
    printf '\n' >&2
    k=${k//[: -]/}
    [[ $k =~ ^[0-9A-Fa-f]{32}$ ]] || die 2 "$label must be 32 hex digits (nothing was sent to AWS)"
    printf -v "$2" '%s' "$k"
}

appkey=
nwkkey=
read_key AppKey appkey
case $mac in
    1.1*) read_key NwkKey nwkkey
          otaa=$(printf '"OtaaV1_1": {"AppKey": "%s", "NwkKey": "%s", "JoinEui": "%s"}' "$appkey" "$nwkkey" "$joineui") ;;
    *)    otaa=$(printf '"OtaaV1_0_x": {"AppKey": "%s", "AppEui": "%s"}' "$appkey" "$joineui") ;;
esac

# --- 4. Register. The key travels in a file only this user can read. --------
req=$tmpdir/request.json
printf '{"Type": "LoRaWAN", "Name": "%s", "DestinationName": "%s", "LoRaWAN": {"DevEui": "%s", "DeviceProfileId": "%s", "ServiceProfileId": "%s", %s}}\n' \
    "$name" "$destination" "$deveui" "$dp_id" "$sp_id" "$otaa" >"$req"
unset otaa

# aws.exe on Windows (Git Bash) needs a Windows path after file://
if command -v cygpath >/dev/null 2>&1; then req_url="file://$(cygpath -m "$req")"; else req_url="file://$req"; fi

aws iotwireless create-wireless-device --cli-input-json "$req_url" --query Id --output text >/dev/null 2>"$errf"
rc=$?
rm -f "$req"

if [ $rc -ne 0 ]; then
    # Cut the keys out of whatever AWS answered before showing it.
    err=$(cat "$errf")
    shopt -s nocasematch
    err=${err//"$appkey"/[key removed]}
    [ -n "$nwkkey" ] && err=${err//"$nwkkey"/[key removed]}
    shopt -u nocasematch
    printf '%s\n' "$err" | sed 's/^/  aws: /' >&2
    unset appkey nwkkey
    die 1 "AWS refused the registration; nothing was created"
fi
unset appkey nwkkey

printf 'Registered node ...%s as "%s" with destination "%s".\n' "$short" "$name" "$destination"
exit 0
