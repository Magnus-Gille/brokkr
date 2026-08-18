#!/usr/bin/env bash
# Hermetic tests for the NAS Tailscale authentication and key-expiry check.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../../network/check-tailscale-auth.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat >"$TMP/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" != "status --json" ]]; then
  echo "unexpected tailscale arguments" >&2
  exit 64
fi
if [ -n "${MOCK_TAILSCALE_SLEEP:-}" ]; then sleep "$MOCK_TAILSCALE_SLEEP"; fi
if [ "${MOCK_TAILSCALE_RC:-0}" -ne 0 ]; then exit "$MOCK_TAILSCALE_RC"; fi
printf '%s\n' "${MOCK_TAILSCALE_JSON:-}"
EOF
chmod +x "$TMP/bin/tailscale"
export PATH="$TMP/bin:$PATH"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
run_check() {
  OUT="$(python3 "$CHECK" 2>&1)"
  RC=$?
}
check() {
  local desc="$1" want_rc="$2" pattern="$3"
  if [ "$RC" -ne "$want_rc" ]; then bad "$desc (rc=$RC, want $want_rc; output=$OUT)"; return; fi
  if ! grep -Fq "$pattern" <<<"$OUT"; then bad "$desc (missing '$pattern'; output=$OUT)"; return; fi
  if [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -ne 1 ]; then bad "$desc (output is not one line)"; return; fi
  if grep -Fq 'Traceback' <<<"$OUT"; then bad "$desc (traceback leaked)"; return; fi
  ok "$desc"
}

echo "tailscale-auth-health.test.sh"

export BROKKR_NOW_EPOCH=2000000000
export BROKKR_TAILSCALE_EXPECTED_DNS_NAME='nas.example.ts.net'
export MOCK_TAILSCALE_JSON='{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":true,"DNSName":"NAS.EXAMPLE.TS.NET."}}'

export BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=disabled
run_check; check "disabled policy passes when expiry is absent and identity is current" 0 'OK:'

unset BROKKR_TAILSCALE_KEY_EXPIRY_POLICY
run_check; check "missing expiry policy is explicit" 1 'policy is not configured'

export BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=forever
run_check; check "invalid expiry policy fails closed" 2 'invalid key-expiry policy'

export BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=disabled
export MOCK_TAILSCALE_JSON='{"BackendState":"NeedsLogin"}'
run_check; check "NeedsLogin is an actionable authentication failure" 2 'authentication required'

export MOCK_TAILSCALE_JSON='{"BackendState":"Stopped"}'
run_check; check "other non-running backend states fail" 2 'not running'

export MOCK_TAILSCALE_JSON='{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":false,"DNSName":"nas.example.ts.net"}}'
run_check; check "offline self node fails" 2 'not online'

export MOCK_TAILSCALE_JSON='{"BackendState":"Running","TailscaleIPs":[],"Self":{"Online":true,"DNSName":"nas.example.ts.net"}}'
run_check; check "missing current tailnet IP fails without printing an address" 2 'no current tailnet identity'

export MOCK_TAILSCALE_JSON='not-json'
run_check; check "malformed status fails without a traceback" 2 'invalid status JSON'

export MOCK_TAILSCALE_JSON=''
run_check; check "empty status fails without a traceback" 2 'invalid status JSON'

export MOCK_TAILSCALE_RC=7
run_check; check "nonzero tailscale exit fails" 2 'status command failed'
unset MOCK_TAILSCALE_RC

export MOCK_TAILSCALE_SLEEP=2 BROKKR_TAILSCALE_STATUS_TIMEOUT_SECS=1
run_check; check "hung status command times out and fails" 2 'status command timed out'
unset MOCK_TAILSCALE_SLEEP BROKKR_TAILSCALE_STATUS_TIMEOUT_SECS

export BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=monitored
export MOCK_TAILSCALE_JSON='{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":true,"DNSName":"nas.example.ts.net","KeyExpiry":"2033-06-20T03:33:20Z"}}'
run_check; check "monitored policy passes outside the warning window" 0 'expiry monitored'

export MOCK_TAILSCALE_JSON='{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":true,"DNSName":"nas.example.ts.net","KeyExpiry":"2033-05-25T03:33:20Z"}}'
run_check; check "monitored policy warns before expiry" 1 'expires within'

export MOCK_TAILSCALE_JSON='{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":true,"DNSName":"nas.example.ts.net","KeyExpiry":"2033-05-17T03:33:20Z"}}'
run_check; check "past key expiry fails independent of backend optimism" 2 'node key has expired'

export MOCK_TAILSCALE_JSON='{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":true,"Expired":true,"DNSName":"nas.example.ts.net"}}'
run_check; check "explicit Expired flag fails" 2 'node key has expired'

export MOCK_TAILSCALE_JSON='{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":true,"DNSName":"nas.example.ts.net","KeyExpiry":null}}'
run_check; check "monitored policy rejects null expiry" 2 'valid key expiry is unavailable'

export MOCK_TAILSCALE_JSON='{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":true,"DNSName":"nas.example.ts.net","KeyExpiry":"soon"}}'
run_check; check "invalid RFC3339 expiry fails" 2 'invalid key expiry'

export BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=disabled
export MOCK_TAILSCALE_JSON='{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":true,"DNSName":"nas.example.ts.net","KeyExpiry":"2033-06-20T03:33:20Z"}}'
run_check; check "disabled policy warns when expiry is unexpectedly enabled" 1 'policy drift'

export BROKKR_TAILSCALE_EXPECTED_DNS_NAME='private-name.example.ts.net'
export MOCK_TAILSCALE_JSON='{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":true,"DNSName":"other-private.example.ts.net"}}'
run_check; check "identity mismatch is generic and fails" 2 'tailnet identity mismatch'
if [[ "$OUT" == *private-name* || "$OUT" == *other-private* || "$OUT" == *192.0.2.10* ]]; then
  bad "identity mismatch output leaks configured topology"
else
  ok "identity mismatch output does not leak configured topology"
fi

export BROKKR_TAILSCALE_EXPECTED_DNS_NAME='nas.example.ts.net'
export BROKKR_TAILSCALE_EXPIRY_WARN_SECS=invalid
export BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=monitored
run_check; check "invalid warning threshold fails closed" 2 'invalid expiry warning threshold'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
