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
    *) exit 64 ;;
  esac
done <"$CONFIG"
for configured_path in "$TM_SNAPSHOT_PATH" "$TM_ROOT" "$MUNIN_BACKUP_DIR" "$MIMIR_LOG" "$MIMIR_SYNC_STAMP" "$MIMIR_SYNC_DIR"; do
  [[ -n "$configured_path" ]] || exit 64
done

if [[ "${1:-}" == "--validate-config" ]]; then
  exit 0
fi
[[ $# -eq 0 ]] || exit 64

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
tail -1 "$MIMIR_LOG" 2>/dev/null || echo ''
echo ---
cat "$MIMIR_SYNC_STAMP" 2>/dev/null || find "$MIMIR_SYNC_DIR" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 || echo ''
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
