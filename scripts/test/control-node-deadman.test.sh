#!/usr/bin/env bash
# Unit test for scripts/control-node-deadman.sh. No network or Telegram needed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../control-node-deadman.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home"
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--config -"* ]]; then
  if [[ "${1:-}" == "--disable" ]]; then
    cat >/dev/null
  else
    # Simulate a malicious ~/.curlrc trace directive leaking stdin config.
    cat >>"$MOCK_CURLRC_LEAK_LOG"
  fi
  printf 'external\n' >>"$MOCK_EXTERNAL_CALLS"
  printf '%s' "${MOCK_EXTERNAL_HTTP_STATUS:-204}"
  exit "${MOCK_EXTERNAL_CURL_RC:-0}"
fi
if [ "${MOCK_CURL_OK:-1}" = 1 ]; then
  exit 0
fi
echo "mock curl failure" >&2
exit 7
EOF
chmod +x "$TMP/bin/curl"

cat >"$TMP/notify.sh" <<'EOF'
notify_telegram() {
  printf '%s\n' "$1" >>"$MOCK_NOTIFY_LOG"
}
EOF

export PATH="$TMP/bin:$PATH" HOME="$TMP/home"
export BROKKR_STATE_DIR="$TMP/state"
export BROKKR_NOTIFY_HELPER="$TMP/notify.sh"
export MOCK_NOTIFY_LOG="$TMP/notify.log"
export MOCK_EXTERNAL_CALLS="$TMP/external-calls.log"
export MOCK_CURLRC_LEAK_LOG="$TMP/curlrc-leak.log"
export CONTROL_NODE_DEADMAN_FAIL_AFTER=3
export CONTROL_NODE_DEADMAN_ALERT_COOLDOWN_SECS=100
: >"$MOCK_NOTIFY_LOG"
: >"$MOCK_EXTERNAL_CALLS"
: >"$MOCK_CURLRC_LEAK_LOG"
printf 'trace-ascii = "%s"\n' "$MOCK_CURLRC_LEAK_LOG" >"$HOME/.curlrc"

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
notify_count() { wc -l <"$MOCK_NOTIFY_LOG" | tr -d ' '; }
external_count() { wc -l <"$MOCK_EXTERNAL_CALLS" | tr -d ' '; }
run_at() {
  BROKKR_DEADMAN_NOW="$1" bash "$SCRIPT" >"$TMP/out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/out")"
}
want_count() {
  local desc="$1" want="$2" got
  got="$(notify_count)"
  [ "$RC" -eq 0 ] || { bad "$desc (rc=$RC)"; return; }
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc (notify count want $want got $got; out=$OUT)"
  fi
}

echo "control-node-deadman.test.sh"

export MOCK_CURL_OK=0
run_at 1000; want_count "first miss below threshold -> no alert" 0
run_at 1010; want_count "second miss below threshold -> no alert" 0
run_at 1020; want_count "third miss reaches threshold -> alert" 1
run_at 1030; want_count "continuing failure inside cooldown -> no extra alert" 1
run_at 1130; want_count "continuing failure after cooldown -> repeat alert" 2

export MOCK_CURL_OK=1
run_at 1140; want_count "recovery after fail -> recovery alert" 3
if grep -q "recovered" "$MOCK_NOTIFY_LOG"; then
  ok "recovery alert text recorded"
else
  bad "missing recovery alert text"
fi

export MOCK_CURL_OK=0
run_at 1150; want_count "new miss after recovery resets threshold -> no alert" 3

# Optional external missed-ping integration: success-only, secret-safe, and
# non-zero on delivery/configuration failure so it cannot silently disappear.
unset CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL
rm -rf "$BROKKR_STATE_DIR"
: >"$MOCK_EXTERNAL_CALLS"
export CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL='https://heartbeat.example/p/secret-sentinel'

export MOCK_CURL_OK=1
run_at 2000
if [[ "$RC" -eq 0 && "$(external_count)" == 1 && \
  "$(cat "$BROKKR_STATE_DIR/control-node-deadman/last-external-success")" == 2000 ]]; then
  ok "passing target emits one external heartbeat and records success"
else
  bad "passing target external heartbeat (rc=$RC calls=$(external_count); out=$OUT)"
fi
if [[ "$OUT" != *secret-sentinel* ]]; then
  ok "external heartbeat URL is not printed"
else
  bad "external heartbeat URL leaked to output"
fi
if [[ ! -s "$MOCK_CURLRC_LEAK_LOG" ]]; then
  ok "curl --disable defeats a malicious user curlrc"
else
  bad "malicious curlrc captured the external URL"
fi

export MOCK_CURL_OK=0
run_at 2010
if [[ "$RC" -eq 0 && "$(external_count)" == 1 ]]; then
  ok "failed target emits no external heartbeat"
else
  bad "failed target external suppression (rc=$RC calls=$(external_count); out=$OUT)"
fi

export MOCK_CURL_OK=1 MOCK_EXTERNAL_CURL_RC=7
run_at 2020
if [[ "$RC" -ne 0 && "$(external_count)" == 2 && "$OUT" != *secret-sentinel* ]]; then
  ok "failed external delivery is visible without leaking URL"
else
  bad "external delivery failure handling (rc=$RC calls=$(external_count); out=$OUT)"
fi
unset MOCK_EXTERNAL_CURL_RC

export MOCK_EXTERNAL_HTTP_STATUS=301
run_at 2025
if [[ "$RC" -ne 0 && "$(external_count)" == 3 && "$OUT" != *secret-sentinel* ]]; then
  ok "external HTTP 301 is not counted as heartbeat success"
else
  bad "external 301 handling (rc=$RC calls=$(external_count); out=$OUT)"
fi

export MOCK_EXTERNAL_HTTP_STATUS=302
run_at 2026
if [[ "$RC" -ne 0 && "$(external_count)" == 4 && "$OUT" != *secret-sentinel* ]]; then
  ok "external HTTP 302 is not counted as heartbeat success"
else
  bad "external 302 handling (rc=$RC calls=$(external_count); out=$OUT)"
fi
unset MOCK_EXTERNAL_HTTP_STATUS

export CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL='http://heartbeat.example/secret-sentinel'
run_at 2030
if [[ "$RC" -ne 0 && "$(external_count)" == 4 && "$OUT" != *secret-sentinel* ]]; then
  ok "non-HTTPS external URL fails closed without a request or leak"
else
  bad "external URL validation (rc=$RC calls=$(external_count); out=$OUT)"
fi

export CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL='https:///secret-sentinel'
run_at 2040
if [[ "$RC" -ne 0 && "$(external_count)" == 4 && "$OUT" != *secret-sentinel* ]]; then
  ok "external HTTPS URL without a host fails closed"
else
  bad "external URL host validation (rc=$RC calls=$(external_count); out=$OUT)"
fi
unset CONTROL_NODE_DEADMAN_EXTERNAL_HEARTBEAT_URL

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
