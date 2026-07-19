#!/usr/bin/env bash
# Brokkr · off-box dead-man check for the control node (brokkr#38).
#
# Runs on a monitoring host that does not share fate with the control node.
# It probes a lightweight control-node endpoint and sends Telegram when misses
# cross a threshold. Notification goes through scripts/lib/notify.sh, which can
# use a preferred notifier when it is reachable and direct Telegram as fallback.
#
# Target misses exit 0: they are reported by the dead-man's own alert path.
# Invalid external-heartbeat configuration or delivery exits non-zero so the
# optional independent monitoring path cannot silently fail closed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_NAME="${CONTROL_NODE_DEADMAN_TARGET_NAME:-control-node}"
TARGET_URL="${CONTROL_NODE_DEADMAN_URL:-http://control-node:3033/api/health}"
TIMEOUT_SECS="${CONTROL_NODE_DEADMAN_TIMEOUT_SECS:-8}"
FAIL_AFTER="${CONTROL_NODE_DEADMAN_FAIL_AFTER:-3}"
ALERT_COOLDOWN_SECS="${CONTROL_NODE_DEADMAN_ALERT_COOLDOWN_SECS:-1800}"
EXTERNAL_HEARTBEAT_URL="${CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL:-}"
EXTERNAL_TIMEOUT_SECS="${CONTROL_NODE_DEADMAN_EXTERNAL_TIMEOUT_SECS:-8}"
STATE_DIR="${BROKKR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/brokkr}/control-node-deadman"
NOW="${BROKKR_DEADMAN_NOW:-$(date +%s)}"
NOTIFY_HELPER="${BROKKR_NOTIFY_HELPER:-$HERE/lib/notify.sh}"

log() { printf '%s control-node-deadman: %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*"; }

positive_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
nonnegative_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

valid_external_url() {
  [[ "${1:-}" =~ ^https://[^/?#[:space:]\"\\]+([/?#][^[:space:]\"\\]*)?$ ]]
}

external_ping() {
  local status
  # --disable must be curl's first argument: otherwise ~/.curlrc can enable
  # tracing, redirects, or other behavior before command-line options apply.
  status="$(printf 'url = "%s"\n' "$EXTERNAL_HEARTBEAT_URL" | \
    curl --disable --config - --proto '=https' --max-redirs 0 -sS \
      -m "$EXTERNAL_TIMEOUT_SECS" --retry 0 -o /dev/null -w '%{http_code}' \
      2>/dev/null)" || return 1
  [[ "$status" =~ ^2[0-9][0-9]$ ]]
}

read_int_file() {
  local path="$1" fallback="$2" value
  value="$(cat "$path" 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+$ ]] && printf '%s\n' "$value" || printf '%s\n' "$fallback"
}

write_file() {
  local path="$1" value="$2"
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
  printf '%s\n' "$value" > "$path" 2>/dev/null
}

notify() {
  local msg="$1"
  if [[ -f "$NOTIFY_HELPER" ]]; then
    # shellcheck source=scripts/lib/notify.sh
    source "$NOTIFY_HELPER"
    notify_telegram "$msg"
  else
    log "notify helper missing at $NOTIFY_HELPER; alert not sent: $msg"
  fi
}

if ! positive_int "$TIMEOUT_SECS"; then
  log "no-op: invalid CONTROL_NODE_DEADMAN_TIMEOUT_SECS='$TIMEOUT_SECS'"
  exit 0
fi
if ! positive_int "$FAIL_AFTER"; then
  log "no-op: invalid CONTROL_NODE_DEADMAN_FAIL_AFTER='$FAIL_AFTER'"
  exit 0
fi
if ! nonnegative_int "$ALERT_COOLDOWN_SECS"; then
  log "no-op: invalid CONTROL_NODE_DEADMAN_ALERT_COOLDOWN_SECS='$ALERT_COOLDOWN_SECS'"
  exit 0
fi
if ! nonnegative_int "$NOW"; then
  log "no-op: invalid BROKKR_DEADMAN_NOW='$NOW'"
  exit 0
fi
if [[ -n "$EXTERNAL_HEARTBEAT_URL" ]]; then
  if ! valid_external_url "$EXTERNAL_HEARTBEAT_URL"; then
    log "refusing: external heartbeat URL must be a non-empty HTTPS URL (value not printed)"
    exit 2
  fi
  if ! positive_int "$EXTERNAL_TIMEOUT_SECS"; then
    log "refusing: invalid CONTROL_NODE_DEADMAN_EXTERNAL_TIMEOUT_SECS (value not printed)"
    exit 2
  fi
fi

fail_count_file="$STATE_DIR/fail-count"
state_file="$STATE_DIR/state"
last_alert_file="$STATE_DIR/last-alert"
last_success_file="$STATE_DIR/last-success"
last_external_success_file="$STATE_DIR/last-external-success"
last_error_file="$STATE_DIR/last-error"

prev_state="$(cat "$state_file" 2>/dev/null || printf 'unknown')"
tmp="$(mktemp "${TMPDIR:-/tmp}/brokkr-deadman.XXXXXX")" || {
  log "no-op: could not allocate temp file"
  exit 0
}
trap 'rm -f "$tmp" "$tmp.err"' EXIT

probe_err=""
if curl -fsS -m "$TIMEOUT_SECS" -o "$tmp" "$TARGET_URL" 2>"$tmp.err"; then
  write_file "$fail_count_file" 0 || true
  write_file "$state_file" pass || true
  write_file "$last_success_file" "$NOW" || true
  rm -f "$last_error_file" 2>/dev/null || true

  if [[ "$prev_state" == "fail" ]]; then
    notify "Brokkr dead-man recovered: ${TARGET_NAME} responds again at ${TARGET_URL}"
    log "RECOVERY: $TARGET_NAME responds again"
  else
    log "ok: $TARGET_NAME responds at $TARGET_URL"
  fi

  # The URL is a bearer secret. Feed it to curl over stdin so it is neither
  # logged nor exposed in the process argument list. A ping is emitted only
  # after the local target probe has passed; absence of future pings lets the
  # external provider detect loss of the monitoring host or the whole site.
  if [[ -n "$EXTERNAL_HEARTBEAT_URL" ]]; then
    if external_ping; then
      write_file "$last_external_success_file" "$NOW" || true
      log "external heartbeat delivered (URL not printed)"
    else
      log "ERROR: external heartbeat delivery failed (URL not printed)"
      exit 1
    fi
  fi
  exit 0
fi

probe_err="$(tr '\n' ' ' <"$tmp.err" 2>/dev/null | cut -c1-240)"

fail_count="$(read_int_file "$fail_count_file" 0)"
fail_count=$((fail_count + 1))
write_file "$fail_count_file" "$fail_count" || true
write_file "$last_error_file" "$probe_err" || true

if [[ "$fail_count" -lt "$FAIL_AFTER" ]]; then
  log "miss ${fail_count}/${FAIL_AFTER}: $TARGET_NAME probe failed (${probe_err:-unknown error})"
  exit 0
fi

write_file "$state_file" fail || true
last_alert="$(read_int_file "$last_alert_file" 0)"
since_alert=$((NOW - last_alert))

if [[ "$prev_state" != "fail" || "$since_alert" -ge "$ALERT_COOLDOWN_SECS" ]]; then
  notify "Brokkr dead-man: ${TARGET_NAME} missed ${fail_count} probes (${TARGET_URL}). Last error: ${probe_err:-unknown error}"
  write_file "$last_alert_file" "$NOW" || true
  log "ALERT: $TARGET_NAME missed $fail_count probes"
else
  log "still failing: $TARGET_NAME missed $fail_count probes; alert cooldown ${since_alert}/${ALERT_COOLDOWN_SECS}s"
fi

exit 0
