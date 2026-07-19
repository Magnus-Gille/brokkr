#!/usr/bin/env bash
# Brokkr · disk health — capacity check for the NAS backup disk.
#
# Runs ON the storage host. The shared backup volume feeds Time Machine + Mimir +
# munin backups, so disk-full hits all three at once. This check did not exist before Brokkr.
#
# Exit: 0 = OK (pass), 1 = WARN (>= warn %), 2 = FAIL (>= fail %).
set -euo pipefail

MOUNT="${BROKKR_DISK_MOUNT:-/mnt/timemachine}"
WARN_PCT="${BROKKR_DISK_WARN_PCT:-80}"
FAIL_PCT="${BROKKR_DISK_FAIL_PCT:-90}"

# Use the POSIX -P format so the row is never line-wrapped, then read use% and avail.
used_pct="$(df -P "$MOUNT" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
avail="$(df -Ph "$MOUNT" | awk 'NR==2 {print $4}')"

if [ "$used_pct" -ge "$FAIL_PCT" ]; then
  echo "FAIL: $MOUNT ${used_pct}% used (${avail} free) — at/over ${FAIL_PCT}%"
  exit 2
elif [ "$used_pct" -ge "$WARN_PCT" ]; then
  echo "WARN: $MOUNT ${used_pct}% used (${avail} free) — at/over ${WARN_PCT}%"
  exit 1
fi

echo "OK: $MOUNT ${used_pct}% used (${avail} free)"
exit 0
