#!/usr/bin/env bash
# Unit test for scripts/deploy-control-node-deadman.sh. No live host, systemd, or network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$HERE/../deploy-control-node-deadman.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home/.config/grimnir"
CALLS="$TMP/calls"
: >"$CALLS"

cat >"$TMP/bin/hostname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_HOSTNAME:-inference-host}"
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$MOCK_CALLS"
if [[ "$*" == *"--config -"* ]]; then
  if [[ "${1:-}" == "--disable" ]]; then
    cat >/dev/null
  else
    cat >>"$MOCK_CURLRC_LEAK_LOG"
  fi
  printf '%s' "${MOCK_EXTERNAL_HTTP_STATUS:-204}"
  exit "${MOCK_EXTERNAL_CURL_RC:-0}"
fi
exit "${MOCK_CURL_RC:-0}"
EOF
cat >"$TMP/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
printf 'loginctl %s\n' "$*" >>"$MOCK_CALLS"
printf '%s\n' "${MOCK_LINGER:-yes}"
EOF
cat >"$TMP/bin/cp" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${MOCK_CP_FAIL_PATTERN:-}" && "$*" == *"$MOCK_CP_FAIL_PATTERN"* ]]; then
  exit 93
fi
exec /bin/cp "$@"
EOF
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_CALLS"
legacy_profile_site="$(printf '%s%s' hugin munin)"
legacy_profile_timer="brokkr-${legacy_profile_site}-deadman.timer"
case "$*" in
  "--user is-enabled --quiet brokkr-control-node-deadman.timer")
    [[ "$(cat "$MOCK_TIMER_ENABLED_FILE")" == 1 ]]
    exit
    ;;
  "--user is-active --quiet brokkr-control-node-deadman.timer")
    [[ "$(cat "$MOCK_TIMER_ACTIVE_FILE")" == 1 ]]
    exit
    ;;
  "--user enable --now brokkr-control-node-deadman.timer")
    printf '1\n' >"$MOCK_TIMER_ENABLED_FILE"
    printf '1\n' >"$MOCK_TIMER_ACTIVE_FILE"
    exit "${MOCK_ENABLE_NOW_RC:-0}"
    ;;
  "--user enable brokkr-control-node-deadman.timer")
    printf '1\n' >"$MOCK_TIMER_ENABLED_FILE"
    ;;
  "--user disable brokkr-control-node-deadman.timer")
    if [[ "${MOCK_DISABLE_RC:-0}" != 0 ]]; then
      exit "$MOCK_DISABLE_RC"
    fi
    printf '0\n' >"$MOCK_TIMER_ENABLED_FILE"
    ;;
  "--user start brokkr-control-node-deadman.timer")
    printf '1\n' >"$MOCK_TIMER_ACTIVE_FILE"
    ;;
  "--user stop brokkr-control-node-deadman.timer")
    printf '0\n' >"$MOCK_TIMER_ACTIVE_FILE"
    ;;
  "--user is-enabled legacy-node-deadman.timer")
    if [[ -n "${MOCK_LEGACY_TIMER_ENABLED_QUERY_ERROR:-}" ]]; then
      printf '%s\n' "${MOCK_LEGACY_TIMER_ENABLED_QUERY_ERROR}"
      exit 1
    fi
    if [[ "$(cat "$MOCK_LEGACY_TIMER_ENABLED_FILE")" == 1 ]]; then
      printf 'enabled\n'
      exit 0
    fi
    printf 'disabled\n'
    exit 1
    ;;
  "--user is-active legacy-node-deadman.timer")
    if [[ "$(cat "$MOCK_LEGACY_TIMER_ACTIVE_FILE")" == 1 ]]; then
      printf 'active\n'
      exit 0
    fi
    printf 'inactive\n'
    exit 3
    ;;
  "--user enable legacy-node-deadman.timer")
    printf '1\n' >"$MOCK_LEGACY_TIMER_ENABLED_FILE"
    ;;
  "--user disable legacy-node-deadman.timer")
    printf '0\n' >"$MOCK_LEGACY_TIMER_ENABLED_FILE"
    ;;
  "--user start legacy-node-deadman.timer")
    printf '1\n' >"$MOCK_LEGACY_TIMER_ACTIVE_FILE"
    ;;
  "--user stop legacy-node-deadman.timer")
    printf '0\n' >"$MOCK_LEGACY_TIMER_ACTIVE_FILE"
    ;;
  "--user is-enabled $legacy_profile_timer")
    if [[ "$(cat "$MOCK_LEGACY_TIMER_ENABLED_FILE")" == 1 ]]; then
      printf 'enabled\n'
      exit 0
    fi
    printf 'disabled\n'
    exit 1
    ;;
  "--user is-active $legacy_profile_timer")
    if [[ "$(cat "$MOCK_LEGACY_TIMER_ACTIVE_FILE")" == 1 ]]; then
      printf 'active\n'
      exit 0
    fi
    printf 'inactive\n'
    exit 3
    ;;
  "--user enable $legacy_profile_timer")
    printf '1\n' >"$MOCK_LEGACY_TIMER_ENABLED_FILE"
    ;;
  "--user disable $legacy_profile_timer")
    printf '0\n' >"$MOCK_LEGACY_TIMER_ENABLED_FILE"
    ;;
  "--user start $legacy_profile_timer")
    printf '1\n' >"$MOCK_LEGACY_TIMER_ACTIVE_FILE"
    ;;
  "--user stop $legacy_profile_timer")
    printf '0\n' >"$MOCK_LEGACY_TIMER_ACTIVE_FILE"
    ;;
  "--user start brokkr-control-node-deadman.service")
    if [[ "${MOCK_WRITE_STATE:-1}" == 1 ]]; then
      mkdir -p "$(dirname "$MOCK_STATE_FILE")"
      printf 'pass\n' >"$MOCK_STATE_FILE"
      date +%s >"$(dirname "$MOCK_STATE_FILE")/last-success"
      if [[ "${MOCK_WRITE_EXTERNAL_STATE:-1}" == 1 && -f "$MOCK_EXTERNAL_ENV" ]]; then
        date +%s >"$(dirname "$MOCK_STATE_FILE")/last-external-success"
      fi
    fi
    exit "${MOCK_SERVICE_RC:-0}"
    ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/hostname" "$TMP/bin/curl" "$TMP/bin/loginctl" "$TMP/bin/cp" "$TMP/bin/systemctl"

NOTIFY_ENV="$TMP/home/.config/grimnir/notify.env"
EXTERNAL_ENV="$TMP/home/.config/grimnir/deadman-external.env"
UNIT_DIR="$TMP/home/.config/systemd/user"
STATE_ROOT="$TMP/state"
mkdir -p "$TMP/rollback"
export PATH="$TMP/bin:$PATH" HOME="$TMP/home" TMPDIR="$TMP/rollback" MOCK_CALLS="$CALLS"
export BROKKR_DEADMAN_NOTIFY_ENV="$NOTIFY_ENV" BROKKR_DEADMAN_UNIT_DIR="$UNIT_DIR"
export BROKKR_DEADMAN_EXTERNAL_ENV="$EXTERNAL_ENV" MOCK_EXTERNAL_ENV="$EXTERNAL_ENV"
export BROKKR_DEADMAN_STATE_DIR="$STATE_ROOT" MOCK_STATE_FILE="$STATE_ROOT/control-node-deadman/state"
export BROKKR_DEADMAN_EXPECTED_HOST=inference-host BROKKR_DEADMAN_TARGET_URL=http://control-node:3033/api/health
export MOCK_TIMER_ENABLED_FILE="$TMP/timer-enabled" MOCK_TIMER_ACTIVE_FILE="$TMP/timer-active"
export MOCK_LEGACY_TIMER_ENABLED_FILE="$TMP/legacy-timer-enabled" MOCK_LEGACY_TIMER_ACTIVE_FILE="$TMP/legacy-timer-active"
export MOCK_CURLRC_LEAK_LOG="$TMP/curlrc-leak.log"
printf '0\n' >"$MOCK_TIMER_ENABLED_FILE"
printf '0\n' >"$MOCK_TIMER_ACTIVE_FILE"
printf '0\n' >"$MOCK_LEGACY_TIMER_ENABLED_FILE"
printf '0\n' >"$MOCK_LEGACY_TIMER_ACTIVE_FILE"
: >"$MOCK_CURLRC_LEAK_LOG"
printf 'trace-ascii = "%s"\n' "$MOCK_CURLRC_LEAK_LOG" >"$HOME/.curlrc"
BROKKR_DEADMAN_EXPECTED_ROOT="$(cd "$HERE/../.." && pwd)"
export BROKKR_DEADMAN_EXPECTED_ROOT

write_env() {
  printf 'RATATOSKR_SEND_API_KEY=%s\nTELEGRAM_ALLOWED_USERS=%s\nTELEGRAM_BOT_TOKEN=%s\n' \
    "${1-ratatoskr-secret-sentinel}" "${2-123456789}" "${3-telegram-secret-sentinel}" >"$NOTIFY_ENV"
  chmod 600 "$NOTIFY_ENV"
}

write_external_env() {
  printf 'CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL=%s\n' \
    "${1-https://heartbeat.example/p/external-secret-sentinel}" >"$EXTERNAL_ENV"
  chmod 600 "$EXTERNAL_ENV"
}

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run_deploy() { OUT="$(bash "$DEPLOY" 2>&1)"; RC=$?; : "$OUT" "$RC"; }
run_deploy_args() { OUT="$(bash "$DEPLOY" "$@" 2>&1)"; RC=$?; : "$OUT" "$RC"; }

echo "deploy-control-node-deadman.test.sh"

write_env
run_deploy
check "valid preflight installs successfully" '[[ "$RC" -eq 0 ]]'
check "service installed with default target URL" 'grep -Fxq "Environment=CONTROL_NODE_DEADMAN_URL=http://control-node:3033/api/health" "$UNIT_DIR/brokkr-control-node-deadman.service" && ! grep -Fq "@CONTROL_NODE_DEADMAN_URL@" "$UNIT_DIR/brokkr-control-node-deadman.service"'
check "timer installed" 'cmp -s "$HERE/../../systemd/m5/brokkr-control-node-deadman.timer" "$UNIT_DIR/brokkr-control-node-deadman.timer"'
check "credential file is mandatory at runtime" 'grep -q "^EnvironmentFile=%h/.config/grimnir/notify.env$" "$UNIT_DIR/brokkr-control-node-deadman.service"'
check "external credential file is optional at runtime" 'grep -q "^EnvironmentFile=-%h/.config/grimnir/deadman-external.env$" "$UNIT_DIR/brokkr-control-node-deadman.service"'
check "timer enabled" 'grep -q "systemctl --user enable --now brokkr-control-node-deadman.timer" "$CALLS"'
check "runtime service gate precedes timer enable" '[[ "$(grep -n "systemctl --user start brokkr-control-node-deadman.service" "$CALLS" | tail -1 | cut -d: -f1)" -lt "$(grep -n "systemctl --user enable --now brokkr-control-node-deadman.timer" "$CALLS" | tail -1 | cut -d: -f1)" ]]'
check "secret values are not printed" '[[ "$OUT" != *ratatoskr-secret-sentinel* && "$OUT" != *telegram-secret-sentinel* ]]'

run_deploy
check "second install is idempotent" '[[ "$RC" -eq 0 ]]'

: >"$CALLS"; write_env
export BROKKR_DEADMAN_TARGET_URL=http://control-node.tailnet.example:3033/api/health
run_deploy
check "explicit target URL installs successfully" '[[ "$RC" -eq 0 ]]'
check "installed service binds the explicit target URL" 'grep -Fxq "Environment=CONTROL_NODE_DEADMAN_URL=http://control-node.tailnet.example:3033/api/health" "$UNIT_DIR/brokkr-control-node-deadman.service"'
unset BROKKR_DEADMAN_TARGET_URL

# A rollback snapshot failure must not turn a read-only pre-mutation error into
# deletion of the live legacy unit named in the pending migration.
: >"$CALLS"; write_env; rm -f "$EXTERNAL_ENV"
cat >"$UNIT_DIR/legacy-node-deadman.service" <<'EOF'
[Service]
ExecStart=%h/repos/brokkr/scripts/legacy-node-deadman.sh
EOF
cat >"$UNIT_DIR/legacy-node-deadman.timer" <<'EOF'
[Timer]
Unit=legacy-node-deadman.service
EOF
mkdir -p "$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SERVICE=legacy-node-deadman.service
export BROKKR_DEADMAN_LEGACY_TIMER=legacy-node-deadman.timer
export BROKKR_DEADMAN_LEGACY_STATE_DIR="$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SCRIPT=scripts/legacy-node-deadman.sh
export MOCK_CP_FAIL_PATTERN=legacy-units/legacy-node-deadman.timer
run_deploy
check "legacy snapshot failure is visible" '[[ "$RC" -ne 0 && "$OUT" == *"could not snapshot legacy unit"* ]]'
check "legacy timer survives snapshot failure" '[[ -f "$UNIT_DIR/legacy-node-deadman.timer" ]]'
check "legacy service survives snapshot failure" '[[ -f "$UNIT_DIR/legacy-node-deadman.service" ]]'
unset MOCK_CP_FAIL_PATTERN BROKKR_DEADMAN_LEGACY_SERVICE BROKKR_DEADMAN_LEGACY_TIMER BROKKR_DEADMAN_LEGACY_STATE_DIR BROKKR_DEADMAN_LEGACY_SCRIPT

# A previous private deployment used legacy-node-deadman.service and its matching
# script.  The installer must retire that exact installation, preserve its
# operational counters without copying credentials, and leave only the
# current control-node unit/configuration behind.
: >"$CALLS"; write_env; rm -f "$EXTERNAL_ENV"
rm -rf "$STATE_ROOT/control-node-deadman"
cat >"$UNIT_DIR/legacy-node-deadman.service" <<'EOF'
[Service]
ExecStart=%h/repos/brokkr/scripts/legacy-node-deadman.sh
EOF
cat >"$UNIT_DIR/legacy-node-deadman.timer" <<'EOF'
[Timer]
Unit=legacy-node-deadman.service
EOF
mkdir -p "$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SERVICE=legacy-node-deadman.service
export BROKKR_DEADMAN_LEGACY_TIMER=legacy-node-deadman.timer
export BROKKR_DEADMAN_LEGACY_STATE_DIR="$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SCRIPT=scripts/legacy-node-deadman.sh
printf '2\n' >"$STATE_ROOT/legacy-node-deadman/fail-count"
printf 'fail\n' >"$STATE_ROOT/legacy-node-deadman/state"
printf '500\n' >"$STATE_ROOT/legacy-node-deadman/last-alert"
printf '\000\377legacy diagnostic\nprivate/path\000tail' >"$TMP/legacy-last-error.expected"
cp "$TMP/legacy-last-error.expected" "$STATE_ROOT/legacy-node-deadman/last-error"
printf '1\n' >"$MOCK_LEGACY_TIMER_ENABLED_FILE"
printf '1\n' >"$MOCK_LEGACY_TIMER_ACTIVE_FILE"
run_deploy
check "legacy dead-man install migrates successfully" '[[ "$RC" -eq 0 ]]'
check "legacy service is removed" '[[ ! -e "$UNIT_DIR/legacy-node-deadman.service" ]]'
check "legacy timer is removed" '[[ ! -e "$UNIT_DIR/legacy-node-deadman.timer" ]]'
check "legacy timer is stopped and disabled before replacement" 'grep -q "systemctl --user stop legacy-node-deadman.timer" "$CALLS" && grep -q "systemctl --user disable legacy-node-deadman.timer" "$CALLS"'
check "legacy operational state is migrated" '[[ "$(cat "$STATE_ROOT/control-node-deadman/last-alert")" == 500 && "$(cat "$STATE_ROOT/control-node-deadman/fail-count")" == 2 ]]'
check "legacy diagnostic remains byte-for-byte in legacy directory" 'cmp -s "$TMP/legacy-last-error.expected" "$STATE_ROOT/legacy-node-deadman/last-error"'
check "legacy diagnostic is not migrated into current state" '[[ ! -e "$STATE_ROOT/control-node-deadman/last-error" ]]'
check "current service points at current script" 'grep -Fxq "ExecStart=%h/repos/brokkr/scripts/control-node-deadman.sh" "$UNIT_DIR/brokkr-control-node-deadman.service"'
check "current unit has no legacy script reference" '! grep -Fq "legacy-node-deadman.sh" "$UNIT_DIR/brokkr-control-node-deadman.service"'
check "current timer targets current service" 'grep -Fxq "Unit=brokkr-control-node-deadman.service" "$UNIT_DIR/brokkr-control-node-deadman.timer"'
unset BROKKR_DEADMAN_LEGACY_SERVICE BROKKR_DEADMAN_LEGACY_TIMER BROKKR_DEADMAN_LEGACY_STATE_DIR BROKKR_DEADMAN_LEGACY_SCRIPT

# The verified historical M5 install has a fixed identity. Its migration is
# available only through an explicit profile; ordinary installs must not
# discover or mutate these names automatically.
: >"$CALLS"; write_env; rm -f "$EXTERNAL_ENV"
rm -rf "$STATE_ROOT/control-node-deadman"
PROFILE_SITE="$(printf '%s%s' hugin munin)"
PROFILE_ID="historic-control-node-v1"
PROFILE_SERVICE="brokkr-${PROFILE_SITE}-deadman.service"
PROFILE_TIMER="brokkr-${PROFILE_SITE}-deadman.timer"
PROFILE_STATE_DIR="$STATE_ROOT/${PROFILE_SITE}-deadman"
cat >"$UNIT_DIR/$PROFILE_SERVICE" <<EOF
[Service]
ExecStart=%h/repos/brokkr/scripts/${PROFILE_SITE}-deadman.sh
EOF
cat >"$UNIT_DIR/$PROFILE_TIMER" <<EOF
[Timer]
Unit=$PROFILE_SERVICE
EOF
mkdir -p "$PROFILE_STATE_DIR"
printf '3\n' >"$PROFILE_STATE_DIR/fail-count"
printf 'fail\n' >"$PROFILE_STATE_DIR/state"
printf '501\n' >"$PROFILE_STATE_DIR/last-alert"
printf '1\n' >"$MOCK_LEGACY_TIMER_ENABLED_FILE"
printf '1\n' >"$MOCK_LEGACY_TIMER_ACTIVE_FILE"
run_deploy_args --legacy-profile "$PROFILE_ID"
check "historical profile migration succeeds" '[[ "$RC" -eq 0 ]]'
check "historical service is removed" '[[ ! -e "$UNIT_DIR/$PROFILE_SERVICE" ]]'
check "historical timer is removed" '[[ ! -e "$UNIT_DIR/$PROFILE_TIMER" ]]'
check "historical timer is stopped and disabled" 'grep -q "systemctl --user stop $PROFILE_TIMER" "$CALLS" && grep -q "systemctl --user disable $PROFILE_TIMER" "$CALLS"'
check "historical operational state is migrated" '[[ "$(cat "$STATE_ROOT/control-node-deadman/last-alert")" == 501 && "$(cat "$STATE_ROOT/control-node-deadman/fail-count")" == 3 ]]'
check "historical state directory is retired" '[[ ! -e "$PROFILE_STATE_DIR" ]]'

# The profile cannot be combined with a second, operator-supplied identity.
: >"$CALLS"; write_env
export BROKKR_DEADMAN_LEGACY_SERVICE=other.service
run_deploy_args --legacy-profile "$PROFILE_ID"
check "historical profile rejects mixed legacy identity" '[[ "$RC" -ne 0 && "$OUT" == *"cannot combine legacy profile"* ]]'
check "mixed profile refuses before systemd mutation" '! grep -q systemctl "$CALLS"'
unset BROKKR_DEADMAN_LEGACY_SERVICE

# With no explicit legacy identity, unrelated dead-man-looking units and state
# are never discovered or changed.
: >"$CALLS"; write_env
cat >"$UNIT_DIR/unrelated-deadman.service" <<'EOF'
[Service]
ExecStart=%h/repos/other/scripts/unrelated-deadman.sh
EOF
cat >"$UNIT_DIR/unrelated-deadman.timer" <<'EOF'
[Timer]
Unit=unrelated-deadman.service
EOF
mkdir -p "$STATE_ROOT/unrelated-deadman"
printf 'unrelated\n' >"$STATE_ROOT/unrelated-deadman/state"
run_deploy
check "unrelated legacy-looking install does not trigger migration" '[[ "$RC" -eq 0 ]]'
check "unrelated service remains untouched" '[[ -f "$UNIT_DIR/unrelated-deadman.service" ]]'
check "unrelated timer remains untouched" '[[ -f "$UNIT_DIR/unrelated-deadman.timer" ]]'
check "unrelated state remains untouched" '[[ "$(cat "$STATE_ROOT/unrelated-deadman/state")" == unrelated ]]'
check "unrelated units receive no systemctl mutation" '! grep -q "unrelated-deadman" "$CALLS"'

# A supplied identity is fail-closed when its service/script correlation is
# corrupt; no unit mutation may happen before the operator fixes it.
: >"$CALLS"; write_env
cat >"$UNIT_DIR/legacy-node-deadman.service" <<'EOF'
[Service]
ExecStart=%h/repos/brokkr/scripts/not-the-declared-script.sh
EOF
cat >"$UNIT_DIR/legacy-node-deadman.timer" <<'EOF'
[Timer]
Unit=legacy-node-deadman.service
EOF
mkdir -p "$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SERVICE=legacy-node-deadman.service
export BROKKR_DEADMAN_LEGACY_TIMER=legacy-node-deadman.timer
export BROKKR_DEADMAN_LEGACY_STATE_DIR="$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SCRIPT=scripts/legacy-node-deadman.sh
run_deploy
check "corrupt legacy script identity refuses" '[[ "$RC" -ne 0 && "$OUT" == *"script reference does not match identity"* ]]'
check "corrupt legacy identity refuses before unit mutation" '! grep -q "daemon-reload\|enable --now" "$CALLS"'
check "corrupt legacy service remains untouched" '[[ -f "$UNIT_DIR/legacy-node-deadman.service" ]]'
unset BROKKR_DEADMAN_LEGACY_SERVICE BROKKR_DEADMAN_LEGACY_TIMER BROKKR_DEADMAN_LEGACY_STATE_DIR BROKKR_DEADMAN_LEGACY_SCRIPT

: >"$CALLS"; write_env
export BROKKR_DEADMAN_LEGACY_SERVICE='../legacy-node-deadman.service'
export BROKKR_DEADMAN_LEGACY_TIMER=legacy-node-deadman.timer
export BROKKR_DEADMAN_LEGACY_STATE_DIR="$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SCRIPT=scripts/legacy-node-deadman.sh
run_deploy
check "path-shaped legacy unit identity refuses" '[[ "$RC" -ne 0 && "$OUT" == *"invalid legacy service identity"* ]]'
check "path-shaped identity refuses before unit mutation" '! grep -q "daemon-reload\|enable --now" "$CALLS"'
unset BROKKR_DEADMAN_LEGACY_SERVICE BROKKR_DEADMAN_LEGACY_TIMER BROKKR_DEADMAN_LEGACY_STATE_DIR BROKKR_DEADMAN_LEGACY_SCRIPT

: >"$CALLS"; write_env
export BROKKR_DEADMAN_LEGACY_SERVICE=legacy-node-deadman.service
export BROKKR_DEADMAN_LEGACY_TIMER=legacy-node-deadman.timer
export BROKKR_DEADMAN_LEGACY_STATE_DIR="$STATE_ROOT/control-node-deadman"
export BROKKR_DEADMAN_LEGACY_SCRIPT=scripts/legacy-node-deadman.sh
run_deploy
check "current dead-man state directory is not accepted as legacy source" '[[ "$RC" -ne 0 && "$OUT" == *"legacy state directory names the current dead-man state"* ]]'
check "current-state collision refuses before unit mutation" '! grep -q "daemon-reload\|enable --now\|stop\|disable" "$CALLS"'
unset BROKKR_DEADMAN_LEGACY_SERVICE BROKKR_DEADMAN_LEGACY_TIMER BROKKR_DEADMAN_LEGACY_STATE_DIR BROKKR_DEADMAN_LEGACY_SCRIPT

: >"$CALLS"; write_env
cat >"$UNIT_DIR/legacy-node-deadman.service" <<'EOF'
[Service]
ExecStart=%h/repos/brokkr/scripts/legacy-node-deadman.sh
EOF
cat >"$UNIT_DIR/legacy-node-deadman.timer" <<'EOF'
[Timer]
Unit=legacy-node-deadman.service
EOF
mkdir -p "$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SERVICE=legacy-node-deadman.service
export BROKKR_DEADMAN_LEGACY_TIMER=legacy-node-deadman.timer
export BROKKR_DEADMAN_LEGACY_STATE_DIR="$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SCRIPT=scripts/legacy-node-deadman.sh
export MOCK_LEGACY_TIMER_ENABLED_QUERY_ERROR=failed
run_deploy
check "indeterminate legacy timer state refuses" '[[ "$RC" -ne 0 && "$OUT" == *"could not snapshot legacy timer enablement"* ]]'
check "indeterminate timer state refuses before unit mutation" '! grep -q "stop legacy-node-deadman\|disable legacy-node-deadman\|daemon-reload\|enable --now" "$CALLS"'
check "indeterminate timer state preserves legacy units" '[[ -f "$UNIT_DIR/legacy-node-deadman.service" && -f "$UNIT_DIR/legacy-node-deadman.timer" ]]'
unset MOCK_LEGACY_TIMER_ENABLED_QUERY_ERROR BROKKR_DEADMAN_LEGACY_SERVICE BROKKR_DEADMAN_LEGACY_TIMER BROKKR_DEADMAN_LEGACY_STATE_DIR BROKKR_DEADMAN_LEGACY_SCRIPT

: >"$CALLS"; write_env
export BROKKR_DEADMAN_LEGACY_SERVICE=legacy-node-deadman.service
export BROKKR_DEADMAN_LEGACY_TIMER=legacy-node-deadman.timer
export BROKKR_DEADMAN_LEGACY_STATE_DIR="$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SCRIPT=scripts/../legacy-node-deadman.sh
run_deploy
check "traversal-shaped legacy script identity refuses" '[[ "$RC" -ne 0 && "$OUT" == *"invalid legacy script identity"* ]]'
check "traversal-shaped script refuses before unit mutation" '! grep -q "daemon-reload\|enable --now\|stop\|disable" "$CALLS"'
unset BROKKR_DEADMAN_LEGACY_SERVICE BROKKR_DEADMAN_LEGACY_TIMER BROKKR_DEADMAN_LEGACY_STATE_DIR BROKKR_DEADMAN_LEGACY_SCRIPT

# If the replacement's runtime gate fails, the old install must come back with
# its timer state and counters intact.
: >"$CALLS"; write_env
cat >"$UNIT_DIR/legacy-node-deadman.service" <<'EOF'
[Service]
ExecStart=%h/repos/brokkr/scripts/legacy-node-deadman.sh
EOF
cat >"$UNIT_DIR/legacy-node-deadman.timer" <<'EOF'
[Timer]
Unit=legacy-node-deadman.service
EOF
mkdir -p "$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SERVICE=legacy-node-deadman.service
export BROKKR_DEADMAN_LEGACY_TIMER=legacy-node-deadman.timer
export BROKKR_DEADMAN_LEGACY_STATE_DIR="$STATE_ROOT/legacy-node-deadman"
export BROKKR_DEADMAN_LEGACY_SCRIPT=scripts/legacy-node-deadman.sh
printf '7\n' >"$STATE_ROOT/legacy-node-deadman/last-alert"
printf '1\n' >"$MOCK_LEGACY_TIMER_ENABLED_FILE"
printf '1\n' >"$MOCK_LEGACY_TIMER_ACTIVE_FILE"
export MOCK_SERVICE_RC=7
run_deploy
check "legacy migration runtime failure is visible" '[[ "$RC" -ne 0 && "$OUT" == *"runtime validation failed"* ]]'
check "legacy service is restored after failed migration" '[[ -f "$UNIT_DIR/legacy-node-deadman.service" ]]'
check "legacy timer is restored after failed migration" '[[ -f "$UNIT_DIR/legacy-node-deadman.timer" ]]'
check "legacy timer state is restored after failed migration" '[[ "$(cat "$MOCK_LEGACY_TIMER_ENABLED_FILE")" == 1 && "$(cat "$MOCK_LEGACY_TIMER_ACTIVE_FILE")" == 1 ]]'
check "legacy counter is restored after failed migration" '[[ "$(cat "$STATE_ROOT/legacy-node-deadman/last-alert")" == 7 ]]'
unset MOCK_SERVICE_RC BROKKR_DEADMAN_LEGACY_SERVICE BROKKR_DEADMAN_LEGACY_TIMER BROKKR_DEADMAN_LEGACY_STATE_DIR BROKKR_DEADMAN_LEGACY_SCRIPT

# First-install failure after enable --now has already created enablement: the
# rollback must explicitly disable before removing the candidate unit files.
: >"$CALLS"; write_env; rm -f "$EXTERNAL_ENV" "$UNIT_DIR/brokkr-control-node-deadman.service" "$UNIT_DIR/brokkr-control-node-deadman.timer"
printf '0\n' >"$MOCK_TIMER_ENABLED_FILE"; printf '0\n' >"$MOCK_TIMER_ACTIVE_FILE"
export MOCK_ENABLE_NOW_RC=7
run_deploy
check "first-install enable failure returns non-zero" '[[ "$RC" -ne 0 && "$OUT" == *"could not enable and start"* ]]'
check "first-install enable failure invokes unconditional disable" 'grep -q "systemctl --user disable brokkr-control-node-deadman.timer" "$CALLS"'
check "first-install enable failure leaves no unit files" '[[ ! -e "$UNIT_DIR/brokkr-control-node-deadman.service" && ! -e "$UNIT_DIR/brokkr-control-node-deadman.timer" ]]'
check "first-install enable failure leaves no dangling timer state" '[[ "$(cat "$MOCK_TIMER_ENABLED_FILE")" == 0 && "$(cat "$MOCK_TIMER_ACTIVE_FILE")" == 0 ]]'
unset MOCK_ENABLE_NOW_RC

# If even the rollback disable fails, retain the 0700 snapshot and tell the
# operator exactly where manual recovery evidence lives.
: >"$CALLS"; write_env
printf '0\n' >"$MOCK_TIMER_ENABLED_FILE"; printf '0\n' >"$MOCK_TIMER_ACTIVE_FILE"
export MOCK_ENABLE_NOW_RC=7 MOCK_DISABLE_RC=5
run_deploy
RECOVERY_PATH="$(printf '%s\n' "$OUT" | sed -n 's/^ERROR: rollback was incomplete; recovery snapshot preserved at //p' | tail -1)"
export RECOVERY_PATH
check "incomplete rollback reports preserved snapshot path" '[[ -n "$RECOVERY_PATH" && -d "$RECOVERY_PATH" ]]'
check "incomplete rollback snapshot remains mode 0700" '[[ "$(stat -c "%a" "$RECOVERY_PATH" 2>/dev/null || stat -f "%Lp" "$RECOVERY_PATH")" == 700 ]]'
unset MOCK_ENABLE_NOW_RC MOCK_DISABLE_RC
printf '0\n' >"$MOCK_TIMER_ENABLED_FILE"; printf '0\n' >"$MOCK_TIMER_ACTIVE_FILE"

: >"$CALLS"; write_env; write_external_env
run_deploy
check "protected external heartbeat installs successfully" '[[ "$RC" -eq 0 ]]'
check "external preflight disables curlrc and keeps URL off argv" 'grep -q "curl --disable --config -" "$CALLS" && ! grep -q external-secret-sentinel "$CALLS"'
check "user manager and linger precede first provider ping" '[[ "$(grep -n "^loginctl " "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n "curl --disable --config -" "$CALLS" | head -1 | cut -d: -f1)" ]]'
check "malicious curlrc cannot capture external config" '[[ ! -s "$MOCK_CURLRC_LEAK_LOG" ]]'
check "external secret value is not printed" '[[ "$OUT" != *external-secret-sentinel* ]]'
check "configured runtime heartbeat records fresh success" '[[ -s "$STATE_ROOT/control-node-deadman/last-external-success" ]]'

: >"$CALLS"; write_env; write_external_env; export MOCK_EXTERNAL_HTTP_STATUS=301
run_deploy
check "external preflight rejects HTTP 301" '[[ "$RC" -ne 0 && "$OUT" == *"external heartbeat preflight failed"* ]]'
check "HTTP 301 refusal occurs before unit mutation" '! grep -q "daemon-reload\|enable --now" "$CALLS"'

: >"$CALLS"; write_env; write_external_env; export MOCK_EXTERNAL_HTTP_STATUS=302
run_deploy
check "external preflight rejects HTTP 302" '[[ "$RC" -ne 0 && "$OUT" == *"external heartbeat preflight failed"* ]]'
check "HTTP 302 refusal occurs before unit mutation" '! grep -q "daemon-reload\|enable --now" "$CALLS"'
unset MOCK_EXTERNAL_HTTP_STATUS

: >"$CALLS"; write_env; write_external_env 'http://heartbeat.example/external-secret-sentinel'
run_deploy
check "non-HTTPS external URL refuses" '[[ "$RC" -ne 0 && "$OUT" == *"non-empty HTTPS heartbeat URL"* ]]'
check "invalid external URL is not printed" '[[ "$OUT" != *external-secret-sentinel* ]]'
check "invalid external URL refuses before network or systemd" '[[ ! -s "$CALLS" ]]'

: >"$CALLS"; write_env; write_external_env 'https:///external-secret-sentinel'
run_deploy
check "external HTTPS URL without a host refuses" '[[ "$RC" -ne 0 && "$OUT" == *"non-empty HTTPS heartbeat URL"* ]]'
check "hostless external URL refuses before network or systemd" '[[ ! -s "$CALLS" ]]'

: >"$CALLS"; write_env; write_external_env
printf 'PATH=/tmp/unexpected\n' >>"$EXTERNAL_ENV"
run_deploy
check "extra external env assignment refuses" '[[ "$RC" -ne 0 && "$OUT" == *"only the external heartbeat assignment"* ]]'
check "extra external env assignment refuses before network or systemd" '[[ ! -s "$CALLS" ]]'

: >"$CALLS"; write_env; write_external_env; chmod 644 "$EXTERNAL_ENV"
run_deploy
check "insecure external secret mode refuses" '[[ "$RC" -ne 0 && "$OUT" == *"must have mode"* ]]'
check "insecure external secret refuses before network or systemd" '[[ ! -s "$CALLS" ]]'

: >"$CALLS"; write_env; write_external_env; export MOCK_EXTERNAL_CURL_RC=7
run_deploy
check "failed external preflight refuses" '[[ "$RC" -ne 0 && "$OUT" == *"external heartbeat preflight failed"* ]]'
check "external preflight runs only after target preflight" '[[ "$(grep -c "^curl " "$CALLS")" == 2 ]]'
check "manager and linger gates precede failed external preflight" 'grep -q "systemctl --user show-environment" "$CALLS" && grep -q "^loginctl " "$CALLS"'
check "failed external preflight refuses before unit mutation" '! grep -q "daemon-reload\|enable --now" "$CALLS"'
unset MOCK_EXTERNAL_CURL_RC

: >"$CALLS"; write_env; write_external_env; export MOCK_WRITE_EXTERNAL_STATE=0
mkdir -p "$UNIT_DIR" "$STATE_ROOT/control-node-deadman"
printf 'prior service unit\n' >"$UNIT_DIR/brokkr-control-node-deadman.service"
printf 'prior timer unit\n' >"$UNIT_DIR/brokkr-control-node-deadman.timer"
printf 'fail\n' >"$STATE_ROOT/control-node-deadman/state"
printf '111\n' >"$STATE_ROOT/control-node-deadman/last-success"
printf '222\n' >"$STATE_ROOT/control-node-deadman/last-external-success"
printf '1\n' >"$MOCK_TIMER_ENABLED_FILE"
printf '1\n' >"$MOCK_TIMER_ACTIVE_FILE"
run_deploy
check "missing runtime external success fails post-install gate" '[[ "$RC" -ne 0 && "$OUT" == *"fresh external heartbeat"* ]]'
check "failed post-install gate reports rollback" '[[ "$OUT" == *"rollback: restored prior units, timer state, and dead-man state"* ]]'
check "failed post-install gate restores prior service unit" 'grep -qx "prior service unit" "$UNIT_DIR/brokkr-control-node-deadman.service"'
check "failed post-install gate restores prior timer unit" 'grep -qx "prior timer unit" "$UNIT_DIR/brokkr-control-node-deadman.timer"'
check "failed post-install gate restores timer enable and active state" '[[ "$(cat "$MOCK_TIMER_ENABLED_FILE")" == 1 && "$(cat "$MOCK_TIMER_ACTIVE_FILE")" == 1 ]]'
check "failed post-install gate restores dead-man state" '[[ "$(cat "$STATE_ROOT/control-node-deadman/state")" == fail && "$(cat "$STATE_ROOT/control-node-deadman/last-success")" == 111 && "$(cat "$STATE_ROOT/control-node-deadman/last-external-success")" == 222 ]]'
check "failed post-install gate never enables new timer" '! grep -q "enable --now" "$CALLS"'
unset MOCK_WRITE_EXTERNAL_STATE
rm -f "$EXTERNAL_ENV"

: >"$CALLS"; write_env valid-key 123456789 ''
run_deploy
check "missing direct fallback refuses" '[[ "$RC" -ne 0 && "$OUT" == *"direct fallback is mandatory"* ]]'
check "secret refusal happens before systemd" '! grep -q systemctl "$CALLS"'

: >"$CALLS"; write_env; chmod 644 "$NOTIFY_ENV"
run_deploy
check "insecure secret mode refuses" '[[ "$RC" -ne 0 && "$OUT" == *"must have mode"* ]]'

: >"$CALLS"; write_env; printf 'TELEGRAM_BOT_TOKEN=\n' >>"$NOTIFY_ENV"
run_deploy
check "duplicate secret assignment refuses" '[[ "$RC" -ne 0 && "$OUT" == *"exactly one TELEGRAM_BOT_TOKEN"* ]]'
check "duplicate refusal happens before systemd" '! grep -q systemctl "$CALLS"'

: >"$CALLS"; write_env; export MOCK_CURL_RC=7
run_deploy
check "failed production probe refuses" '[[ "$RC" -ne 0 && "$OUT" == *"production probe failed"* ]]'
check "probe refusal happens before systemd" '! grep -q systemctl "$CALLS"'
unset MOCK_CURL_RC

: >"$CALLS"; write_env; export MOCK_LINGER=no
run_deploy
check "disabled lingering refuses" '[[ "$RC" -ne 0 && "$OUT" == *"lingering is disabled"* ]]'
check "linger refusal happens before unit mutation" '[[ ! -s "$CALLS" || "$(tail -1 "$CALLS")" == loginctl* ]]'
unset MOCK_LINGER

: >"$CALLS"; write_env; mkdir -p "$(dirname "$MOCK_STATE_FILE")"
printf 'pass\n' >"$MOCK_STATE_FILE"; printf '1\n' >"$(dirname "$MOCK_STATE_FILE")/last-success"
export MOCK_WRITE_STATE=0
run_deploy
check "stale passing state does not satisfy post-install gate" '[[ "$RC" -ne 0 && "$OUT" == *"fresh production probe"* ]]'
unset MOCK_WRITE_STATE

: >"$CALLS"; export MOCK_HOSTNAME=not-monitoring-host
run_deploy
check "wrong host refuses" '[[ "$RC" -ne 0 && "$OUT" == *"targets inference-host"* ]]'
unset MOCK_HOSTNAME

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
