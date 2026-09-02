#!/usr/bin/env bash
# Live, isolated acceptance drill for the control-node dead-man alert paths.
# The production timer and production state are read-only prerequisites.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMER="brokkr-control-node-deadman.timer"
DEADMAN_SCRIPT="${BROKKR_DEADMAN_SCRIPT:-$HERE/control-node-deadman.sh}"
NOTIFY_HELPER="${BROKKR_DEADMAN_NOTIFY_HELPER:-$HERE/lib/notify.sh}"
SYSTEMCTL_BIN="${BROKKR_DEADMAN_SYSTEMCTL_BIN:-systemctl}"
ID_BIN="${BROKKR_DEADMAN_ID_BIN:-id}"
PYTHON_BIN="${BROKKR_DEADMAN_PYTHON_BIN:-python3}"
PRODUCTION_STATE_DIR="${BROKKR_DEADMAN_PRODUCTION_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/brokkr/control-node-deadman}"
DRILL_TMPDIR="${BROKKR_DEADMAN_DRILL_TMPDIR:-${TMPDIR:-/tmp}}"
NOTIFY_ENV_PATH="${NOTIFY_ENV:-$HOME/.config/grimnir/notify.env}"
EXTERNAL_MAX_AGE_SECS="${BROKKR_DEADMAN_EXTERNAL_MAX_AGE_SECS:-300}"
RECOVERY_URL="${BROKKR_DEADMAN_DRILL_RECOVERY_URL:-}"

usage() {
  printf '%s\n' "usage: control-node-deadman-acceptance-drill.sh --confirm-live-alerts" >&2
  printf '%s\n' "Sends three operator test notifications; never mutates the production timer or state." >&2
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

stat_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

stat_uid() {
  stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null
}

[[ "$#" -eq 1 && "$1" == "--confirm-live-alerts" ]] || {
  usage
  exit 64
}

current_uid="$("$ID_BIN" -u 2>/dev/null)" || die "cannot determine runtime identity"
[[ "$current_uid" =~ ^[0-9]+$ ]] || die "runtime identity is invalid"
[[ "$current_uid" -ne 0 ]] || die "run the drill as the monitoring service user, not root"
[[ -x "$DEADMAN_SCRIPT" && ! -L "$DEADMAN_SCRIPT" ]] ||
  die "dead-man runtime is unavailable or unsafe"
[[ -f "$NOTIFY_HELPER" && ! -L "$NOTIFY_HELPER" ]] ||
  die "notification helper is unavailable or unsafe"
[[ -f "$NOTIFY_ENV_PATH" && ! -L "$NOTIFY_ENV_PATH" ]] ||
  die "protected notification configuration is unavailable or unsafe"
notify_mode="$(stat_mode "$NOTIFY_ENV_PATH")" ||
  die "cannot inspect protected notification configuration"
notify_uid="$(stat_uid "$NOTIFY_ENV_PATH")" ||
  die "cannot inspect protected notification configuration"
[[ "$notify_mode" == 600 || "$notify_mode" == 400 ]] ||
  die "protected notification configuration must be owner-only"
[[ "$notify_uid" == "$current_uid" ]] ||
  die "protected notification configuration has the wrong owner"
[[ "$EXTERNAL_MAX_AGE_SECS" =~ ^[1-9][0-9]*$ ]] ||
  die "external heartbeat freshness bound is invalid"
if [[ -n "$RECOVERY_URL" ]]; then
  [[ "$RECOVERY_URL" =~ ^http://127\.0\.0\.1:[1-9][0-9]*/$ ]] ||
    die "injected recovery endpoint must be loopback HTTP"
fi

timer_gate() {
  "$SYSTEMCTL_BIN" --user is-enabled --quiet "$TIMER" &&
    "$SYSTEMCTL_BIN" --user is-active --quiet "$TIMER"
}

production_state_gate() {
  local state last_external now age
  state="$(cat "$PRODUCTION_STATE_DIR/state" 2>/dev/null || true)"
  last_external="$(cat "$PRODUCTION_STATE_DIR/last-external-success" 2>/dev/null || true)"
  [[ "$state" == pass && "$last_external" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)" || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  if [[ "$last_external" -gt $((now + 5)) ]]; then
    return 1
  fi
  age=$((now - last_external))
  [[ "$age" -le "$EXTERNAL_MAX_AGE_SECS" ]]
}

timer_gate || die "production dead-man timer is not enabled and active"
production_state_gate ||
  die "production dead-man state or external heartbeat is not fresh"

umask 077
drill_root=""
responder_pid=""
cleanup_done=0

cleanup() {
  local cleanup_rc=0
  if [[ -n "$responder_pid" ]]; then
    kill "$responder_pid" 2>/dev/null || true
    wait "$responder_pid" 2>/dev/null || true
    responder_pid=""
  fi
  if [[ -n "$drill_root" ]]; then
    case "$drill_root" in
      "$DRILL_TMPDIR"/brokkr-control-node-deadman-drill.*) ;;
      *)
        cleanup_rc=1
        ;;
    esac
    if [[ "$cleanup_rc" -eq 0 && -d "$drill_root" && ! -L "$drill_root" &&
          -f "$drill_root/.brokkr-deadman-drill" && ! -L "$drill_root/.brokkr-deadman-drill" &&
          "$(cat "$drill_root/.brokkr-deadman-drill" 2>/dev/null)" == owned ]]; then
      rm -rf -- "$drill_root" || cleanup_rc=1
      [[ ! -e "$drill_root" ]] || cleanup_rc=1
    else
      cleanup_rc=1
    fi
  fi
  cleanup_done=1
  return "$cleanup_rc"
}

trap 'if [[ "$cleanup_done" -eq 0 ]]; then cleanup || true; fi' EXIT

[[ -d "$DRILL_TMPDIR" && ! -L "$DRILL_TMPDIR" ]] ||
  die "drill temporary parent is unavailable or unsafe"
drill_root="$(mktemp -d "$DRILL_TMPDIR/brokkr-control-node-deadman-drill.XXXXXXXX")" ||
  die "cannot allocate isolated drill state"
printf 'owned\n' >"$drill_root/.brokkr-deadman-drill" ||
  die "cannot mark isolated drill state"
private_log="$drill_root/drill.log"
isolated_state="$drill_root/state"
now="$(date +%s)" || die "cannot read drill clock"

run_isolated() {
  local at="$1" url="$2"
  BROKKR_STATE_DIR="$isolated_state" \
  BROKKR_NOTIFY_HELPER="$NOTIFY_HELPER" \
  NOTIFY_ENV="$NOTIFY_ENV_PATH" \
  CONTROL_NODE_DEADMAN_TARGET_NAME="acceptance-drill" \
  CONTROL_NODE_DEADMAN_URL="$url" \
  CONTROL_NODE_DEADMAN_TIMEOUT_SECS=2 \
  CONTROL_NODE_DEADMAN_FAIL_AFTER=3 \
  CONTROL_NODE_DEADMAN_ALERT_COOLDOWN_SECS=300 \
  CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL='' \
  BROKKR_DEADMAN_NOW="$at" \
    "$DEADMAN_SCRIPT" >>"$private_log" 2>&1
}

run_isolated "$now" "http://127.0.0.1:9/" ||
  die "first isolated target miss did not complete"
run_isolated "$((now + 1))" "http://127.0.0.1:9/" ||
  die "second isolated target miss did not complete"
run_isolated "$((now + 2))" "http://127.0.0.1:9/" ||
  die "third isolated target miss did not complete"
[[ "$(cat "$isolated_state/control-node-deadman/state" 2>/dev/null)" == fail &&
   "$(cat "$isolated_state/control-node-deadman/fail-count" 2>/dev/null)" == 3 ]] ||
  die "isolated failure transition was not recorded"

if [[ -n "$RECOVERY_URL" ]]; then
  recovery_url="$RECOVERY_URL"
else
  port_file="$drill_root/responder.port"
  "$PYTHON_BIN" - "$port_file" >>"$private_log" 2>&1 <<'PY' &
import http.server
import socketserver
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"OK")

    def log_message(self, _format, *_args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    with open(sys.argv[1], "w", encoding="ascii") as handle:
        handle.write(str(server.server_address[1]))
    server.timeout = 10
    server.handle_request()
PY
  responder_pid="$!"

  attempt=0
  while [[ ! -s "$port_file" && "$attempt" -lt 200 ]]; do
    kill -0 "$responder_pid" 2>/dev/null ||
      die "isolated recovery responder exited before readiness"
    sleep 0.05
    attempt=$((attempt + 1))
  done
  [[ -s "$port_file" ]] || die "isolated recovery responder readiness timed out"
  recovery_port="$(cat "$port_file" 2>/dev/null)"
  [[ "$recovery_port" =~ ^[0-9]+$ && "$recovery_port" -ge 1 &&
     "$recovery_port" -le 65535 ]] ||
    die "isolated recovery responder returned an invalid port"
  recovery_url="http://127.0.0.1:$recovery_port/"
fi

run_isolated "$((now + 3))" "$recovery_url" ||
  die "isolated recovery probe did not complete"
if [[ -n "$responder_pid" ]]; then
  wait "$responder_pid" || die "isolated recovery responder failed"
  responder_pid=""
fi
[[ "$(cat "$isolated_state/control-node-deadman/state" 2>/dev/null)" == pass &&
   "$(cat "$isolated_state/control-node-deadman/fail-count" 2>/dev/null)" == 0 ]] ||
  die "isolated recovery transition was not recorded"

RATATOSKR_URL="http://127.0.0.1:9/" \
RATATOSKR_ENV="$drill_root/not-present" \
NOTIFY_ENV="$NOTIFY_ENV_PATH" \
  bash -c 'source "$1"; notify_telegram "Brokkr dead-man direct fallback drill from monitoring host"' \
    _ "$NOTIFY_HELPER" >>"$private_log" 2>&1 ||
  die "direct fallback drill invocation failed"

timer_gate || die "production dead-man timer changed during the drill"
production_state_gate ||
  die "production dead-man state or external heartbeat changed during the drill"
cleanup || die "isolated drill cleanup failed"
trap - EXIT

observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" ||
  die "cannot create metadata receipt"
printf '%s\n' \
  "schema=brokkr-control-node-deadman-acceptance/v1" \
  "observed_at=$observed_at" \
  "production_timer_enabled=pass" \
  "production_timer_active=pass" \
  "production_state=pass" \
  "external_heartbeat_fresh=pass" \
  "isolated_failure_state=pass" \
  "isolated_recovery_state=pass" \
  "failure_notification=attempted" \
  "recovery_notification=attempted" \
  "direct_fallback_notification=attempted" \
  "cleanup=pass" \
  "operator_delivery_confirmation=required" \
  "provider_missed_window_drill=required"
