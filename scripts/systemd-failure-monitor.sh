#!/usr/bin/env bash
# Brokkr · fleet-wide systemd failure reporting (brokkr#6).
#
# `--unit` is the immediate OnFailure path. `--sweep` is the periodic backstop
# for every failed *system* service on the host, including units that have not
# yet adopted the template. Both paths reconcile the same state, so an immediate
# handler and the next sweep cannot send duplicate failure notifications.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
UNIT="${2:-}"

usage() {
  echo "usage: $0 --sweep | --unit <failed.service>" >&2
  exit 64
}

case "$MODE" in
  --sweep) [ "$#" -eq 1 ] || usage ;;
  --unit)
    [ "$#" -eq 2 ] || usage
    # `%i` from the template must name a system service, not a shell fragment,
    # path, or a user unit. The independent sweep remains the safety net.
    if [[ ! "$UNIT" =~ ^[A-Za-z0-9:_.@\\-]+\.service$ ]]; then
      echo "brokkr systemd failure monitor: invalid unit '$UNIT'" >&2
      exit 64
    fi
    ;;
  *) usage ;;
esac

if [ -z "${HEIMDALL_HUB_URL:-}" ] || [ -z "${HEIMDALL_FLEET_TOKEN:-}" ]; then
  echo "brokkr systemd failure monitor: Heimdall delivery is not configured" >&2
  exit 2
fi

STATE_ROOT="${BROKKR_STATE_DIR:-${HOME:-/var/lib/brokkr}/.local/state/brokkr}"
STATE_DIR="$STATE_ROOT/systemd-failures"
umask 077
mkdir -p "$STATE_DIR"
# shellcheck source=lib/notify.sh
source "$HERE/scripts/lib/notify.sh"

# A handler and a timer can arrive together. Use a kernel-released advisory lock:
# a SIGKILL or reboot releases it automatically, unlike a mkdir sentinel. Remove
# an empty sentinel left by the pre-flock implementation during an upgrade.
LOCK_FILE="$STATE_DIR/.lock"
if [ -d "$LOCK_FILE" ] && ! rmdir "$LOCK_FILE" 2>/dev/null; then
  echo "brokkr systemd failure monitor: another reconciliation is in progress; skipping" >&2
  exit 0
fi
if ! exec 9>"$LOCK_FILE"; then
  echo "brokkr systemd failure monitor: could not open lock file" >&2
  exit 1
fi
if ! flock -n 9; then
  echo "brokkr systemd failure monitor: another reconciliation is in progress; skipping" >&2
  exit 0
fi

if ! listed="$(systemctl list-units --all --type=service --state=failed --no-legend --plain)"; then
  echo "brokkr systemd failure monitor: could not list failed system services" >&2
  exit 1
fi

CURRENT="$STATE_DIR/.current.$$"
PREVIOUS="$STATE_DIR/failed-units"
NEW="$STATE_DIR/.new.$$"
RECOVERED="$STATE_DIR/.recovered.$$"
SORTED_PREVIOUS="$STATE_DIR/.previous.$$"
SNAPSHOT="$STATE_DIR/systemd-failures.json"
TMP_SNAPSHOT="$STATE_DIR/.snapshot.$$"
TMP_PREVIOUS="$STATE_DIR/.failed-units.$$"
trap 'rm -f "$CURRENT" "$NEW" "$RECOVERED" "$SORTED_PREVIOUS" "$TMP_SNAPSHOT" "$TMP_PREVIOUS"' EXIT

# `systemctl list-units` is column-oriented. Only accept legal service names so
# malformed output can never become a panel/notification injection primitive.
printf '%s\n' "$listed" | awk '
  $1 ~ /^[A-Za-z0-9:_.@\\-]+\.service$/ { print $1 }
' | LC_ALL=C sort -u >"$CURRENT"
[ -f "$PREVIOUS" ] || : >"$PREVIOUS"
LC_ALL=C sort -u "$PREVIOUS" >"$SORTED_PREVIOUS"
comm -13 "$SORTED_PREVIOUS" "$CURRENT" >"$NEW"
comm -23 "$SORTED_PREVIOUS" "$CURRENT" >"$RECOVERED"

if ! python3 - "$CURRENT" "$TMP_SNAPSHOT" <<'PY'
import json
import sys

units = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
checks = (
    [{"name": f"systemd:{unit}", "status": "fail", "detail": "systemd reports this service as failed"}
     for unit in units]
    if units else
    [{"name": "systemd-failed-units", "status": "pass", "detail": "no failed system services"}]
)
snapshot = {
    "name": "brokkr",
    "namespace": "grimnir",
    "kind": "platform",
    "status": "fail" if units else "pass",
    "checks": checks,
}
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(snapshot, fh, separators=(",", ":"))
    fh.write("\n")
PY
then
  echo "brokkr systemd failure monitor: could not compose Heimdall snapshot" >&2
  exit 1
fi
mv "$TMP_SNAPSHOT" "$SNAPSHOT"

# The panel is refreshed on each sweep, while notification delivery below only
# occurs on state transitions. A failed push keeps the old state so the next
# invocation retries instead of silently considering the incident delivered.
if ! BROKKR_HEIMDALL_PANEL=systemd-failures \
  BROKKR_HEIMDALL_LABEL='Systemd Unit Failures' \
  BROKKR_HEIMDALL_STAMP_PREFIX='systemd-failures-' \
  "$HERE/heimdall/push.sh" "$SNAPSHOT"; then
  echo "brokkr systemd failure monitor: Heimdall push failed; failure state retained for retry" >&2
  exit 1
fi

if [ -s "$NEW" ]; then
  while IFS= read -r failed; do
    echo "brokkr systemd failure monitor: new failure: $failed"
    # Notification is intentionally secondary to the authenticated Heimdall
    # upsert; notify.sh has its own Ratatoskr/direct-Telegram fallback contract.
    notify_telegram "Brokkr systemd failure on $(hostname): $failed" || true
  done <"$NEW"
fi
if [ -s "$RECOVERED" ]; then
  while IFS= read -r recovered; do
    echo "brokkr systemd failure monitor: recovered: $recovered"
    notify_telegram "Brokkr systemd recovery on $(hostname): $recovered" || true
  done <"$RECOVERED"
fi

# Publish the dedup state atomically only after Heimdall acknowledged the
# snapshot, so a delivery failure remains a retryable transition.
cp "$CURRENT" "$TMP_PREVIOUS"
mv "$TMP_PREVIOUS" "$PREVIOUS"
if [ ! -s "$NEW" ] && [ ! -s "$RECOVERED" ]; then
  echo "brokkr systemd failure monitor: no state change"
fi
