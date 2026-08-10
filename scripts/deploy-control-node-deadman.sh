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
LEGACY_STATE_FILE_NAMES="fail-count state last-alert last-success last-external-success"
LEGACY_SERVICE="${BROKKR_DEADMAN_LEGACY_SERVICE:-}"
LEGACY_TIMER="${BROKKR_DEADMAN_LEGACY_TIMER:-}"
LEGACY_STATE_DIR="${BROKKR_DEADMAN_LEGACY_STATE_DIR:-}"
LEGACY_SCRIPT="${BROKKR_DEADMAN_LEGACY_SCRIPT:-}"

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
  local rollback_failed=0 state_name legacy_path legacy_name legacy_state_entry
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

  # Restore any legacy unit files that were retired for this upgrade.  The
  # manifest is created only after all preflight gates pass, so a failed
  # upgrade cannot strand the old monitor in a stopped/disabled state.
  if [[ -s "$rollback_dir/legacy-units.manifest" || -s "$rollback_dir/legacy-state.manifest" ]]; then
    while IFS= read -r legacy_path; do
      [[ -n "$legacy_path" ]] || continue
      legacy_name="${legacy_path##*/}"
      rm -f "$legacy_path" || rollback_failed=1
      if [[ -e "$rollback_dir/legacy-units/$legacy_name" || -L "$rollback_dir/legacy-units/$legacy_name" ]]; then
        cp -a "$rollback_dir/legacy-units/$legacy_name" "$legacy_path" || rollback_failed=1
      fi
    done <"$rollback_dir/legacy-units.manifest"
    systemctl --user daemon-reload >/dev/null 2>&1 || rollback_failed=1

    while IFS= read -r legacy_path; do
      [[ -n "$legacy_path" ]] || continue
      legacy_name="${legacy_path##*/}"
      [[ "$legacy_name" == *.timer ]] || continue
      if [[ -f "$rollback_dir/legacy-units/$legacy_name.enabled" ]]; then
        systemctl --user enable "$legacy_name" >/dev/null 2>&1 || rollback_failed=1
      else
        systemctl --user disable "$legacy_name" >/dev/null 2>&1 || rollback_failed=1
      fi
      if [[ -f "$rollback_dir/legacy-units/$legacy_name.active" ]]; then
        systemctl --user start "$legacy_name" >/dev/null 2>&1 || rollback_failed=1
      else
        systemctl --user stop "$legacy_name" >/dev/null 2>&1 || rollback_failed=1
      fi
    done <"$rollback_dir/legacy-units.manifest"

    while IFS='|' read -r legacy_name legacy_state_entry; do
      [[ -n "$legacy_name" && -n "$legacy_state_entry" ]] || continue
      if [[ -f "$rollback_dir/legacy-state/$legacy_name/$legacy_state_entry" ]]; then
        mkdir -p "$STATE_ROOT/$legacy_name" || rollback_failed=1
        cp -p "$rollback_dir/legacy-state/$legacy_name/$legacy_state_entry" \
          "$STATE_ROOT/$legacy_name/$legacy_state_entry" || rollback_failed=1
      fi
    done <"$rollback_dir/legacy-state.manifest"
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

validate_legacy_identity() {
  local identity_count=0 state_relative expected_exec
  [[ -n "$LEGACY_SERVICE" ]] && identity_count=$((identity_count + 1))
  [[ -n "$LEGACY_TIMER" ]] && identity_count=$((identity_count + 1))
  [[ -n "$LEGACY_STATE_DIR" ]] && identity_count=$((identity_count + 1))
  [[ -n "$LEGACY_SCRIPT" ]] && identity_count=$((identity_count + 1))

  if [[ "$identity_count" == 0 ]]; then
    LEGACY_CONFIGURED=0
    return 0
  fi
  [[ "$identity_count" == 4 ]] || die "legacy migration requires service, timer, state directory, and script identity"
  [[ "$LEGACY_SERVICE" =~ ^[A-Za-z0-9][A-Za-z0-9_.@:+-]*\.service$ ]] || die "invalid legacy service identity"
  [[ "$LEGACY_TIMER" =~ ^[A-Za-z0-9][A-Za-z0-9_.@:+-]*\.timer$ ]] || die "invalid legacy timer identity"
  [[ "$LEGACY_SERVICE" != "$SERVICE" && "$LEGACY_TIMER" != "$TIMER" ]] || die "legacy identity names the current unit"
  [[ "$LEGACY_SCRIPT" =~ ^scripts/[A-Za-z0-9][A-Za-z0-9_.@:+-]*\.sh$ ]] || die "invalid legacy script identity"
  case "$LEGACY_STATE_DIR" in
    "$STATE_ROOT"/*) state_relative="${LEGACY_STATE_DIR#"$STATE_ROOT"/}" ;;
    *) die "legacy state directory must be one child of the configured state root" ;;
  esac
  [[ "$state_relative" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid legacy state directory identity"
  [[ -f "$UNIT_DIR/$LEGACY_SERVICE" && ! -L "$UNIT_DIR/$LEGACY_SERVICE" ]] || die "legacy service unit is missing or not regular"
  [[ -f "$UNIT_DIR/$LEGACY_TIMER" && ! -L "$UNIT_DIR/$LEGACY_TIMER" ]] || die "legacy timer unit is missing or not regular"
  [[ -d "$LEGACY_STATE_DIR" && ! -L "$LEGACY_STATE_DIR" ]] || die "legacy state directory is missing or not regular"

  expected_exec="%h/repos/brokkr/$LEGACY_SCRIPT"
  grep -Fqx "ExecStart=$expected_exec" "$UNIT_DIR/$LEGACY_SERVICE" || die "legacy service script reference does not match identity"
  grep -Fqx "Unit=$LEGACY_SERVICE" "$UNIT_DIR/$LEGACY_TIMER" || die "legacy timer does not target the legacy service identity"
  LEGACY_STATE_NAME="$state_relative"
  LEGACY_CONFIGURED=1
}

retire_legacy_install() {
  local legacy_path legacy_name legacy_state_dir state_name source destination
  : >"$rollback_dir/legacy-units.manifest"
  : >"$rollback_dir/legacy-state.manifest"
  mkdir -p "$rollback_dir/legacy-units" "$rollback_dir/legacy-state"

  [[ "$LEGACY_CONFIGURED" == 1 ]] || return 0
  for legacy_name in "$LEGACY_TIMER" "$LEGACY_SERVICE"; do
    legacy_path="$UNIT_DIR/$legacy_name"
    printf '%s\n' "$legacy_path" >>"$rollback_dir/legacy-units.manifest"
    cp -a "$legacy_path" "$rollback_dir/legacy-units/$legacy_name" || \
      die "could not snapshot legacy unit $legacy_name"
    if [[ "$legacy_name" == "$LEGACY_TIMER" ]]; then
      if systemctl --user is-enabled --quiet "$legacy_name"; then
        printf 'enabled\n' >"$rollback_dir/legacy-units/$legacy_name.enabled"
      fi
      if systemctl --user is-active --quiet "$legacy_name"; then
        printf 'active\n' >"$rollback_dir/legacy-units/$legacy_name.active"
      fi
      systemctl --user stop "$legacy_name" || die "could not stop legacy $legacy_name"
      systemctl --user disable "$legacy_name" || die "could not disable legacy $legacy_name"
    else
      systemctl --user stop "$legacy_name" || die "could not stop legacy $legacy_name"
    fi
    rm -f "$legacy_path" || die "could not remove legacy unit $legacy_name"
  done

  legacy_state_dir="$LEGACY_STATE_DIR"
  legacy_name="$LEGACY_STATE_NAME"
  mkdir -p "$rollback_dir/legacy-state/$legacy_name"
  for state_name in $LEGACY_STATE_FILE_NAMES; do
    source="$legacy_state_dir/$state_name"
    [[ -f "$source" && ! -L "$source" ]] || continue
    printf '%s|%s\n' "$legacy_name" "$state_name" >>"$rollback_dir/legacy-state.manifest"
    cp -p "$source" "$rollback_dir/legacy-state/$legacy_name/$state_name" || \
      die "could not snapshot legacy dead-man state"
    destination="$state_dir/$state_name"
    if [[ ! -e "$destination" ]]; then
      mkdir -p "$state_dir" || die "could not create current dead-man state directory"
      cp -p "$source" "$destination" || die "could not migrate legacy dead-man state"
    fi
    rm -f "$source" || die "could not retire legacy dead-man state"
  done
  rmdir "$legacy_state_dir" 2>/dev/null || true
}

LEGACY_CONFIGURED=0
LEGACY_STATE_NAME=""
validate_legacy_identity
transaction_mutated=1
retire_legacy_install

install -d -m 0755 "$UNIT_DIR"
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
