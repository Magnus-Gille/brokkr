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
STALE_REPORTERS="$STATE_DIR/.stale-reporters.$$"
PENDING_RESETS="$STATE_DIR/reset-reporters"
TMP_PENDING_RESETS="$STATE_DIR/.reset-reporters.$$"
TMP_FILTER="$STATE_DIR/.filter.$$"
trap 'rm -f "$CURRENT" "$NEW" "$RECOVERED" "$SORTED_PREVIOUS" "$TMP_SNAPSHOT" "$TMP_PREVIOUS" "$STALE_REPORTERS" "$TMP_PENDING_RESETS" "$TMP_FILTER"' EXIT

# `systemctl list-units` is column-oriented. Only accept legal service names so
# malformed output can never become a panel/notification injection primitive.
printf '%s\n' "$listed" | awk '
  $1 ~ /^[A-Za-z0-9:_.@\\-]+\.service$/ { print $1 }
' | LC_ALL=C sort -u >"$CURRENT"

# An immediate OnFailure invocation carries an authoritative unit name, but a
# concurrent list-units snapshot can race with that unit's state transition.
# Reconcile the explicit unit when it is absent from the snapshot: retain it
# only after a direct failed-state readback, and fail closed on an unreadable or
# unknown state so a transient systemd observation cannot hide a real failure.
if [ "$MODE" = "--unit" ] && ! grep -Fqx "$UNIT" "$CURRENT"; then
  if ! active_state="$(systemctl show --property=ActiveState --value "$UNIT")"; then
    echo "brokkr systemd failure monitor: could not read state for '$UNIT'" >&2
    exit 1
  fi
  case "$active_state" in
    failed)
      printf '%s\n' "$UNIT" >>"$CURRENT"
      LC_ALL=C sort -u "$CURRENT" -o "$CURRENT"
      ;;
    active|inactive)
      # The OnFailure unit has recovered or is no longer failed. Leave it out
      # so the normal previous-state diff emits one recovery transition.
      ;;
    unknown)
      echo "brokkr systemd failure monitor: unknown state '$active_state' for '$UNIT'" >&2
      exit 1
      ;;
    *)
      echo "brokkr systemd failure monitor: ambiguous state '$active_state' for '$UNIT'" >&2
      exit 1
      ;;
  esac
fi
[ -f "$PREVIOUS" ] || : >"$PREVIOUS"
LC_ALL=C sort -u "$PREVIOUS" >"$SORTED_PREVIOUS"
comm -13 "$SORTED_PREVIOUS" "$CURRENT" >"$NEW"
comm -23 "$SORTED_PREVIOUS" "$CURRENT" >"$RECOVERED"

# A reset can succeed immediately before the final panel delivery fails. Keep
# those exact reporter names as pending so the retry does not emit a misleading
# recovery notification for a reporter whose failure was already cleared.
if [ -f "$PENDING_RESETS" ]; then
  if ! while IFS= read -r pending; do
    [[ "$pending" =~ ^brokkr-systemd-failure@[A-Za-z0-9:_.@\\-]+\.service$ ]] || exit 1
  done <"$PENDING_RESETS"; then
    echo "brokkr systemd failure monitor: invalid pending reporter state" >&2
    exit 1
  fi
  grep -Fvx -f "$PENDING_RESETS" "$RECOVERED" >"$TMP_FILTER" || :
  mv "$TMP_FILTER" "$RECOVERED"
fi

# A failed immediate handler can remain as a failed systemd instance after its
# producer has recovered. Only consider the exact Brokkr reporter instance for
# a recovered producer, and verify every producer directly before any reset or
# recovery publication. Only stable active/inactive states qualify as recovery;
# a failed or transitional/unknown state fails closed without changing durable
# state.
: >"$STALE_REPORTERS"
if [ -s "$RECOVERED" ]; then
  while IFS= read -r recovered; do
    if [[ ! "$recovered" =~ ^[A-Za-z0-9:_.@\\-]+\.service$ ]]; then
      echo "brokkr systemd failure monitor: invalid recovered unit state" >&2
      exit 1
    fi
    case "$recovered" in
      brokkr-systemd-failure@*.service) continue ;;
    esac
    if ! producer_state="$(systemctl show --property=ActiveState --value "$recovered")"; then
      echo "brokkr systemd failure monitor: could not verify recovery for '$recovered'" >&2
      exit 1
    fi
    case "$producer_state" in
      failed)
        printf '%s\n' "$recovered" >>"$CURRENT"
        ;;
      active|inactive)
        reporter="brokkr-systemd-failure@${recovered}.service"
        if grep -Fqx "$reporter" "$CURRENT"; then
          printf '%s\n' "$reporter" >>"$STALE_REPORTERS"
        fi
        ;;
      unknown)
        echo "brokkr systemd failure monitor: unknown state '$producer_state' for '$recovered'" >&2
        exit 1
        ;;
      *)
        echo "brokkr systemd failure monitor: ambiguous producer state '$producer_state' for '$recovered'" >&2
        exit 1
        ;;
    esac
  done <"$RECOVERED"
  LC_ALL=C sort -u "$CURRENT" -o "$CURRENT"
  LC_ALL=C sort -u "$STALE_REPORTERS" -o "$STALE_REPORTERS"
  # Recompute transitions after correcting a list snapshot that omitted a
  # producer which is still genuinely failed.
  comm -13 "$SORTED_PREVIOUS" "$CURRENT" >"$NEW"
  comm -23 "$SORTED_PREVIOUS" "$CURRENT" >"$RECOVERED"
  if [ -f "$PENDING_RESETS" ]; then
    grep -Fvx -f "$PENDING_RESETS" "$RECOVERED" >"$TMP_FILTER" || :
    mv "$TMP_FILTER" "$RECOVERED"
  fi
fi

compose_snapshot() {
  python3 - "$CURRENT" "$TMP_SNAPSHOT" <<'PY'
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
}

if ! compose_snapshot; then
  echo "brokkr systemd failure monitor: could not compose Heimdall snapshot" >&2
  exit 1
fi
mv "$TMP_SNAPSHOT" "$SNAPSHOT"

push_snapshot() {
  BROKKR_HEIMDALL_PANEL=systemd-failures \
    BROKKR_HEIMDALL_LABEL='Systemd Unit Failures' \
    BROKKR_HEIMDALL_STAMP_PREFIX='systemd-failures-' \
    "$HERE/heimdall/push.sh" "$SNAPSHOT"
}

mark_pending_reset() {
  : >"$TMP_PENDING_RESETS"
  if [ -f "$PENDING_RESETS" ]; then
    cat "$PENDING_RESETS" >"$TMP_PENDING_RESETS"
  fi
  printf '%s\n' "$1" >>"$TMP_PENDING_RESETS"
  LC_ALL=C sort -u "$TMP_PENDING_RESETS" -o "$TMP_PENDING_RESETS"
  mv "$TMP_PENDING_RESETS" "$PENDING_RESETS"
}

# The panel is refreshed on each sweep, while notification delivery below only
# occurs on state transitions. A failed push keeps the old state so the next
# invocation retries instead of silently considering the incident delivered.
if ! push_snapshot; then
  echo "brokkr systemd failure monitor: Heimdall push failed; failure state retained for retry" >&2
  exit 1
fi

# Delivery has succeeded and the producer recovery was verified above. Clear
# only a reporter instance that is still known failed; a changed or ambiguous
# reporter state is never force-cleared. Durable transition state is left to
# the normal reconciliation below, so a reset failure remains visible and
# retryable on the next sweep.
if [ -s "$STALE_REPORTERS" ]; then
  while IFS= read -r reporter; do
    producer="${reporter#brokkr-systemd-failure@}"
    producer="${producer%.service}"
    reporter_reset=0
    if ! producer_state="$(systemctl show --property=ActiveState --value "$producer")"; then
      echo "brokkr systemd failure monitor: could not reverify recovery for '$producer'" >&2
      exit 1
    fi
    case "$producer_state" in
      failed)
        echo "brokkr systemd failure monitor: producer '$producer' failed again; reporter reset skipped" >&2
        exit 1
        ;;
      active|inactive) ;;
      unknown)
        echo "brokkr systemd failure monitor: unknown post-reset state '$producer_state' for '$producer'" >&2
        exit 1
        ;;
      *)
        echo "brokkr systemd failure monitor: ambiguous post-reset producer state '$producer_state' for '$producer'" >&2
        exit 1
        ;;
    esac
    if ! reporter_state="$(systemctl show --property=ActiveState --value "$reporter")"; then
      echo "brokkr systemd failure monitor: could not read reporter state for '$reporter'" >&2
      exit 1
    fi
    case "$reporter_state" in
      failed)
        if ! systemctl reset-failed "$reporter"; then
          echo "brokkr systemd failure monitor: could not clear failed reporter '$reporter'" >&2
          exit 1
        fi
        mark_pending_reset "$reporter"
        reporter_reset=1
        ;;
      active|inactive) ;;
      unknown)
        echo "brokkr systemd failure monitor: unknown post-reset reporter state '$reporter_state' for '$reporter'" >&2
        exit 1
        ;;
      *)
        echo "brokkr systemd failure monitor: ambiguous post-reset reporter state '$reporter_state' for '$reporter'" >&2
        exit 1
        ;;
    esac

    # The reporter may already have self-cleared, but every stale reporter
    # still needs a fresh producer readback before it can be removed from
    # CURRENT or published as recovered. reset-failed is not a synchronization
    # barrier for either unit, so the producer may also fail after the
    # pre-reset readback. The pending marker and prior durable state make
    # either race visible and retryable.
    if ! producer_state="$(systemctl show --property=ActiveState --value "$producer")"; then
      echo "brokkr systemd failure monitor: could not verify post-reset state for '$producer'" >&2
      exit 1
    fi
    case "$producer_state" in
      failed)
        if [ "$reporter_reset" -eq 1 ]; then
          echo "brokkr systemd failure monitor: producer '$producer' failed again after reporter reset" >&2
        else
          echo "brokkr systemd failure monitor: producer '$producer' failed again before reporter recovery commit" >&2
        fi
        exit 1
        ;;
      active|inactive) ;;
      unknown)
        echo "brokkr systemd failure monitor: unknown post-reset state '$producer_state' for '$producer'" >&2
        exit 1
        ;;
      *)
        echo "brokkr systemd failure monitor: ambiguous post-reset producer state '$producer_state' for '$producer'" >&2
        exit 1
        ;;
    esac
    if ! reporter_state="$(systemctl show --property=ActiveState --value "$reporter")"; then
      echo "brokkr systemd failure monitor: could not verify post-reset reporter state for '$reporter'" >&2
      exit 1
    fi
    case "$reporter_state" in
      failed)
        if [ "$reporter_reset" -eq 1 ]; then
          echo "brokkr systemd failure monitor: reporter '$reporter' failed again after reset" >&2
        else
          echo "brokkr systemd failure monitor: reporter '$reporter' failed again before recovery commit" >&2
        fi
        exit 1
        ;;
      active|inactive) ;;
      unknown)
        echo "brokkr systemd failure monitor: unknown post-reset reporter state '$reporter_state' for '$reporter'" >&2
        exit 1
        ;;
      *)
        echo "brokkr systemd failure monitor: ambiguous post-reset reporter state '$reporter_state' for '$reporter'" >&2
        exit 1
        ;;
    esac
    if [ "$reporter_reset" -eq 1 ]; then
      echo "brokkr systemd failure monitor: cleared failed reporter: $reporter"
    fi
  done <"$STALE_REPORTERS"

  # The first authenticated delivery was the gate for reset-failed. Rebuild
  # the final panel and transitions after removing only reporters that were
  # actually reset, then require a second authenticated delivery before state
  # publication. A failed final push leaves pending reset markers for a clean
  # retry without a misleading reporter-recovery notification.
  while IFS= read -r reporter; do
    grep -Fvx "$reporter" "$CURRENT" >"$TMP_FILTER" || :
    mv "$TMP_FILTER" "$CURRENT"
  done <"$STALE_REPORTERS"
  LC_ALL=C sort -u "$CURRENT" -o "$CURRENT"
  comm -13 "$SORTED_PREVIOUS" "$CURRENT" >"$NEW"
  comm -23 "$SORTED_PREVIOUS" "$CURRENT" >"$RECOVERED"
  if [ -s "$PENDING_RESETS" ]; then
    grep -Fvx -f "$PENDING_RESETS" "$RECOVERED" >"$TMP_FILTER" || :
    mv "$TMP_FILTER" "$RECOVERED"
  fi
  if ! compose_snapshot; then
    echo "brokkr systemd failure monitor: could not compose final Heimdall snapshot" >&2
    exit 1
  fi
  mv "$TMP_SNAPSHOT" "$SNAPSHOT"
  if ! push_snapshot; then
    echo "brokkr systemd failure monitor: final Heimdall push failed; reset reporter state retained for retry" >&2
    exit 1
  fi
  : >"$TMP_PENDING_RESETS"
  mv "$TMP_PENDING_RESETS" "$PENDING_RESETS"
elif [ -f "$PENDING_RESETS" ]; then
  # A retry after a successful reset but failed final push has now delivered
  # the converged panel; the marker has served its suppression purpose.
  : >"$TMP_PENDING_RESETS"
  mv "$TMP_PENDING_RESETS" "$PENDING_RESETS"
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
