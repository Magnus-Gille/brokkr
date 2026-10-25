#!/usr/bin/env bash
# Brokkr · offline (LUKS) rotation disk freshness check.
#
# Reads the receipts written by the offline rotation script and reports how long ago
# the last completed rotation was. It only reads the receipt directory: it never
# touches the disk, LUKS, hosts, the network, or systemd (except the optional --push).
#
# Receipts: ${BROKKR_OFFLINE_RECEIPT_DIR:-/var/lib/brokkr/offline-rotation/receipts}/
# <UTC stamp>.receipt, key=value lines, first line exactly
# `format=brokkr-offline-rotation-receipt-v1`, with exactly one `completed_epoch=<digits>`.
# Receipts are parsed with grep/sed and never sourced. Only regular, non-symlink files
# count. The newest valid receipt is chosen by numeric completed_epoch, not by filename.
#
# Environment:
#   BROKKR_OFFLINE_ENV_FILE      optional private env file (see scripts/lib/private-env.sh)
#   BROKKR_OFFLINE_MAX_AGE_DAYS  staleness threshold, 1..3650 (default 90)
#   BROKKR_OFFLINE_NOW_EPOCH     override "now" (tests)
#
# Usage: offline-rotation-freshness.sh [--push]
#
# Exit: 0 = OK (fresh), 1 = WARN (stale, or state unknown: unreadable receipt dir,
# no valid receipt, future timestamp, bad configuration), 2 = FAIL (a readable receipt
# directory proves no rotation was ever recorded). Usage error: 64.
#
# --push publishes the result to Heimdall (`offline-rotation` panel) through
# heimdall/push.sh. As with link-health, a WARN/FAIL observation that was delivered
# exits 0; missing Heimdall configuration exits 2; snapshot or push failure exits
# non-zero so systemd records the loss of observability.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PUSH=0
case "$#:${1:-}" in
  0:) ;;
  1:--push) PUSH=1 ;;
  *) echo "usage: offline-rotation-freshness.sh [--push]" >&2; exit 64 ;;
esac

# --- optional private env file (may also carry Heimdall settings) ---------------
env_error=0
if [ -n "${BROKKR_OFFLINE_ENV_FILE:-}" ]; then
  # shellcheck source=lib/private-env.sh
  . "$SCRIPT_DIR/lib/private-env.sh"
  # The helper's diagnostic names the file; keep it out of output that may be published.
  brokkr_source_private_env "$BROKKR_OFFLINE_ENV_FILE" 2>/dev/null || env_error=1
fi

# is_epoch VALUE: digits only, 1-15 characters (no arithmetic overflow).
is_epoch() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 15 ]
}

# evaluate: prints one WARN/OK/FAIL line and returns 0/1/2.
evaluate() {
  local max_age="${BROKKR_OFFLINE_MAX_AGE_DAYS-90}" dir now f first count value
  local best_epoch="" best_name="" present=0 age_days

  if [ "$env_error" -ne 0 ]; then
    echo "WARN: BROKKR_OFFLINE_ENV_FILE rejected (must be a private regular file); offline rotation state unknown"
    return 1
  fi
  case "$max_age" in ''|*[!0-9]*|0*) max_age=invalid ;; esac
  if [ "$max_age" = invalid ] || [ "${#max_age}" -gt 4 ] || [ "$max_age" -gt 3650 ]; then
    echo "WARN: invalid BROKKR_OFFLINE_MAX_AGE_DAYS; offline rotation state unknown"
    return 1
  fi

  now="${BROKKR_OFFLINE_NOW_EPOCH:-$(date "+%s")}"
  if ! is_epoch "$now"; then
    echo "WARN: current time is invalid; offline rotation state unknown"
    return 1
  fi

  dir="${BROKKR_OFFLINE_RECEIPT_DIR:-/var/lib/brokkr/offline-rotation/receipts}"
  if [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    echo "WARN: offline rotation receipt directory missing or unreadable; offline rotation state unknown"
    return 1
  fi

  for f in "$dir"/*.receipt; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    present=$((present + 1))
    # Symlinks and non-regular files are never trusted.
    if [ -L "$f" ] || [ ! -f "$f" ]; then continue; fi
    first="$(head -n 1 "$f" 2>/dev/null)" || continue
    [ "$first" = "format=brokkr-offline-rotation-receipt-v1" ] || continue
    count="$(grep -c '^completed_epoch=' "$f" 2>/dev/null)" || true
    [ "$count" = "1" ] || continue
    value="$(sed -n 's/^completed_epoch=//p' "$f" 2>/dev/null)" || continue
    is_epoch "$value" || continue
    if [ -z "$best_epoch" ] || [ "$((10#$value))" -gt "$((10#$best_epoch))" ]; then
      best_epoch="$value"
      best_name="$(basename "$f")"
    fi
  done

  if [ "$present" -eq 0 ]; then
    echo "FAIL: no offline rotation receipts in $dir"
    return 2
  fi
  if [ -z "$best_epoch" ]; then
    echo "WARN: no valid offline rotation receipt in receipt directory; offline rotation state unknown"
    return 1
  fi
  if [ "$((10#$best_epoch))" -gt "$((10#$now))" ]; then
    echo "WARN: newest offline rotation receipt ($best_name) is in the future; offline rotation state unknown"
    return 1
  fi
  age_days=$(( (10#$now - 10#$best_epoch) / 86400 ))
  if [ "$age_days" -ge "$((10#$max_age))" ]; then
    echo "WARN: last offline rotation ${age_days}d ago (>= ${max_age}d); rotate the offline disk"
    return 1
  fi
  echo "OK: last offline rotation ${age_days}d ago ($best_name)"
  return 0
}

if [ "$PUSH" -eq 0 ]; then
  evaluate
  exit $?
fi

# --- --push: publish a Heimdall snapshot ---------------------------------------
STATE_DIR="${BROKKR_STATE_DIR:-${HOME:-/var/lib/brokkr}/.local/state/brokkr}"
PUSH_SCRIPT="${BROKKR_HEIMDALL_PUSH:-$HERE_ROOT/heimdall/push.sh}"
fail() { echo "brokkr offline rotation: $1" >&2; exit 2; }

[ -n "${HEIMDALL_HUB_URL:-}" ] && [ -n "${HEIMDALL_FLEET_TOKEN:-}" ] || fail "Heimdall delivery is not configured"
mkdir -p "$STATE_DIR" || fail "cannot create state directory"

detail="$(evaluate)"
case "$?" in 0) status=pass ;; 1) status=warn ;; *) status=fail ;; esac
[ -n "$detail" ] || fail "check produced no result"
echo "$detail"

snapshot="$STATE_DIR/offline-rotation.json"
tmp="$STATE_DIR/.offline-rotation.json.$$"
trap 'rm -f "$tmp"' EXIT
if ! python3 - "$tmp" "$status" "$detail" <<'PY'
import json, sys
path, status, detail = sys.argv[1:]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"name": "brokkr", "namespace": "grimnir", "kind": "platform", "status": status,
               "checks": [{"name": "offline-rotation", "status": status, "detail": detail}]}, fh, separators=(",", ":"))
    fh.write("\n")
PY
then
  fail "cannot generate snapshot"
fi
mv "$tmp" "$snapshot" || fail "cannot publish snapshot"
trap - EXIT
echo "brokkr offline rotation: $status → $snapshot"

BROKKR_HEIMDALL_PANEL="offline-rotation" \
BROKKR_HEIMDALL_LABEL="Offline Rotation Disk" \
BROKKR_HEIMDALL_STAMP_PREFIX="offline-rotation-" \
BROKKR_STATE_DIR="$STATE_DIR" \
  bash "$PUSH_SCRIPT" "$snapshot"
