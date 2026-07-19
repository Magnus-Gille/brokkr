#!/usr/bin/env bash
# Brokkr · Time Machine health — runs ON THE MAC (tmutil is macOS-only).
#
# Time Machine is configured hourly (AutoBackupInterval = 3600). This flags a stale
# backup, i.e. one older than the threshold — usually means the NAS share is unreachable,
# the disk is unmounted/full, or the sparsebundle is wedged.
#
# Exit: 0 = OK (pass), 1 = WARN (state unknown / couldn't parse), 2 = FAIL
# (a successful query proves stale or absent backups).
set -euo pipefail

MAX_AGE_HOURS="${BROKKR_TM_MAX_AGE_HOURS:-26}"
case "$MAX_AGE_HOURS" in
  ''|*[!0-9]*|0) echo "WARN: invalid BROKKR_TM_MAX_AGE_HOURS; Time Machine state unknown"; exit 1 ;;
esac

if ! command -v tmutil >/dev/null 2>&1; then
  echo "WARN: tmutil unavailable; Time Machine state unknown"
  exit 1
fi

err_file="$(mktemp "${TMPDIR:-/tmp}/brokkr-tm.XXXXXX")"
trap 'rm -f "$err_file"' EXIT
if ! latest="$(tmutil latestbackup 2>"$err_file")"; then
  err="$(tr '\n' ' ' < "$err_file" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-160)"
  echo "WARN: tmutil latestbackup failed; Time Machine state unknown${err:+ ($err)}"
  exit 1
fi
if [ -z "$latest" ]; then
  echo "FAIL: tmutil successfully reported no Time Machine backups"
  exit 2
fi

# Backup path ends in .../YYYY-MM-DD-HHMMSS.backup[/...]; pull the timestamp token.
latest="$(printf '%s\n' "$latest" | tail -n 1)"
stamp="$(basename "$latest" | sed -E 's/\.backup.*$//')"
ts="$(date -j -f "%Y-%m-%d-%H%M%S" "$stamp" "+%s" 2>/dev/null \
  || date -u -d "${stamp:0:10} ${stamp:11:2}:${stamp:13:2}:${stamp:15:2}" "+%s" 2>/dev/null \
  || true)"
if [ -z "$ts" ]; then
  echo "WARN: latest backup '$stamp' found but age could not be parsed"
  exit 1
fi

now="${BROKKR_TM_NOW_EPOCH:-$(date "+%s")}"
case "$now" in ''|*[!0-9]*) echo "WARN: current time is invalid; Time Machine state unknown"; exit 1 ;; esac
if [ "$ts" -gt "$now" ]; then
  echo "WARN: latest backup '$stamp' is in the future; Time Machine state unknown"
  exit 1
fi
age_h=$(( (now - ts) / 3600 ))

if [ "$age_h" -ge "$MAX_AGE_HOURS" ]; then
  echo "FAIL: last Time Machine backup ${age_h}h ago (>= ${MAX_AGE_HOURS}h): $stamp"
  exit 2
fi

echo "OK: last Time Machine backup ${age_h}h ago: $stamp"
exit 0
