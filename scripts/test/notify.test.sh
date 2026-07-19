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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
