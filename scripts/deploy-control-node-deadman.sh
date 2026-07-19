#!/usr/bin/env bash
# Brokkr · install the control-node dead-man user timer on an off-box host.
#
# Runs from the monitoring host's Brokkr checkout. The preflight is fail-closed:
# the direct Telegram fallback, healthy production probe, configured external
# heartbeat, user manager, and user lingering must all be ready before install.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_ROOT="${BROKKR_DEADMAN_EXPECTED_ROOT:-$HOME/repos/brokkr}"
UNIT_DIR="${BROKKR_DEADMAN_UNIT_DIR:-$HOME/.config/systemd/user}"
NOTIFY_ENV="${BROKKR_DEADMAN_NOTIFY_ENV:-$HOME/.config/grimnir/notify.env}"
EXTERNAL_ENV="${BROKKR_DEADMAN_EXTERNAL_ENV:-$HOME/.config/grimnir/deadman-external.env}"
STATE_ROOT="${BROKKR_DEADMAN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/brokkr}"
EXPECTED_HOST="${BROKKR_DEADMAN_EXPECTED_HOST:-inference-host}"
TARGET_URL="${BROKKR_DEADMAN_TARGET_URL:-http://control-node:3033/api/health}"
EXTERNAL_TIMEOUT_SECS=8
SERVICE="brokkr-control-node-deadman.service"
TIMER="brokkr-control-node-deadman.timer"

die() { printf 'refusing: %s\n' "$*" >&2; exit 1; }

cfg_get() {
  grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"\r' || true
}

require_single_cfg() {
  local count
  count="$(grep -Ec "^$2=" "$1" 2>/dev/null || true)"
  [[ "$count" == "1" ]] || die "$1 must contain exactly one $2 assignment (found $count)"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

file_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"
}

valid_external_url() {
  [[ "${1:-}" =~ ^https://[^/?#[:space:]\"\\]+([/?#][^[:space:]\"\\]*)?$ ]]
}

external_ping_url() {
  local url="$1" status
  # --disable must be curl's first argument: otherwise ~/.curlrc can enable
  # tracing, redirects, or other behavior before command-line options apply.
  status="$(printf 'url = "%s"\n' "$url" | \
    curl --disable --config - --proto '=https' --max-redirs 0 -sS \
      -m "$EXTERNAL_TIMEOUT_SECS" --retry 0 -o /dev/null -w '%{http_code}' \
      2>/dev/null)" || return 1
  [[ "$status" =~ ^2[0-9][0-9]$ ]]
}

require_private_file() {
  local path="$1" label="$2" uid mode
  uid="$(file_uid "$path")"
  [[ "$uid" == "$(id -u)" ]] || die "$label is not owned by the invoking user"
  mode="$(file_mode "$path")"
  [[ "$mode" == "600" || "$mode" == "400" ]] || \
    die "$label must have mode 0600 or 0400 (found $mode)"
}

host="$(hostname -s)"
[[ "$host" == "$EXPECTED_HOST" ]] || die "targets $EXPECTED_HOST but hostname is '$host'"
[[ "$(id -u)" -ne 0 ]] || die "run as the monitoring-host user, not root"
[[ "$HERE" == "$EXPECTED_ROOT" ]] || \
  die "run from $EXPECTED_ROOT; installed units execute that canonical checkout"

[[ -f "$NOTIFY_ENV" ]] || die "$NOTIFY_ENV is missing"
require_private_file "$NOTIFY_ENV" "$NOTIFY_ENV"

require_single_cfg "$NOTIFY_ENV" RATATOSKR_SEND_API_KEY
require_single_cfg "$NOTIFY_ENV" TELEGRAM_ALLOWED_USERS
require_single_cfg "$NOTIFY_ENV" TELEGRAM_BOT_TOKEN
send_key="$(cfg_get "$NOTIFY_ENV" RATATOSKR_SEND_API_KEY)"
chat_ids="$(cfg_get "$NOTIFY_ENV" TELEGRAM_ALLOWED_USERS)"
bot_token="$(cfg_get "$NOTIFY_ENV" TELEGRAM_BOT_TOKEN)"
[[ -n "$send_key" ]] || die "RATATOSKR_SEND_API_KEY is empty in $NOTIFY_ENV"
[[ "$chat_ids" =~ ^-?[0-9]+(,-?[0-9]+)*$ ]] || die "TELEGRAM_ALLOWED_USERS is empty or invalid in $NOTIFY_ENV"
[[ -n "$bot_token" ]] || die "TELEGRAM_BOT_TOKEN is empty in $NOTIFY_ENV; direct fallback is mandatory"
unset send_key chat_ids bot_token
echo "preflight: notification variable names, ownership, and mode are valid (values not printed)"

external_configured=0
external_url=""
if [[ -e "$EXTERNAL_ENV" ]]; then
  [[ -f "$EXTERNAL_ENV" ]] || die "$EXTERNAL_ENV exists but is not a regular file"
  require_private_file "$EXTERNAL_ENV" "$EXTERNAL_ENV"
  require_single_cfg "$EXTERNAL_ENV" CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL
  external_active_lines="$(grep -Ecv '^[[:space:]]*(#|$)' "$EXTERNAL_ENV" 2>/dev/null || true)"
  [[ "$external_active_lines" == 1 ]] || \
    die "$EXTERNAL_ENV must contain only the external heartbeat assignment (found $external_active_lines active lines)"
  external_url="$(cfg_get "$EXTERNAL_ENV" CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL)"
  valid_external_url "$external_url" || \
    die "$EXTERNAL_ENV must contain one non-empty HTTPS heartbeat URL (value not printed)"
  external_configured=1
  echo "preflight: external heartbeat configuration is protected and valid (value not printed)"
else
  echo "preflight: external heartbeat is not configured"
fi

curl -fsS -m 8 -o /dev/null "$TARGET_URL" || die "production probe failed: $TARGET_URL"
echo "preflight: production probe passes"

systemctl --user show-environment >/dev/null || die "user systemd manager is unavailable"
user_name="$(id -un)"
[[ "$(loginctl show-user "$user_name" -p Linger --value 2>/dev/null)" == "yes" ]] || \
  die "user lingering is disabled; run: sudo loginctl enable-linger $user_name"
echo "preflight: user systemd manager and lingering are ready"

if [[ "$external_configured" == 1 ]]; then
  if ! external_ping_url "$external_url"; then
    unset external_url
    die "external heartbeat preflight failed (URL not printed)"
  fi
  unset external_url
  echo "preflight: external heartbeat accepted a ping after the production probe passed (URL not printed)"
fi

rollback_dir="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-deadman-deploy.XXXXXX")" || \
  die "could not create rollback workspace"
trap 'rm -rf "$rollback_dir"' EXIT
prior_service=0
prior_timer=0
prior_timer_enabled=0
prior_timer_active=0
transaction_mutated=0
transaction_committed=0
state_dir="$STATE_ROOT/control-node-deadman"
state_files="fail-count state last-alert last-success last-external-success last-error"

if [[ -e "$UNIT_DIR/$SERVICE" || -L "$UNIT_DIR/$SERVICE" ]]; then
  cp -a "$UNIT_DIR/$SERVICE" "$rollback_dir/$SERVICE" || die "could not snapshot prior service unit"
  prior_service=1
fi
if [[ -e "$UNIT_DIR/$TIMER" || -L "$UNIT_DIR/$TIMER" ]]; then
  cp -a "$UNIT_DIR/$TIMER" "$rollback_dir/$TIMER" || die "could not snapshot prior timer unit"
  prior_timer=1
  if systemctl --user is-enabled --quiet "$TIMER"; then prior_timer_enabled=1; fi
  if systemctl --user is-active --quiet "$TIMER"; then prior_timer_active=1; fi
fi
mkdir -p "$rollback_dir/state"
for state_name in $state_files; do
  if [[ -f "$state_dir/$state_name" ]]; then
    cp -p "$state_dir/$state_name" "$rollback_dir/state/$state_name" || \
      die "could not snapshot prior dead-man state"
  fi
done

rollback_transaction() {
  local rollback_failed=0 state_name
  systemctl --user stop "$TIMER" >/dev/null 2>&1 || rollback_failed=1
  # Always remove any enablement created by the candidate unit before its
  # files disappear. In particular, enable --now can create the wants symlink
  # and then fail, which must not leave a dangling enabled timer on a first
  # install. Prior enable/active state is restored below after daemon-reload.
  systemctl --user disable "$TIMER" >/dev/null 2>&1 || rollback_failed=1

  rm -f "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER" || rollback_failed=1
  if [[ "$prior_service" == 1 ]]; then
    cp -a "$rollback_dir/$SERVICE" "$UNIT_DIR/$SERVICE" || rollback_failed=1
  fi
  if [[ "$prior_timer" == 1 ]]; then
    cp -a "$rollback_dir/$TIMER" "$UNIT_DIR/$TIMER" || rollback_failed=1
  fi
  systemctl --user daemon-reload >/dev/null 2>&1 || rollback_failed=1

  if [[ "$prior_timer" == 1 ]]; then
    if [[ "$prior_timer_enabled" == 1 ]]; then
      systemctl --user enable "$TIMER" >/dev/null 2>&1 || rollback_failed=1
    else
      systemctl --user disable "$TIMER" >/dev/null 2>&1 || rollback_failed=1
    fi
    if [[ "$prior_timer_active" == 1 ]]; then
      systemctl --user start "$TIMER" >/dev/null 2>&1 || rollback_failed=1
    else
      systemctl --user stop "$TIMER" >/dev/null 2>&1 || rollback_failed=1
    fi
  fi

  mkdir -p "$state_dir" || rollback_failed=1
  for state_name in $state_files; do
    rm -f "$state_dir/$state_name" || rollback_failed=1
    if [[ -f "$rollback_dir/state/$state_name" ]]; then
      cp -p "$rollback_dir/state/$state_name" "$state_dir/$state_name" || rollback_failed=1
    fi
  done
  return "$rollback_failed"
}

finish_transaction() {
  local rc=$? preserve_rollback=0
  trap - EXIT
  if [[ "$transaction_mutated" == 1 && "$transaction_committed" != 1 ]]; then
    if rollback_transaction; then
      echo "rollback: restored prior units, timer state, and dead-man state" >&2
    else
      preserve_rollback=1
      chmod 0700 "$rollback_dir" 2>/dev/null || true
      echo "ERROR: rollback was incomplete; recovery snapshot preserved at $rollback_dir" >&2
    fi
  fi
  if [[ "$preserve_rollback" != 1 ]]; then
    rm -rf "$rollback_dir"
  fi
  exit "$rc"
}
trap finish_transaction EXIT

install -d -m 0755 "$UNIT_DIR"
transaction_mutated=1
if [[ "$prior_timer_active" == 1 ]]; then
  systemctl --user stop "$TIMER" || die "could not stop prior $TIMER for atomic upgrade"
fi
install -m 0644 "$HERE/systemd/m5/$SERVICE" "$UNIT_DIR/$SERVICE"
install -m 0644 "$HERE/systemd/m5/$TIMER" "$UNIT_DIR/$TIMER"
systemctl --user daemon-reload || die "user systemd daemon-reload failed"
probe_started_at="$(date +%s)"
systemctl --user start "$SERVICE" || die "$SERVICE runtime validation failed"

[[ "$(cat "$STATE_ROOT/control-node-deadman/state" 2>/dev/null || true)" == "pass" ]] || \
  die "$SERVICE did not record a passing production probe"
last_success="$(cat "$STATE_ROOT/control-node-deadman/last-success" 2>/dev/null || true)"
[[ "$last_success" =~ ^[0-9]+$ && "$last_success" -ge "$probe_started_at" ]] || \
  die "$SERVICE did not record a fresh production probe"
if [[ "$external_configured" == 1 ]]; then
  last_external_success="$(cat "$STATE_ROOT/control-node-deadman/last-external-success" 2>/dev/null || true)"
  [[ "$last_external_success" =~ ^[0-9]+$ && "$last_external_success" -ge "$probe_started_at" ]] || \
    die "$SERVICE did not record a fresh external heartbeat"
fi

# Timer activation is the commit point. It happens only after the exact unit
# that will be scheduled has passed all production and external runtime gates.
systemctl --user enable --now "$TIMER" || die "could not enable and start $TIMER"
systemctl --user is-enabled --quiet "$TIMER" || die "$TIMER is not enabled"
systemctl --user is-active --quiet "$TIMER" || die "$TIMER is not active"
transaction_committed=1

echo "installed: $TIMER is enabled and active; production and configured external probes passed"
