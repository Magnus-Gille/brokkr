#!/usr/bin/env bash
# Hermetic gates for scripts/guarded-reboot.sh. The script runs with a PATH that holds only the
# stubs in $BIN and symlinks to the plain utilities it needs in $TOOLS, so the real sudo and
# systemctl are unreachable by construction. sudo, systemctl, who, uname, hostname, nproc, timeout,
# the process lookup, rpi-eeprom-update and the notify helper are stubs that log to one ordered
# call log; the clock, boot id, load, boot directory, crypttab, kill switch, cgroup tree, state
# and audit file are temp paths. Nothing real is rebooted, staged, queried or sent.
# Set BASH_UNDER_TEST to run the script with another bash (for example /bin/bash 3.2).
# shellcheck disable=SC2016,SC2034 # assertions are evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# The EEPROM status is parsed from JSON by python3 or node; without either most checks cannot run.
if ! { python3 -I -c "import json" >/dev/null 2>&1 || node -e 0 >/dev/null 2>&1; }; then
  echo "SKIP  guarded-reboot.test.sh needs python3 or node for the EEPROM JSON reader"
  exit 0
fi
# shellcheck source=scripts/test/lib/fixture-cleanup.sh
source "$HERE/lib/fixture-cleanup.sh"
TMP="$(fixture_cleanup_alloc)"
trap 'fixture_cleanup_on_exit "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

SCRIPT="$ROOT/scripts/guarded-reboot.sh"
BASH_BIN="$(type -P "${BASH_UNDER_TEST:-bash}")"
BIN="$TMP/bin"; TOOLS="$TMP/tools"; MOCK="$TMP/mock"; CALLS="$TMP/calls"
HOME_DIR="$TMP/home"; BOOT="$TMP/boot"; CG="$TMP/cgroup"; SD="$TMP/sd"; AUDITDIR="$TMP/audit"
mkdir -p "$BIN" "$TOOLS" "$MOCK" "$HOME_DIR"

# Plain utilities the script needs; everything else (above all sudo and systemctl) is absent.
for t in awk sed grep tr sort cat head tail wc cut find mktemp mv rm mkdir chmod date stat tee cksum \
  dirname ls touch sleep python3 node getconf sha256sum shasum; do
  p="$(type -P "$t" 2>/dev/null || true)"
  if [[ -n "$p" ]]; then ln -s "$p" "$TOOLS/$t"; fi
done
ln -s "$BASH_BIN" "$TOOLS/bash"

# --- stubs ---------------------------------------------------------------------------------------
# sudo: only the fixed argument lists are accepted. Every call is logged; anything else is logged
# as unexpected and fails. tee -a really appends (under the caller's umask) so the audit file is real.
cat >"$BIN/sudo" <<'FAKE'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$MOCK_CALLS"
if [ "${1:-}" != -n ]; then echo "sudo: stub requires -n" >&2; echo "sudo $*" >>"$MOCK_DIR/unexpected"; exit 2; fi
shift
case "$*" in
  "tee -a /var/lib/brokkr/guarded-reboot/audit.jsonl")
    # The production path is a constant argument; the stub maps it into the test tree.
    printf 'umask %s\n' "$(umask)" >>"$MOCK_DIR/tee-umask"
    if [ -e "$MOCK_DIR/audit-fail" ]; then exit 1; fi
    exec tee -a "$MOCK_AUDIT_FILE" ;;
  "systemctl reboot")
    echo reboot >>"$MOCK_DIR/reboot-calls"
    if [ -e "$MOCK_DIR/reboot-fail" ]; then exit 1; fi
    exit 0 ;;
  "true") exit 0 ;;
  "rpi-eeprom-update -j -m /run/brokkr-guarded-reboot-eeprom.json")
    # The status path is a constant argument below /run; the stub maps it into the test tree.
    printf 'umask %s\n' "$(umask)" >>"$MOCK_DIR/eeprom-umask"
    exec "$MOCK_BIN/rpi-eeprom-update" -j -m "$BROKKR_EEPROM_STATUS_FILE" ;;
  "rpi-eeprom-update -a"|"rpi-eeprom-update -r")
    shift
    exec "$MOCK_BIN/rpi-eeprom-update" "$@" ;;
  "install -d -m 0755 "*)
    echo "install $*" >>"$MOCK_DIR/installs"
    exit 0 ;;
  "systemctl disable rpi-eeprom-update.service")
    echo "disable" >>"$MOCK_DIR/eeprom-service-disable"
    exit 0 ;;
  *) echo "sudo $*" >>"$MOCK_DIR/unexpected"; echo "sudo stub: unexpected command: $*" >&2; exit 99 ;;
esac
FAKE
# systemctl: never reboots or disables anything; answers from fixture files in $MOCK_SD.
cat >"$BIN/systemctl" <<'FAKE'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$MOCK_CALLS"
scope=system
if [ "${1:-}" = --user ]; then scope=user; shift; fi
case "${1:-}" in
  show)
    if [ "${2:-}" = -p ] && [ "${4:-}" = --value ]; then
      [ ! -e "$MOCK_SD/systemctl-fail" ] || { echo "Failed to connect to bus" >&2; exit 1; }
      unit=$5
      case "$3" in
        ActiveState) cat "$MOCK_SD/$unit.state" 2>/dev/null || echo inactive ;;
        ControlGroup) cat "$MOCK_SD/$unit.cg" 2>/dev/null || true ;;
        *) exit 2 ;;
      esac
      exit 0
    fi
    if [ "${2:-}" = -p ] && [ "${3:-}" = Type,BusName,UnitFileState,TriggeredBy ]; then
      unit=$4
      if [ -e "$MOCK_SD/show.$scope.$unit" ]; then cat "$MOCK_SD/show.$scope.$unit"; else printf 'Type=simple\nBusName=\nUnitFileState=enabled\nTriggeredBy=\n'; fi
      exit 0
    fi
    exit 2 ;;
  is-active)
    state=$(cat "$MOCK_SD/$2.active" 2>/dev/null || echo inactive)
    echo "$state"
    [ "$state" = active ] && exit 0
    exit 3 ;;
  list-units)
    [ ! -e "$MOCK_SD/list-fail.$scope" ] || { echo "Failed to list units" >&2; exit 1; }
    while IFS= read -r u; do
      [ -n "$u" ] && printf '%s loaded active running Fixture unit\n' "$u"
    done <"$MOCK_SD/running.$scope" 2>/dev/null
    exit 0 ;;
  --failed)
    [ ! -e "$MOCK_SD/failed-fail.$scope" ] || exit 1
    while IFS= read -r u; do
      [ -n "$u" ] && printf '%s loaded failed failed Fixture unit\n' "$u"
    done <"$MOCK_SD/failed.$scope" 2>/dev/null
    exit 0 ;;
  *) echo "systemctl $*" >>"$MOCK_DIR/unexpected"; echo "systemctl stub: unexpected: $*" >&2; exit 99 ;;
esac
FAKE
# who -u: fixture output; who.out.2 replaces it after who.flip calls (a change between guard passes),
# or once a "Rebooting" notice has gone out (a change while the notice was in flight).
cat >"$BIN/who" <<'FAKE'
#!/bin/bash
printf 'who %s\n' "$*" >>"$MOCK_CALLS"
[ ! -e "$MOCK_DIR/who-fail" ] || exit 1
n=$(cat "$MOCK_DIR/who.count" 2>/dev/null || echo 0)
echo $((n + 1)) >"$MOCK_DIR/who.count"
if [ -e "$MOCK_DIR/who.flip" ] && [ "$n" -ge "$(cat "$MOCK_DIR/who.flip")" ] && [ -e "$MOCK_DIR/who.out.2" ]; then
  cat "$MOCK_DIR/who.out.2"; exit 0
fi
if [ -e "$MOCK_DIR/notice.sent" ] && [ -e "$MOCK_DIR/who.out.after-notice" ]; then
  cat "$MOCK_DIR/who.out.after-notice"; exit 0
fi
cat "$MOCK_DIR/who.out" 2>/dev/null || true
FAKE
cat >"$BIN/uname" <<'FAKE'
#!/bin/bash
case "${1:-}" in
  -s) echo "${MOCK_UNAME_S:-Linux}" ;;
  -r) echo "${MOCK_KERNEL:-7.0.0-38-generic}" ;;
  -n) echo node-a ;;
  *) echo "uname $*" >>"$MOCK_DIR/unexpected"; exit 2 ;;
esac
FAKE
cat >"$BIN/hostname" <<'FAKE'
#!/bin/bash
case "${1:-}" in -f) echo "${MOCK_FQDN:-node-a.example}" ;; *) echo node-a ;; esac
FAKE
cat >"$BIN/nproc" <<'FAKE'
#!/bin/bash
echo "${MOCK_NPROC:-4}"
FAKE
# timeout 5 bash -c <script> _ <peer>: the peer is reachable unless listed in peers.down.
cat >"$BIN/timeout" <<'FAKE'
#!/bin/bash
# timeout 5 hostname -f (the self-peer check) runs the real command; timeout 5 bash -c <script> _ <peer>
# is the reachability probe: the peer is reachable unless listed in peers.down.
if [ "${2:-}" != bash ]; then shift; exec "$@"; fi
printf 'timeout %s\n' "$*" >>"$MOCK_CALLS"
peer=${*: -1}
if grep -Fxq -- "$peer" "$MOCK_DIR/peers.down" 2>/dev/null; then exit 124; fi
exit 0
FAKE
# rpi-eeprom-update (reached only through the sudo stub): -j -m FILE writes JSON status, -a stages,
# -r cancels. Fixtures: eeprom.cur / eeprom.latest, eeprom.mode (nojson|failed|garbage),
# eeprom.stage-fail, eeprom.cancel-fail.
cat >"$BIN/rpi-eeprom-update" <<'FAKE'
#!/bin/bash
printf 'rpi-eeprom-update %s\n' "$*" >>"$MOCK_CALLS"
cur=$(cat "$MOCK_DIR/eeprom.cur" 2>/dev/null || echo 1700000000)
latest=$(cat "$MOCK_DIR/eeprom.latest" 2>/dev/null || echo 1700000000)
mode=$(cat "$MOCK_DIR/eeprom.mode" 2>/dev/null || echo normal)
case "${1:-}" in
  -j)
    out=$3
    case "$mode" in
      nojson) echo "sudo: a password is required" >&2; exit 1 ;;
      garbage) echo 'not json' >"$out"; exit 0 ;;
      # unreadable: a status file left behind with a mode the unprivileged job cannot read.
      unreadable) printf '{"EXITCODE": "EXIT_SUCCESS", "BOOTLOADER_CURRENT": %s, "BOOTLOADER_LATEST": %s}\n' "$cur" "$latest" >"$out"; chmod 000 "$out"; exit 0 ;;
      failed) printf '{"EXITCODE": "EXIT_FAILED", "BOOTLOADER_CURRENT": %s, "BOOTLOADER_LATEST": %s}\n' "$cur" "$latest" >"$out"; exit 2 ;;
    esac
    if [ "$latest" -gt "$cur" ]; then code=EXIT_UPDATE_REQUIRED; rc=1; else code=EXIT_SUCCESS; rc=0; fi
    printf '{\n  "EXITCODE": "%s",\n  "BOOTLOADER_AUTO_UPDATE_MIN_VERSION": 0,\n  "BOOTLOADER_CURRENT": %s,\n  "BOOTLOADER_LATEST": %s,\n  "VL805_CURRENT": "",\n  "VL805_LATEST": "",\n  "VL805_EEPROM": false\n}\n' "$code" "$cur" "$latest" >"$out"
    # rcmismatch: a status that contradicts the command's own exit status.
    if [ "$mode" = rcmismatch ]; then rc=$((1 - rc)); fi
    exit "$rc" ;;
  -a)
    [ ! -e "$MOCK_DIR/eeprom.stage-fail" ] || { echo "EEPROM version is frozen" >&2; exit 3; }
    # stage-partial: the staging fails but leaves its files behind.
    if [ -e "$MOCK_DIR/eeprom.stage-partial" ]; then echo "recovery 1790000000" >"$BROKKR_EEPROM_PENDING_FLAG"; exit 3; fi
    echo "recovery 1790000000" >"$BROKKR_EEPROM_PENDING_FLAG"
    echo "EEPROM updates pending. Please reboot to apply the update."
    exit 0 ;;
  -r)
    [ ! -e "$MOCK_DIR/eeprom.cancel-fail" ] || exit 1
    rm -f "$BROKKR_EEPROM_PENDING_FLAG" "$BROKKR_BOOT_DIR/firmware/pieeprom.upd" "$BROKKR_BOOT_DIR/pieeprom.upd"
    exit 0 ;;
  *) echo "rpi-eeprom-update $*" >>"$MOCK_DIR/unexpected"; exit 2 ;;
esac
FAKE
# The notify helper seam: logs every message into the ordered call log. MOCK_NOTIFY_FAIL makes
# delivery fail; MOCK_NOTIFY_KILL creates the kill switch while the "Rebooting" notice is in flight.
cat >"$TMP/notify-stub.sh" <<'FAKE'
notify_telegram_confirmed() {
  printf 'notify %s\n' "$1" >>"$MOCK_CALLS"
  printf '%s\n' "$1" >>"$MOCK_DIR/notices"
  case "$1" in
    Rebooting*)
      : >"$MOCK_DIR/notice.sent"
      if [ -n "${MOCK_NOTIFY_KILL:-}" ]; then : >"$BROKKR_KILL_SWITCH"; fi ;;
  esac
  [ -z "${MOCK_NOTIFY_FAIL:-}" ] || return 1
  return 0
}
notify_telegram() { notify_telegram_confirmed "$@" || true; return 0; }
FAKE
printf 'notify_telegram() { return 0; }\n' >"$TMP/notify-old.sh"
chmod 755 "$BIN/"*
# The rpi-eeprom-update stub is only on PATH for tests that call with_eeprom (a Pi host); without it
# the host has no bootloader EEPROM and the script skips every EEPROM step.
EEPROM_BIN="$TMP/eeprom-bin"; mkdir -p "$EEPROM_BIN"; mv "$BIN/rpi-eeprom-update" "$EEPROM_BIN/rpi-eeprom-update"
# The process-name lookup: `pgrep -x NAME` succeeds when NAME is listed in the pnames fixture, fails
# with 1 when it is not and with 2 when pgrep.fail exists. It never prints argv.
cat >"$BIN/pgrep" <<'FAKE'
#!/bin/bash
printf 'pgrep %s\n' "$*" >>"$MOCK_CALLS"
[ ! -e "$MOCK_DIR/pgrep.fail" ] || exit 2
[ "${1:-}" = -x ] || { echo "pgrep $*" >>"$MOCK_DIR/unexpected"; exit 2; }
if grep -Fxq -- "$2" "$MOCK_DIR/pnames" 2>/dev/null; then echo 4242; exit 0; fi
exit 1
FAKE
chmod 755 "$BIN/pgrep"

# --- harness -------------------------------------------------------------------------------------
export MOCK_DIR="$MOCK" MOCK_CALLS="$CALLS" MOCK_BIN="$BIN" MOCK_SD="$SD"
STATE="$HOME_DIR/state"; STATE_FILE="$STATE/guarded-reboot.json"; AUDIT="$AUDITDIR/audit.jsonl"; export MOCK_AUDIT_FILE="$AUDIT"
KILL="$TMP/kill-switch"; BOOTID_FILE="$TMP/boot-id"; LOADAVG="$TMP/loadavg"; CRYPTTAB="$TMP/crypttab"
RR_FILE="$TMP/reboot-required"; PENDING_FLAG="$TMP/eeprom-pending"
BID1=aaaaaaaa-0000-4000-8000-000000000001
BID2=bbbbbbbb-0000-4000-8000-000000000002
BID3=cccccccc-0000-4000-8000-000000000003
DAY=86400

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; printf '        rc=%s out=%s\n' "${RC:-}" "${OUT:-}" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
skip() { printf '  SKIP  %s\n' "$1"; }
have_python() { command -v python3 >/dev/null 2>&1; }

# The script runs with the stub PATH only, the fixture HOME and whatever BROKKR_* seams are exported.
run() {
  OUT="$(cd "$TMP" && PATH="$BIN:$TOOLS" HOME="$HOME_DIR" "$BASH_BIN" "$SCRIPT" "$@" 2>&1)"
  RC=$?
}
reset() {
  local v
  rm -rf "$MOCK" "$BOOT" "$CG" "$SD" "$AUDITDIR" "$STATE" "$KILL" "$CRYPTTAB" "$RR_FILE" "$RR_FILE.pkgs" "$PENDING_FLAG"; rm -f "$BIN/rpi-eeprom-update"
  mkdir -p "$MOCK" "$BOOT" "$CG" "$SD" "$AUDITDIR" "$HOME_DIR"
  : >"$CALLS"
  for v in $(compgen -e | grep -E '^(BROKKR_|MOCK_[A-Z]+$)' || true); do
    case "$v" in MOCK_DIR|MOCK_CALLS|MOCK_BIN|MOCK_SD) ;; *) unset "$v" ;; esac
  done
  NOW=1790000000
  export BROKKR_NOW_EPOCH=$NOW BROKKR_BOOT_DIR="$BOOT" BROKKR_REBOOT_REQUIRED_FILE="$RR_FILE"
  export BROKKR_CRYPTTAB="$CRYPTTAB" BROKKR_KILL_SWITCH="$KILL" BROKKR_BOOT_ID_FILE="$BOOTID_FILE"
  export BROKKR_LOADAVG_FILE="$LOADAVG" BROKKR_CGROUP_ROOT="$CG" BROKKR_EEPROM_PENDING_FLAG="$PENDING_FLAG"
  export BROKKR_EEPROM_STATUS_FILE="$MOCK/eeprom-status.json" BROKKR_STATE_DIR="$STATE" BROKKR_NOTIFY_HELPER="$TMP/notify-stub.sh"
  export MOCK_KERNEL=7.0.0-38-generic
  printf '%s\n' "$BID1" >"$BOOTID_FILE"
  printf '0.10 0.10 0.10 1/100 1\n' >"$LOADAVG"
  : >"$BOOT/vmlinuz-7.0.0-38-generic"
  printf 'alpha.service\nbeta.service\n' >"$SD/running.system"
  printf 'agent.service\n' >"$SD/running.user"
  : >"$SD/failed.system"; : >"$SD/failed.user"
  : >"$MOCK/who.out"
}
reset_busy() { reset; export BROKKR_GUARDED_REBOOT_BUSY_UNITS="hugin.service other.service"; }
night() { NOW=$((NOW + DAY)); export BROKKR_NOW_EPOCH=$NOW; }
advance() { NOW=$((NOW + $1)); export BROKKR_NOW_EPOCH=$NOW; }

# Ordered-call helpers: every stub appends to $CALLS, so line numbers give the order of events.
line_of() { grep -n -- "$1" "$CALLS" | head -n 1 | cut -d: -f1; }
count_calls() { grep -c -- "$1" "$CALLS" || true; }
reboots() { if [[ -s "$MOCK/reboot-calls" ]]; then wc -l <"$MOCK/reboot-calls" | tr -d ' '; else echo 0; fi; }
no_unexpected() { [[ ! -s "$MOCK/unexpected" ]]; }
audit_count() { if [[ -f "$AUDIT" ]]; then wc -l <"$AUDIT" | tr -d ' '; else echo 0; fi; }
audit_actions() { sed -n 's/.*"action":"\([^"]*\)".*/\1/p' "$AUDIT" 2>/dev/null | tr '\n' ' '; }
audit_last() { tail -n 1 "$AUDIT" 2>/dev/null; }
audit_has() { grep -Fq -- "$1" "$AUDIT" 2>/dev/null; }
notice_count() { if [[ -f "$MOCK/notices" ]]; then wc -l <"$MOCK/notices" | tr -d ' '; else echo 0; fi; }
notice_has() { grep -Fq -- "$1" "$MOCK/notices" 2>/dev/null; }
state_raw() { sed -n 's/^  "'"$1"'": \(.*\),$/\1/p' "$STATE_FILE" | head -n 1; }
state_has() { grep -Fq -- "$1" "$STATE_FILE"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
json_ok() { if have_python; then python3 -I -m json.tool "$1" >/dev/null 2>&1; else grep -q '^{' "$1"; fi; }

# Fixtures.
add_kernel() { local k; for k; do : >"$BOOT/vmlinuz-$k"; done; }
set_who() { printf '%s\n' "$@" >"$MOCK/who.out"; }
who_row() { printf 'magnus   pts/0        2026-09-21 09:00 %s     1234 (203.0.113.9)' "$1"; }
set_load() { printf '%s\n' "$1" >"$LOADAVG"; }
busy_unit() { # unit state cgroup-path pids
  printf '%s\n' "$2" >"$SD/$1.state"
  printf '%s\n' "$3" >"$SD/$1.cg"
  mkdir -p "$CG$3"
  : >"$CG$3/cgroup.procs"
  local n=$4
  while [[ "$n" -gt 0 ]]; do echo "$((1000 + n))" >>"$CG$3/cgroup.procs"; n=$((n - 1)); done
}
set_running() { printf '%s\n' "${@:2}" >"$SD/running.$1"; }   # scope units...
set_failed() { printf '%s\n' "${@:2}" >"$SD/failed.$1"; }
show_fixture() { printf '%s\n' "${@:3}" >"$SD/show.$1.$2"; } # scope unit lines...
with_eeprom() { ln -sf "$EEPROM_BIN/rpi-eeprom-update" "$BIN/rpi-eeprom-update"; }
set_eeprom() { with_eeprom; printf '%s\n' "$1" >"$MOCK/eeprom.cur"; printf '%s\n' "$2" >"$MOCK/eeprom.latest"; }
# An EEPROM-capable host (the stub is put on PATH) that reports a bootloader update.
eeprom_available() { set_eeprom 1700000000 1790000001; }
trigger_rr() { : >"$RR_FILE"; printf 'linux-image-7.0.0-39-generic\nlibc6\n' >"$RR_FILE.pkgs"; }
trigger_kernel() { add_kernel 7.0.0-39-generic; }
reboot_mode() { export BROKKR_GUARDED_REBOOT_MODE=reboot BROKKR_GUARDED_REBOOT_PEERS=node-b.example; }

echo "guarded-reboot.test.sh"
reset

# --- the sandbox: no real sudo or systemctl can be reached ------------------------------------------
check "sudo resolves to the stub" '[[ "$(PATH="$BIN:$TOOLS" type -P sudo)" == "$BIN/sudo" ]]'
check "systemctl resolves to the stub" '[[ "$(PATH="$BIN:$TOOLS" type -P systemctl)" == "$BIN/systemctl" ]]'
check "no other sudo or systemctl exists on the script PATH" '[[ -z "$(ls "$TOOLS" | grep -E "^(sudo|systemctl|reboot|shutdown)$")" ]]'

# --- usage and configuration: exit 64 ------------------------------------------------------------------
run --help
check "--help prints the usage and exits 0" '[[ "$RC" -eq 0 && "$OUT" == *usage* && "$OUT" == *clear-latch* ]]'
run bogus
check "an unknown subcommand is a usage error" '[[ "$RC" -eq 64 ]]'
run check post-boot
check "two subcommands are a usage error" '[[ "$RC" -eq 64 ]]'
run --nope
check "an unknown option is a usage error" '[[ "$RC" -eq 64 ]]'
MOCK_UNAME_S=Darwin run check
check "a non-Linux host is refused" '[[ "$RC" -eq 64 && "$OUT" == *"Linux only"* ]] && [[ ! -e "$STATE_FILE" ]]'
for bad_value in reboot-now Report "" x; do
  if [[ -z "$bad_value" ]]; then continue; fi
  BROKKR_GUARDED_REBOOT_MODE="$bad_value" run check
  check "invalid mode '$bad_value' exits 64" '[[ "$RC" -eq 64 && "$OUT" == *BROKKR_GUARDED_REBOOT_MODE* ]]'
done
for bad_value in 'bad' 'x;y.service' 'a.timer' '-x.service' '../x.service' '$(id).service' '*.service'; do
  BROKKR_GUARDED_REBOOT_BUSY_UNITS="hugin.service $bad_value" run check
  check "invalid busy unit '$bad_value' exits 64" '[[ "$RC" -eq 64 && "$OUT" == *BROKKR_GUARDED_REBOOT_BUSY_UNITS* ]]'
done
for bad_value in abc -1 1.2.3 .5 1e3 99999 '1,5'; do
  BROKKR_GUARDED_REBOOT_MAX_LOAD="$bad_value" run check
  check "invalid max load '$bad_value' exits 64" '[[ "$RC" -eq 64 && "$OUT" == *MAX_LOAD* ]]'
done
for bad_value in abc -5 1441 1.5 99999; do
  BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN="$bad_value" run check
  check "invalid terminal idle '$bad_value' exits 64" '[[ "$RC" -eq 64 && "$OUT" == *TTY_IDLE_MIN* ]]'
done
for bad_value in abc 0 -1 366 1.5; do
  BROKKR_GUARDED_REBOOT_ALERT_AFTER="$bad_value" run check
  check "invalid alert-after '$bad_value' exits 64" '[[ "$RC" -eq 64 && "$OUT" == *ALERT_AFTER* ]]'
done
for bad_value in '-bad' 'a b!' 'x;y' '$(id)' 'a/b' '.x'; do
  BROKKR_GUARDED_REBOOT_PEERS="node-b.example $bad_value" run check
  check "invalid peer '$bad_value' exits 64" '[[ "$RC" -eq 64 && "$OUT" == *PEERS* ]]'
done
BROKKR_NOW_EPOCH=yesterday run check
check "an invalid clock seam exits 64" '[[ "$RC" -eq 64 ]]'
BROKKR_STATE_DIR=relative/state run check
check "a relative state directory exits 64" '[[ "$RC" -eq 64 ]]'
check "invalid configuration never reached sudo or systemctl" '[[ ! -s "$CALLS" ]] && no_unexpected'

# Privileged arguments are constants: no environment variable changes any argument of a sudo call.
reset; with_eeprom
BROKKR_GUARDED_REBOOT_AUDIT=/tmp/other-audit.jsonl BROKKR_AUDIT_FILE=/tmp/other-audit.jsonl BROKKR_EEPROM_STATUS_PATH=/tmp/other-status.json run check
check "the audit path is the constant production path whatever the environment says" 'grep -Fxq "sudo -n tee -a /var/lib/brokkr/guarded-reboot/audit.jsonl" "$CALLS" && ! grep "^sudo" "$CALLS" | grep -q "other-audit" && [[ "$(audit_count)" -eq 1 ]]'
check "the EEPROM status file is the constant file below /run, written by root through sudo" 'grep -Fxq "sudo -n rpi-eeprom-update -j -m /run/brokkr-guarded-reboot-eeprom.json" "$CALLS" && ! grep "^sudo" "$CALLS" | grep -q "other-status"'
check "every sudo call in a full run is one of the constant argument lists" '! grep "^sudo" "$CALLS" | grep -Ev "^sudo -n (tee -a /var/lib/brokkr/guarded-reboot/audit.jsonl|rpi-eeprom-update -j -m /run/brokkr-guarded-reboot-eeprom.json|rpi-eeprom-update -a|rpi-eeprom-update -r|systemctl reboot)$"'
reset; with_eeprom; BROKKR_EEPROM_STATUS_FILE="$MOCK/elsewhere.json" run check
check "the read-only status seam moves only where the result is read, never the sudo argument" 'grep -Fxq "sudo -n rpi-eeprom-update -j -m /run/brokkr-guarded-reboot-eeprom.json" "$CALLS" && [[ -s "$MOCK/elsewhere.json" ]]'

# --- no trigger, state and audit format ------------------------------------------------------------------
reset
run check
check "no trigger: exit 0 and action none" '[[ "$RC" -eq 0 && "$OUT" == *"decision: none"* ]] && grep -q "^  \"action\": \"none\"," "$STATE_FILE"'
check "state file is private valid JSON" '[[ "$(mode_of "$STATE_FILE")" == 600 ]] && json_ok "$STATE_FILE"'
check "no trigger: nothing reboots, notifies, or stages" '[[ "$(reboots)" -eq 0 && "$(notice_count)" -eq 0 ]] && ! grep -q "rpi-eeprom-update -a" "$CALLS" && no_unexpected'
check "the first run audits one none line" '[[ "$(audit_count)" -eq 1 && "$(audit_actions)" == "none " ]]'
LINE="$(audit_last)"
check "audit line has exactly the agreed keys in order" '[[ "$LINE" =~ ^\{\"ts\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\",\"epoch\":[0-9]+,\"host\":\"node-a\",\"mode\":\"report\",\"action\":\"none\",\"triggers\":\"\",\"guards\":\"\",\"boot_id\":\"'"$BID1"'\",\"detail\":\"[^\"]*\"\}$ ]]'
check "audit timestamp matches the clock seam" '[[ "$LINE" == *"\"epoch\":$NOW,"* ]] && [[ "$LINE" == *"\"ts\":\"$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ)\""* ]]'
if have_python; then
  check "audit line is valid JSON with keys in the documented order" '[[ "$(python3 -I -c "import json,sys; print(\",\".join(k for k,v in json.loads(sys.stdin.readline(), object_pairs_hook=list)))" <"$AUDIT")" == "ts,epoch,host,mode,action,triggers,guards,boot_id,detail" ]]'
else
  skip "audit line JSON key order (python3 unavailable)"
fi
check "the audit file is created world-readable (root umask 022 in effect for sudo tee)" '[[ "$(mode_of "$AUDIT")" == 644 ]] && [[ "$(sort -u "$MOCK/tee-umask")" == "umask 0022" ]]'
check "the only privileged commands are the fixed ones" '! grep "^sudo" "$CALLS" | grep -Ev "^sudo -n (tee -a [^ ]+|rpi-eeprom-update -j -m [^ ]+|rpi-eeprom-update -a|rpi-eeprom-update -r|systemctl reboot)$"'
night; run check
check "a second no-trigger night audits nothing new" '[[ "$RC" -eq 0 && "$(audit_count)" -eq 1 ]]'
check "state records the nightly service baseline" 'grep -q "^    \"alpha.service\"," "$STATE_FILE" && grep -q "^    \"agent.service\"$" "$STATE_FILE" && [[ "$(state_raw baseline_epoch)" -eq "$NOW" ]]'
night; trigger_rr; run check
night; rm -f "$RR_FILE" "$RR_FILE.pkgs"; run check
check "going from a trigger back to none audits the change" '[[ "$(audit_actions)" == "none would-reboot none " ]]'

reset
run status
check "status works before any state exists" '[[ "$RC" -eq 0 && "$OUT" == *"state: none yet"* && "$OUT" == *"kill switch: absent"* ]]'
printf '{ not json' >/dev/null
mkdir -p "$STATE"; printf 'garbage\n' >"$STATE_FILE"
run check
check "a damaged state file is refused with exit 1 and nothing runs" '[[ "$RC" -eq 1 && "$OUT" == *"invalid"* ]] && [[ "$(reboots)" -eq 0 ]]'
reset
run check; sed -i.bak 's/^  "latch": 0,/  "latch": "x",/' "$STATE_FILE" 2>/dev/null; rm -f "$STATE_FILE.bak"
night; run check
check "a state value of the wrong type is refused with exit 1" '[[ "$RC" -eq 1 ]]'
reset
mkdir -p "$STATE"; ln -s "$TMP/elsewhere" "$STATE_FILE"
run check
check "a symlinked state file is refused" '[[ "$RC" -eq 1 ]]'

# --- triggers, one at a time (report mode, no guard) -----------------------------------------------------
reset; trigger_rr; run check
check "reboot-required alone: would-reboot with the trigger id" '[[ "$RC" -eq 0 && "$OUT" == *"decision: would-reboot"* && "$OUT" == *"triggers: reboot-required"* ]] && state_has "\"triggers\": \"reboot-required\","'
check "reboot-required detail names the packages, bounded" 'audit_has "linux-image-7.0.0-39-generic" && audit_has "libc6"'
reset; : >"$RR_FILE"; run check
check "reboot-required without a .pkgs file still triggers" '[[ "$RC" -eq 0 && "$OUT" == *"triggers: reboot-required"* ]]'

reset; trigger_kernel; run check
check "kernel: a newer generic kernel installed triggers" '[[ "$RC" -eq 0 && "$OUT" == *"triggers: kernel"* ]] && audit_has "7.0.0-39-generic"'
reset; MOCK_KERNEL=6.18.50+rpt-rpi-2712; rm -f "$BOOT"/vmlinuz-*; add_kernel 6.18.50+rpt-rpi-2712 6.18.50+rpt-rpi-v8; run check
check "Pi: the running 2712 kernel is newest of its flavour, the v8 flavour beside it is not a trigger" '[[ "$RC" -eq 0 && "$OUT" == *"decision: none"* ]]'
reset; export MOCK_KERNEL=6.18.50+rpt-rpi-2712; rm -f "$BOOT"/vmlinuz-*; add_kernel 6.18.50+rpt-rpi-2712 6.18.51+rpt-rpi-v8; run check
check "Pi: a newer v8 kernel beside the running 2712 kernel is still no trigger" '[[ "$OUT" == *"decision: none"* ]]'
reset; export MOCK_KERNEL=6.18.50+rpt-rpi-2712; rm -f "$BOOT"/vmlinuz-*; add_kernel 6.18.50+rpt-rpi-2712 6.18.51+rpt-rpi-2712 6.18.52+rpt-rpi-v8; run check
check "Pi: a newer 2712 kernel is a trigger" '[[ "$OUT" == *"triggers: kernel"* ]] && audit_has "6.18.51+rpt-rpi-2712"'
reset; export MOCK_KERNEL=6.12.48+deb13-amd64; rm -f "$BOOT"/vmlinuz-*; add_kernel 6.12.48+deb13-amd64 6.12.9+deb13-amd64; run check
check "Debian amd64: version order is numeric (6.12.48 is newer than 6.12.9)" '[[ "$OUT" == *"decision: none"* ]]'
reset; export MOCK_KERNEL=6.12.48+deb13-amd64; rm -f "$BOOT"/vmlinuz-*; add_kernel 6.12.48+deb13-amd64 6.12.49+deb13-rt-amd64 6.12.50+deb13-rt-amd64; run check
check "Debian: rt-amd64 kernels installed beside the running amd64 kernel are another flavour" '[[ "$OUT" == *"decision: none"* ]]'
reset; export MOCK_KERNEL=6.12.48+deb13-rt-amd64; rm -f "$BOOT"/vmlinuz-*; add_kernel 6.12.48+deb13-amd64 6.12.49+deb13-amd64 6.12.48+deb13-rt-amd64; run check
check "Debian: a running rt-amd64 kernel is compared only with rt-amd64 kernels" '[[ "$OUT" == *"decision: none"* ]]'
reset; export MOCK_KERNEL=6.12.48+deb13-rt-amd64; rm -f "$BOOT"/vmlinuz-*; add_kernel 6.12.48+deb13-rt-amd64 6.12.49+deb13-rt-amd64; run check
check "Debian: a newer rt-amd64 kernel is a trigger" '[[ "$OUT" == *"triggers: kernel"* ]]'
reset; export MOCK_KERNEL=7.0.0-38-generic; rm -f "$BOOT"/vmlinuz-*; add_kernel 7.0.0-38-generic 7.0.0-39-lowlatency 7.0.0-37-generic; run check
check "Ubuntu: the generic flavour is compared only with generic kernels" '[[ "$OUT" == *"decision: none"* ]]'
reset; rm -f "$BOOT"/vmlinuz-*; add_kernel 7.0.0-38-generic 7.0.0-38-generic.efi.signed 7.0.0-99-generic.dpkg-bak; run check
check "vmlinuz files with a suffix after the flavour are not candidates" '[[ "$OUT" == *"decision: none"* ]]'
reset; export MOCK_KERNEL=7.0.0-40-generic; run check
check "a running kernel newer than every installed one is not a trigger" '[[ "$OUT" == *"decision: none"* && "$OUT" == *"newer than the newest installed"* ]]'
reset; rm -f "$BOOT"/vmlinuz-*; run check
check "no vmlinuz of the running flavour is a note, not a trigger" '[[ "$RC" -eq 0 && "$OUT" == *"decision: none"* && "$OUT" == *"kernel status unknown"* ]]'
reset; export MOCK_KERNEL=7.0.0-38; run check
check "a release with no flavour is a note, not a trigger" '[[ "$RC" -eq 0 && "$OUT" == *"has no flavour"* ]]'
reset; rm -rf "$BOOT"; run check
check "an unreadable boot directory is an internal failure (exit 1) and nothing runs" '[[ "$RC" -eq 1 && "$OUT" == *"boot directory"* ]] && [[ "$(reboots)" -eq 0 && ! -e "$STATE_FILE" ]]'
reset; rm -f "$BOOTID_FILE"; run check
check "an unreadable boot id is an internal failure (exit 1)" '[[ "$RC" -eq 1 && "$OUT" == *"boot id"* ]]'
reset; printf 'not a boot id!\n' >"$BOOTID_FILE"; run check
check "a malformed boot id is an internal failure (exit 1)" '[[ "$RC" -eq 1 ]]'

# EEPROM: JSON status via -j -m, never scraped from text output.
reset; eeprom_available; run check
check "eeprom: an available bootloader update is a trigger with the latest version as identity" '[[ "$RC" -eq 0 && "$OUT" == *"triggers: eeprom"* ]] && audit_has "version 1790000001" && grep -q "rpi-eeprom-update -j -m " "$CALLS"'
check "eeprom: report mode never stages" '! grep -q "rpi-eeprom-update -a" "$CALLS" && [[ "$(reboots)" -eq 0 ]]'
reset; with_eeprom; run check
check "eeprom: up to date is no trigger" '[[ "$OUT" == *"decision: none"* && "$OUT" != *"eeprom status unknown"* ]]'
reset; with_eeprom; echo nojson >"$MOCK/eeprom.mode"; run check
check "eeprom: no readable JSON is recorded as unknown, not a trigger" '[[ "$RC" -eq 0 && "$OUT" == *"decision: none"* && "$OUT" == *"eeprom status unknown"* ]]'
reset; with_eeprom; echo garbage >"$MOCK/eeprom.mode"; run check
check "eeprom: garbage JSON is unknown, not a trigger" '[[ "$OUT" == *"decision: none"* && "$OUT" == *"eeprom status unknown"* ]]'
reset; eeprom_available; saved_umask=$(umask); umask 077; run check; umask "$saved_umask"
check "eeprom: the status command runs under umask 022 even when the job starts under 077 (the deploy's first run)" '[[ "$(cat "$MOCK/eeprom-umask")" == "umask 0022" && "$OUT" == *"triggers: eeprom"* ]]'
if [ "$(id -u)" -ne 0 ]; then
  reset; with_eeprom; echo unreadable >"$MOCK/eeprom.mode"; run check
  check "eeprom: an unreadable status file is unknown with its own note, not a missing file" '[[ "$OUT" == *"decision: none"* && "$OUT" == *"eeprom status unknown (the status file is not readable"* && "$OUT" != *"no status file"* ]]'
else
  skip "eeprom: unreadable status file (root reads any mode)"
fi
reset; echo failed >"$MOCK/eeprom.mode"; eeprom_available; run check
check "eeprom: EXIT_FAILED is unknown, not a trigger" '[[ "$OUT" == *"decision: none"* && "$OUT" == *"eeprom status unknown"* ]]'
reset; set_eeprom 0 1790000001; run check
check "eeprom: an unknown running bootloader version is unknown, never an update" '[[ "$OUT" == *"decision: none"* && "$OUT" == *"eeprom status unknown"* ]]'
reset; set_eeprom 1790000005 1790000001; run check
check "eeprom: a running bootloader newer than the offered one is no trigger" '[[ "$OUT" == *"decision: none"* ]]'
reset; printf '1790000001\n' >"$MOCK/eeprom.latest"; run check
check "eeprom: no rpi-eeprom-update on the host means no eeprom check at all" '[[ "$OUT" == *"decision: none"* ]] && ! grep -q "rpi-eeprom-update" "$CALLS"'
reset; trigger_rr; trigger_kernel; eeprom_available; run check
check "several triggers are listed in a fixed order" '[[ "$OUT" == *"triggers: reboot-required,kernel,eeprom"* ]]'
check "no private status file is left behind" '[[ -z "$(find "$STATE" -name ".eeprom-status.*")" ]]'

# --- guards, one at a time ---------------------------------------------------------------------------------
deferred_by() { [[ "$RC" -eq 0 && "$OUT" == *"decision: deferred"* && "$OUT" == *"guards: $1"* ]] && state_has "\"guards\": \"$1\"," && [[ "$(reboots)" -eq 0 ]]; }
not_deferred() { [[ "$RC" -eq 0 && "$OUT" == *"decision: would-reboot"* ]]; }

reset; trigger_rr; : >"$KILL"; run check
check "kill switch: defers and records the guard" 'deferred_by kill-switch'
night; run check; night; run check; night; run check; night; run check
check "kill switch never escalates: no alert after many nights" '[[ "$(notice_count)" -eq 0 && "$(state_raw episode_deferrals)" -eq 0 && "$(audit_actions)" != *alert* ]]'
rm -f "$KILL"; night; run check
check "removing the kill switch lets the next night proceed" 'not_deferred'
reset; trigger_rr; ln -s "$TMP/nowhere" "$KILL"; run check
check "a dangling kill-switch symlink still counts" 'deferred_by kill-switch'

reset_busy; trigger_rr; busy_unit hugin.service inactive /user.slice/hugin.service 0; run check
check "busy unit: a stopped unit does not defer" 'not_deferred'
reset_busy; trigger_rr; busy_unit hugin.service active /user.slice/hugin.service 1; run check
check "busy unit: an active unit with only its main process does not defer" 'not_deferred'
reset_busy; trigger_rr; busy_unit hugin.service active /user.slice/hugin.service 3; run check
check "busy unit: an active unit with spawned work defers as busy:<unit>" 'deferred_by busy:hugin.service && audit_has "3 processes"'
reset_busy; trigger_rr; busy_unit other.service reloading /user.slice/other.service 3; run check
check "busy unit: a transitional state is inspected like active" 'deferred_by busy:other.service'
reset_busy; trigger_rr; busy_unit hugin.service active /user.slice/hugin.service 3; busy_unit other.service active /user.slice/other.service 2; run check
check "busy units: every busy unit is recorded" 'deferred_by busy:hugin.service,busy:other.service'
reset_busy; trigger_rr; : >"$SD/hugin.service.state"; run check
check "busy unit: an empty state fails closed" 'deferred_by busy:hugin.service && audit_has "no state"'
reset_busy; trigger_rr; : >"$SD/systemctl-fail"; run check
check "busy unit: systemctl failing fails closed" 'deferred_by busy:hugin.service,busy:other.service'
reset_busy; trigger_rr; printf 'active\n' >"$SD/hugin.service.state"; printf '/user.slice/gone.service\n' >"$SD/hugin.service.cg"; run check
check "busy unit: an unreadable cgroup fails closed" 'deferred_by busy:hugin.service'
reset_busy; trigger_rr; printf 'active\n' >"$SD/hugin.service.state"; printf '/../etc\n' >"$SD/hugin.service.cg"; run check
check "busy unit: an unsafe control group path fails closed" 'deferred_by busy:hugin.service && audit_has unsafe'

reset; trigger_rr; set_load "3.50 3.01 2.00 1/100 1"; run check
check "load: the default maximum is 0.75 x CPUs and a higher 5-minute load defers" 'deferred_by load && audit_has "maximum 3.00"'
reset; trigger_rr; set_load "9.00 2.99 9.00 1/100 1"; run check
check "load: only the 5-minute average counts" 'not_deferred'
reset; trigger_rr; export MOCK_NPROC=8; set_load "0.10 5.50 0.10 1/100 1"; run check
check "load: the default scales with nproc" 'not_deferred'
reset; trigger_rr; set_load "0.10 0.60 0.10 1/100 1"; BROKKR_GUARDED_REBOOT_MAX_LOAD=0.5 run check
check "load: an explicit maximum is honoured" 'deferred_by load'
reset; trigger_rr; set_load "0.10 0.50 0.10 1/100 1"; BROKKR_GUARDED_REBOOT_MAX_LOAD=0.5 run check
check "load: a load equal to the maximum does not defer" 'not_deferred'
reset; trigger_rr; rm -f "$LOADAVG"; run check
check "load: an unreadable load average fails closed" 'deferred_by load'
reset; trigger_rr; printf 'garbage\n' >"$LOADAVG"; run check
check "load: a malformed load average fails closed" 'deferred_by load'

reset; trigger_rr; set_who "$(who_row .)"; run check
check "tty: a session active right now defers" 'deferred_by tty'
reset; trigger_rr; set_who "$(who_row 00:59)"; run check
check "tty: 59 minutes idle is within the last hour" 'deferred_by tty && audit_has "59 minutes"'
reset; trigger_rr; set_who "$(who_row 01:00)"; run check
check "tty: 60 minutes idle is outside the window" 'not_deferred'
reset; trigger_rr; set_who "$(who_row old)"; run check
check "tty: an old session (over a day idle) is ignored" 'not_deferred'
reset; trigger_rr; set_who "$(who_row '?')"; run check
check "tty: an entry with unknown idle (a graphical seat) is ignored" 'not_deferred'
reset; trigger_rr; set_who "$(who_row old)" "$(who_row 00:10)"; run check
check "tty: the most recently used of several sessions decides" 'deferred_by tty'
reset; trigger_rr; set_who "magnus   pts/1        Sep 21 09:00 00:05     1234 (203.0.113.9)"; run check
check "tty: the older who date format is understood" 'deferred_by tty'
reset; trigger_rr; set_who "unexpected row"; run check
check "tty: a row that cannot be parsed fails closed" 'deferred_by tty'
reset; trigger_rr; : >"$MOCK/who-fail"; run check
check "tty: who failing fails closed" 'deferred_by tty'
reset; trigger_rr; set_who "$(who_row .)"; BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN=0 run check
check "tty: a limit of 0 disables the terminal guard" 'not_deferred'
reset; trigger_rr; set_who "$(who_row 00:20)"; BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN=10 run check
check "tty: the limit is configurable" 'not_deferred'
lookup_fail() { : >"$MOCK/pgrep.fail"; }

# apt-busy: a package transaction, or its preparation by the stock apt timers
reset; trigger_rr; echo dpkg >"$MOCK/pnames"; run check
check "apt-busy: a running dpkg defers" 'deferred_by apt-busy && audit_has "dpkg running"'
for name in apt apt-get unattended-upgr; do
  reset; trigger_rr; echo "$name" >"$MOCK/pnames"; run check
  check "apt-busy: a running $name defers" 'deferred_by apt-busy'
done
reset; trigger_rr; echo "dpkg-query" >"$MOCK/pnames"; run check
check "apt-busy: process names must match exactly" 'not_deferred'
reset; trigger_rr; echo active >"$SD/apt-daily-upgrade.service.active"; run check
check "apt-busy: an active apt-daily-upgrade.service defers" 'deferred_by apt-busy && audit_has "apt-daily-upgrade.service is active"'
reset; trigger_rr; echo activating >"$SD/apt-daily.service.active"; run check
check "apt-busy: an activating apt-daily.service defers" 'deferred_by apt-busy'
reset; trigger_rr; echo failed >"$SD/apt-daily.service.active"; run check
check "apt-busy: a failed apt-daily.service does not defer" 'not_deferred'
reset; trigger_rr; lookup_fail; run check
check "apt-busy: a process lookup that errors fails closed" 'deferred_by apt-busy'
reset; trigger_rr; run check
check "apt-busy: no package activity does not defer" 'not_deferred'
check "apt-busy: only process names are looked up, never argv" '! grep -E "^pgrep" "$CALLS" | grep -Ev "^pgrep -x (dpkg|apt|apt-get|unattended-upgr)$"'

# peers: TCP port 22 within 5 seconds, bash /dev/tcp under timeout
reset; trigger_rr; BROKKR_GUARDED_REBOOT_PEERS="node-b.example node-c.example" run check
check "peers: every peer reachable lets the night proceed" 'not_deferred && [[ "$(count_calls "^timeout 5 bash -c ")" -eq 2 ]]'
reset; trigger_rr; echo node-b.example >"$MOCK/peers.down"; BROKKR_GUARDED_REBOOT_PEERS="node-b.example node-c.example" run check
check "peers: an unreachable peer defers as peer:<name>" 'deferred_by peer:node-b.example'
reset; trigger_rr; printf 'node-b.example\nnode-c.example\n' >"$MOCK/peers.down"; BROKKR_GUARDED_REBOOT_PEERS="node-b.example node-c.example" run check
check "peers: every unreachable peer is recorded" 'deferred_by peer:node-b.example,peer:node-c.example'
reset; trigger_rr; mv "$BIN/timeout" "$BIN/timeout.off"; BROKKR_GUARDED_REBOOT_PEERS="node-b.example" run check
mv "$BIN/timeout.off" "$BIN/timeout"
check "peers: a host without timeout cannot check a peer and fails closed" 'deferred_by peer:node-b.example'
reset; trigger_rr; run check
check "peers: none configured means no peer check" 'not_deferred && ! grep -q "^timeout" "$CALLS"'

# unlock: every crypttab entry needed at boot is an encrypted boot volume. Nothing in crypttab proves
# that it unlocks unattended, so each one defers and alerts unless the owner has verified it
# (BROKKR_GUARDED_REBOOT_UNLOCK_VERIFIED=1); options that can prompt stay a hard block regardless.
unverified_alert() { notice_has "encrypted boot volume: unattended unlock not owner-verified (ADR-009)"; }
reset; trigger_rr; printf '# comment\nroot UUID=1 none luks\n' >"$CRYPTTAB"; run check
check "unlock: a passphrase entry defers as unlock and alerts that unattended unlock is not owner-verified" 'deferred_by unlock && unverified_alert && audit_has "root"'
check "unlock: the alert is audited" '[[ "$(audit_actions)" == "deferred alert " ]]'
for entry in 'root UUID=1 none luks,tpm2-device=auto' 'root UUID=1 none luks,tpm2-device=auto,tpm2-pcrs=7' 'root UUID=1 - luks,tpm2-device=auto' 'swap /dev/sda3 /dev/urandom swap,cipher=aes-xts-plain64' 'data UUID=2 /etc/keys/data.key luks' 'data UUID=2 keys/data.key luks' 'data UUID=2 - luks,discard' 'swap /dev/sda3'; do
  reset; trigger_rr; printf '%s\n' "$entry" >"$CRYPTTAB"; run check
  check "unlock: '$entry' is not inferred to be unattended: it defers and alerts" 'deferred_by unlock && unverified_alert'
done
reset; trigger_rr; printf 'root UUID=1 none luks,noauto\n' >"$CRYPTTAB"; run check
check "unlock: a noauto entry is not needed at boot" 'not_deferred'
reset; trigger_rr; printf 'root UUID=1 none luks,tpm2-device=auto\ndata UUID=2 none luks\nbackup UUID=3 none luks,noauto\n' >"$CRYPTTAB"; run check
check "unlock: every entry needed at boot counts, not only the root volume, and noauto ones do not" 'deferred_by unlock && audit_has "root,data" && ! audit_has "backup"'
reset; run check
check "unlock: with no trigger the guard is not evaluated and nothing alerts" '[[ "$OUT" == *"decision: none"* && "$(notice_count)" -eq 0 ]]'
reset; trigger_rr; printf 'root UUID=1 none luks\n' >"$CRYPTTAB"; chmod 000 "$CRYPTTAB"
if [[ -r "$CRYPTTAB" ]]; then skip "unlock: unreadable crypttab (running as root)"; else
  run check
  check "unlock: an unreadable crypttab fails closed" 'deferred_by unlock'
fi
chmod 644 "$CRYPTTAB"
reset; trigger_rr; : >"$CRYPTTAB"; run check
check "unlock: a crypttab with no entries needs nothing" 'not_deferred'

# The owner has verified unattended unlock: entries that only needed the owner's word pass.
for entry in 'root UUID=1 none luks' 'root UUID=1 none luks,tpm2-device=auto' 'data UUID=2 /etc/keys/data.key luks'; do
  reset; trigger_rr; printf '%s\n' "$entry" >"$CRYPTTAB"; BROKKR_GUARDED_REBOOT_UNLOCK_VERIFIED=1 run check
  check "unlock verified: '$entry' no longer defers" 'not_deferred'
done
# ... but an option that can prompt is a hard block whatever the owner says.
for entry in 'root UUID=1 none luks,fido2-device=auto' 'root UUID=1 none luks,fido2-device=auto,fido2-with-client-pin=no' 'root UUID=1 /etc/keys/root.key luks,fido2-device=auto' 'root UUID=1 none luks,pkcs11-uri=auto' 'root UUID=1 none luks,keyscript=/lib/cryptsetup/scripts/passdev' 'root UUID=1 none luks,headless=false,tpm2-device=auto' 'root UUID=1 /etc/keys/root.key luks,pkcs11-pin=yes' 'root UUID=1 none luks,tpm2-device=auto,tpm2-pin=yes'; do
  reset; trigger_rr; printf '%s\n' "$entry" >"$CRYPTTAB"; BROKKR_GUARDED_REBOOT_UNLOCK_VERIFIED=1 run check
  check "unlock verified: '$entry' still defers (an option that can prompt is a hard block)" 'deferred_by unlock && notice_has "have an option that can prompt"'
  reset; trigger_rr; printf '%s\n' "$entry" >"$CRYPTTAB"; run check
  check "unlock unverified: '$entry' defers as well" 'deferred_by unlock'
done
reset; trigger_rr; printf 'root UUID=1 none luks\ndata UUID=2 none luks,fido2-device=auto\n' >"$CRYPTTAB"; BROKKR_GUARDED_REBOOT_UNLOCK_VERIFIED=1 run check
check "unlock verified: only the entries with a prompting option are named" 'deferred_by unlock && audit_has "data" && ! audit_has "root"'
reset; trigger_rr; printf 'root UUID=1 none luks\ndata UUID=2 none luks,fido2-device=auto\n' >"$CRYPTTAB"; run check
check "unlock unverified: both kinds are named and both alerts are in one message" 'deferred_by unlock && notice_has "have an option that can prompt" && unverified_alert && [[ "$(notice_count)" -eq 1 ]]'
for bad_value in 2 yes true -1 ''; do
  if [[ -z "$bad_value" ]]; then continue; fi
  reset; BROKKR_GUARDED_REBOOT_UNLOCK_VERIFIED="$bad_value" run check
  check "unlock: BROKKR_GUARDED_REBOOT_UNLOCK_VERIFIED='$bad_value' is a configuration error (exit 64)" '[[ "$RC" -eq 64 && "$OUT" == *UNLOCK_VERIFIED* ]]'
done
reset; BROKKR_GUARDED_REBOOT_UNLOCK_VERIFIED=0 run check
check "unlock: 0 is accepted and is the default" '[[ "$RC" -eq 0 ]]'

# Peers: a peer that is this very host is refused.
for peer in node-a NODE-A node-a.example Node-A.Example; do
  reset; BROKKR_GUARDED_REBOOT_PEERS="node-b.example $peer" run check
  check "self peer: '$peer' is this host, so the configuration is refused (exit 64)" '[[ "$RC" -eq 64 && "$OUT" == *"names this host itself"* ]]'
done
reset; MOCK_FQDN=node-a.lan.example BROKKR_GUARDED_REBOOT_PEERS="node-a.lan.example" run check
check "self peer: the FQDN comes from hostname -f" '[[ "$RC" -eq 64 && "$OUT" == *"names this host itself"* ]]'
reset; BROKKR_GUARDED_REBOOT_PEERS="node-b.example node-c" run check
check "self peer: other hosts are accepted" '[[ "$RC" -eq 0 ]]'
# Loopback and IP literals can never prove that another host is up: peers are host names.
for peer in localhost LocalHost 127.0.0.1 127.1 10.0.0.5 192.0.2.10 localhost6 localhost.localdomain ip6-localhost ip6-loopback; do
  reset; BROKKR_GUARDED_REBOOT_PEERS="node-b.example $peer" run check
  check "peer '$peer' (loopback or an IP literal) is refused (exit 64)" '[[ "$RC" -eq 64 ]]'
done

# --- escalation and report mode ---------------------------------------------------------------------------------
reset; trigger_rr; set_who "$(who_row .)"
run check; check "escalation: night 1 defers without an alert" 'deferred_by tty && [[ "$(notice_count)" -eq 0 ]]'
night; run check; check "escalation: night 2 defers without an alert" '[[ "$(notice_count)" -eq 0 && "$(state_raw episode_deferrals)" -eq 2 ]]'
night; run check
check "escalation: night 3 alerts once, audited" '[[ "$(notice_count)" -eq 1 ]] && notice_has "ALERT node-a: reboot deferred for 3 nights" && notice_has "guards: tty" && [[ "$(audit_actions)" == "deferred deferred deferred alert " ]]'
night; run check; night; run check
check "escalation: the alert is sent once per episode" '[[ "$(notice_count)" -eq 1 && "$(state_raw episode_deferrals)" -eq 5 ]]'
check "escalation: an alert does not override a guard" '[[ "$(reboots)" -eq 0 ]]'
set_who ""; night; run check
check "escalation: a night with every guard clear resets the consecutive count" 'not_deferred && [[ "$(state_raw episode_deferrals)" -eq 0 ]]'
rm -f "$RR_FILE" "$RR_FILE.pkgs"; night; run check; trigger_rr; set_who "$(who_row .)"
night; run check; night; run check; night; run check
check "escalation: a new episode alerts again after three deferred nights" '[[ "$(notice_count)" -eq 3 ]] && notice_has "reboot deferred for 3 nights"'

reset; trigger_rr; set_who "$(who_row .)"; run check; advance 3600; run check; advance 7200; run check
check "escalation: manual re-runs within a night do not count as extra nights" '[[ "$(state_raw episode_deferrals)" -eq 1 && "$(notice_count)" -eq 0 ]]'
reset; trigger_rr; set_who "$(who_row .)"; BROKKR_GUARDED_REBOOT_ALERT_AFTER=1 run check
check "escalation: ALERT_AFTER is configurable" '[[ "$(notice_count)" -eq 1 ]] && notice_has "reboot deferred for 1 nights"'
reset; trigger_rr; printf 'root UUID=1 none luks\n' >"$CRYPTTAB"; run check; night; run check
check "unlock: the alert is sent once per episode, not every night" '[[ "$(notice_count)" -eq 1 ]]'

reset; trigger_rr; run check; night; run check; night; run check
check "report mode: would-reboot every night, one notice per episode" '[[ "$(audit_actions)" == "would-reboot would-reboot would-reboot " && "$(notice_count)" -eq 1 ]] && notice_has "report mode: would reboot node-a for reboot-required"'
check "report mode: no reboot, no staging, only fixed privileged commands" '[[ "$(reboots)" -eq 0 ]] && ! grep -q "rpi-eeprom-update -a" "$CALLS" && no_unexpected'
check "report mode: the audit lines say mode report" '! grep -q "\"mode\":\"reboot\"" "$AUDIT"'
rm -f "$RR_FILE" "$RR_FILE.pkgs"; night; run check; trigger_rr; night; run check
check "report mode: a new episode sends a new notice" '[[ "$(notice_count)" -eq 2 ]]'

reset; trigger_rr; reboot_mode; run check --report-only
check "--report-only forces report mode even when the unit says reboot" '[[ "$RC" -eq 0 && "$OUT" == *"decision: would-reboot"* && "$(reboots)" -eq 0 ]] && grep -q "\"mode\":\"report\"" "$AUDIT" && ! grep -q "systemctl reboot" "$CALLS"'
reset; trigger_rr; run --report-only
check "--report-only without a subcommand means check" '[[ "$RC" -eq 0 && "$OUT" == *"decision: would-reboot"* ]]'

# --- reboot mode ---------------------------------------------------------------------------------------------------
sha_of_sorted() { sort "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; }
audit_line_of() { grep -F -- "\"action\":\"$1\"" "$AUDIT" | tail -n 1; }
calls_after() { # pattern-of-marker pattern : count of matching lines after the first marker line
  awk -v m="$1" -v p="$2" 'index($0, m) == 1 { seen = 1; next } seen && index($0, p) == 1 { n++ } END { print n + 0 }' "$CALLS"
}
calls_before() {
  awk -v m="$1" -v p="$2" 'index($0, m) == 1 { exit } index($0, p) == 1 { n++ } END { print n + 0 }' "$CALLS"
}

reset; reboot_mode; trigger_rr; run check
check "reboot mode: a trigger with every guard clear reboots exactly once, exit 0" '[[ "$RC" -eq 0 && "$OUT" == *"reboot requested"* && "$(reboots)" -eq 1 ]]'
check "reboot mode: the reboot is the one fixed privileged command" 'grep -Fxq "sudo -n systemctl reboot" "$CALLS" && no_unexpected'
check "reboot mode: audit line first, then the notice, then the reboot" '[[ "$(line_of "^sudo -n tee -a ")" -lt "$(line_of "^notify Rebooting node-a for reboot-required")" && "$(line_of "^notify Rebooting")" -lt "$(line_of "^sudo -n systemctl reboot")" ]]'
check "reboot mode: the audit line is a reboot record in reboot mode" '[[ "$(audit_actions)" == "reboot " ]] && audit_line_of reboot | grep -q "\"mode\":\"reboot\"" && audit_has "\"triggers\":\"reboot-required\""'
check "reboot mode: guards are evaluated before and again after the notice, right before the reboot" '[[ "$(calls_before "notify Rebooting" "who -u")" -ge 2 && "$(calls_after "notify Rebooting" "who -u")" -ge 1 ]]'
check "reboot mode: the notice names the host and the triggers" 'notice_has "Rebooting node-a for reboot-required"'
check "reboot mode: the attempt record is unresolved with boot id and identities" '[[ "$(state_raw attempt_status)" == "\"unresolved\"" && "$(state_raw attempt_boot_id)" == "\"$BID1\"" && "$(state_raw attempt_triggers)" == "\"reboot-required\"" ]]'
check "reboot mode: the reboot-required identity is the sha256 of the sorted .pkgs content" '[[ "$(state_raw attempt_identities)" == "\"reboot-required=$(sha_of_sorted "$RR_FILE.pkgs")\"" ]]'
check "reboot mode: the pre-reboot service baseline is in the state" 'grep -q "^    \"alpha.service\"," "$STATE_FILE" && grep -q "^    \"agent.service\"$" "$STATE_FILE"'
check "reboot mode: a reboot starts a fresh episode" '[[ "$(state_raw episode_first_seen)" -eq 0 && "$(state_raw episode_deferrals)" -eq 0 ]]'
reset; reboot_mode; : >"$RR_FILE"; run check
check "reboot-required identity without a .pkgs file is the flag file mtime" '[[ "$(state_raw attempt_identities)" == \"reboot-required=mtime-[0-9]*\" ]]'

reset; reboot_mode; run check
check "reboot mode: no trigger means no reboot" '[[ "$RC" -eq 0 && "$(reboots)" -eq 0 && "$OUT" == *"decision: none"* ]]'
reset; reboot_mode; trigger_rr; set_who "$(who_row .)"; run check
check "reboot mode: a guard defers instead of rebooting" 'deferred_by tty && [[ "$(audit_actions)" == "deferred " ]]'
reset; trigger_rr; BROKKR_GUARDED_REBOOT_MODE=reboot run check
check "reboot mode without a peer is a configuration error (exit 64) and does nothing" '[[ "$RC" -eq 64 && "$OUT" == *"at least one peer"* && "$(reboots)" -eq 0 && ! -e "$STATE_FILE" ]]'
reset; trigger_rr; BROKKR_GUARDED_REBOOT_MODE=reboot run check --report-only
check "--report-only does not need a peer even when the unit says reboot" '[[ "$RC" -eq 0 && "$OUT" == *"decision: would-reboot"* ]]'
reset; BROKKR_GUARDED_REBOOT_MODE=reboot run status
check "status and the other subcommands run without a peer" '[[ "$RC" -eq 0 ]]'

reset; reboot_mode; trigger_rr; MOCK_NOTIFY_FAIL=1 run check
check "fail-closed alert path: a notice that cannot be delivered stops the reboot, guard notify" '[[ "$RC" -eq 0 && "$(reboots)" -eq 0 && "$OUT" == *"guards: notify"* ]] && state_has "\"guards\": \"notify\","'
check "fail-closed alert path: the trail shows the reboot record and then the abort" '[[ "$(audit_actions)" == "reboot deferred " ]] && audit_line_of deferred | grep -q "aborted"'
check "fail-closed alert path: the attempt record is put back and the night counts as deferred" '[[ "$(state_raw attempt_status)" == "\"none\"" && "$(state_raw episode_deferrals)" -eq 1 ]]'
export MOCK_NOTIFY_FAIL=; unset MOCK_NOTIFY_FAIL
reset; reboot_mode; trigger_rr; export BROKKR_NOTIFY_HELPER="$TMP/notify-old.sh"; run check
check "fail-closed alert path: a notify helper without notify_telegram_confirmed is not trusted" '[[ "$(reboots)" -eq 0 && "$OUT" == *"guards: notify"* ]]'
reset; reboot_mode; trigger_rr; export BROKKR_NOTIFY_HELPER="$TMP/does-not-exist.sh"; run check
check "fail-closed alert path: a missing notify helper stops the reboot" '[[ "$(reboots)" -eq 0 && "$OUT" == *"guards: notify"* ]]'
reset; reboot_mode; trigger_rr; cp "$TMP/notify-stub.sh" "$TMP/notify-open.sh"; chmod 666 "$TMP/notify-open.sh"; export BROKKR_NOTIFY_HELPER="$TMP/notify-open.sh"; run check
check "the sourced notify helper is code: one that others can write is not trusted" '[[ "$(reboots)" -eq 0 && "$OUT" == *"guards: notify"* && "$OUT" == *"writable by others"* ]] && ! grep -q "^notify " "$CALLS"'
reset; reboot_mode; trigger_rr; ln -sf "$TMP/notify-stub.sh" "$TMP/notify-link.sh"; export BROKKR_NOTIFY_HELPER="$TMP/notify-link.sh"; run check
check "the sourced notify helper is code: a symlink is not trusted" '[[ "$(reboots)" -eq 0 && "$OUT" == *"guards: notify"* ]]'
rm -f "$TMP/notify-open.sh" "$TMP/notify-link.sh"

reset; reboot_mode; trigger_rr; : >"$MOCK/audit-fail"; run check
check "fail-closed audit: an audit write failure stops everything, exit 1" '[[ "$RC" -eq 1 && "$(reboots)" -eq 0 && "$OUT" == *"nothing reboots"* ]]'
check "fail-closed audit: nothing is notified when the audit write fails" '[[ "$(notice_count)" -eq 0 ]] && ! grep -q "^notify" "$CALLS"'

reset; reboot_mode; trigger_rr; : >"$SD/list-fail.system"; run check
check "reboot mode: a baseline that cannot be captured stops the reboot, exit 1" '[[ "$RC" -eq 1 && "$(reboots)" -eq 0 && "$OUT" == *"baseline"* ]] && [[ "$(audit_count)" -eq 0 ]]'
reset; reboot_mode; trigger_rr; : >"$SD/list-fail.user"; run check
check "reboot mode: a user-service baseline that cannot be captured stops the reboot too" '[[ "$RC" -eq 1 && "$(reboots)" -eq 0 ]]'
reset; trigger_rr; : >"$SD/list-fail.system"; run check
check "report mode: a failing baseline capture is only a warning" '[[ "$RC" -eq 0 && "$OUT" == *"decision: would-reboot"* ]]'

reset; reboot_mode; trigger_rr; : >"$TMP/not-a-dir"; BROKKR_STATE_DIR="$TMP/not-a-dir/state" run check
check "reboot mode: a state file that cannot be written stops the reboot, exit 1" '[[ "$RC" -eq 1 && "$(reboots)" -eq 0 && "$OUT" == *"not rebooting"* ]]'

reset; reboot_mode; trigger_rr; set_who "$(who_row 05:00)"; echo "$(who_row .)" >"$MOCK/who.out.2"; echo 1 >"$MOCK/who.flip"; run check
check "second guard pass: a guard that appears after the first pass defers before anything is written for the reboot" '[[ "$RC" -eq 0 && "$(reboots)" -eq 0 && "$OUT" == *"guards: tty"* ]] && ! grep -q "^notify Rebooting" "$CALLS" && [[ "$(audit_actions)" == "deferred " ]]'
reset; reboot_mode; trigger_rr; echo "$(who_row .)" >"$MOCK/who.out.after-notice"; run check
check "final guard pass: a guard that appears while the notice is in flight stops the reboot" '[[ "$RC" -eq 0 && "$(reboots)" -eq 0 && "$OUT" == *"guards: tty"* ]] && [[ "$(audit_actions)" == "reboot deferred " ]]'
reset; reboot_mode; trigger_rr; MOCK_NOTIFY_KILL=1 run check
check "final guard pass: the kill switch created while the notice is in flight stops the reboot" '[[ "$RC" -eq 0 && "$(reboots)" -eq 0 && "$OUT" == *"guards: kill-switch"* ]] && [[ "$(state_raw episode_deferrals)" -eq 0 ]]'

reset; reboot_mode; trigger_rr; : >"$MOCK/reboot-fail"; run check
check "reboot command failure: exit 1, the host latches at once with an audited alert" '[[ "$RC" -eq 1 && "$(reboots)" -eq 1 && "$(state_raw latch)" -eq 1 ]] && audit_line_of alert | grep -q "\"detail\":\"latched: reboot command failed (exit 1)" && notice_has "ALERT node-a: latched: reboot command failed (exit 1)"'
check "reboot command failure: the attempt is kept, never silently restored" '[[ "$(state_raw attempt_status)" == "\"unresolved\"" && "$(state_raw attempt_boot_id)" == "\"$BID1\"" ]] && [[ "$(audit_actions)" == "reboot alert alert " ]]'
# Contract with the maintenance-report projection: the refused command is itself an audited alert
# whose detail starts "reboot command failed", which resolves the earlier reboot intent there.
check "reboot command failure: an alert whose detail starts 'reboot command failed' is appended" 'grep -F "\"action\":\"alert\"" "$AUDIT" | grep -q "\"detail\":\"reboot command failed (exit 1); nothing was rebooted"'
night; run check
check "reboot command failure: the next night is latched, not retried" '[[ "$OUT" == *"guards: latched"* && "$(reboots)" -eq 1 ]]'
reset; reboot_mode; trigger_rr; echo dpkg >"$MOCK/pnames"; run check
check "reboot mode: a running package transaction prevents the reboot" 'deferred_by apt-busy'
check "reboot mode: nothing is staged or announced when a guard defers" '! grep -q "rpi-eeprom-update -a" "$CALLS" && ! grep -q "^notify Rebooting" "$CALLS"'

# --- EEPROM staging: only inside an admitted guarded reboot ---------------------------------------------------------
# Order in reboot mode: second full guard pass, the attempt/intent audit record, staging and its
# verification, the confirmed notice, the final guard pass, the reboot.
reset; reboot_mode; eeprom_available; run check
check "eeprom: an admitted reboot stages the update once and then reboots" '[[ "$RC" -eq 0 && "$(reboots)" -eq 1 && "$(count_calls "^sudo -n rpi-eeprom-update -a$")" -eq 1 && "$(count_calls "^sudo -n rpi-eeprom-update -r$")" -eq 0 ]]'
check "eeprom: the intent audit record comes after the second guard pass and BEFORE the staging, then the notice, the final pass and the reboot" '[[ "$(calls_before "sudo -n tee -a " "who -u")" -ge 2 && "$(line_of "^sudo -n tee -a ")" -lt "$(line_of "^sudo -n rpi-eeprom-update -a$")" && "$(line_of "^sudo -n rpi-eeprom-update -a$")" -lt "$(line_of "^notify Rebooting")" && "$(calls_after "notify Rebooting" "who -u")" -ge 1 && "$(line_of "^notify Rebooting")" -lt "$(line_of "^sudo -n systemctl reboot$")" ]]'
check "eeprom: the intent record carries the identities, the planned staging and the reversal recipe" 'audit_line_of reboot | grep -q "identities eeprom=1790000001; eeprom-staging planned (version 1790000001); reversal irreversible" && audit_has "\"triggers\":\"eeprom\""'
check "eeprom: only one audit line is written before the reboot" '[[ "$(audit_actions)" == "reboot " ]]'
check "eeprom: the attempt identity is the available bootloader version" '[[ "$(state_raw attempt_identities)" == "\"eeprom=1790000001\"" ]]'
check "eeprom: the update is staged when the reboot is requested" '[[ -s "$PENDING_FLAG" ]]'
reset; reboot_mode; trigger_kernel; eeprom_available; run check
check "eeprom: a combined kernel and eeprom attempt records both identities" '[[ "$(state_raw attempt_identities)" == "\"kernel=7.0.0-39-generic,eeprom=1790000001\"" ]] && audit_line_of reboot | grep -q "eeprom-staging planned"'
reset; reboot_mode; trigger_kernel; run check
check "eeprom: without an eeprom trigger nothing is staged and the record plans no staging" '[[ "$(reboots)" -eq 1 ]] && ! grep -q "rpi-eeprom-update -a" "$CALLS" && ! audit_has "eeprom-staging"'

reset; reboot_mode; eeprom_available; : >"$MOCK/audit-fail"; run check
check "eeprom: an audit failure prevents the staging, the notice and the reboot (exit 1)" '[[ "$RC" -eq 1 && "$(reboots)" -eq 0 && ! -e "$PENDING_FLAG" && "$(notice_count)" -eq 0 ]] && ! grep -q "rpi-eeprom-update -a" "$CALLS"'

reset; reboot_mode; eeprom_available; : >"$MOCK/eeprom.stage-partial"; run check
check "eeprom: a staging failure appends the abort, cancels with -r, and stops the reboot (guard eeprom-stage)" '[[ "$RC" -eq 0 && "$(reboots)" -eq 0 && "$OUT" == *"guards: eeprom-stage"* ]] && [[ "$(audit_actions)" == "reboot deferred " ]] && audit_line_of deferred | grep -q "\"detail\":\"reboot aborted" && [[ ! -e "$PENDING_FLAG" ]] && ! grep -q "^notify Rebooting" "$CALLS"'
check "eeprom: the abort is appended before the cancellation, and the cancellation worked, so no latch" '[[ "$(line_of "^sudo -n tee -a ")" -lt "$(line_of "^sudo -n rpi-eeprom-update -a$")" && "$(count_calls "^sudo -n tee -a ")" -eq 2 && "$(count_calls "^sudo -n rpi-eeprom-update -r$")" -eq 1 && "$(state_raw latch)" -eq 0 ]]'
reset; reboot_mode; eeprom_available; : >"$MOCK/eeprom.stage-partial"; : >"$MOCK/eeprom.cancel-fail"; run check
check "eeprom: if the cancellation after a staging failure fails too, the host latches (an alert starting latched)" '[[ "$RC" -eq 1 && "$(reboots)" -eq 0 && "$(state_raw latch)" -eq 1 ]] && audit_line_of alert | grep -q "\"detail\":\"latched: " && notice_has "ALERT node-a: latched: "'
check "eeprom: and the next night is blocked by the latch and by the stray staged update" 'night; run check; [[ "$OUT" == *"latched"* && "$OUT" == *"eeprom-stray"* && "$(reboots)" -eq 0 ]]'
reset; reboot_mode; eeprom_available; MOCK_NOTIFY_FAIL=1 run check
check "eeprom: a notice that cannot be delivered cancels the staged update and stops the reboot" '[[ "$(reboots)" -eq 0 && ! -e "$PENDING_FLAG" && "$OUT" == *"guards: notify"* ]] && [[ "$(audit_actions)" == "reboot deferred " ]] && [[ "$(count_calls "^sudo -n rpi-eeprom-update -r$")" -eq 1 ]]'
reset; reboot_mode; eeprom_available; export MOCK_NOTIFY_FAIL=1; : >"$MOCK/eeprom.cancel-fail"; run check
check "eeprom: an aborted reboot whose staged update cannot be cancelled latches the host" '[[ "$RC" -eq 1 && "$(state_raw latch)" -eq 1 && -e "$PENDING_FLAG" ]] && audit_line_of alert | grep -q "\"detail\":\"latched: "'
unset MOCK_NOTIFY_FAIL
reset; reboot_mode; eeprom_available; echo "$(who_row .)" >"$MOCK/who.out.after-notice"; run check
check "eeprom: a guard in the final pass cancels the staged update and stops the reboot" '[[ "$(reboots)" -eq 0 && ! -e "$PENDING_FLAG" && "$OUT" == *"guards: tty"* ]]'
reset; reboot_mode; eeprom_available; MOCK_NOTIFY_KILL=1 run check
check "eeprom: the kill switch appearing before the reboot cancels the staged update" '[[ "$(reboots)" -eq 0 && ! -e "$PENDING_FLAG" ]]'
reset; reboot_mode; eeprom_available; : >"$MOCK/reboot-fail"; run check
check "eeprom: a failing reboot command cancels the staged update and latches with the reboot failure" '[[ "$RC" -eq 1 && ! -e "$PENDING_FLAG" && "$(state_raw latch)" -eq 1 ]] && audit_line_of alert | grep -q "\"detail\":\"latched: reboot command failed (exit 1)"'
reset; reboot_mode; eeprom_available; : >"$MOCK/reboot-fail"; : >"$MOCK/eeprom.cancel-fail"; run check
check "eeprom: a failing reboot command with a staged update that cannot be cancelled says so in the latch" '[[ "$RC" -eq 1 && -e "$PENDING_FLAG" ]] && audit_line_of alert | grep -q "reboot command failed (exit 1); the staged EEPROM update could not be cancelled"'

reset; reboot_mode; eeprom_available; : >"$KILL"; run check
check "eeprom: the kill switch prevents staging" 'deferred_by kill-switch && ! grep -q "rpi-eeprom-update -a" "$CALLS"'
reset; reboot_mode; eeprom_available; set_who "$(who_row .)"; run check
check "eeprom: a guard prevents staging" 'deferred_by tty && ! grep -q "rpi-eeprom-update -a" "$CALLS"'
reset; eeprom_available; run check
check "eeprom: report mode never stages" '! grep -q "rpi-eeprom-update -a" "$CALLS"'
reset; reboot_mode; eeprom_available; run check --report-only
check "eeprom: --report-only never stages" '! grep -q "rpi-eeprom-update -a" "$CALLS" && [[ "$(reboots)" -eq 0 ]]'

# The EEPROM status is a root-written file below /run, read unprivileged: it must be fresh and agree
# with the command's exit status, or the status is unknown (never a trigger).
reset; with_eeprom; eeprom_available; echo nojson >"$MOCK/eeprom.mode"
printf '{"EXITCODE": "EXIT_UPDATE_REQUIRED", "BOOTLOADER_CURRENT": 1700000000, "BOOTLOADER_LATEST": 1790000001}\n' >"$MOCK/eeprom-status.json"
touch -t 202001010000 "$MOCK/eeprom-status.json"
run check
check "eeprom status: a stale file left by an earlier run is not taken for this run's answer" '[[ "$OUT" == *"decision: none"* && "$OUT" != *"triggers: eeprom"* ]] && audit_has "stale"'
reset; with_eeprom; eeprom_available; echo rcmismatch >"$MOCK/eeprom.mode"; run check
check "eeprom status: a status that contradicts the command's exit status is unknown" '[[ "$OUT" == *"decision: none"* ]] && audit_has "does not match the exit status"'

# A staged update found when no attempt is in progress is cancelled, audited and announced.
reset; with_eeprom; echo "recovery 1790000000" >"$PENDING_FLAG"; run check
check "stray staging: cancelled with rpi-eeprom-update -r, audited as an alert starting eeprom-cancelled" '[[ "$RC" -eq 0 && ! -e "$PENDING_FLAG" && "$(count_calls "^sudo -n rpi-eeprom-update -r$")" -eq 1 ]] && audit_line_of alert | grep -q "\"detail\":\"eeprom-cancelled"'
check "stray staging: the cancellation is announced" 'notice_has "ALERT node-a: eeprom-cancelled"'
reset; reboot_mode; with_eeprom; mkdir -p "$BOOT/firmware"; : >"$BOOT/firmware/pieeprom.upd"; run check
check "stray staging: a pieeprom.upd on the boot partition is found too, also in reboot mode" '[[ ! -e "$BOOT/firmware/pieeprom.upd" ]] && audit_has "eeprom-cancelled"'
reset; with_eeprom; echo "recovery 1790000000" >"$PENDING_FLAG"; run check --report-only
check "stray staging: --report-only does not cancel anything" '[[ -e "$PENDING_FLAG" ]] && ! grep -q "rpi-eeprom-update -r" "$CALLS"'
reset; with_eeprom; echo "recovery 1790000000" >"$PENDING_FLAG"; : >"$MOCK/eeprom.cancel-fail"; run check
check "stray staging: a cancel that fails is an exit 1 with an eeprom-cancel-failed alert" '[[ "$RC" -eq 1 && -e "$PENDING_FLAG" ]] && audit_has "eeprom-cancel-failed"'
reset; echo "recovery 1790000000" >"$PENDING_FLAG"; run check
check "stray staging: a host without rpi-eeprom-update is left alone" '[[ "$RC" -eq 0 ]] && ! grep -q "rpi-eeprom-update" "$CALLS"'
reset; with_eeprom; run check
check "stray staging: nothing staged means no cancel call" '! grep -q "rpi-eeprom-update -r" "$CALLS"'

# A stray staged update that cannot be cancelled blocks admission until a later run cancels it.
reset; reboot_mode; with_eeprom; trigger_rr; echo "recovery 1790000000" >"$PENDING_FLAG"; : >"$MOCK/eeprom.cancel-fail"; run check
check "stray staging: a failed cancellation blocks the reboot with the guard eeprom-stray and exit 1" '[[ "$RC" -eq 1 && "$(reboots)" -eq 0 && "$OUT" == *"guards: eeprom-stray"* ]] && ! grep -q "rpi-eeprom-update -a" "$CALLS" && ! grep -q "^notify Rebooting" "$CALLS"'
check "stray staging: the alert was audited and delivered before the run returned" 'audit_line_of alert | grep -q "\"detail\":\"eeprom-cancel-failed" && notice_has "ALERT node-a: eeprom-cancel-failed"'
rm -f "$MOCK/eeprom.cancel-fail"; night; run check
check "stray staging: the block persists only until a later run cancels successfully, then the night proceeds" '[[ ! -e "$PENDING_FLAG" && "$(reboots)" -eq 1 ]] && audit_has "eeprom-cancelled"'
reset; reboot_mode; with_eeprom; trigger_rr; echo "recovery 1790000000" >"$PENDING_FLAG"; : >"$MOCK/eeprom.cancel-fail"; run check; night; run check
check "stray staging: while it cannot be cancelled every night stays blocked" '[[ "$(reboots)" -eq 0 && "$OUT" == *"guards: eeprom-stray"* ]]'
reset; with_eeprom; trigger_rr; echo "recovery 1790000000" >"$PENDING_FLAG"; run check --report-only
check "stray staging: --report-only may not cancel, so it reports the block instead of a would-reboot" 'deferred_by eeprom-stray'
reset; with_eeprom; echo "recovery 1790000000" >"$PENDING_FLAG"; : >"$MOCK/eeprom.cancel-fail"; run check
check "stray staging: with no trigger the failed cancellation is still alerted, audited and exit 1" '[[ "$RC" -eq 1 ]] && audit_has "eeprom-cancel-failed" && [[ "$OUT" == *"decision: none"* ]]'

# --- post-boot: the health check after a guarded reboot ---------------------------------------------------------------
# attempt: a reboot-mode night that reboots for the reboot-required trigger (BID1); after_reboot: the
# host is back on BID2 ten minutes later with the trigger gone.
attempt() { reset; reboot_mode; trigger_rr; run check; }
after_reboot() { printf '%s\n' "$BID2" >"$BOOTID_FILE"; advance 600; rm -f "$RR_FILE" "$RR_FILE.pkgs"; }

reset; run post-boot
check "post-boot without an attempt is silent and writes nothing" '[[ "$RC" -eq 0 && -z "$OUT" && ! -e "$STATE_FILE" && "$(audit_count)" -eq 0 ]]'
attempt; advance 600; run post-boot
check "post-boot while the boot id is unchanged is silent" '[[ "$RC" -eq 0 && -z "$OUT" && "$(audit_actions)" == "reboot " && "$(state_raw attempt_status)" == "\"unresolved\"" ]]'

attempt; after_reboot; N0=$(notice_count); run post-boot
check "post-boot ok: audit post-boot-ok, a back-up notice naming the kernel, the attempt resolved" '[[ "$RC" -eq 0 && "$(audit_actions)" == "reboot post-boot-ok " && "$(state_raw attempt_status)" == "\"ok\"" ]] && notice_has "back up: node-a kernel 7.0.0-38-generic; health OK" && [[ "$(state_raw latch)" -eq 0 ]]'
check "post-boot ok: the audit line carries the kernel and says health OK" 'audit_line_of post-boot-ok | grep -q "kernel 7.0.0-38-generic; health OK"'
run post-boot
check "post-boot runs once per attempt: a second run is silent" '[[ -z "$OUT" && "$(audit_actions)" == "reboot post-boot-ok " ]]'

attempt; after_reboot; set_running system alpha.service; run post-boot
check "post-boot issues: a baseline system service that did not come back" '[[ "$RC" -eq 0 && "$(audit_actions)" == "reboot post-boot-issues alert " ]] && audit_line_of post-boot-issues | grep -q "system services not running again: beta.service" && notice_has "back up: node-a kernel 7.0.0-38-generic; issues:"'
check "post-boot issues latch automatic reboots off with one alert starting latched" '[[ "$(state_raw latch)" -eq 1 && "$(state_raw attempt_status)" == "\"issues\"" ]] && audit_line_of alert | grep -q "\"detail\":\"latched: " && [[ "$(grep -c "latched: " "$MOCK/notices")" -eq 1 ]]'
attempt; after_reboot; set_running user; run post-boot
check "post-boot issues: a baseline user service that did not come back" 'audit_line_of post-boot-issues | grep -q "user services not running again: agent.service"'
attempt; after_reboot; set_failed system broken.service; run post-boot
check "post-boot issues: a failed system unit" 'audit_line_of post-boot-issues | grep -q "failed system units: broken.service"'
attempt; after_reboot; set_failed user user-broken.service; run post-boot
check "post-boot issues: a failed user unit" 'audit_line_of post-boot-issues | grep -q "failed user units: user-broken.service"'
attempt; after_reboot; : >"$SD/failed-fail.system"; run post-boot
check "post-boot issues: failed units that cannot be listed are an issue, not a pass" 'audit_line_of post-boot-issues | grep -q "cannot query the failed system units"'
attempt; after_reboot; : >"$SD/list-fail.user"; run post-boot
check "post-boot issues: user services that cannot be listed are an issue" 'audit_line_of post-boot-issues | grep -q "cannot list the running user services"'

# The recorded targets are verified positively; an unknown observation is an issue and latches.
attempt; printf '%s\n' "$BID2" >"$BOOTID_FILE"; advance 600; run post-boot
check "post-boot issues: the reboot-required flag still present with the same identity" '[[ "$(audit_actions)" == "reboot post-boot-issues alert " ]] && audit_line_of post-boot-issues | grep -q "the reboot-required flag is still present with the same identity" && [[ "$(state_raw latch)" -eq 1 ]]'
attempt; printf '%s\n' "$BID2" >"$BOOTID_FILE"; advance 600; printf 'linux-image-9.9.9\n' >"$RR_FILE.pkgs"; run post-boot
check "post-boot: a reboot-required flag whose identity changed is a note, not an issue, and does not latch" '[[ "$(audit_actions)" == "reboot post-boot-ok " && "$(state_raw latch)" -eq 0 ]] && audit_line_of post-boot-ok | grep -q "new trigger since the reboot: reboot-required="'

attempt_kernel() { reset; reboot_mode; trigger_kernel; run check; printf '%s\n' "$BID2" >"$BOOTID_FILE"; advance 600; }
attempt_kernel; export MOCK_KERNEL=7.0.0-39-generic; run post-boot
check "post-boot kernel attempt: the running kernel equals the recorded expected version" '[[ "$(audit_actions)" == "reboot post-boot-ok " && "$(state_raw attempt_status)" == "\"ok\"" ]]'
attempt_kernel; run post-boot
check "post-boot kernel attempt: still running the old kernel is an issue and latches" '[[ "$(audit_actions)" == "reboot post-boot-issues alert " && "$(state_raw latch)" -eq 1 ]] && audit_line_of post-boot-issues | grep -q "running kernel is 7.0.0-38-generic, the attempt expected 7.0.0-39-generic"'
attempt_kernel; export MOCK_KERNEL=7.0.0-40-generic; run post-boot
check "post-boot kernel attempt: any kernel other than the recorded one is an issue, even a newer one" 'audit_line_of post-boot-issues | grep -q "the attempt expected 7.0.0-39-generic"'

attempt_eeprom() { reset; reboot_mode; eeprom_available; run check; rm -f "$PENDING_FLAG" "$MOCK/eeprom-status.json"; printf '%s\n' "$BID2" >"$BOOTID_FILE"; advance 600; }
attempt_eeprom; set_eeprom 1790000001 1790000001; run post-boot
check "post-boot EEPROM attempt: a successful status read at the recorded target is verified" '[[ "$(audit_actions)" == "reboot post-boot-ok " ]]'
attempt_eeprom; set_eeprom 1790000009 1790000009; run post-boot
check "post-boot EEPROM attempt: a bootloader newer than the target is fine" '[[ "$(audit_actions)" == "reboot post-boot-ok " ]]'
attempt_eeprom; set_eeprom 1700000000 1790000001; run post-boot
check "post-boot EEPROM attempt: a bootloader still below the target is an issue and latches" '[[ "$(audit_actions)" == "reboot post-boot-issues alert " && "$(state_raw latch)" -eq 1 ]] && audit_line_of post-boot-issues | grep -q "bootloader is 1700000000, the attempt expected at least 1790000001"'
attempt_eeprom; echo nojson >"$MOCK/eeprom.mode"; run post-boot
check "post-boot EEPROM attempt: an unknown status is an issue, never a pass" 'audit_line_of post-boot-issues | grep -q "bootloader version unknown after the reboot" && [[ "$(state_raw latch)" -eq 1 ]]'
attempt_eeprom; set_eeprom 1790000001 1790000001; rm -f "$BIN/rpi-eeprom-update"; run post-boot
check "post-boot EEPROM attempt: a host that lost rpi-eeprom-update cannot verify, which is an issue" 'audit_line_of post-boot-issues | grep -q "rpi-eeprom-update is missing"'
attempt_eeprom; set_eeprom 1790000001 1790000001; echo rcmismatch >"$MOCK/eeprom.mode"; run post-boot
check "post-boot EEPROM attempt: a contradictory status is unknown, hence an issue" 'audit_line_of post-boot-issues | grep -q "does not match the exit status"'
reset; reboot_mode; trigger_kernel; eeprom_available; trigger_rr; run check; rm -f "$PENDING_FLAG" "$RR_FILE" "$RR_FILE.pkgs"; printf '%s\n' "$BID2" >"$BOOTID_FILE"; advance 600; export MOCK_KERNEL=7.0.0-39-generic; set_eeprom 1790000001 1790000001; run post-boot
check "post-boot: an attempt for several triggers is verified for each of them" '[[ "$(audit_actions)" == "reboot post-boot-ok " ]]'
reset; reboot_mode; trigger_kernel; eeprom_available; run check; rm -f "$PENDING_FLAG"; printf '%s\n' "$BID2" >"$BOOTID_FILE"; advance 600; export MOCK_KERNEL=7.0.0-39-generic; set_eeprom 1700000000 1790000001; run post-boot
check "post-boot: one target missed among several is enough for an issue" 'audit_line_of post-boot-issues | grep -q "bootloader is 1700000000" && ! audit_line_of post-boot-issues | grep -q "running kernel is"'

# Outcome durability: the outcome is appended BEFORE it is persisted.
attempt; after_reboot; : >"$MOCK/audit-fail"; run post-boot
check "outcome durability: if the post-boot record cannot be appended the attempt stays unresolved, exit 1" '[[ "$RC" -eq 1 && "$(state_raw attempt_status)" == "\"unresolved\"" && "$(state_raw latch)" -eq 0 ]] && ! audit_has "post-boot-ok"'
check "outcome durability: the notice still goes out" 'notice_has "back up: node-a kernel 7.0.0-38-generic; health OK"'
rm -f "$MOCK/audit-fail"; advance 10800; run check
check "outcome durability: the next check latches the unverified attempt as missing verification" '[[ "$(state_raw latch)" -eq 1 ]] && audit_line_of alert | grep -q "post-boot verification missing"'
attempt; after_reboot; set_running system alpha.service; : >"$MOCK/audit-fail"; run post-boot
check "outcome durability: observed issues are latched and kept even though the record could not be appended; the attempt stays unresolved, exit 1" '[[ "$RC" -eq 1 && "$(state_raw attempt_status)" == "\"unresolved\"" && "$(state_raw latch)" -eq 1 ]] && [[ "$(state_raw attempt_observed)" == *"beta.service"* ]] && ! audit_has "post-boot-issues"'
check "outcome durability: the issue notice and the latch alert still go out as notices" 'notice_has "issues: system services not running again: beta.service" && notice_has "ALERT node-a: latched: "'
check "outcome durability: status shows the unrecorded observation" 'run status; [[ "$OUT" == *"LATCH: automatic reboots are OFF"* && "$OUT" == *"observed but not yet recorded"* && "$OUT" == *"status=unresolved"* ]]'
night; trigger_rr; run check
check "outcome durability: with the latch set the next night is held (guard latched), not reboot-eligible" '[[ "$OUT" == *"latched"* && "$(reboots)" -eq 1 ]]'
# The audit recovers and the retry is healthy: the attempt is still not a pass.
rm -f "$MOCK/audit-fail" "$RR_FILE" "$RR_FILE.pkgs"; set_running system alpha.service beta.service
run post-boot
check "outcome durability: a healthy retry after the audit recovers still records issues and keeps the latch" '[[ "$RC" -eq 0 && "$(state_raw attempt_status)" == "\"issues\"" && "$(state_raw latch)" -eq 1 ]] && audit_line_of post-boot-issues | grep -q "an earlier post-boot check observed" && ! audit_has "post-boot-ok"'
check "outcome durability: the observation is cleared once recorded, and the latching alert is recorded now that the audit works" '[[ "$(state_raw attempt_observed)" == "\"\"" ]] && audit_line_of alert | grep -q "\"detail\":\"latched: "'
run post-boot
check "outcome durability: only clear-latch clears it; another post-boot run does nothing" '[[ -z "$OUT" && "$(state_raw latch)" -eq 1 ]]'
run clear-latch
check "outcome durability: clear-latch clears the latch and the observation, and the attempt is acknowledged" '[[ "$RC" -eq 0 && "$(state_raw latch)" -eq 0 && "$(state_raw attempt_status)" == "\"cleared\"" ]]'
# A healthy outcome whose record cannot be appended leaves no trace to carry over.
attempt; after_reboot; : >"$MOCK/audit-fail"; run post-boot
check "outcome durability: a healthy outcome that cannot be recorded persists nothing" '[[ "$RC" -eq 1 && "$(state_raw attempt_status)" == "\"unresolved\"" && "$(state_raw latch)" -eq 0 && "$(state_raw attempt_observed)" == "\"\"" ]]'
rm -f "$MOCK/audit-fail"; run post-boot
check "outcome durability: and the healthy retry then records ok" '[[ "$(state_raw attempt_status)" == "\"ok\"" && "$(state_raw latch)" -eq 0 ]]'
# A state file written before attempt_observed existed still loads.
attempt; after_reboot; sed -i.bak '/"attempt_observed"/d' "$STATE_FILE"; rm -f "$STATE_FILE.bak"; run post-boot
check "outcome durability: a state file without attempt_observed still loads" '[[ "$RC" -eq 0 && "$(audit_actions)" == "reboot post-boot-ok " ]]'

# On-demand exemptions: only Type=dbus, a BusName, a TriggeredBy or a transient unit may be down.
# A static or indirect unit file proves nothing about whether the service is long-running.
attempt; after_reboot; set_running system alpha.service
show_fixture system beta.service "Type=dbus" "BusName=org.example.Svc" "UnitFileState=static" "TriggeredBy="
run post-boot
check "on-demand: a static D-Bus activated service that is not running is exempt" '[[ "$(audit_actions)" == "reboot post-boot-ok " ]]'
attempt; after_reboot; set_running system alpha.service
show_fixture system beta.service "Type=simple" "BusName=org.example.Svc" "UnitFileState=enabled" "TriggeredBy="
run post-boot
check "on-demand: a service with a BusName is exempt" '[[ "$(audit_actions)" == "reboot post-boot-ok " ]]'
attempt; after_reboot; set_running system alpha.service
show_fixture system beta.service "Type=simple" "BusName=" "UnitFileState=enabled" "TriggeredBy=beta.socket"
run post-boot
check "on-demand: a socket-activated service is exempt" '[[ "$(audit_actions)" == "reboot post-boot-ok " ]]'
attempt; after_reboot; set_running system alpha.service
show_fixture system beta.service "Type=simple" "BusName=" "UnitFileState=transient" "TriggeredBy="
run post-boot
check "on-demand: a transient unit is exempt" '[[ "$(audit_actions)" == "reboot post-boot-ok " ]]'
attempt; after_reboot; set_running system alpha.service
show_fixture system beta.service "Type=simple" "BusName=" "UnitFileState=static" "TriggeredBy="
run post-boot
check "on-demand: a static long-running service that disappeared is an issue (no blanket static exemption)" '[[ "$(audit_actions)" == "reboot post-boot-issues alert " ]] && audit_line_of post-boot-issues | grep -q "system services not running again: beta.service"'
attempt; after_reboot; set_running system alpha.service
show_fixture system beta.service "Type=simple" "BusName=" "UnitFileState=indirect" "TriggeredBy="
run post-boot
check "on-demand: an indirect unit file is not an exemption either" '[[ "$(audit_actions)" == "reboot post-boot-issues alert " ]]'
attempt; after_reboot; set_running user
show_fixture user agent.service "Type=dbus" "BusName=" "UnitFileState=enabled" "TriggeredBy="
run post-boot
check "on-demand: a Type=dbus user service is exempt" '[[ "$(audit_actions)" == "reboot post-boot-ok " ]]'
attempt; after_reboot; set_running system alpha.service
show_fixture system beta.service "Type=simple" "BusName=" "UnitFileState=enabled" "TriggeredBy="
run post-boot
check "post-boot: an enabled long-running service that is missing is an issue" '[[ "$(audit_actions)" == "reboot post-boot-issues alert " ]]'

# safe_text and the state validator agree: an escaped unit name and every replaced character
# round-trips through write, load, status and clear-latch.
reset; reboot_mode; trigger_rr; set_running system alpha.service 'foo\x2dbar.service'; run check
check "round trip: an escaped unit name is written to the baseline as valid JSON" 'json_ok "$STATE_FILE" && grep -Fq "foo\\\\x2dbar.service" "$STATE_FILE"'
after_reboot; set_failed system 'bad\x2dunit.service'; run post-boot
check "round trip: a failed escaped unit name lands in the audit and the state (replaced characters become ?)" 'audit_line_of post-boot-issues | grep -q "failed system units: bad?x2dunit.service" && json_ok "$STATE_FILE"'
run status
check "round trip: status reads the state back" '[[ "$RC" -eq 0 && "$OUT" == *"LATCH: automatic reboots are OFF"* && "$OUT" == *"bad?x2dunit"* ]]'
run clear-latch
check "round trip: clear-latch reads and rewrites it" '[[ "$RC" -eq 0 && "$(state_raw latch)" -eq 0 ]] && grep -Fq "foo\\\\x2dbar.service" "$STATE_FILE"'
night; run check
check "round trip: the next nightly check loads the rewritten state" '[[ "$RC" -eq 0 ]]'

reset; reboot_mode; trigger_rr; set_running system alpha.service brokkr-guarded-reboot.service brokkr-post-boot-check.service run-r1234.service; run check
check "the baseline leaves out this job's own units and transient run units" '! grep -q "brokkr-guarded-reboot" "$STATE_FILE" && ! grep -q "brokkr-post-boot-check" "$STATE_FILE" && ! grep -q "run-r1234" "$STATE_FILE"'
attempt; after_reboot; export MOCK_KERNEL=7.0.0-39-generic; run post-boot
check "post-boot reports the kernel that is running now" 'notice_has "back up: node-a kernel 7.0.0-39-generic; health OK"'

# --- the latch ---------------------------------------------------------------------------------------------------------------
# After issues the latch keeps automatic reboots off until the owner clears it; new triggers never clear it.
attempt; after_reboot; set_running system alpha.service; run post-boot
night; trigger_rr; run check
check "latched: the next night defers with guard latched and does not reboot" '[[ "$RC" -eq 0 && "$OUT" == *"guards: latched"* && "$(reboots)" -eq 1 ]] && audit_line_of deferred | grep -q "latched off since"'
trigger_kernel; night; run check
check "latched: a new trigger does not clear the latch" '[[ "$OUT" == *"guards: latched"* && "$(reboots)" -eq 1 && "$(state_raw latch)" -eq 1 ]]'
check "latched: the latch alert was sent exactly once" '[[ "$(grep -c "latched: " "$MOCK/notices")" -eq 1 ]]'
night; run check; night; run check
check "latched: deferral alerts still never override the guard" '[[ "$(reboots)" -eq 1 ]]'
run status
check "status shows the latch and how to clear it" '[[ "$OUT" == *"LATCH: automatic reboots are OFF"* && "$OUT" == *"clear-latch"* ]]'

N_BEFORE=$(audit_count)
run clear-latch
check "clear-latch: audited as action none with a detail starting latch-cleared" '[[ "$RC" -eq 0 && "$(audit_count)" -eq $((N_BEFORE + 1)) ]] && [[ "$(audit_last)" == *"\"action\":\"none\""* && "$(audit_last)" == *"\"detail\":\"latch-cleared: "* ]]'
check "clear-latch: the latch is off, the attempt is acknowledged, a notice goes out" '[[ "$(state_raw latch)" -eq 0 && "$(state_raw attempt_status)" == "\"cleared\"" ]] && notice_has "latch cleared"'
night; run check
check "after clear-latch the next night with a trigger can reboot again" '[[ "$(reboots)" -eq 2 ]]'
run clear-latch
check "clear-latch without a latch does nothing and audits nothing" '[[ "$RC" -eq 0 && "$OUT" == *"no latch"* ]]'

attempt; after_reboot; set_running system alpha.service; run post-boot
: >"$MOCK/audit-fail"; run clear-latch
check "clear-latch: if the audit append fails the latch stays, exit 1" '[[ "$RC" -eq 1 && "$(state_raw latch)" -eq 1 ]]'

# An attempt without a successful post-boot result blocks further reboots.
attempt; advance 3600; run check
check "unresolved attempt within the grace period: guard attempt-pending, no latch" '[[ "$OUT" == *"guards: attempt-pending"* ]] && [[ "$(state_raw latch)" -eq 0 && "$(reboots)" -eq 1 ]]'
attempt; advance 10800; run check
check "unresolved attempt, boot id unchanged: latched as reboot did not happen" '[[ "$OUT" == *"guards: latched"* && "$(state_raw latch)" -eq 1 && "$(reboots)" -eq 1 ]] && audit_line_of alert | grep -q "\"detail\":\"latched: reboot did not happen"'
attempt; after_reboot; advance 10800; trigger_rr; run check
check "unresolved attempt, rebooted but no post-boot result: latched as post-boot verification missing" '[[ "$OUT" == *"guards: latched"* && "$(state_raw latch)" -eq 1 && "$(reboots)" -eq 1 ]] && audit_line_of alert | grep -q "post-boot verification missing"'
attempt; after_reboot; advance 10800; run check
check "an unresolved attempt latches even when no trigger is left" '[[ "$(state_raw latch)" -eq 1 ]]'
attempt; after_reboot; run post-boot; night; trigger_kernel; run check
check "a successful post-boot result makes the host eligible again" '[[ "$(reboots)" -eq 2 && "$(state_raw latch)" -eq 0 && "$OUT" == *"decision: reboot"* ]]'
attempt; after_reboot; run post-boot; night; trigger_rr; printf 'linux-image-7.0.0-40\n' >"$RR_FILE.pkgs"; run check
check "a second reboot-required episode with different packages reboots after a good first one" '[[ "$(reboots)" -eq 2 && "$(state_raw latch)" -eq 0 ]]'

# --- health: the daily post-update check -------------------------------------------------------------------------------------
reset; run health
check "health without a baseline compares nothing, audits nothing, exit 0" '[[ "$RC" -eq 0 && "$OUT" == *"no pre-update baseline"* && "$(audit_count)" -eq 0 ]]'
reset; run check; N0=$(audit_count); advance 18000; run health
check "health ok: silent, nothing audited, nothing notified" '[[ "$RC" -eq 0 && "$OUT" == *"health: ok"* && "$(audit_count)" -eq "$N0" && "$(notice_count)" -eq 0 && "$(state_raw health_action)" == "\"health-ok\"" ]]'
set_running system alpha.service; advance 3600; run health
check "health regression: a service gone after the updates is audited as health-issues and alerted" '[[ "$(audit_actions)" == "none health-issues " ]] && audit_line_of health-issues | grep -q "system services not running again: beta.service" && notice_has "ALERT node-a: post-update health check found issues"'
N1=$(notice_count); A1=$(audit_count); advance 86400; run health
check "health: the same issue on the next day is not re-audited or re-alerted" '[[ "$(audit_count)" -eq "$A1" && "$(notice_count)" -eq "$N1" ]]'
set_failed system broken.service; advance 7200; run health
check "health: a changed set of issues is audited and alerted again" '[[ "$(audit_count)" -eq $((A1 + 1)) && "$(notice_count)" -eq $((N1 + 1)) ]] && audit_last | grep -q "failed system units: broken.service"'
set_running system alpha.service beta.service; set_failed system; advance 7200; run health
check "health recovery: audited once as health-ok" '[[ "$(audit_actions)" == "none health-issues health-issues health-ok " ]]'
advance 7200; run health
check "health: staying ok afterwards audits nothing" '[[ "$(audit_actions)" == "none health-issues health-issues health-ok " ]]'
check "health: the audit lines keep the agreed shape (empty triggers and guards)" 'audit_line_of health-ok | grep -q "\"triggers\":\"\",\"guards\":\"\",\"boot_id\":\"$BID1\""'

reset; run check; set_failed user bad.service; advance 3600; run health
check "health: a failed user unit is an issue" 'audit_line_of health-issues | grep -q "failed user units: bad.service"'
reset; run check; set_running system alpha.service; show_fixture system beta.service "Type=dbus" "BusName=" "UnitFileState=enabled" "TriggeredBy="; advance 3600; run health
check "health ignores on-demand units as post-boot does" '[[ "$(audit_actions)" == "none " ]]'
reset; run check; advance 259200; run health
check "health: a baseline older than two days means the nightly check stopped, audited" 'audit_line_of health-issues | grep -q "pre-update baseline is stale"'
reset; run check; : >"$SD/failed-fail.system"; advance 3600; run health
check "health: failed units that cannot be queried are an issue" 'audit_line_of health-issues | grep -q "cannot query the failed system units"'
reset; run check; set_running system alpha.service; night; run check; advance 3600; run health
check "the nightly check refreshes the baseline, so yesterday's removal is the new normal" '[[ "$(audit_actions)" == "none " ]]'
reset; run check; : >"$MOCK/audit-fail"; set_failed system oops.service; advance 3600; run health
check "health: an audit failure is exit 1 but the alert still goes out" '[[ "$RC" -eq 1 ]] && notice_has "post-update health check found issues"'

# --- status ----------------------------------------------------------------------------------------------------------------------------
reset; reboot_mode; trigger_rr; BROKKR_GUARDED_REBOOT_BUSY_UNITS=hugin.service BROKKR_GUARDED_REBOOT_PEERS=node-b.example run check; run status
check "status prints mode, limits, units, peers and the attempt" '[[ "$RC" -eq 0 && "$OUT" == *"configured mode: reboot"* && "$OUT" == *"busy units: (none)"* ]] && [[ "$OUT" == *"last reboot attempt:"*"status=unresolved"* && "$OUT" == *"latch: off"* ]]'
BROKKR_GUARDED_REBOOT_BUSY_UNITS=hugin.service BROKKR_GUARDED_REBOOT_PEERS=node-b.example run status
check "status shows the configured busy units and peers" '[[ "$OUT" == *"busy units: hugin.service; peers: node-b.example"* ]]'
reset; : >"$KILL"; run status
check "status shows a present kill switch" '[[ "$OUT" == *"kill switch: PRESENT"* ]]'
reset; echo "recovery 1790000000" >"$PENDING_FLAG"; run status
check "status states that a staged EEPROM update applies at the next boot and that the kill switch does not cancel it" '[[ "$OUT" == *"bootloader update is STAGED"* && "$OUT" == *"next boot of any kind"* && "$OUT" == *"kill"*"does not cancel it"* ]]'
check "status names the ADR-009 way to suspend firmware writes and to cancel a staged update" '[[ "$OUT" == *"suspended only when nothing is staged"* && "$OUT" == *"kill switch"* && "$OUT" == *"rpi-eeprom-update.service"* && "$OUT" == *"sudo rpi-eeprom-update -r"* && "$OUT" != *"apt-mark hold rpi-eeprom and/or"* ]]'
check "status points at the power-interruption risk and the recovery image" '[[ "$OUT" == *"power-interruption"* && "$OUT" == *"recovery image"* ]]'
check "status never runs a privileged command" '! grep -q "^sudo" "$CALLS"'
reset; with_eeprom; run status
check "status on an EEPROM host with nothing staged says so" '[[ "$OUT" == *"no update is staged"* ]]'
reset; run status
check "status on a host without rpi-eeprom-update prints no EEPROM line" '[[ "$OUT" != *EEPROM* ]]'

# --- the real notify helper (scripts/lib/notify.sh) behind a curl stub ---------------------------------------------------------
cat >"$BIN/curl" <<'FAKE'
#!/bin/bash
cfg=$(cat)
printf 'curl %s\n' "$*" >>"$MOCK_CALLS"
case "$cfg" in *fake-bot-token*) echo "token-in-config" >>"$MOCK_DIR/curl-config" ;; esac
case "$*" in *"-w %{http_code}"*) printf '%s' "${MOCK_CURL_CODE:-200}" ;; esac
FAKE
chmod 755 "$BIN/curl"
real_notify() {
  export BROKKR_NOTIFY_HELPER="$ROOT/scripts/lib/notify.sh" RATATOSKR_ENV="$TMP/no-ratatoskr.env" NOTIFY_ENV="$TMP/no-notify.env"
  export TELEGRAM_ALLOWED_USERS=123456789 TELEGRAM_BOT_TOKEN=fake-bot-token
}
reset; real_notify; reboot_mode; trigger_rr; run check
check "real notify.sh: a confirmed delivery lets the reboot go ahead" '[[ "$RC" -eq 0 && "$(reboots)" -eq 1 ]] && grep -q "^curl " "$CALLS" && [[ -s "$MOCK/curl-config" ]]'
check "real notify.sh: the bot token never appears in curl arguments" '! grep "^curl " "$CALLS" | grep -q "fake-bot-token"'
reset; real_notify; reboot_mode; trigger_rr; MOCK_CURL_CODE=503 run check
check "real notify.sh: an HTTP failure counts as not delivered and stops the reboot" '[[ "$RC" -eq 0 && "$(reboots)" -eq 0 && "$OUT" == *"guards: notify"* ]]'
reset; real_notify; unset TELEGRAM_BOT_TOKEN; reboot_mode; trigger_rr; run check
check "real notify.sh: no configured destination is not a delivery, so reboot mode stays put" '[[ "$(reboots)" -eq 0 && "$OUT" == *"guards: notify"* ]]'
reset; real_notify; trigger_rr; MOCK_CURL_CODE=503 run check
check "real notify.sh: in report mode a failed notice is only logged" '[[ "$RC" -eq 0 && "$OUT" == *"decision: would-reboot"* ]]'
unset RATATOSKR_ENV NOTIFY_ENV TELEGRAM_ALLOWED_USERS TELEGRAM_BOT_TOKEN
rm -f "$BIN/curl"

# --- the sandbox held ------------------------------------------------------------------------------------------------------------------
reset; reboot_mode; trigger_rr; trigger_kernel; eeprom_available; run check; night; run check; run status; run health
check "across a full run no stub saw a command outside the fixed lists" 'no_unexpected'
check "the real sudo and systemctl were never reachable: every sudo and systemctl call went to a stub" '[[ "$(PATH="$BIN:$TOOLS" type -P sudo)" == "$BIN/sudo" && "$(PATH="$BIN:$TOOLS" type -P systemctl)" == "$BIN/systemctl" ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
