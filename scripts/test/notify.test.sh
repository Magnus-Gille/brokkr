#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/scripts/lib/notify.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-notify-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
CALLS="$TMP/calls"

cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
stdin="$(cat)"
printf 'argv=%s\nconfig=%s\n--\n' "$*" "$stdin" >>"$MOCK_CALLS"
if [[ "$*" == *"-w %{http_code}"* ]]; then
  printf '%s' "${MOCK_RAT_CODE:-200}"
fi
MOCK
chmod +x "$TMP/bin/curl"

run_notify() {
  env -i \
    HOME="$TMP/home" \
    PATH="$TMP/bin:/usr/local/bin:/usr/bin:/bin" \
    MOCK_CALLS="$CALLS" \
    RATATOSKR_ENV="$TMP/missing-ratatoskr.env" \
    NOTIFY_ENV="$TMP/missing-notify.env" \
    "$@" \
    bash -c 'set -euo pipefail; source "$1"; notify_telegram "synthetic alert"' _ "$LIB"
}

PASS=0
FAIL=0
check() {
  local label="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'not ok - %s\n' "$label" >&2
    FAIL=$((FAIL + 1))
  fi
}

: >"$CALLS"
run_notify TELEGRAM_ALLOWED_USERS=123456789 >"$TMP/unconfigured.out" 2>&1
check "unconfigured notifier performs no network request" test ! -s "$CALLS"
check "unconfigured notifier explains the skip" grep -qi 'not configured\|no .*url' "$TMP/unconfigured.out"

: >"$CALLS"
run_notify TELEGRAM_ALLOWED_USERS=123456789 TELEGRAM_BOT_TOKEN=fake-bot-token \
  MOCK_RAT_CODE=503 >"$TMP/direct.out" 2>&1
check "explicit direct fallback makes exactly one request" test "$(grep -c '^argv=' "$CALLS")" -eq 1
check "direct-only request targets Telegram via curl config" grep -q 'api.telegram.org/botfake-bot-token/sendMessage' "$CALLS"
check "direct token is absent from process arguments" sh -c '! grep "^argv=.*fake-bot-token" "$1"' _ "$CALLS"

: >"$CALLS"
run_notify TELEGRAM_ALLOWED_USERS=123456789 \
  RATATOSKR_URL=http://ratatoskr.example/api/send \
  RATATOSKR_SEND_API_KEY=fake-send-key >"$TMP/rat.out" 2>&1
check "explicit Ratatoskr URL makes one preferred request" test "$(grep -c '^argv=' "$CALLS")" -eq 1
check "preferred request uses only the explicit URL" grep -q 'http://ratatoskr.example/api/send' "$CALLS"
check "send key is absent from process arguments" sh -c '! grep "^argv=.*fake-send-key" "$1"' _ "$CALLS"

cat >"$TMP/notify.env" <<'EOF'
RATATOSKR_URL=http://ratatoskr-config.example/api/send
RATATOSKR_SEND_API_KEY=fake-config-key
TELEGRAM_ALLOWED_USERS=123456789
TELEGRAM_BOT_TOKEN=
EOF
: >"$CALLS"
env -i \
  HOME="$TMP/home" PATH="$TMP/bin:/usr/local/bin:/usr/bin:/bin" MOCK_CALLS="$CALLS" \
  RATATOSKR_ENV="$TMP/missing-ratatoskr.env" NOTIFY_ENV="$TMP/notify.env" \
  bash -c 'set -euo pipefail; source "$1"; notify_telegram "synthetic alert"' _ "$LIB" \
  >"$TMP/config.out" 2>&1
check "config file can explicitly supply Ratatoskr URL" grep -q 'http://ratatoskr-config.example/api/send' "$CALLS"

# Regression (brokkr-maintenance-os exit 1, 2026-07-25): the real ratatoskr/.env
# on the control node never defines RATATOSKR_URL (it's a client-side setting —
# Ratatoskr doesn't need to know its own URL), only RATATOSKR_SEND_API_KEY,
# TELEGRAM_ALLOWED_USERS, and TELEGRAM_BOT_TOKEN. _notify_cfg_get's pipeline
# (`grep | head | cut | tr`) returns grep's "no match" exit status (1) under the
# caller's inherited `set -o pipefail`, even though "key absent from this file"
# is an explicitly documented, valid, best-effort outcome — NOT a hard error. A
# bare `url="${RATATOSKR_URL:-$(_notify_cfg_get ...)}"` assignment then aborts
# the whole calling script (maintenance-report.sh, `set -euo pipefail`) under
# set -e, breaking the documented contract that "a notify failure NEVER fails
# the calling script" (notify.sh header). Reproduce with a config file that
# omits the RATATOSKR_URL= line entirely (not merely sets it empty).
cat >"$TMP/prod-shaped.env" <<'EOF'
RATATOSKR_SEND_API_KEY=fake-send-key
TELEGRAM_ALLOWED_USERS=123456789
TELEGRAM_BOT_TOKEN=fake-bot-token
EOF
: >"$CALLS"
set +e
env -i \
  HOME="$TMP/home" PATH="$TMP/bin:/usr/local/bin:/usr/bin:/bin" MOCK_CALLS="$CALLS" \
  RATATOSKR_ENV="$TMP/missing-ratatoskr.env" NOTIFY_ENV="$TMP/prod-shaped.env" \
  bash -c 'set -euo pipefail; source "$1"; notify_telegram "synthetic alert"' _ "$LIB" \
  >"$TMP/prod-shaped.out" 2>&1
prod_rc=$?
set -e
check "a config file missing an unrelated key does not abort the caller" test "$prod_rc" -eq 0
check "the lookup falls through to the direct Telegram fallback" \
  grep -q 'api.telegram.org/botfake-bot-token/sendMessage' "$CALLS"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
