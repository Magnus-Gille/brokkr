#!/usr/bin/env bash
# Brokkr · disk health — is the NAS backup disk actually mounted?
#
# Runs ON the storage host. A silent unmount means Time Machine + Mimir +
# munin backups all write into an empty mountpoint on the SD card instead of the HD.
# Before Brokkr the only guard was an inline check inside mimir's backup-artifacts.sh.
#
# Exit: 0 = OK (pass), 2 = not mounted (fail).
set -euo pipefail

MOUNT="${BROKKR_DISK_MOUNT:-/mnt/timemachine}"
DEV="${BROKKR_DISK_DEV:-/dev/sda1}"

if ! mountpoint -q "$MOUNT"; then
  echo "FAIL: $MOUNT is not a mountpoint (expected $DEV)"
  exit 2
fi

src="$(findmnt -no SOURCE "$MOUNT" 2>/dev/null || true)"
echo "OK: $MOUNT mounted (${src:-source unknown})"
exit 0
