#!/usr/bin/env bash
# Brokkr · guarded reboot (Grimnir ADR-009, "Host OS updates and guarded reboots").
# Runs ON a Linux host as the operator user, from systemd user timers installed by
# scripts/deploy-guarded-reboot.sh. See docs/guarded-reboot.md.
#
#   guarded-reboot.sh [check] [--report-only]   nightly decision (the default)
#   guarded-reboot.sh post-boot                 health check ~10 min after a guarded reboot
#   guarded-reboot.sh health                    daily check that the night's updates broke nothing
#   guarded-reboot.sh status                    print the state, latch and EEPROM notes
#   guarded-reboot.sh clear-latch               owner action: re-allow automatic reboots (audited)
#
# Deterministic by design: no model decides anything here. The only privileged actions are
# `sudo -n` with constant argument lists: `rpi-eeprom-update -j -m /run/brokkr-guarded-reboot-eeprom.json`
# (status), `rpi-eeprom-update -a` (stage) and `-r` (cancel), `tee -a /var/lib/brokkr/guarded-reboot/audit.jsonl`
# and `systemctl reboot`. No environment variable changes any of those arguments, and nothing
# fetched or read from a file is ever interpolated into a command. Exit 0: normal, including
# deferred / report / no trigger. Exit 1: internal failure (state or audit write failure,
# unreadable required input). Exit 64: usage or configuration.
#
# Runs under bash 3.2 and 5: no associative arrays, mapfile, ${x,,}, namerefs or wait -n.
set -euo pipefail
# Parsing tool output and writing JSON by bytes needs the C locale.
export LC_ALL=C

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
PROG="brokkr guarded-reboot"

die() { echo "$PROG: $*" >&2; exit 64; }
fatal() { echo "$PROG: $*" >&2; exit 1; }
log() { echo "$PROG: $*"; }
warn() { echo "$PROG: $*" >&2; }

usage_text() {
  echo "usage: $0 [check|post-boot|health|status|clear-latch] [--report-only]"
  echo "  check        the nightly decision (default); --report-only forces report mode for this run"
  echo "  post-boot    health check after a guarded reboot"
  echo "  health       daily check that updates did not break a service"
  echo "  status       print the state; clear-latch re-allows automatic reboots (audited)"
  echo "  env: BROKKR_GUARDED_REBOOT_MODE (report|reboot, default report),"
  echo "       BROKKR_GUARDED_REBOOT_BUSY_UNITS (space-separated systemd user .service units),"
  echo "       BROKKR_GUARDED_REBOOT_MAX_LOAD (default 0.75 x CPUs), BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN (60),"
  echo "       BROKKR_GUARDED_REBOOT_ALERT_AFTER (3), BROKKR_GUARDED_REBOOT_PEERS (hosts that must answer on port 22),"
  echo "       BROKKR_STATE_DIR (default \${XDG_STATE_HOME:-~/.local/state}/brokkr)"
}
usage() { usage_text >&2; exit 64; }

CMD=
REPORT_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-only) REPORT_ONLY=1 ;;
    -h|--help) usage_text; exit 0 ;;
    check|post-boot|health|status|clear-latch)
      [ -z "$CMD" ] || usage
      CMD=$1 ;;
    *) usage ;;
  esac
  shift
done
[ -n "$CMD" ] || CMD=check

[ "$(uname -s 2>/dev/null || true)" = Linux ] || die "Linux only (uname -s did not report Linux)"

# --- configuration (validated before anything runs) --------------------------------------------
MODE=${BROKKR_GUARDED_REBOOT_MODE:-report}
case "$MODE" in
  report|reboot) ;;
  *) die "invalid BROKKR_GUARDED_REBOOT_MODE (report or reboot)" ;;
esac
if [ "$REPORT_ONLY" -eq 1 ]; then MODE=report; fi

# A unit name must not start with '-': it is passed to systemctl as a plain argument.
UNIT_RE='^[A-Za-z0-9@_.][A-Za-z0-9@._-]*\.service$'
BUSY_RAW=${BROKKR_GUARDED_REBOOT_BUSY_UNITS:-}
case "$BUSY_RAW" in
  *[!A-Za-z0-9@._\ -]*) die "invalid BROKKR_GUARDED_REBOOT_BUSY_UNITS (space-separated .service unit names)" ;;
esac
# The charset above has no glob characters, so the unquoted expansion only splits on spaces.
BUSY_LIST=
for word in $BUSY_RAW; do
  [[ "$word" =~ $UNIT_RE ]] || die "invalid BROKKR_GUARDED_REBOOT_BUSY_UNITS entry '$word' (a .service unit name is required)"
  BUSY_LIST="${BUSY_LIST:+$BUSY_LIST }$word"
done

# Peers: hosts that must accept a TCP connection on port 22 before this host may reboot, so a host
# never goes down while the host that monitors it (or its alert path) is already down.
PEERS_RAW=${BROKKR_GUARDED_REBOOT_PEERS:-}
case "$PEERS_RAW" in
  *[!A-Za-z0-9.\ -]*) die "invalid BROKKR_GUARDED_REBOOT_PEERS (space-separated host names)" ;;
esac
PEER_LIST=
for word in $PEERS_RAW; do
  [[ "$word" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "invalid BROKKR_GUARDED_REBOOT_PEERS entry '$word' (a host name is required)"
  [ "${#word}" -le 253 ] || die "invalid BROKKR_GUARDED_REBOOT_PEERS entry (longer than 253 characters)"
  PEER_LIST="${PEER_LIST:+$PEER_LIST }$word"
done

cpu_count() {
  local n
  n=$(nproc 2>/dev/null) || n=
  case "$n" in ''|*[!0-9]*) n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n= ;; esac
  case "$n" in ''|*[!0-9]*|0) n=1 ;; esac
  printf '%s' "$n"
}
MAX_LOAD=${BROKKR_GUARDED_REBOOT_MAX_LOAD:-}
if [ -n "$MAX_LOAD" ]; then
  [[ "$MAX_LOAD" =~ ^[0-9]{1,4}(\.[0-9]{1,3})?$ ]] || die "invalid BROKKR_GUARDED_REBOOT_MAX_LOAD (a decimal such as 1.5)"
else
  MAX_LOAD=$(awk -v n="$(cpu_count)" 'BEGIN { printf "%.2f", n * 0.75 }')
fi

TTY_IDLE_MIN=${BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN:-60}
if ! [[ "$TTY_IDLE_MIN" =~ ^[0-9]{1,4}$ ]] || [ "$((0 + 10#$TTY_IDLE_MIN))" -gt 1440 ]; then
  die "invalid BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN (minutes, 0 to 1440; 0 disables the terminal guard)"
fi
TTY_IDLE_MIN=$((0 + 10#$TTY_IDLE_MIN))
ALERT_AFTER=${BROKKR_GUARDED_REBOOT_ALERT_AFTER:-3}
if ! [[ "$ALERT_AFTER" =~ ^[0-9]{1,3}$ ]] || [ "$((0 + 10#$ALERT_AFTER))" -lt 1 ] || [ "$((0 + 10#$ALERT_AFTER))" -gt 365 ]; then
  die "invalid BROKKR_GUARDED_REBOOT_ALERT_AFTER (deferred nights before alerting, 1 to 365)"
fi
ALERT_AFTER=$((0 + 10#$ALERT_AFTER))

if [ -n "${BROKKR_NOW_EPOCH+set}" ]; then
  [[ "$BROKKR_NOW_EPOCH" =~ ^[0-9]{1,12}$ ]] || die "invalid BROKKR_NOW_EPOCH (epoch seconds)"
  NOW=$((0 + 10#$BROKKR_NOW_EPOCH))
else
  NOW=$(date +%s)
fi

# Kernel interface defaults (kept apart so the paths read as plain constants).
DEFAULT_BOOT_ID_FILE=/proc/sys/kernel/random/boot_id
DEFAULT_LOADAVG_FILE=/proc/loadavg

# Privileged arguments are constants. No environment variable changes any argument of a sudo
# invocation: the audit file and the file rpi-eeprom-update writes its status to are fixed paths
# (/run is writable by root only). The tests put a stub sudo on PATH that maps these constants into
# their fixture tree; EEPROM_STATUS_READ below is only where the result is READ from, unprivileged.
AUDIT_FILE=/var/lib/brokkr/guarded-reboot/audit.jsonl
EEPROM_STATUS_FILE=/run/brokkr-guarded-reboot-eeprom.json

# Paths read or tested here are absolute and plain.
need_path() { # name value
  case "$2" in /*) ;; *) die "$1 must be an absolute path" ;; esac
  case "$2" in
    *[!A-Za-z0-9._/@:+-]*) die "$1 contains unsupported characters" ;;
    *//*|*/./*|*/../*|*/.|*/..) die "$1 must not contain empty, . or .. components" ;;
  esac
}
BOOT_DIR=${BROKKR_BOOT_DIR:-/boot}
REBOOT_REQUIRED_FILE=${BROKKR_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}
CRYPTTAB=${BROKKR_CRYPTTAB:-/etc/crypttab}
KILL_SWITCH=${BROKKR_KILL_SWITCH:-/etc/brokkr/guarded-reboot.disabled}
CGROUP_ROOT=${BROKKR_CGROUP_ROOT:-/sys/fs/cgroup}
EEPROM_PENDING_FLAG=${BROKKR_EEPROM_PENDING_FLAG:-/run/rpi-eeprom-update-pending}
EEPROM_STATUS_READ=${BROKKR_EEPROM_STATUS_FILE:-}
if [ -z "$EEPROM_STATUS_READ" ]; then EEPROM_STATUS_READ=$EEPROM_STATUS_FILE; fi
BOOT_ID_FILE=${BROKKR_BOOT_ID_FILE:-}
if [ -z "$BOOT_ID_FILE" ]; then BOOT_ID_FILE=$DEFAULT_BOOT_ID_FILE; fi
LOADAVG_FILE=${BROKKR_LOADAVG_FILE:-}
if [ -z "$LOADAVG_FILE" ]; then LOADAVG_FILE=$DEFAULT_LOADAVG_FILE; fi
NOTIFY_HELPER=${BROKKR_NOTIFY_HELPER:-}
if [ -z "$NOTIFY_HELPER" ]; then NOTIFY_HELPER="$SELF_DIR/lib/notify.sh"; fi
STATE_DIR=${BROKKR_STATE_DIR:-}
if [ -z "$STATE_DIR" ]; then
  case "${HOME:-}" in /*) ;; *) die "HOME must be set to an absolute path (or set BROKKR_STATE_DIR)" ;; esac
  STATE_DIR=${XDG_STATE_HOME:-}
  if [ -z "$STATE_DIR" ]; then STATE_DIR="$HOME/.local/state"; fi
  STATE_DIR="$STATE_DIR/brokkr"
fi
need_path BROKKR_BOOT_DIR "$BOOT_DIR"
need_path BROKKR_REBOOT_REQUIRED_FILE "$REBOOT_REQUIRED_FILE"
need_path BROKKR_CRYPTTAB "$CRYPTTAB"
need_path BROKKR_KILL_SWITCH "$KILL_SWITCH"
need_path BROKKR_BOOT_ID_FILE "$BOOT_ID_FILE"
need_path BROKKR_LOADAVG_FILE "$LOADAVG_FILE"
need_path BROKKR_CGROUP_ROOT "$CGROUP_ROOT"
need_path BROKKR_EEPROM_PENDING_FLAG "$EEPROM_PENDING_FLAG"
need_path BROKKR_EEPROM_STATUS_FILE "$EEPROM_STATUS_READ"
need_path BROKKR_NOTIFY_HELPER "$NOTIFY_HELPER"
need_path BROKKR_STATE_DIR "$STATE_DIR"
STATE_FILE=$STATE_DIR/guarded-reboot.json

# Deferred nights count once per DEFER_GAP, so a manual run the morning after does not count as a
# second night. An attempt younger than ATTEMPT_GRACE is still waiting for its post-boot result.
DEFER_GAP=43200
ATTEMPT_GRACE=7200
BASELINE_STALE_SECS=172800

# --- text helpers --------------------------------------------------------------------------------
# Everything that reaches the state file or the audit file is reduced to this set first, so the
# state file can be validated on read and a hostile package or unit name cannot inject structure.
SAFE_CHARS='A-Za-z0-9:,._@+=~() /;-'
safe_text() { printf '%s' "$1" | tr -c "$SAFE_CHARS" '?'; }
bound() { # text max
  if [ "${#1}" -gt "$2" ]; then printf '%s...' "${1:0:$((0 + $2 - 3))}"; else printf '%s' "$1"; fi
}
clean() { safe_text "$(bound "$1" "${2:-400}")"; } # sanitised and bounded
# Assigns to a variable named by an internal caller (never by data).
set_var() { eval "$1=\$2"; }

# JSON strings in pure shell: escape backslash, double quote and every control character as a
# u00XX sequence. The fast path covers the usual text; anything else is walked byte by byte.
JSTR=
json_str() {
  local s=$1 out='' c i=0 n code
  case "$s" in
    *[!A-Za-z0-9\ ._:@/+,\;=\(\)-]*) ;;
    *) JSTR="\"$s\""; return 0 ;;
  esac
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    case "$c" in
      '\') out="$out\\\\" ;;
      '"') out="$out\\\"" ;;
      [[:cntrl:]])
        code=$(printf '%d' "'$c")
        out="$out$(printf '\\u%04x' "$code")" ;;
      *) out="$out$c" ;;
    esac
    i=$((i + 1))
  done
  JSTR="\"$out\""
}

# ISO-8601 UTC from epoch seconds, in pure shell (civil-from-days), so the clock seam is exact.
iso_utc() {
  local t=$1 days secs z era doe yoe y doy mp d m
  days=$((t / 86400)); secs=$((t % 86400))
  z=$((days + 719468)); era=$((z / 146097)); doe=$((z - era * 146097))
  yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
  y=$((yoe + era * 400)); doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
  mp=$(((5 * doy + 2) / 153)); d=$((doy - (153 * mp + 2) / 5 + 1))
  if [ "$mp" -lt 10 ]; then m=$((mp + 3)); else m=$((mp - 9)); fi
  if [ "$m" -le 2 ]; then y=$((y + 1)); fi
  printf '%04d-%02d-%02dT%02d:%02d:%02dZ' "$y" "$m" "$d" $((secs / 3600)) $((secs % 3600 / 60)) $((secs % 60))
}

HOST=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)
HOST=$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9._-' '?' | cut -c1-100)
[ -n "$HOST" ] || HOST=unknown
TS=$(iso_utc "$NOW")

BOOT_ID=
read_boot_id() {
  local raw
  [ -f "$BOOT_ID_FILE" ] && [ -r "$BOOT_ID_FILE" ] || fatal "cannot read the boot id ($BOOT_ID_FILE)"
  raw=$(tr -d '[:space:]' <"$BOOT_ID_FILE") || fatal "cannot read the boot id ($BOOT_ID_FILE)"
  [[ "$raw" =~ ^[0-9A-Za-z-]{8,64}$ ]] || fatal "the boot id in $BOOT_ID_FILE is not a plain identifier"
  BOOT_ID=$raw
}

# --- state file ----------------------------------------------------------------------------------
# The operator's own JSON, written atomically at mode 0600. Scalars are one `  "key": value,` line
# each; the two baseline lists close the object. It is read back with fixed patterns and every
# value is validated, so a damaged file is refused (exit 1) instead of guessed at.
E_FIRST=0; E_DEFERRALS=0; E_LAST_COUNTED=0; E_ALERTED=0; E_REPORTED=0; E_UNLOCK_ALERTED=0
LATCH=0; LATCH_SINCE=0; LATCH_REASON=
# The last guarded-reboot attempt: its boot id, time, triggers, trigger identities and status
# (none, unresolved, ok, issues, cleared). unresolved means no post-boot result is recorded yet.
A_BOOT_ID=; A_EPOCH=0; A_TRIGGERS=; A_IDS=; A_STATUS=none
# Issues a post-boot check observed whose outcome record could not be appended to the audit file.
# They are kept (with the latch) while the attempt stays unresolved, so a later healthy retry cannot
# turn the attempt into a pass; only clear-latch drops them.
A_OBSERVED=
BASE_EPOCH=0; BASE_BOOT_ID=; BASE_SYS=; BASE_USER=
H_EPOCH=0; H_ACTION=; H_SIG=
W_TS=; W_EPOCH=0; W_ACTION=; W_TRIGGERS=; W_GUARDS=; W_DETAIL=
STATE_PRESENT=0
PREV_ACTION=

bad_state() { fatal "state file $STATE_FILE is unreadable or invalid (field $1); inspect it or remove it"; }
st_raw() { sed -n 's/^  "'"$1"'": \(.*\),$/\1/p' "$STATE_FILE" | head -n 1; }
load_int() { # var key
  local v
  v=$(st_raw "$2")
  [[ "$v" =~ ^[0-9]{1,12}$ ]] || bad_state "$2"
  set_var "$1" "$((0 + 10#$v))"
}
load_str() { # var key
  # Everything safe_text can emit: SAFE_CHARS and the ? it substitutes for any other character.
  local v re='^"([A-Za-z0-9:,._@+=~() /;?-]*)"$'
  v=$(st_raw "$2")
  [[ "$v" =~ $re ]] || bad_state "$2"
  set_var "$1" "${BASH_REMATCH[1]}"
}
load_str_opt() { # var key: like load_str, but a key the file does not have yet is empty
  if [ -z "$(st_raw "$2")" ]; then set_var "$1" ""; else load_str "$1" "$2"; fi
}
state_array() { # key -> one unescaped item per line
  awk -v start="  \"$1\": [" '
    $0 == start { on = 1; next }
    on && /^  \],?$/ { exit }
    on { sub(/^    "/, ""); sub(/",?$/, ""); print }
  ' "$STATE_FILE" | sed 's/\\\\/\\/g'
}
UNIT_NAME_RE='^[A-Za-z0-9:_.@\\-]+\.service$'
load_units() { # var key
  local list item
  list=$(state_array "$2")
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    [[ "$item" =~ $UNIT_NAME_RE ]] || bad_state "$2"
  done <<<"$list"
  set_var "$1" "$list"
}

load_state() {
  local schema
  PREV_ACTION=
  if [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; then return 0; fi
  if [ ! -f "$STATE_FILE" ] || [ -L "$STATE_FILE" ] || [ ! -r "$STATE_FILE" ]; then
    fatal "state file $STATE_FILE is not a readable regular file"
  fi
  STATE_PRESENT=1
  load_int schema schema
  [ "$schema" -eq 1 ] || bad_state schema
  load_str W_TS timestamp; load_int W_EPOCH epoch; load_str W_ACTION action
  load_str W_TRIGGERS triggers; load_str W_GUARDS guards; load_str W_DETAIL detail
  load_int E_FIRST episode_first_seen; load_int E_DEFERRALS episode_deferrals
  load_int E_LAST_COUNTED episode_last_counted; load_int E_ALERTED episode_alerted
  load_int E_REPORTED episode_reported; load_int E_UNLOCK_ALERTED episode_unlock_alerted
  load_int LATCH latch; load_int LATCH_SINCE latch_since; load_str LATCH_REASON latch_reason
  load_str A_BOOT_ID attempt_boot_id; load_int A_EPOCH attempt_epoch
  load_str A_TRIGGERS attempt_triggers; load_str A_IDS attempt_identities
  load_str A_STATUS attempt_status
  case "$A_STATUS" in none|unresolved|ok|issues|cleared) ;; *) bad_state attempt_status ;; esac
  load_str_opt A_OBSERVED attempt_observed
  load_int BASE_EPOCH baseline_epoch; load_str BASE_BOOT_ID baseline_boot_id
  load_int H_EPOCH health_epoch; load_str H_ACTION health_action; load_str H_SIG health_sig
  load_units BASE_SYS baseline_system; load_units BASE_USER baseline_user
  PREV_ACTION=$W_ACTION
}

kv_str() { json_str "$2"; printf '  "%s": %s,\n' "$1" "$JSTR"; }
kv_int() { printf '  "%s": %s,\n' "$1" "$2"; }
kv_list() { # key list closing
  local line sep=
  if [ -z "$2" ]; then printf '  "%s": []%s\n' "$1" "$3"; return 0; fi
  printf '  "%s": [\n' "$1"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -n "$sep" ]; then printf ',\n'; fi
    json_str "$line"; printf '    %s' "$JSTR"
    sep=1
  done <<<"$2"
  printf '\n  ]%s\n' "$3"
}
render_state_json() {
  printf '{\n'
  kv_int schema 1
  kv_str timestamp "$W_TS"; kv_int epoch "$W_EPOCH"; kv_str hostname "$HOST"; kv_str mode "$MODE"
  kv_str action "$W_ACTION"; kv_str triggers "$W_TRIGGERS"; kv_str guards "$W_GUARDS"
  kv_str boot_id "$BOOT_ID"; kv_str detail "$W_DETAIL"
  kv_int episode_first_seen "$E_FIRST"; kv_int episode_deferrals "$E_DEFERRALS"
  kv_int episode_last_counted "$E_LAST_COUNTED"; kv_int episode_alerted "$E_ALERTED"
  kv_int episode_reported "$E_REPORTED"; kv_int episode_unlock_alerted "$E_UNLOCK_ALERTED"
  kv_int latch "$LATCH"; kv_int latch_since "$LATCH_SINCE"; kv_str latch_reason "$LATCH_REASON"
  kv_str attempt_boot_id "$A_BOOT_ID"; kv_int attempt_epoch "$A_EPOCH"
  kv_str attempt_triggers "$A_TRIGGERS"; kv_str attempt_identities "$A_IDS"
  kv_str attempt_status "$A_STATUS"; kv_str attempt_observed "$A_OBSERVED"
  kv_int baseline_epoch "$BASE_EPOCH"; kv_str baseline_boot_id "$BASE_BOOT_ID"
  kv_int health_epoch "$H_EPOCH"; kv_str health_action "$H_ACTION"; kv_str health_sig "$H_SIG"
  kv_list baseline_system "$BASE_SYS" ,
  kv_list baseline_user "$BASE_USER" ''
  printf '}\n'
}
STATE_TMP=
cleanup() {
  if [ -n "$STATE_TMP" ]; then rm -f "$STATE_TMP"; STATE_TMP=''; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Written atomically (temp file in the same directory, then rename) and privately.
write_state() {
  local tmp
  (umask 077; mkdir -p "$STATE_DIR") || return 1
  tmp=$(umask 077; mktemp "$STATE_DIR/.guarded-reboot.json.XXXXXX") || return 1
  STATE_TMP=$tmp
  if ! render_state_json >"$tmp"; then rm -f "$tmp"; STATE_TMP=; return 1; fi
  if ! mv -f "$tmp" "$STATE_FILE"; then rm -f "$tmp"; STATE_TMP=; return 1; fi
  STATE_TMP=
}

set_event() { # action triggers guards detail
  W_TS=$TS; W_EPOCH=$NOW; W_ACTION=$1; W_TRIGGERS=$2; W_GUARDS=$3
  W_DETAIL=$(clean "$4" 400)
  EV_TRIGGERS=$W_TRIGGERS; EV_GUARDS=$W_GUARDS
}

episode_reset() {
  E_FIRST=0; E_DEFERRALS=0; E_LAST_COUNTED=0; E_ALERTED=0; E_REPORTED=0; E_UNLOCK_ALERTED=0
}

# --- audit and notices ---------------------------------------------------------------------------
# One JSON object per line, key order fixed (another component parses it with sed/awk), appended
# through the one fixed privileged command `sudo -n tee -a <audit file>` under umask 022 so the
# file stays world-readable. A failed append is returned, never swallowed.
EV_TRIGGERS=
EV_GUARDS=
audit_append() { # action detail   (triggers and guards come from EV_TRIGGERS / EV_GUARDS)
  local detail j1 j2 j3 j4 j5 j6 j7 j8 line
  detail=$(clean "$2" 400)
  json_str "$TS"; j1=$JSTR
  json_str "$HOST"; j2=$JSTR
  json_str "$MODE"; j3=$JSTR
  json_str "$1"; j4=$JSTR
  json_str "$EV_TRIGGERS"; j5=$JSTR
  json_str "$EV_GUARDS"; j6=$JSTR
  json_str "$BOOT_ID"; j7=$JSTR
  json_str "$detail"; j8=$JSTR
  line=$(printf '{"ts":%s,"epoch":%s,"host":%s,"mode":%s,"action":%s,"triggers":%s,"guards":%s,"boot_id":%s,"detail":%s}' \
    "$j1" "$NOW" "$j2" "$j3" "$j4" "$j5" "$j6" "$j7" "$j8")
  if ! printf '%s\n' "$line" | (umask 022; sudo -n tee -a "$AUDIT_FILE" >/dev/null); then
    warn "cannot append to the audit file $AUDIT_FILE"
    return 1
  fi
}

# Delivered through scripts/lib/notify.sh. Returns 0 only when delivery was confirmed; any
# failure is logged and returned so a caller that must not act on a lost alert can stop.
send_notice() { # message
  local msg
  msg=$(clean "$1" 500)
  # The helper is sourced, so it is code: a regular, non-symlink file owned by the current user
  # that no one else can write.
  if [ ! -f "$NOTIFY_HELPER" ] || [ -L "$NOTIFY_HELPER" ] || [ ! -O "$NOTIFY_HELPER" ] \
    || [ -n "$(find "$NOTIFY_HELPER" -maxdepth 0 \( -perm -020 -o -perm -002 \) -print 2>/dev/null)" ]; then
    warn "notify helper $NOTIFY_HELPER is missing, a symlink, not owned by this user or writable by others; not sent: $msg"
    return 1
  fi
  if ! (
    # shellcheck source=scripts/lib/notify.sh
    source "$NOTIFY_HELPER" || exit 1
    [ "$(type -t notify_telegram_confirmed)" = function ] || exit 1
    notify_telegram_confirmed "$msg"
  ) </dev/null; then
    warn "notice not delivered: $msg"
    return 1
  fi
}

ALERTS=
NOTICES=
RC=0
queue_alert() { ALERTS="$ALERTS$1"$'\n'; }    # audited as `alert`, then notified
queue_notice() { NOTICES="$NOTICES$1"$'\n'; } # notified only
flush_queues() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    audit_append alert "$line" || RC=1
    send_notice "ALERT $HOST: $line" || true
  done <<<"$ALERTS"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    send_notice "$line" || true
  done <<<"$NOTICES"
  ALERTS=; NOTICES=
}

# --- trigger detection ---------------------------------------------------------------------------
# A trigger has an id and an identity. The identity says WHICH reboot-worthy thing is pending, so
# "the same trigger survived the reboot" is told apart from "a new one arrived":
#   reboot-required  sha256 of the sorted .pkgs content (the flag file mtime without a .pkgs)
#   kernel           the expected newest kernel of the running flavour
#   eeprom           the newest available bootloader version (a timestamp) from rpi-eeprom-update
TRIG_IDS=; TRIG_PAIRS=; TRIG_DETAIL=; TRIG_NOTE=; TRIG_ERR=; RUNNING_KERNEL=
add_trigger() { # id identity detail
  local ident
  ident=$(printf '%s' "$2" | tr -c 'A-Za-z0-9.+_~:-' '?' | cut -c1-80)
  [ -n "$ident" ] || ident=unknown
  TRIG_IDS="${TRIG_IDS:+$TRIG_IDS,}$1"
  TRIG_PAIRS="${TRIG_PAIRS:+$TRIG_PAIRS,}$1=$ident"
  TRIG_DETAIL="${TRIG_DETAIL:+$TRIG_DETAIL; }$3"
}
add_note() { TRIG_NOTE="${TRIG_NOTE:+$TRIG_NOTE; }$1"; }

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{ print $1 }'
  else cksum | awk '{ print "cksum" $1 "-" $2 }'; fi
}
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

reboot_flag_present() { [ -e "$REBOOT_REQUIRED_FILE" ] || [ -L "$REBOOT_REQUIRED_FILE" ]; }
# The identity of the pending reboot-required flag: sha256 of the sorted .pkgs content, else the
# flag file's mtime. Same sanitising as add_trigger, so it compares with a recorded identity.
reboot_flag_identity() {
  local pkgs_file="$REBOOT_REQUIRED_FILE.pkgs" ident
  if [ -f "$pkgs_file" ] && [ -r "$pkgs_file" ]; then
    ident=$(sort "$pkgs_file" | hash_stdin) || ident=unknown
  else
    ident=$(file_mtime "$REBOOT_REQUIRED_FILE") || ident=
    ident="mtime-${ident:-unknown}"
  fi
  printf '%s' "$ident" | tr -c 'A-Za-z0-9.+_~:-' '?' | cut -c1-80
}

detect_reboot_required() {
  local pkgs_file="$REBOOT_REQUIRED_FILE.pkgs" ident names=''
  reboot_flag_present || return 0
  ident=$(reboot_flag_identity)
  if [ -f "$pkgs_file" ] && [ -r "$pkgs_file" ]; then
    names=$(head -n 20 "$pkgs_file" | tr -c 'A-Za-z0-9.+:_\n-' '?' | sort -u | head -n 8 | tr '\n' ',' | sed 's/,$//') || names=
  fi
  add_trigger reboot-required "$ident" "reboot-required flag present${names:+ (packages: $(bound "$names" 120))}"
}

# The flavour of a kernel release (shared rule, identical in the maintenance report): the version
# part is the longest prefix matching ^[0-9]+(\.[0-9]+)*(\+[a-z0-9]+)?(-[0-9]+)? and the flavour is
# everything after the - that follows it. 7.0.0-38-generic is generic, 6.12.48+deb13-amd64 is
# amd64, 6.12.48+deb13-rt-amd64 is rt-amd64, 6.18.50+rpt-rpi-2712 is rpi-2712 (rpi-v8 is another).
# Prints nothing when the release has no flavour.
KERNEL_VERSION_RE='^[0-9]+(\.[0-9]+)*(\+[a-z0-9]+)?'
kernel_flavour() { # release
  local rest=$1
  [[ "$rest" =~ $KERNEL_VERSION_RE ]] || return 0
  rest=${rest#"${BASH_REMATCH[0]}"}
  if [[ "$rest" =~ ^-[0-9]+ ]]; then rest=${rest#"${BASH_REMATCH[0]}"}; fi
  case "$rest" in
    -?*) printf '%s' "${rest#-}" ;;
  esac
}

detect_kernel() {
  local running flavour f name nflavour list='' best lowest
  running=$(uname -r 2>/dev/null) || { TRIG_ERR="cannot read the running kernel (uname -r)"; return 1; }
  [[ "$running" =~ ^[A-Za-z0-9.+_~-]+$ ]] || { TRIG_ERR="unexpected running kernel release"; return 1; }
  RUNNING_KERNEL=$running
  [ -d "$BOOT_DIR" ] && [ -r "$BOOT_DIR" ] || { TRIG_ERR="cannot read the boot directory $BOOT_DIR"; return 1; }
  flavour=$(kernel_flavour "$running")
  if [ -z "$flavour" ]; then add_note "kernel status unknown (release $running has no flavour)"; return 0; fi
  for f in "$BOOT_DIR"/vmlinuz-*; do
    [ -e "$f" ] || continue
    name=${f##*/vmlinuz-}
    [[ "$name" =~ ^[A-Za-z0-9.+_~-]+$ ]] || continue
    # A candidate is an installed kernel of exactly the running flavour.
    nflavour=$(kernel_flavour "$name")
    [ "$nflavour" = "$flavour" ] || continue
    list="$list$name"$'\n'
  done
  if [ -z "$list" ]; then add_note "kernel status unknown (no $flavour vmlinuz in $BOOT_DIR)"; return 0; fi
  best=$(printf '%s' "$list" | sort -V | tail -n 1)
  if [ "$best" = "$running" ]; then return 0; fi
  # Only a newer installed kernel is a reason to reboot; never "upgrade" into an older one.
  lowest=$(printf '%s\n%s\n' "$running" "$best" | sort -V | head -n 1)
  if [ "$lowest" = "$running" ]; then
    add_trigger kernel "$best" "running kernel $running is older than installed $best"
  else
    add_note "running kernel $running is newer than the newest installed $best"
  fi
}

# rpi-eeprom-update writes its status as JSON with -j -m FILE (nothing is scraped from the text
# output, and stdin is closed so its install prompt can never be offered). The data reaches the
# reader on stdin; the reader code is a constant.
EEPROM_JSON_PY='
import json, sys
d = json.load(sys.stdin)
vals = [d["BOOTLOADER_CURRENT"], d["BOOTLOADER_LATEST"]]
for v in vals:
    if isinstance(v, bool) or not isinstance(v, int) or v < 0:
        sys.exit(2)
print(str(d["EXITCODE"]), vals[0], vals[1])
'
EEPROM_JSON_JS='
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const vals = [d.BOOTLOADER_CURRENT, d.BOOTLOADER_LATEST];
for (const v of vals) { if (!Number.isInteger(v) || v < 0) process.exit(2); }
process.stdout.write([String(d.EXITCODE), vals[0], vals[1]].join(" ") + "\n");
'
eeprom_json() { # status JSON on stdin -> "EXITCODE CURRENT LATEST"
  local doc out
  doc=$(cat)
  if command -v python3 >/dev/null 2>&1 && out=$(printf '%s' "$doc" | python3 -I -c "$EEPROM_JSON_PY" 2>/dev/null); then
    printf '%s\n' "$out"; return 0
  fi
  command -v node >/dev/null 2>&1 || return 1
  out=$(printf '%s' "$doc" | node -e "$EEPROM_JSON_JS" 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

EEPROM_STATUS_MAX_AGE=60
EEPROM_CUR=0; EEPROM_LATEST=0; EEPROM_NOTE=
# Root writes the status to the constant file below /run (only root can write there) and the file is
# read unprivileged afterwards. Because the privileged path is fixed, a file left by an earlier run
# must not pass for this run's answer: it has to be fresh (real clock, not the NOW seam) and agree
# with the command's own exit status (0 is EXIT_SUCCESS, 1 is EXIT_UPDATE_REQUIRED).
eeprom_read_status() { # sets EEPROM_CUR/EEPROM_LATEST; returns 1 with EEPROM_NOTE when unknown
  local out rc=0 parsed code cur latest mtime real
  EEPROM_NOTE=
  # Exit status 1 is its normal "update required" answer; only the JSON counts.
  out=$(sudo -n rpi-eeprom-update -j -m "$EEPROM_STATUS_FILE" </dev/null 2>&1) || rc=$?
  if [ ! -f "$EEPROM_STATUS_READ" ] || [ -L "$EEPROM_STATUS_READ" ] || [ ! -r "$EEPROM_STATUS_READ" ]; then
    EEPROM_NOTE="no status file: $(clean "$(printf '%s' "$out" | head -n 1)" 80)"
    return 1
  fi
  mtime=$(file_mtime "$EEPROM_STATUS_READ") || mtime=
  real=$(date +%s)
  if ! [[ "$mtime" =~ ^[0-9]+$ ]] || [ "$mtime" -lt $((real - EEPROM_STATUS_MAX_AGE)) ]; then
    EEPROM_NOTE="the status file is stale (not written by this run): $(clean "$(printf '%s' "$out" | head -n 1)" 80)"
    return 1
  fi
  parsed=$(eeprom_json <"$EEPROM_STATUS_READ") || parsed=
  if ! [[ "$parsed" =~ ^(EXIT_[A-Z_]+)\ ([0-9]{1,12})\ ([0-9]{1,12})$ ]]; then
    EEPROM_NOTE="no readable JSON status: $(clean "$(printf '%s' "$out" | head -n 1)" 80)"
    return 1
  fi
  code=${BASH_REMATCH[1]}; cur=${BASH_REMATCH[2]}; latest=${BASH_REMATCH[3]}
  case "$code:$rc" in
    EXIT_SUCCESS:0|EXIT_UPDATE_REQUIRED:1) ;;
    EXIT_FAILED:*) EEPROM_NOTE="rpi-eeprom-update reported EXIT_FAILED"; return 1 ;;
    *) EEPROM_NOTE="the status $code does not match the exit status $rc of the command"; return 1 ;;
  esac
  EEPROM_CUR=$((0 + 10#$cur)); EEPROM_LATEST=$((0 + 10#$latest))
}

detect_eeprom() {
  command -v rpi-eeprom-update >/dev/null 2>&1 || return 0
  if ! eeprom_read_status; then add_note "eeprom status unknown ($EEPROM_NOTE)"; return 0; fi
  if [ "$EEPROM_CUR" -eq 0 ]; then add_note "eeprom status unknown (the running bootloader version is unavailable)"; return 0; fi
  if [ "$EEPROM_LATEST" -gt "$EEPROM_CUR" ]; then
    add_trigger eeprom "$EEPROM_LATEST" "bootloader EEPROM update available (version $EEPROM_LATEST)"
  fi
}

# Sets TRIG_*; returns 1 with TRIG_ERR when a required input cannot be read.
detect_triggers() {
  TRIG_IDS=; TRIG_PAIRS=; TRIG_DETAIL=; TRIG_NOTE=; TRIG_ERR=; RUNNING_KERNEL=
  detect_reboot_required
  detect_kernel || return 1
  detect_eeprom
  return 0
}

# --- EEPROM staging -------------------------------------------------------------------------------
# A staged update is flashed by the bootloader at the NEXT boot of any kind, and the kill switch
# cannot stop that. So staging happens only inside an admitted guarded reboot, and a staged update
# found anywhere else is cancelled. The stock boot service that would stage one at every boot is
# disabled by the deploy.
eeprom_staged() {
  [ -s "$EEPROM_PENDING_FLAG" ] && return 0
  [ -e "$BOOT_DIR/firmware/pieeprom.upd" ] || [ -e "$BOOT_DIR/pieeprom.upd" ]
}
eeprom_stage() { # 0 only when rpi-eeprom-update -a ran and the update is verifiably staged
  local out rc=0
  out=$(sudo -n rpi-eeprom-update -a </dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] || ! eeprom_staged; then
    warn "staging the EEPROM update failed (exit $rc): $(clean "$(printf '%s' "$out" | tail -n 1)" 120)"
    return 1
  fi
}
eeprom_cancel() { # 0 when nothing is staged afterwards
  sudo -n rpi-eeprom-update -r </dev/null >/dev/null 2>&1 || true
  ! eeprom_staged
}
# A staged update found at the start of a run has no reboot attempt behind it (this job stages one
# only inside a reboot it is already executing), so it is cancelled. A cancellation that fails, or a
# report-only run that is not allowed to cancel, leaves STRAY_BLOCK=1: the guard eeprom-stray then
# stops any reboot until a later run cancels it, because it would be flashed by the very next boot.
STRAY_BLOCK=0
cancel_stray_staging() {
  STRAY_BLOCK=0
  command -v rpi-eeprom-update >/dev/null 2>&1 || return 0
  eeprom_staged || return 0
  if [ "$REPORT_ONLY" -ne 0 ]; then STRAY_BLOCK=1; return 0; fi
  if eeprom_cancel; then
    queue_alert "eeprom-cancelled: a staged bootloader EEPROM update was found with no reboot attempt in progress and was cancelled (rpi-eeprom-update -r)"
  else
    RC=1
    STRAY_BLOCK=1
    queue_alert "eeprom-cancel-failed: a staged bootloader EEPROM update was found with no reboot attempt in progress and could not be cancelled; no reboot is admitted until it is gone, run sudo rpi-eeprom-update -r by hand"
  fi
}

# --- latch ----------------------------------------------------------------------------------------
# After a guarded reboot, a trigger identity that is still pending, a failed post-boot check, a
# missing post-boot result or a reboot that did not happen latches automatic reboots off until the
# owner runs clear-latch. New triggers never clear it.
set_latch() { # reason
  [ "$LATCH" -eq 0 ] || return 0
  LATCH=1; LATCH_SINCE=$NOW
  LATCH_REASON=$(clean "$1" 160)
  queue_alert "latched: $(clean "$1" 200). Automatic reboots stay off until the owner has investigated and runs guarded-reboot.sh clear-latch"
}

# The last attempt must have a successful post-boot result before the host is eligible again.
ATTEMPT_PENDING=0
check_attempt_gate() {
  ATTEMPT_PENDING=0
  [ "$A_STATUS" = unresolved ] || return 0
  if [ $((NOW - A_EPOCH)) -lt "$ATTEMPT_GRACE" ]; then ATTEMPT_PENDING=1; return 0; fi
  if [ "$A_BOOT_ID" = "$BOOT_ID" ]; then
    set_latch "reboot did not happen: the attempt of $(iso_utc "$A_EPOCH") left the boot id unchanged"
  else
    set_latch "post-boot verification missing: the host rebooted after the attempt of $(iso_utc "$A_EPOCH") but no post-boot result was recorded"
  fi
}

# --- guards ---------------------------------------------------------------------------------------
# Any one guard defers the reboot to the next night; every guard that applies is recorded. A
# guard that cannot be evaluated counts as applying (fail closed). The kill switch is checked first
# and ends the evaluation: it is the owner's intent, so it never escalates.
GUARD_IDS=; GUARD_DETAIL=; G_KILL=0; G_UNLOCK=0; UNLOCK_NAMES=
add_guard() { # id detail
  GUARD_IDS="${GUARD_IDS:+$GUARD_IDS,}$1"
  GUARD_DETAIL="${GUARD_DETAIL:+$GUARD_DETAIL; }$2"
}

# Counts PIDs across every cgroup.procs below a cgroup directory. Fails when nothing can be read.
count_cgroup_pids() {
  local dir=$1 files f n total=0
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 1
  files=$(find "$dir" -type f -name cgroup.procs 2>/dev/null) || return 1
  [ -n "$files" ] || return 1
  while IFS= read -r f; do
    n=$(wc -l <"$f" 2>/dev/null) || return 1
    total=$((total + n))
  done <<<"$files"
  printf '%s\n' "$total"
}

# A service's own cgroup holds its main process; more than one PID means it has spawned work (for
# example a running Hugin task). Prints the reason and returns 0 when the unit is busy or cannot
# be judged; returns 1 when it is idle.
busy_reason() { # unit
  local unit=$1 state cg dir pids
  if ! state=$(systemctl --user show -p ActiveState --value "$unit" 2>/dev/null); then
    printf '%s' "cannot query $unit with systemctl --user (failing closed)"; return 0
  fi
  # Only a stopped unit is skipped. Transitional states (reloading, activating, deactivating,
  # refreshing) can still hold spawned work, so they are inspected like active; an empty or
  # unrecognised answer is not taken to mean idle.
  case "$state" in
    inactive|failed) return 1 ;;
    '') printf '%s' "systemctl --user reported no state for $unit (failing closed)"; return 0 ;;
  esac
  if ! cg=$(systemctl --user show -p ControlGroup --value "$unit" 2>/dev/null) || [ -z "$cg" ]; then
    printf '%s' "cannot read the control group of $state unit $unit (failing closed)"; return 0
  fi
  case "$cg" in
    */../*|*/..|*//*) printf '%s' "unsafe control group for $unit (failing closed)"; return 0 ;;
    /*) ;;
    *) printf '%s' "unsafe control group for $unit (failing closed)"; return 0 ;;
  esac
  dir=$CGROUP_ROOT$cg
  if ! pids=$(count_cgroup_pids "$dir"); then
    printf '%s' "cannot read cgroup $dir of unit $unit (failing closed)"; return 0
  fi
  if [ "$pids" -gt 1 ]; then
    printf '%s' "$unit is $state with $pids processes in its cgroup (a task is running)"; return 0
  fi
  return 1
}
guard_busy_units() {
  local unit reason
  for unit in $BUSY_LIST; do
    if reason=$(busy_reason "$unit"); then add_guard "busy:$unit" "$reason"; fi
  done
}

# A package transaction, or its preparation by the stock apt timers, is running. Process names
# only (the lookup prints PIDs and nothing else); no argv is ever read.
guard_apt_busy() {
  local name rc found='' state unit
  if ! command -v pgrep >/dev/null 2>&1; then
    add_guard apt-busy "pgrep not found (failing closed)"; return 0
  fi
  for name in dpkg apt apt-get unattended-upgr; do
    rc=0
    pgrep -x "$name" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) found="${found:+$found, }$name running" ;;
      1) ;;
      *) found="${found:+$found, }cannot look for $name (failing closed)" ;;
    esac
  done
  for unit in apt-daily-upgrade.service apt-daily.service; do
    state=$(systemctl is-active "$unit" 2>/dev/null) || true
    case "$state" in
      active|activating|reloading|deactivating|refreshing) found="${found:+$found, }$unit is $state" ;;
      '') found="${found:+$found, }no state for $unit (failing closed)" ;;
    esac
  done
  if [ -n "$found" ]; then add_guard apt-busy "package activity: $found"; fi
}

guard_load() {
  local l5 rest
  if [ ! -r "$LOADAVG_FILE" ] || ! read -r _ l5 rest <"$LOADAVG_FILE" || ! [[ "$l5" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    add_guard load "cannot read the 5-minute load average (failing closed)"; return 0
  fi
  if awk -v a="$l5" -v b="$MAX_LOAD" 'BEGIN { exit !(a + 0 > b + 0) }'; then
    add_guard load "5-minute load $l5 is above the maximum $MAX_LOAD"
  fi
}

# `who -u`: the idle column is `.` (active in the last minute), HH:MM, `old` (over a day) or `?`
# (no terminal, for example a graphical seat). The idle column is the one between the login time
# and the PID, which also holds for the older date format.
TTY_AWK='
BEGIN { best = -1; bad = 0; line = "-" }
NF == 0 { next }
{
  idle = ""
  for (i = 5; i <= NF; i++) {
    if ($i ~ /^[0-9]+$/ && $(i - 1) ~ /^(\.|old|\?|[0-9]+:[0-9][0-9])$/ && $(i - 2) ~ /^[0-9]+:[0-9][0-9]$/) { idle = $(i - 1); break }
  }
  if (idle == "") { bad++; next }
  if (idle == "old" || idle == "?") next
  if (idle == ".") { m = 0 } else { split(idle, t, ":"); m = t[1] * 60 + t[2] }
  if (best < 0 || m < best) { best = m; line = $2 }
}
END { printf "%d %d %s\n", best, bad, line }
'
guard_tty() {
  local out res best bad line
  [ "$TTY_IDLE_MIN" -gt 0 ] || return 0
  if ! out=$(who -u 2>/dev/null); then
    add_guard tty "cannot run who -u (failing closed)"; return 0
  fi
  res=$(printf '%s\n' "$out" | awk "$TTY_AWK") || { add_guard tty "cannot read who -u (failing closed)"; return 0; }
  read -r best bad line <<<"$res"
  if [ "$bad" -gt 0 ]; then add_guard tty "unrecognised who -u rows (failing closed)"; fi
  if [ "$best" -ge 0 ] && [ "$best" -lt "$TTY_IDLE_MIN" ]; then
    add_guard tty "an interactive session on $(clean "$line" 20) was used $best minutes ago (limit $TTY_IDLE_MIN)"
  fi
}

# Hosts that must be reachable before this one goes down: a TCP connection to port 22 within
# 5 seconds (bash /dev/tcp under timeout). Anything else defers.
guard_peers() {
  local peer
  for peer in $PEER_LIST; do
    if ! command -v timeout >/dev/null 2>&1; then
      add_guard "peer:$peer" "timeout not found, so peer $peer cannot be checked (failing closed)"
    elif ! timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/22"' _ "$peer" >/dev/null 2>&1; then
      add_guard "peer:$peer" "peer $peer did not accept a TCP connection on port 22 within 5 seconds"
    fi
  done
}

# Every crypttab entry needed at boot (not noauto) must unlock unattended, or an unattended reboot
# would stop the boot at a prompt. An entry counts as unattended only if its key field is a key-file
# path or its options contain tpm2-device= without tpm2-pin=yes. Anything that can prompt makes it
# interactive whatever else it says: fido2-device=, pkcs11-uri=, keyscript=, any *-pin=yes,
# fido2-with-*, headless=false. An empty, none or - key without tpm2 is interactive.
UNLOCK_AWK='
/^[[:space:]]*#/ { next }
NF == 0 { next }
{
  key = (NF >= 3) ? $3 : "none"
  opts = (NF >= 4) ? $4 : ""
  n = split(opts, o, ",")
  noauto = 0; interactive = 0; tpm2 = 0
  for (k = 1; k <= n; k++) {
    if (o[k] == "noauto") noauto = 1
    if (o[k] ~ /^(fido2-device|pkcs11-uri|keyscript)=/) interactive = 1
    if (o[k] ~ /-pin=yes$/) interactive = 1
    if (o[k] ~ /^fido2-with-/) interactive = 1
    if (o[k] == "headless=false") interactive = 1
    if (o[k] ~ /^tpm2-device=/) tpm2 = 1
  }
  if (noauto) next
  unattended = 0
  if (key ~ /^\//) unattended = 1
  if (tpm2) unattended = 1
  if (interactive) unattended = 0
  if (!unattended) print $1
}
'
guard_unlock() {
  local names
  [ -e "$CRYPTTAB" ] || return 0
  if [ ! -r "$CRYPTTAB" ] || ! names=$(awk "$UNLOCK_AWK" "$CRYPTTAB"); then
    G_UNLOCK=1; UNLOCK_NAMES="unreadable crypttab"
    add_guard unlock "cannot read $CRYPTTAB (failing closed)"; return 0
  fi
  [ -n "$names" ] || return 0
  G_UNLOCK=1
  UNLOCK_NAMES=$(clean "$(printf '%s' "$names" | head -n 8 | tr '\n' ',' | sed 's/,$//')" 120)
  add_guard unlock "an unattended reboot would stop at a passphrase prompt for crypttab entries: $UNLOCK_NAMES"
}

evaluate_guards() {
  GUARD_IDS=; GUARD_DETAIL=; G_KILL=0; G_UNLOCK=0; UNLOCK_NAMES=
  if [ -e "$KILL_SWITCH" ] || [ -L "$KILL_SWITCH" ]; then
    G_KILL=1
    add_guard kill-switch "the kill switch $KILL_SWITCH exists; reboots are disabled by the owner"
    return 0
  fi
  if [ "$LATCH" -eq 1 ]; then
    add_guard latched "automatic reboots are latched off since $(iso_utc "$LATCH_SINCE") ($LATCH_REASON); clear-latch re-allows them"
  fi
  if [ "$ATTEMPT_PENDING" -eq 1 ]; then
    add_guard attempt-pending "the reboot attempt of $(iso_utc "$A_EPOCH") has no post-boot result yet"
  fi
  if [ "$STRAY_BLOCK" -eq 1 ]; then
    add_guard eeprom-stray "a staged bootloader EEPROM update remains (it could not be cancelled, or this run may not cancel) and the next boot would flash it"
  fi
  guard_apt_busy
  guard_busy_units
  guard_load
  guard_tty
  guard_peers
  guard_unlock
  return 0
}

# --- running-service baseline and health ---------------------------------------------------------
# The nightly check records which services run (system and the operator's user manager) before the
# stock apt timers install anything; post-boot and the daily health check compare against it.
# Units that start on demand may legitimately be down and are ignored.
BASE_EXCLUDE_RE='^(brokkr-guarded-reboot|brokkr-post-boot-check|brokkr-post-update-health)\.service$|^run-'
NL=$'\n'
list_running() { # scope (system|user) -> unit names, sorted, one per line
  local out
  if [ "$1" = user ]; then
    out=$(systemctl --user list-units --type=service --state=running --plain --no-legend) || return 1
  else
    out=$(systemctl list-units --type=service --state=running --plain --no-legend) || return 1
  fi
  printf '%s\n' "$out" | awk 'NF { print $1 }' | { grep -E "$UNIT_NAME_RE" || true; } \
    | { grep -Ev "$BASE_EXCLUDE_RE" || true; } | sort -u | awk 'NR <= 500'
}

BASE_OK=0
capture_baseline() {
  local sys user
  BASE_OK=0
  if ! sys=$(list_running system); then
    warn "cannot list the running system services; the previous baseline is kept"; return 1
  fi
  if ! user=$(list_running user); then
    warn "cannot list the running user services; the previous baseline is kept"; return 1
  fi
  BASE_SYS=$sys; BASE_USER=$user; BASE_EPOCH=$NOW; BASE_BOOT_ID=$BOOT_ID; BASE_OK=1
}

# 0 when the unit starts on demand and may legitimately be down: Type=dbus, a non-empty BusName=
# (bus activated), a non-empty TriggeredBy= (socket or timer activated) or a transient unit. Being a
# static or indirect unit file proves nothing (a static long-running service that vanished is a
# regression). 1 otherwise or when the unit cannot be queried.
unit_on_demand() { # scope unit
  local out line type='' state='' trig='' bus=''
  if [ "$1" = user ]; then
    out=$(systemctl --user show -p Type,BusName,UnitFileState,TriggeredBy "$2" 2>/dev/null) || return 1
  else
    out=$(systemctl show -p Type,BusName,UnitFileState,TriggeredBy "$2" 2>/dev/null) || return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      Type=*) type=${line#Type=} ;;
      BusName=*) bus=${line#BusName=} ;;
      UnitFileState=*) state=${line#UnitFileState=} ;;
      TriggeredBy=*) trig=${line#TriggeredBy=} ;;
    esac
  done <<<"$out"
  if [ "$type" = dbus ]; then return 0; fi
  if [ "$state" = transient ]; then return 0; fi
  if [ -n "$bus" ] || [ -n "$trig" ]; then return 0; fi
  return 1
}

# Baseline services that are not running now and do not start on demand, one per line. Fails when
# the current services cannot be listed.
missing_units() { # scope baseline-list
  local cur u
  cur=$(list_running "$1") || return 1
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    case "$NL$cur$NL" in *"$NL$u$NL"*) continue ;; esac
    if unit_on_demand "$1" "$u"; then continue; fi
    printf '%s\n' "$u"
  done <<<"$2"
}

failed_units() { # scope -> failed unit names, one per line
  local out
  if [ "$1" = user ]; then
    out=$(systemctl --user --failed --plain --no-legend) || return 1
  else
    out=$(systemctl --failed --plain --no-legend) || return 1
  fi
  printf '%s\n' "$out" | awk 'NF { print $1 }' | tr -c 'A-Za-z0-9:_.@\n-' '?' | awk 'NR <= 50'
}

join_names() { # newline-separated names -> a bounded comma list
  printf '%s\n' "$1" | awk 'NF && NR <= 8 { a = a (a == "" ? "" : ",") $0 } NF { n++ } END { if (n > 8) a = a ",+" (n - 8) " more"; print a }'
}

ISSUES=
add_issue() { ISSUES="${ISSUES:+$ISSUES; }$1"; }
# Failed units, and (when compare is 1) baseline services that did not come back.
collect_health_issues() { # compare
  local scope names base
  for scope in system user; do
    if names=$(failed_units "$scope"); then
      if [ -n "$names" ]; then add_issue "failed $scope units: $(join_names "$names")"; fi
    else
      add_issue "cannot query the failed $scope units"
    fi
  done
  [ "$1" -eq 1 ] || return 0
  for scope in system user; do
    if [ "$scope" = user ]; then base=$BASE_USER; else base=$BASE_SYS; fi
    if names=$(missing_units "$scope" "$base"); then
      if [ -n "$names" ]; then add_issue "$scope services not running again: $(join_names "$names")"; fi
    else
      add_issue "cannot list the running $scope services"
    fi
  done
}

# --- shared bookkeeping --------------------------------------------------------------------------
# Writes the state, appends the main audit line (when asked) and delivers the queued alerts. A
# state or audit failure sets the exit code to 1 but never stops the notices.
commit_event() { # audit-main (1 or 0)
  if ! write_state; then warn "cannot write the state file in $STATE_DIR"; RC=1; fi
  if [ "$1" -eq 1 ]; then audit_append "$W_ACTION" "$W_DETAIL" || RC=1; fi
  flush_queues
}

# A night that ends deferred: count it (once per DEFER_GAP, never for the kill switch) and raise
# the one-per-episode alerts. Alerts never override a guard.
note_deferral() {
  [ "$G_KILL" -eq 0 ] || return 0
  if [ "$E_LAST_COUNTED" -eq 0 ] || [ "$NOW" -lt "$E_LAST_COUNTED" ] || [ $((NOW - E_LAST_COUNTED)) -ge "$DEFER_GAP" ]; then
    E_DEFERRALS=$((E_DEFERRALS + 1)); E_LAST_COUNTED=$NOW
  fi
  if [ "$G_UNLOCK" -eq 1 ] && [ "$E_UNLOCK_ALERTED" -eq 0 ]; then
    E_UNLOCK_ALERTED=1
    queue_alert "unattended reboot refused: crypttab entries $UNLOCK_NAMES need an interactive unlock at boot (triggers: $TRIG_IDS)"
  fi
  if [ "$E_DEFERRALS" -ge "$ALERT_AFTER" ] && [ "$E_ALERTED" -eq 0 ]; then
    E_ALERTED=1
    queue_alert "reboot deferred for $E_DEFERRALS nights since $(iso_utc "$E_FIRST") (triggers: $TRIG_IDS; guards: $GUARD_IDS)"
  fi
}

# --- check: the nightly decision -------------------------------------------------------------------
SNAP_E=; SNAP_A=
snapshot_attempt_state() {
  SNAP_E="$E_FIRST $E_DEFERRALS $E_LAST_COUNTED $E_ALERTED $E_REPORTED $E_UNLOCK_ALERTED"
  SNAP_A="$A_EPOCH|$A_STATUS|$A_BOOT_ID|$A_TRIGGERS|$A_IDS"
}
restore_attempt_state() {
  local rest
  read -r E_FIRST E_DEFERRALS E_LAST_COUNTED E_ALERTED E_REPORTED E_UNLOCK_ALERTED <<<"$SNAP_E"
  A_EPOCH=${SNAP_A%%|*}; rest=${SNAP_A#*|}
  A_STATUS=${rest%%|*}; rest=${rest#*|}
  A_BOOT_ID=${rest%%|*}; rest=${rest#*|}
  A_TRIGGERS=${rest%%|*}; A_IDS=${rest#*|}
}

EEPROM_STAGED_NOW=0
# The reboot was admitted but did not go ahead. The abort is appended first (action deferred, detail
# starting "reboot aborted"); then anything staged for the reboot is cancelled (-r), and if that
# cancellation fails the host latches, because the staged update would be flashed by the next boot
# of any kind. The attempt record is put back and the night counts as deferred.
abort_reboot() {
  restore_attempt_state
  set_event deferred "$TRIG_IDS" "$GUARD_IDS" "reboot aborted before it was executed: $GUARD_DETAIL"
  note_deferral
  log "decision: deferred (reboot aborted); guards: $GUARD_IDS"
  audit_append deferred "$W_DETAIL" || RC=1
  if [ "$EEPROM_STAGED_NOW" -eq 1 ]; then
    if eeprom_cancel; then
      EEPROM_STAGED_NOW=0
    else
      RC=1
      set_latch "the EEPROM update staged for an aborted reboot could not be cancelled; run sudo rpi-eeprom-update -r by hand"
    fi
  fi
  commit_event 0
}

# Reboot mode, every guard clear. Order: attempt record, second full guard pass, the attempt/intent
# audit record (identities, planned EEPROM staging, reversal recipe), EEPROM staging and its
# verification (only here), the confirmed notice, a final full guard pass, the reboot. An audit
# failure therefore prevents the staging, the notice and the reboot.
reboot_attempt() {
  local detail rc reason staging=0 plan=''
  if [ "$MODE" != reboot ] || [ "$REPORT_ONLY" -ne 0 ]; then fatal "internal error: a reboot was attempted outside reboot mode"; fi
  if [ "$BASE_OK" -ne 1 ]; then fatal "cannot capture the running-service baseline; not rebooting"; fi
  snapshot_attempt_state
  A_BOOT_ID=$BOOT_ID; A_EPOCH=$NOW; A_TRIGGERS=$TRIG_IDS; A_IDS=$TRIG_PAIRS; A_STATUS=unresolved; A_OBSERVED=
  episode_reset
  set_event reboot "$TRIG_IDS" "" "$TRIG_DETAIL"
  if ! write_state; then
    restore_attempt_state
    fatal "cannot write the state file in $STATE_DIR; not rebooting"
  fi
  evaluate_guards
  if [ -n "$GUARD_IDS" ]; then abort_reboot; return 0; fi
  case ",$TRIG_IDS," in
    *,eeprom,*) staging=1; plan="eeprom-staging planned (version $EEPROM_LATEST)" ;;
  esac
  detail="identities $TRIG_PAIRS; ${plan:+$plan; }reversal irreversible (mitigations: post-boot check, latch, kill switch, previous kernel kept); $TRIG_DETAIL"
  set_event reboot "$TRIG_IDS" "" "$detail"
  if ! audit_append reboot "$W_DETAIL"; then
    restore_attempt_state
    write_state || true
    fatal "cannot append to the audit file; nothing was staged or announced and nothing reboots"
  fi
  if [ "$staging" -eq 1 ]; then
    # Whatever the staging leaves behind is cancelled by every abort from here on.
    EEPROM_STAGED_NOW=1
    if ! eeprom_stage; then
      GUARD_IDS=eeprom-stage; GUARD_DETAIL="staging the EEPROM update failed or could not be verified"; G_KILL=0; G_UNLOCK=0
      abort_reboot; return 0
    fi
  fi
  if ! send_notice "Rebooting $HOST for $TRIG_IDS"; then
    GUARD_IDS=notify; GUARD_DETAIL="the pre-reboot notice could not be delivered, so the alert path is not trusted"; G_KILL=0; G_UNLOCK=0
    abort_reboot; return 0
  fi
  evaluate_guards
  if [ -n "$GUARD_IDS" ]; then abort_reboot; return 0; fi
  rc=0
  (umask 022; sudo -n systemctl reboot) || rc=$?
  if [ "$rc" -eq 0 ]; then
    log "reboot requested for $TRIG_IDS"
    return 0
  fi
  warn "sudo -n systemctl reboot failed (exit $rc)"
  reason="reboot command failed (exit $rc)"
  if [ "$EEPROM_STAGED_NOW" -eq 1 ]; then
    if eeprom_cancel; then EEPROM_STAGED_NOW=0; else reason="$reason; the staged EEPROM update could not be cancelled"; fi
  fi
  # The attempt record stays (unresolved, same boot id) and the host latches at once: a reboot that
  # was admitted but refused by the system is not something to retry tomorrow without the owner.
  set_event alert "$TRIG_IDS" "" "$reason; nothing was rebooted"
  set_latch "$reason"
  RC=1
  commit_event 0
}

cmd_check() {
  local audit_main=1
  # A host must not reboot without the peer (the host that monitors it) being reachable.
  if [ "$MODE" = reboot ] && [ -z "$PEER_LIST" ]; then
    die "reboot mode needs at least one peer in BROKKR_GUARDED_REBOOT_PEERS"
  fi
  load_state
  read_boot_id
  capture_baseline || true
  detect_triggers || fatal "$TRIG_ERR"
  cancel_stray_staging
  check_attempt_gate
  if [ -z "$TRIG_IDS" ]; then
    episode_reset
    set_event none "" "" "no reboot trigger${TRIG_NOTE:+; $TRIG_NOTE}"
    # No trigger is not news: it is audited only when it changes the last recorded action.
    if [ "$STATE_PRESENT" -eq 1 ] && [ "$PREV_ACTION" = none ]; then audit_main=0; fi
    log "decision: none; $W_DETAIL"
    commit_event "$audit_main"
    return 0
  fi
  if [ "$E_FIRST" -eq 0 ]; then E_FIRST=$NOW; fi
  evaluate_guards
  if [ -n "$GUARD_IDS" ]; then
    set_event deferred "$TRIG_IDS" "$GUARD_IDS" "$GUARD_DETAIL (triggers: $TRIG_DETAIL)"
    note_deferral
    log "decision: deferred; triggers: $TRIG_IDS; guards: $GUARD_IDS"
    commit_event 1
    return 0
  fi
  E_DEFERRALS=0; E_LAST_COUNTED=0
  if [ "$MODE" = report ]; then
    set_event would-reboot "$TRIG_IDS" "" "report mode, no reboot performed: $TRIG_DETAIL"
    if [ "$E_REPORTED" -eq 0 ]; then
      E_REPORTED=1
      queue_notice "report mode: would reboot $HOST for $TRIG_IDS"
    fi
    log "decision: would-reboot; triggers: $TRIG_IDS"
    commit_event 1
    return 0
  fi
  log "decision: reboot; triggers: $TRIG_IDS"
  # Alerts raised earlier in this run (a cancelled stray update) are audited before the intent record.
  flush_queues
  reboot_attempt
}

csv_has() { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }

# --- post-boot: health after a guarded reboot ----------------------------------------------------
# Only for an attempt that is still unresolved and whose boot id differs from the current one. A
# successful result makes the host eligible again; issues latch automatic reboots off.
#
# The recorded targets are verified positively, one per trigger of the attempt, and an observation
# that cannot be made is an issue (it never passes by default):
#   kernel           the running kernel equals the recorded expected version
#   eeprom           a successful status read whose current bootloader is at least the recorded target
#   reboot-required  the flag is gone, or its identity changed
verify_attempt_targets() {
  local pair id want have cur pairs
  pairs=$(printf '%s' "$A_IDS" | tr ',' '\n')
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    id=${pair%%=*}
    want=${pair#*=}
    case "$id" in
      kernel)
        have=$(uname -r 2>/dev/null) || have=
        have=$(printf '%s' "$have" | tr -c 'A-Za-z0-9.+_~:-' '?' | cut -c1-80)
        if [ -z "$have" ]; then
          add_issue "cannot read the running kernel to verify $want"
        elif [ "$have" != "$want" ]; then
          add_issue "running kernel is $have, the attempt expected $want"
        fi ;;
      eeprom)
        if ! command -v rpi-eeprom-update >/dev/null 2>&1; then
          add_issue "bootloader version unknown after the reboot (rpi-eeprom-update is missing)"
        elif ! eeprom_read_status; then
          add_issue "bootloader version unknown after the reboot ($EEPROM_NOTE)"
        elif ! [[ "$want" =~ ^[0-9]{1,12}$ ]]; then
          add_issue "the recorded bootloader target is unknown ($want)"
        elif [ "$EEPROM_CUR" -eq 0 ]; then
          add_issue "bootloader version unknown after the reboot (the running version is unavailable)"
        elif [ "$EEPROM_CUR" -lt "$((0 + 10#$want))" ]; then
          add_issue "bootloader is $EEPROM_CUR, the attempt expected at least $want"
        fi ;;
      reboot-required)
        if reboot_flag_present; then
          cur=$(reboot_flag_identity)
          if [ "$cur" = "$want" ]; then add_issue "the reboot-required flag is still present with the same identity ($want)"; fi
        fi ;;
      *) add_issue "the attempt recorded a trigger this job cannot verify ($id)" ;;
    esac
  done <<<"$pairs"
}

cmd_post_boot() {
  local pair kernel notes='' fresh='' detail pairs outcome fresh_issues relatch was_latched
  load_state
  read_boot_id
  [ "$A_STATUS" = unresolved ] || return 0
  [ "$A_BOOT_ID" != "$BOOT_ID" ] || return 0
  ISSUES=
  if detect_triggers; then
    pairs=$(printf '%s' "$TRIG_PAIRS" | tr ',' '\n')
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      if ! csv_has "$A_IDS" "$pair"; then fresh="${fresh:+$fresh,}$pair"; fi
    done <<<"$pairs"
    if [ -n "$fresh" ]; then notes="new trigger since the reboot: $fresh"; fi
  else
    add_issue "cannot re-check the reboot triggers: $TRIG_ERR"
  fi
  verify_attempt_targets
  cancel_stray_staging
  if [ "$STRAY_BLOCK" -eq 1 ] && [ "$REPORT_ONLY" -eq 0 ]; then
    add_issue "a staged bootloader EEPROM update remains and could not be cancelled"
  fi
  collect_health_issues 1
  kernel=$RUNNING_KERNEL
  if [ -z "$kernel" ]; then kernel=$(clean "$(uname -r 2>/dev/null || echo unknown)" 60); fi
  fresh_issues=$ISSUES
  # Issues an earlier run observed but could not record are never forgotten by a healthy retry: the
  # outcome stays issues until the owner clears the latch.
  if [ -n "$A_OBSERVED" ]; then add_issue "an earlier post-boot check observed (its outcome could not be recorded): $A_OBSERVED"; fi
  if [ -z "$ISSUES" ]; then
    outcome=ok
    detail="kernel $kernel; health OK; the recorded targets are verified${notes:+; $notes}"
    set_event post-boot-ok "" "" "$detail"
    queue_notice "back up: $HOST kernel $kernel; health OK"
    log "post-boot: ok; kernel $kernel"
  else
    outcome=issues
    detail="kernel $kernel; $ISSUES${notes:+; $notes}"
    set_event post-boot-issues "" "" "$detail"
    queue_notice "back up: $HOST kernel $kernel; issues: $(clean "$ISSUES" 300)"
    log "post-boot: issues; $ISSUES"
  fi
  # The outcome is appended BEFORE it is persisted. If the append fails the attempt stays unresolved
  # (exit 1), so the next nightly check latches it as missing verification instead of the host
  # looking verified while no record says so. Observed issues are different: they are persisted
  # with the latch even when the append fails (the attempt still stays unresolved), so a later
  # healthy retry cannot erase them. The notices still go out.
  if ! audit_append "$W_ACTION" "$W_DETAIL"; then
    RC=1
    warn "the post-boot outcome could not be audited; the attempt stays unresolved"
    if [ "$outcome" = issues ]; then
      if [ -n "$fresh_issues" ]; then A_OBSERVED=$(clean "$fresh_issues" 200); fi
      set_latch "the post-boot check reported issues: $(clean "$A_OBSERVED" 120)"
      if ! write_state; then warn "cannot write the state file in $STATE_DIR"; fi
    fi
    # Alerts are normally audited as they are sent; with the audit failing they go out as notices.
    if [ -n "$ALERTS" ]; then NOTICES="$NOTICES$(printf '%s' "$ALERTS" | sed "s/^/ALERT $HOST: /")"$'\n'; fi
    ALERTS=''
    flush_queues
    return 0
  fi
  relatch=0
  if [ -n "$A_OBSERVED" ]; then relatch=1; fi
  was_latched=$LATCH
  A_STATUS=$outcome
  A_OBSERVED=''
  if [ "$outcome" = issues ]; then
    set_latch "the post-boot check reported issues: $(clean "$fresh_issues" 120)"
    # The first latching alert could not be audited; the report only sees the latch if it is recorded.
    if [ "$relatch" -eq 1 ] && [ "$was_latched" -eq 1 ]; then
      queue_alert "latched: $LATCH_REASON. Automatic reboots stay off until the owner has investigated and runs guarded-reboot.sh clear-latch"
    fi
  fi
  commit_event 0
}

# --- health: the daily check that the night's updates broke nothing ------------------------------
# Compares the running services with the baseline the nightly check recorded before the stock apt
# timers ran. Issues are audited and alerted when they change; recovery is audited once.
cmd_health() {
  local sig detail
  load_state
  read_boot_id
  if [ "$BASE_EPOCH" -eq 0 ]; then
    log "health: no pre-update baseline yet (the nightly check records one); nothing to compare"
    return 0
  fi
  ISSUES=
  if [ $((NOW - BASE_EPOCH)) -gt "$BASELINE_STALE_SECS" ]; then
    add_issue "the pre-update baseline is stale (captured $(iso_utc "$BASE_EPOCH")); the nightly check is not running"
    collect_health_issues 0
  else
    collect_health_issues 1
  fi
  EV_TRIGGERS=; EV_GUARDS=
  H_EPOCH=$NOW
  if [ -n "$ISSUES" ]; then
    sig=$(printf '%s' "$ISSUES" | cksum | awk '{ print $1 }')
    log "health: issues; $ISSUES"
    if [ "$H_ACTION" != health-issues ] || [ "$H_SIG" != "$sig" ]; then
      H_ACTION='health-issues'; H_SIG=$sig
      detail="since the pre-update baseline of $(iso_utc "$BASE_EPOCH"): $ISSUES"
      if ! write_state; then warn "cannot write the state file in $STATE_DIR"; RC=1; fi
      audit_append health-issues "$detail" || RC=1
      queue_notice "ALERT $HOST: post-update health check found issues: $(clean "$ISSUES" 300)"
      flush_queues
      return 0
    fi
  else
    log "health: ok"
    if [ "$H_ACTION" = health-issues ]; then
      H_ACTION='health-ok'; H_SIG=''
      if ! write_state; then warn "cannot write the state file in $STATE_DIR"; RC=1; fi
      audit_append health-ok "the issues found earlier are gone" || RC=1
      flush_queues
      return 0
    fi
    H_ACTION='health-ok'; H_SIG=''
  fi
  if ! write_state; then warn "cannot write the state file in $STATE_DIR"; RC=1; fi
}

# --- clear-latch: the owner re-allows automatic reboots ------------------------------------------
# Audited as action none with a detail starting latch-cleared; the latching alert's detail starts
# with latched, so a reader can tell the latch is active until a latch-cleared record follows it.
cmd_clear_latch() {
  local was
  load_state
  read_boot_id
  if [ "$LATCH" -eq 0 ]; then log "no latch is set; nothing to clear"; return 0; fi
  was=$LATCH_REASON
  EV_TRIGGERS=; EV_GUARDS=
  # The clearing is audited first: if that fails the latch stays.
  if ! audit_append none "latch-cleared: by the owner (was: $was)"; then
    fatal "cannot append to the audit file; the latch stays"
  fi
  LATCH=0; LATCH_SINCE=0; LATCH_REASON=
  case "$A_STATUS" in unresolved|issues) A_STATUS=cleared ;; esac
  A_OBSERVED=
  if ! write_state; then fatal "cannot write the state file in $STATE_DIR"; fi
  queue_notice "guarded-reboot latch cleared on $HOST by the owner"
  flush_queues
  log "latch cleared; automatic reboots are allowed again"
}

# --- status ----------------------------------------------------------------------------------------
cmd_status() {
  local kill=absent health=none
  load_state
  if [ -e "$KILL_SWITCH" ] || [ -L "$KILL_SWITCH" ]; then kill=PRESENT; fi
  echo "guarded-reboot status for $HOST"
  echo "configured mode: $MODE (limits: load $MAX_LOAD, terminal idle $TTY_IDLE_MIN min, alert after $ALERT_AFTER nights)"
  echo "busy units: ${BUSY_LIST:-(none)}; peers: ${PEER_LIST:-(none)}"
  echo "kill switch: $kill ($KILL_SWITCH)"
  echo "audit file: $AUDIT_FILE"
  if [ "$STATE_PRESENT" -eq 0 ]; then
    echo "state: none yet ($STATE_FILE)"
  else
    echo "last decision: $W_TS action=$W_ACTION triggers=${W_TRIGGERS:--} guards=${W_GUARDS:--}"
    echo "detail: $W_DETAIL"
    if [ "$E_FIRST" -gt 0 ]; then
      echo "pending episode: since $(iso_utc "$E_FIRST"), $E_DEFERRALS deferred nights, alert sent: $E_ALERTED"
    else
      echo "pending episode: none"
    fi
    if [ "$LATCH" -eq 1 ]; then
      echo "LATCH: automatic reboots are OFF since $(iso_utc "$LATCH_SINCE"): $LATCH_REASON"
      echo "  after investigating, re-allow them with: guarded-reboot.sh clear-latch"
    else
      echo "latch: off"
    fi
    if [ "$A_STATUS" = none ]; then
      echo "last reboot attempt: none"
    else
      echo "last reboot attempt: $(iso_utc "$A_EPOCH") status=$A_STATUS triggers=${A_TRIGGERS:--} identities=${A_IDS:--}"
    fi
    if [ -n "$A_OBSERVED" ]; then
      echo "post-boot issues observed but not yet recorded in the audit file: $A_OBSERVED"
    fi
    if [ "$BASE_EPOCH" -gt 0 ]; then
      echo "service baseline: $(iso_utc "$BASE_EPOCH")"
    else
      echo "service baseline: none yet"
    fi
    if [ -n "$H_ACTION" ]; then health="$H_ACTION ($(iso_utc "$H_EPOCH"))"; fi
    echo "last health check: $health"
  fi
  if eeprom_staged; then
    echo "EEPROM: a bootloader update is STAGED. It is applied at the next boot of any kind, and the kill"
    echo "  switch does not cancel it. This job cancels a staged update it did not stage itself at its next"
    echo "  run; to cancel it now run: sudo rpi-eeprom-update -r"
    echo "  Firmware writes count as suspended only when nothing is staged: create the kill switch (no new"
    echo "  staging), keep rpi-eeprom-update.service disabled, and cancel the staged update"
    echo "  (see docs/guarded-reboot.md for the power-interruption risk and the bootloader recovery image)"
  elif command -v rpi-eeprom-update >/dev/null 2>&1; then
    echo "EEPROM: no update is staged (updates are staged only inside an admitted guarded reboot)"
  fi
}

# --- run -------------------------------------------------------------------------------------------
case "$CMD" in
  check) cmd_check ;;
  post-boot) cmd_post_boot ;;
  health) cmd_health ;;
  status) cmd_status ;;
  clear-latch) cmd_clear_latch ;;
esac
exit "$RC"
