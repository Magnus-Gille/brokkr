#!/usr/bin/env bash
# Hermetic acceptance tests for the live dead-man drill helper. No real network,
# systemd, provider, or notification request is allowed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/../control-node-deadman-acceptance-drill.sh"
RUNTIME="$HERE/../control-node-deadman.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/drills" "$TMP/production-state"
printf 'pass\n' >"$TMP/production-state/state"
date +%s >"$TMP/production-state/last-external-success"

cat >"$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  printf '%s\n' "${MOCK_UID:-1000}"
  exit 0
fi
exit 2
EOF

cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_SYSTEMCTL_LOG"
case "$*" in
  "--user is-enabled --quiet brokkr-control-node-deadman.timer")
    [[ "${MOCK_TIMER_ENABLED:-1}" == 1 ]]
    ;;
  "--user is-active --quiet brokkr-control-node-deadman.timer")
    [[ "${MOCK_TIMER_ACTIVE:-1}" == 1 ]]
    ;;
  *)
    printf 'unexpected systemctl call\n' >&2
    exit 90
    ;;
esac
EOF

REAL_PYTHON="$(command -v python3)"
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
target=""
for arg in "$@"; do
  if [[ "$arg" == http://* || "$arg" == https://* ]]; then
    target="$arg"
  fi
done
case "$target" in
  "http://127.0.0.1:9/")
    printf 'fixture connection refused\n' >&2
    exit 7
    ;;
  "http://127.0.0.1:8/")
    exit 0
    ;;
esac
if [[ "$target" == "http://127.0.0.1:43123/" ]]; then
  : >"$MOCK_RESPONDER_RELEASE"
  exit 0
fi
printf 'unexpected curl target\n' >&2
exit 91
EOF

cat >"$TMP/bin/python3" <<'EOF'
#!/usr/bin/env bash
[[ "$#" -eq 2 && "$1" == - ]] || exit 92
payload="$2.py"
cat >"$payload"
"$REAL_PYTHON" -m py_compile "$payload" || exit 93
printf '43123' >"$2"
while [[ ! -e "$MOCK_RESPONDER_RELEASE" ]]; do
  sleep 0.01
done
EOF

cat >"$TMP/notify.sh" <<'EOF'
notify_telegram() {
  printf '%s\n' "$1" >>"$MOCK_NOTIFY_LOG"
}
EOF

cat >"$TMP/notify.env" <<'EOF'
RATATOSKR_SEND_API_KEY=fixture-send-secret
TELEGRAM_BOT_TOKEN=fixture-bot-secret
TELEGRAM_ALLOWED_USERS=123456
EOF
chmod 600 "$TMP/notify.env"
chmod +x "$TMP/bin/id" "$TMP/bin/systemctl" "$TMP/bin/curl" "$TMP/bin/python3"

REAL_UID="$(id -u)"
export PATH="$TMP/bin:$PATH"
export REAL_PYTHON
export MOCK_SYSTEMCTL_LOG="$TMP/systemctl.log"
export MOCK_NOTIFY_LOG="$TMP/notify.log"
export MOCK_RESPONDER_RELEASE="$TMP/responder.release"
export BROKKR_DEADMAN_ID_BIN="$TMP/bin/id"
export BROKKR_DEADMAN_SYSTEMCTL_BIN="$TMP/bin/systemctl"
export BROKKR_DEADMAN_SCRIPT="$RUNTIME"
export BROKKR_DEADMAN_NOTIFY_HELPER="$TMP/notify.sh"
export BROKKR_DEADMAN_PRODUCTION_STATE_DIR="$TMP/production-state"
export BROKKR_DEADMAN_DRILL_TMPDIR="$TMP/drills"
export BROKKR_DEADMAN_PYTHON_BIN="$TMP/bin/python3"
export BROKKR_DEADMAN_DRILL_RECOVERY_URL="http://127.0.0.1:8/"
export NOTIFY_ENV="$TMP/notify.env"
export MOCK_UID="$REAL_UID" MOCK_TIMER_ENABLED=1 MOCK_TIMER_ACTIVE=1
: >"$MOCK_SYSTEMCTL_LOG"
: >"$MOCK_NOTIFY_LOG"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
run_helper() {
  OUT="$("$HELPER" "$@" 2>&1)"
  RC=$?
}
check() {
  local desc="$1"
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}

printf 'control-node-deadman-acceptance-drill.test.sh\n'

run_helper
check "missing explicit live confirmation refuses" test "$RC" -eq 64
check "refusal sends no notification" test ! -s "$MOCK_NOTIFY_LOG"
check "refusal makes no systemd call" test ! -s "$MOCK_SYSTEMCTL_LOG"
if grep -Fq "$TMP" <<<"$OUT"; then
  bad "refusal output contains no private path"
else
  ok "refusal output contains no private path"
fi

MOCK_UID=0 run_helper --confirm-live-alerts
check "root execution refuses" test "$RC" -ne 0
check "root refusal sends no notification" test ! -s "$MOCK_NOTIFY_LOG"

export MOCK_UID="$REAL_UID" MOCK_TIMER_ENABLED=0
run_helper --confirm-live-alerts
check "disabled production timer fails closed" test "$RC" -ne 0
check "disabled timer sends no notification" test ! -s "$MOCK_NOTIFY_LOG"

export MOCK_TIMER_ENABLED=1 MOCK_TIMER_ACTIVE=1
: >"$MOCK_SYSTEMCTL_LOG"
: >"$MOCK_NOTIFY_LOG"
production_state_before="$(cat "$TMP/production-state/state")"
production_external_before="$(cat "$TMP/production-state/last-external-success")"
run_helper --confirm-live-alerts
check "confirmed isolated drill succeeds" test "$RC" -eq 0
check "exactly failure, recovery, and fallback notifications are attempted" test "$(wc -l <"$MOCK_NOTIFY_LOG" | tr -d ' ')" -eq 3
check "isolated failure notification is present" grep -q "missed 3 probes" "$MOCK_NOTIFY_LOG"
check "isolated recovery notification is present" grep -q "recovered" "$MOCK_NOTIFY_LOG"
check "direct fallback notification is present" grep -q "direct fallback drill" "$MOCK_NOTIFY_LOG"
check "production timer is checked before and after without mutation" test "$(wc -l <"$MOCK_SYSTEMCTL_LOG" | tr -d ' ')" -eq 4
if grep -Eq '(^| )(start|stop|restart|enable|disable|set-environment|daemon-reload)( |$)' "$MOCK_SYSTEMCTL_LOG"; then
  bad "helper never mutates systemd"
else
  ok "helper never mutates systemd"
fi
check "helper-created drill state is removed" test -z "$(find "$TMP/drills" -mindepth 1 -maxdepth 1 -print -quit)"
check "production pass state is unchanged" test "$(cat "$TMP/production-state/state")" = "$production_state_before"
check "production external timestamp is unchanged" test "$(cat "$TMP/production-state/last-external-success")" = "$production_external_before"
check "receipt marks attempted actions, not confirmed delivery" grep -q '^operator_delivery_confirmation=required$' <<<"$OUT"
check "receipt keeps provider missed-window proof separate" grep -q '^provider_missed_window_drill=required$' <<<"$OUT"
check "receipt confirms isolated recovery" grep -q '^isolated_recovery_state=pass$' <<<"$OUT"
if grep -Fq 'fixture-send-secret' <<<"$OUT" ||
   grep -Fq 'fixture-bot-secret' <<<"$OUT" ||
   grep -Fq "$TMP" <<<"$OUT" ||
   grep -Eq 'https?://' <<<"$OUT"; then
  bad "receipt contains no secrets, paths, or URLs"
else
  ok "receipt contains no secrets, paths, or URLs"
fi

export BROKKR_DEADMAN_DRILL_RECOVERY_URL=''
: >"$MOCK_SYSTEMCTL_LOG"
: >"$MOCK_NOTIFY_LOG"
rm -f "$MOCK_RESPONDER_RELEASE"
run_helper --confirm-live-alerts
check "default loopback recovery responder succeeds" test "$RC" -eq 0
check "default responder produces the recovery notification" grep -q "recovered" "$MOCK_NOTIFY_LOG"
check "default responder drill attempts exactly three notifications" test "$(wc -l <"$MOCK_NOTIFY_LOG" | tr -d ' ')" -eq 3
check "default responder drill cleans up its state" test -z "$(find "$TMP/drills" -mindepth 1 -maxdepth 1 -print -quit)"
export BROKKR_DEADMAN_DRILL_RECOVERY_URL="http://127.0.0.1:8/"

export MOCK_TIMER_ACTIVE=0
: >"$MOCK_NOTIFY_LOG"
run_helper --confirm-live-alerts
check "inactive production timer fails closed" test "$RC" -ne 0
check "inactive timer sends no notification" test ! -s "$MOCK_NOTIFY_LOG"

export MOCK_TIMER_ACTIVE=1
printf '1\n' >"$TMP/production-state/last-external-success"
: >"$MOCK_NOTIFY_LOG"
run_helper --confirm-live-alerts
check "stale external heartbeat fails closed" test "$RC" -ne 0
check "stale heartbeat sends no notification" test ! -s "$MOCK_NOTIFY_LOG"
date +%s >"$TMP/production-state/last-external-success"

export BROKKR_DEADMAN_DRILL_RECOVERY_URL="http://example.invalid/"
: >"$MOCK_NOTIFY_LOG"
run_helper --confirm-live-alerts
check "non-loopback injected recovery endpoint refuses" test "$RC" -ne 0
check "invalid recovery endpoint refuses before notification" test ! -s "$MOCK_NOTIFY_LOG"
export BROKKR_DEADMAN_DRILL_RECOVERY_URL="http://127.0.0.1:8/"

chmod 644 "$TMP/notify.env"
: >"$MOCK_NOTIFY_LOG"
run_helper --confirm-live-alerts
check "unsafe notification config mode refuses" test "$RC" -ne 0
check "unsafe notification config sends no notification" test ! -s "$MOCK_NOTIFY_LOG"
chmod 600 "$TMP/notify.env"

printf '%s\n' "----" "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
