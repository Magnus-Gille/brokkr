#!/usr/bin/env bash
# Tracked, generic forced command for Heimdall's NAS storage probe.
set -euo pipefail

CONFIG=${BROKKR_STORAGE_PROBE_CONFIG:-/etc/brokkr/heimdall-storage-probe.conf}
TM_SNAPSHOT_PATH=
TM_ROOT=
MUNIN_BACKUP_DIR=
MIMIR_LOG=
MIMIR_SYNC_STAMP=
MIMIR_SYNC_DIR=
MIMIR_BACKUP_RECORD=
MIMIR_SYNC_RECORD=
while IFS='=' read -r key path; do
  [[ -n "$key" ]] || continue
  [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || exit 64
  [[ "$path" != *"//"* && "$path" != *"/../"* && "$path" != *"/./"* &&
    "$path" != */.. && "$path" != */. ]] || exit 64
  case "$key" in
    TM_SNAPSHOT_PATH) [[ -z "$TM_SNAPSHOT_PATH" ]] || exit 64; TM_SNAPSHOT_PATH=$path ;;
    TM_ROOT) [[ -z "$TM_ROOT" ]] || exit 64; TM_ROOT=$path ;;
    MUNIN_BACKUP_DIR) [[ -z "$MUNIN_BACKUP_DIR" ]] || exit 64; MUNIN_BACKUP_DIR=$path ;;
    MIMIR_LOG) [[ -z "$MIMIR_LOG" ]] || exit 64; MIMIR_LOG=$path ;;
    MIMIR_SYNC_STAMP) [[ -z "$MIMIR_SYNC_STAMP" ]] || exit 64; MIMIR_SYNC_STAMP=$path ;;
    MIMIR_SYNC_DIR) [[ -z "$MIMIR_SYNC_DIR" ]] || exit 64; MIMIR_SYNC_DIR=$path ;;
    MIMIR_BACKUP_RECORD) [[ -z "$MIMIR_BACKUP_RECORD" ]] || exit 64; MIMIR_BACKUP_RECORD=$path ;;
    MIMIR_SYNC_RECORD) [[ -z "$MIMIR_SYNC_RECORD" ]] || exit 64; MIMIR_SYNC_RECORD=$path ;;
    *) exit 64 ;;
  esac
done <"$CONFIG"
for configured_path in "$TM_SNAPSHOT_PATH" "$TM_ROOT" "$MUNIN_BACKUP_DIR"; do
  [[ -n "$configured_path" ]] || exit 64
done

legacy_mimir=0
new_mimir=0
[[ -n "$MIMIR_LOG$MIMIR_SYNC_STAMP$MIMIR_SYNC_DIR" ]] && legacy_mimir=1
[[ -n "$MIMIR_BACKUP_RECORD$MIMIR_SYNC_RECORD" ]] && new_mimir=1
(( legacy_mimir + new_mimir == 1 )) || exit 64
if (( legacy_mimir )); then
  for configured_path in "$MIMIR_LOG" "$MIMIR_SYNC_STAMP" "$MIMIR_SYNC_DIR"; do
    [[ -n "$configured_path" ]] || exit 64
  done
else
  [[ -n "$MIMIR_BACKUP_RECORD" && -n "$MIMIR_SYNC_RECORD" ]] || exit 64
  [[ "${MIMIR_BACKUP_RECORD##*/}" == backup.json && "${MIMIR_SYNC_RECORD##*/}" == sync.json ]] || exit 64
  [[ "${MIMIR_BACKUP_RECORD%/*}" == "${MIMIR_SYNC_RECORD%/*}" ]] || exit 64
fi

if [[ "${1:-}" == "--validate-config" ]]; then
  exit 0
fi
[[ $# -eq 0 ]] || exit 64

# Mimir v1 is deliberately a two-record, metadata-only surface.  This reader
# refuses links and non-regular inputs, then accepts only the exact public
# schema.  It prints state plus normalized time for `fresh`, state alone for a
# valid publisher `error`, and nothing for malformed input.  The caller keeps
# the positional consumer contract while making an explicit error unambiguously
# stale rather than silently unknown.
read_mimir_v1_record() {
  local record=$1
  [[ -f "$record" && ! -L "$record" ]] || return 0
  python3 - "$record" <<'PY' 2>/dev/null || true
import datetime as dt
import json
import os
import stat
import sys

path = sys.argv[1]
try:
    # Refuse a symlink in any component, not only at the final record.
    current = os.path.sep
    for component in path.split(os.path.sep)[1:]:
        current = os.path.join(current, component)
        if stat.S_ISLNK(os.lstat(current).st_mode):
            raise ValueError("symlink")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise ValueError("type")
    with os.fdopen(fd, encoding="utf-8") as source:
        value = json.load(source)
    if set(value) != {"schema_version", "state", "observed_at"}:
        raise ValueError("shape")
    if value["schema_version"] != 1 or value["state"] not in {"fresh", "error"}:
        raise ValueError("state")
    observed_at = value["observed_at"]
    if not isinstance(observed_at, str) or not observed_at.endswith("Z"):
        raise ValueError("timestamp")
    parsed = dt.datetime.strptime(observed_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    if parsed > dt.datetime.now(dt.timezone.utc):
        raise ValueError("future")
    if value["state"] == "fresh":
        print(f"fresh\t{observed_at}\t{int(parsed.timestamp())}")
    else:
        print("error")
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    pass
PY
}

for z in /sys/class/thermal/thermal_zone*/; do [ -d "$z" ] || continue; printf '%s\t%s\n' "$(cat "${z}type" 2>/dev/null)" "$(cat "${z}temp" 2>/dev/null)"; done
echo ---
cat /proc/meminfo
echo ---
df --output=source,size,used,avail,pcent /dev/mmcblk0p2 /dev/sda1 2>/dev/null || true
echo ---
cat /proc/loadavg
echo ---
cat /proc/uptime
echo ---
stat -c '%Y' "$TM_SNAPSHOT_PATH" 2>/dev/null || echo ''
echo ---
du -sb "$TM_ROOT" 2>/dev/null || echo ''
echo ---
if latest_backup=$(ls "$MUNIN_BACKUP_DIR" 2>/dev/null | tail -1); then
  printf '%s\n' "$latest_backup"
else
  echo ''
fi
echo ---
if backup_count=$(ls "$MUNIN_BACKUP_DIR" 2>/dev/null | wc -l); then
  printf '%s\n' "$backup_count"
else
  echo '0'
fi
echo ---
if (( legacy_mimir )); then
  tail -1 "$MIMIR_LOG" 2>/dev/null || echo ''
else
  mimir_backup_record="$(read_mimir_v1_record "$MIMIR_BACKUP_RECORD")"
  case "$mimir_backup_record" in
    $'fresh\t'*) printf '%s\n' "$mimir_backup_record" | awk -F '\t' 'NF == 3 { print $2; exit }' ;;
    error) printf '%s\n' '1970-01-01T00:00:01Z Mimir freshness publisher error' ;;
  esac
fi
echo ---
if (( legacy_mimir )); then
  cat "$MIMIR_SYNC_STAMP" 2>/dev/null || find "$MIMIR_SYNC_DIR" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 || echo ''
else
  mimir_sync_record="$(read_mimir_v1_record "$MIMIR_SYNC_RECORD")"
  case "$mimir_sync_record" in
    $'fresh\t'*) printf '%s\n' "$mimir_sync_record" | awk -F '\t' 'NF == 3 { print $3; exit }' ;;
    error) printf '%s\n' 1 ;;
  esac
fi
echo ---
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo ''
echo ---
vcgencmd get_throttled 2>/dev/null || echo ''
echo ---
cat /sys/class/hwmon/hwmon2/in0_lcrit_alarm 2>/dev/null || echo ''
echo ---
cat /proc/net/dev 2>/dev/null
echo ---
cat /sys/block/mmcblk0/stat 2>/dev/null || echo ''
echo ---
cat /sys/block/sda/stat 2>/dev/null || echo ''
echo ---
head -1 /proc/stat 2>/dev/null || echo ''
echo ---
nproc 2>/dev/null || echo ''
