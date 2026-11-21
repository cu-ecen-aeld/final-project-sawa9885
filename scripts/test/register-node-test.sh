#!/usr/bin/env bash
# Host test for scripts/register-node.sh. Runs it against a fake `aws` on the
# PATH; nothing is sent to AWS. Needs bash and `script` (util-linux) for a
# pseudo-terminal. Run from anywhere:  bash scripts/test/register-node-test.sh
#
# This file was partially generated using Claude Code using the chat session at:
# Link to chat session (issue #11): https://claude.ai/code/cshk_01CSAPnvLCUHW6djnp5K19mA6Jjr4s6zEaqsQpq9xFyAZz

set -u
here=$(cd "$(dirname "$0")" && pwd)
sut=${SUT:-$here/../register-node.sh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/tmp"
export TMPDIR=$work/tmp          # the script's temporary files land here
export FAKE_LOG=$work/argv.log FAKE_STATE=$work/state

# Test keys only: random-looking values that are not used by any device.
APPKEY=5A3C9E1F0B7D24C68E1A3F5B7C9D0E2F
NWKKEY=C1D2E3F405162738495A6B7C8D9EAFB0
DEVEUI=00112233445566AB
JOINEUI=0000000000000001

cat >"$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
# Fake AWS CLI. Logs its argv, answers from $FAKE_STATE.
printf '%s\n' "$*" >>"$FAKE_LOG"
st() { [ -e "$FAKE_STATE/$1" ]; }
notfound() { echo "An error occurred (ResourceNotFoundException) when calling the $1 operation: not found" >&2; exit 254; }
op=$2
case $op in
  get-wireless-device)
    st exists && { printf 'existing-node\tsoil-dest\r\n'; exit 0; }
    st auth_fail && { echo "An error occurred (AccessDeniedException)" >&2; exit 254; }
    notfound GetWirelessDevice ;;
  list-device-profiles)  st no_dp && exit 0; echo "dp-0000-id"; exit 0 ;;
  list-service-profiles) echo "sp-0000-id"; exit 0 ;;
  get-device-profile)
    case "$*" in *MacVersion*) cat "$FAKE_STATE/mac" 2>/dev/null || echo 1.0.3 ;; *) echo "dp-0000-id" ;; esac
    exit 0 ;;
  get-service-profile) echo "sp-0000-id"; exit 0 ;;
  get-destination) st no_dest && notfound GetDestination; echo soil-dest; exit 0 ;;
  create-wireless-device)
    for a in "$@"; do case $a in file://*) f=${a#file://} ;; esac; done
    echo "$f" >"$FAKE_STATE/reqpath"
    stat -c %a "$f" >"$FAKE_STATE/reqmode"
    cp "$f" "$FAKE_STATE/request.json"          # kept by the test, outside $TMPDIR
    if st create_fail; then
      echo "An error occurred (ValidationException): bad input $(cat "$f")" >&2; exit 254
    fi
    echo "wd-0000-id"; exit 0 ;;
  *) echo "fake aws: unexpected $op" >&2; exit 99 ;;
esac
FAKE
chmod +x "$work/bin/aws"
export PATH=$work/bin:$PATH
export REGISTER_NODE_DEVICE_PROFILE=soil-dp REGISTER_NODE_SERVICE_PROFILE=soil-sp REGISTER_NODE_DESTINATION=soil-dest

pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
reset() { rm -rf "$FAKE_STATE" "$FAKE_LOG" "$work/tmp"/*; mkdir -p "$FAKE_STATE"; : >"$FAKE_LOG"; for f in "$@"; do : >"$FAKE_STATE/$f"; done; }

# run_plain ARGS...: stdin not a terminal. Sets rc, out, err.
run_plain() { out=$(bash "$sut" "$@" </dev/null 2>"$work/err"); rc=$?; err=$(cat "$work/err"); }

# run_tty KEYS ARGS...: stdin is a pseudo-terminal; each line of KEYS is typed
# after a pause, once its hidden prompt is up (a line typed before `read -s`
# turns echo off would be echoed by the terminal, as for a person). Sets rc and
# out (stdout and stderr together, as a terminal shows them).
run_tty() {
    local keys=$1 line; shift
    local cmd="bash $(printf '%q ' "$sut" "$@"); echo \"RC=\$?\""
    out=$( { while IFS= read -r line; do sleep 1.5; printf '%s\n' "$line"; done < <(printf '%b' "$keys"); sleep 1.5; } \
           | script -qfec "$cmd" /dev/null 2>&1 | tr -d '\r')
    rc=$(printf '%s\n' "$out" | sed -n 's/^RC=//p' | tail -n1)
}

no_key_anywhere() {   # TEST-NAME: the keys appear in no output, argv log or trace
    local where=
    for k in "$APPKEY" "$NWKKEY"; do
        grep -qi "$k" <<<"$out" && where+=" output"
        grep -qi "$k" <<<"${err:-}" && where+=" stderr"
        grep -qi "$k" "$FAKE_LOG" && where+=" argv"
    done
    [ -z "$where" ] && ok "$1: no key in output or aws argv" || bad "$1: key seen in$where"
}
tmp_empty() { [ -z "$(ls -A "$work/tmp")" ] && ok "$1: temporary files removed" || bad "$1: left behind: $(ls -A "$work/tmp")"; }

# ---- argument validation -------------------------------------------------
reset
run_plain;                                  [ "$rc" = 2 ] && ok "no arguments -> 2" || bad "no arguments -> $rc"
run_plain 0011 "$JOINEUI";                  [ "$rc" = 2 ] && ok "short DevEUI -> 2" || bad "short DevEUI -> $rc"
run_plain 00112233445566ZZ "$JOINEUI";      [ "$rc" = 2 ] && ok "non-hex DevEUI -> 2" || bad "non-hex DevEUI -> $rc"
run_plain "$DEVEUI" 00000000000000001;      [ "$rc" = 2 ] && ok "17-digit JoinEUI -> 2" || bad "17-digit JoinEUI -> $rc"
run_plain -x "$DEVEUI" "$JOINEUI";          [ "$rc" = 2 ] && ok "unknown option -> 2" || bad "unknown option -> $rc"
run_plain -n 'a;b' "$DEVEUI" "$JOINEUI";    [ "$rc" = 2 ] && ok "bad name -> 2" || bad "bad name -> $rc"
( unset REGISTER_NODE_DESTINATION; out=$(bash "$sut" "$DEVEUI" "$JOINEUI" 2>&1 </dev/null); echo "rc=$? $out" ) | grep -q '^rc=2 .*destination' \
    && ok "missing destination -> 2" || bad "missing destination did not give 2"
[ ! -s "$FAKE_LOG" ] && ok "validation errors never call aws" || bad "aws was called during validation"
run_plain 00:11:22:33:44:55:66:ab "$JOINEUI"
[ "$rc" = 3 ] && grep -q 'DevEui --identifier 00112233445566ab' "$FAKE_LOG" \
    && ok "DevEUI with ':' accepted and normalised" || bad "separator DevEUI: rc=$rc"

# ---- idempotent path ----------------------------------------------------
reset exists
run_plain "$DEVEUI" "$JOINEUI"
[ "$rc" = 0 ] && grep -q 'already registered' <<<"$out" && ok "existing node -> 0, says so" || bad "existing node: rc=$rc out=$out"
[ "$(grep -c . "$FAKE_LOG")" = 1 ] && ! grep -q create "$FAKE_LOG" && ok "existing node: only one read-only call" || bad "existing node made calls: $(cat "$FAKE_LOG")"
grep -q '\.\.\.66ab' <<<"$out" && ! grep -qi "$DEVEUI" <<<"$out" && ok "only the last 4 of the DevEUI printed" || bad "DevEUI printed in full"
tmp_empty "existing node"
run_plain -d other-dest "$DEVEUI" "$JOINEUI"
[ "$rc" = 0 ] && grep -q WARNING <<<"$out" && ok "existing node, other destination -> warning, 0" || bad "destination warning missing"

# ---- lookups --------------------------------------------------------------
reset auth_fail;  run_plain "$DEVEUI" "$JOINEUI"; [ "$rc" = 1 ] && ok "AWS error on lookup -> 1" || bad "AWS error on lookup -> $rc"
reset no_dp;      run_plain "$DEVEUI" "$JOINEUI"; [ "$rc" = 4 ] && ok "unknown device profile -> 4" || bad "unknown device profile -> $rc"
reset no_dest;    run_plain "$DEVEUI" "$JOINEUI"; [ "$rc" = 4 ] && ok "unknown destination -> 4" || bad "unknown destination -> $rc"
reset;            run_plain -c "$DEVEUI" "$JOINEUI"
[ "$rc" = 0 ] && ! grep -q create "$FAKE_LOG" && ok "-c checks and changes nothing" || bad "-c: rc=$rc"
reset;            run_plain "$DEVEUI" "$JOINEUI"
[ "$rc" = 3 ] && ! grep -q create "$FAKE_LOG" && ok "stdin not a terminal -> 3, nothing created" || bad "non-tty: rc=$rc"
tmp_empty "non-tty"

# ---- registration, LoRaWAN 1.0.x ------------------------------------------
if ! command -v script >/dev/null; then
    bad "registration tests skipped: no 'script' command"
else
    reset; echo 1.0.3 >"$FAKE_STATE/mac"; err=
    run_tty "$APPKEY\n" "$DEVEUI" "$JOINEUI"
    [ "$rc" = 0 ] && grep -q 'Registered node \.\.\.66ab' <<<"$out" && ok "1.0.x register -> 0" || bad "1.0.x register: rc=$rc" "$out"
    grep -q '"OtaaV1_0_x": {"AppKey": "'"$APPKEY"'", "AppEui": "'"$JOINEUI"'"}' "$FAKE_STATE/request.json" \
        && grep -q '"DestinationName": "soil-dest"' "$FAKE_STATE/request.json" \
        && ok "1.0.x request carries the key, JoinEUI and destination" || bad "1.0.x request wrong"
    [ "$(cat "$FAKE_STATE/reqmode")" = 600 ] && ok "request file mode 600" || bad "request file mode $(cat "$FAKE_STATE/reqmode")"
    [ ! -e "$(cat "$FAKE_STATE/reqpath")" ] && ok "request file gone afterwards" || bad "request file still there"
    no_key_anywhere "1.0.x"; tmp_empty "1.0.x"

    # ---- LoRaWAN 1.1: AppKey and NwkKey ----------------------------------
    reset; echo 1.1 >"$FAKE_STATE/mac"
    run_tty "$APPKEY\n$NWKKEY\n" "$DEVEUI" "$JOINEUI"
    grep -q '"OtaaV1_1": {"AppKey": "'"$APPKEY"'", "NwkKey": "'"$NWKKEY"'", "JoinEui": "'"$JOINEUI"'"}' "$FAKE_STATE/request.json" \
        && [ "$rc" = 0 ] && ok "1.1 register with AppKey and NwkKey -> 0" || bad "1.1 register: rc=$rc" "$out"
    no_key_anywhere "1.1"; tmp_empty "1.1"

    # ---- Enter sent as CR LF (Windows console): no empty NwkKey ----------
    reset; echo 1.1 >"$FAKE_STATE/mac"
    run_tty "$APPKEY\r\n$NWKKEY\r\n" "$DEVEUI" "$JOINEUI"
    grep -q '"NwkKey": "'"$NWKKEY"'"' "$FAKE_STATE/request.json" 2>/dev/null \
        && [ "$rc" = 0 ] && ok "keys ended with CR LF -> 0" || bad "CR LF keys: rc=$rc" "$out"
    no_key_anywhere "CR LF"; tmp_empty "CR LF"

    # ---- pasted keys wrapped in bracketed-paste markers --------------------
    reset; echo 1.1 >"$FAKE_STATE/mac"
    run_tty "\e[200~$APPKEY\e[201~\n\e[200~$NWKKEY\e[201~\n" "$DEVEUI" "$JOINEUI"
    grep -q '"AppKey": "'"$APPKEY"'", "NwkKey": "'"$NWKKEY"'"' "$FAKE_STATE/request.json" 2>/dev/null \
        && [ "$rc" = 0 ] && ok "bracketed-paste keys -> 0" || bad "bracketed-paste keys: rc=$rc" "$out"
    no_key_anywhere "bracketed paste"

    # ---- a bad key is refused before anything is sent --------------------
    reset
    run_tty "not-a-key\n" "$DEVEUI" "$JOINEUI"
    [ "$rc" = 2 ] && ! grep -q create "$FAKE_LOG" && ok "malformed key -> 2, nothing sent" || bad "malformed key: rc=$rc"
    tmp_empty "malformed key"

    # ---- AWS refuses and echoes the request: key cut out of the error ----
    reset create_fail
    run_tty "$APPKEY\n" "$DEVEUI" "$JOINEUI"
    [ "$rc" = 1 ] && grep -q 'key removed' <<<"$out" && ok "refused registration -> 1, key cut from AWS error" || bad "refused registration: rc=$rc" "$out"
    no_key_anywhere "refused"; tmp_empty "refused"

    # ---- interrupted at the prompt --------------------------------------
    reset
    out=$( { sleep 1.5; printf '\003'; sleep 1; } | script -qfec "bash $(printf '%q' "$sut") $DEVEUI $JOINEUI" /dev/null 2>&1)
    tmp_empty "Ctrl-C at the prompt"
fi

# ---- the script never turns on tracing or echoes its key variables ------
grep -nE '^[^#]*(set -x|echo[^|]*\$(appkey|nwkkey))' "$sut" >/dev/null && bad "script has set -x or echoes a key" || ok "no set -x, no echo of a key variable"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
