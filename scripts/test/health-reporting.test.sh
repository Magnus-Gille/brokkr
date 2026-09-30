#!/usr/bin/env bash
# Hermetic tests for Brokkr's report -> snapshot -> Heimdall push path.
# shellcheck disable=SC2016 # assertions are intentionally evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/state"
cat > "$TMP/bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit "${MOCK_MOUNT_RC:-0}"
EOF
cat > "$TMP/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_FINDMNT_OUTPUT:-/dev/mock-backup}"
EOF
cat > "$TMP/bin/df" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -P)
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    printf '/dev/mock 1000 %s 200 %s%% /mock\n' "${MOCK_USED_PCT:-70}" "${MOCK_USED_PCT:-70}"
    ;;
  -Ph)
    printf 'Filesystem Size Used Avail Capacity Mounted on\n'
    printf '/dev/mock 2.0T 1.0T %s %s%% /mock\n' "${MOCK_AVAIL:-900G}" "${MOCK_USED_PCT:-70}"
    ;;
  *) exit 2 ;;
esac
EOF
cat > "$TMP/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "${MOCK_DATE_FAIL:-0}" = 1 ]; then exit 74; fi
exec /bin/date "$@"
EOF
cat > "$TMP/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "status --json" ]] || exit 64
printf '%s\n' '{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":true,"DNSName":"nas.example.ts.net"}}'
EOF
chmod +x "$TMP/bin/mountpoint" "$TMP/bin/findmnt" "$TMP/bin/df" "$TMP/bin/date" "$TMP/bin/tailscale"
export PATH="$TMP/bin:$PATH"
export BROKKR_DISK_MOUNT="$TMP/mount" BROKKR_STATE_DIR="$TMP/state"
export BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=disabled
export BROKKR_TAILSCALE_EXPECTED_DNS_NAME=nas.example.ts.net
export MOCK_FINDMNT_OUTPUT=/dev/mock-backup

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
json_value() {
  python3 -c 'import json,sys; data=json.load(sys.stdin); print(eval(sys.argv[1], {"data": data}))' "$1"
}
run_report() {
  OUT="$(bash "$ROOT/heimdall/report.sh" 2>&1)"
  RC=$?
}

echo "health-reporting.test.sh"

export BROKKR_NOW_EPOCH=2000000000
export MOCK_MOUNT_RC=0 MOCK_USED_PCT=70 MOCK_AVAIL=600G
export BROKKR_TM_STATUS='pass","detail":"forged' BROKKR_TM_DETAIL='legacy Mac evidence must be ignored' BROKKR_TM_OBSERVED_AT=1999999990
run_report
check "legacy Mac evidence is ignored and report stays valid" '[[ "$RC" -eq 0 ]] && printf "%s" "$OUT" | python3 -m json.tool >/dev/null'
check "report contains exactly the three platform checks" '[[ "$(printf "%s" "$OUT" | json_value '\''[c["name"] for c in data["checks"]]'\'')" == "['"'"'disk-mount'"'"', '"'"'disk-capacity'"'"', '"'"'tailscale-auth'"'"']" ]]'
check "legacy Mac evidence cannot add a Time Machine row" '[[ "$OUT" != *timemachine* && "$OUT" != *"legacy Mac evidence"* && "$OUT" != *"forged"* ]]'
check "healthy platform checks produce aggregate pass" '[[ "$(printf "%s" "$OUT" | json_value '\''data["status"]'\'')" == pass ]]'
check "healthy Tailscale authentication is included" '[[ "$(printf "%s" "$OUT" | json_value '\''next(c["status"] for c in data["checks"] if c["name"] == "tailscale-auth")'\'')" == pass ]]'

export MOCK_FINDMNT_OUTPUT=$'hostile\r\ttab\bbackspace\fformfeed\x01one\x1funit quote" slash\\ newline\nend'
run_report
check "all JSON-forbidden control bytes from a platform check are escaped and round-trip" 'printf "%s" "$OUT" | python3 -c '\''import json,os,sys; data=json.load(sys.stdin); detail=next(c["detail"] for c in data["checks"] if c["name"] == "disk-mount"); assert detail.endswith("(" + os.environ["MOCK_FINDMNT_OUTPUT"] + ")")'\'''

export MOCK_FINDMNT_OUTPUT=/dev/mock-backup MOCK_MOUNT_RC=2
run_report
check "platform failure produces aggregate fail" '[[ "$(printf "%s" "$OUT" | json_value '\''data["status"]'\'')" == fail ]]'
export MOCK_MOUNT_RC=0

export MOCK_USED_PCT=80
run_report
check "platform warning produces aggregate warn" '[[ "$(printf "%s" "$OUT" | json_value '\''data["status"]'\'')" == warn ]]'
export MOCK_USED_PCT=70

mkdir -p "$TMP/python"
cat > "$TMP/python/sitecustomize.py" <<'PY'
import json, os, urllib.error, urllib.request

class Response:
    def __init__(self, status):
        self.status = status
    def __enter__(self):
        return self
    def __exit__(self, *_args):
        return False

class Opener:
    def __init__(self, no_redirect):
        self.no_redirect = no_redirect
    def open(self, request, timeout):
        with open(os.environ["MOCK_REQUEST_FILE"], "w", encoding="utf-8") as fh:
            json.dump({
                "authorization": request.get_header("Authorization"),
                "body": json.loads(request.data.decode()),
                "no_redirect": self.no_redirect,
                "timeout": timeout,
            }, fh)
        status = int(os.environ["MOCK_HTTP_STATUS"])
        if 200 <= status < 300:
            return Response(status)
        raise urllib.error.HTTPError(request.full_url, status, "mock", {}, None)

def build_opener(*handlers):
    return Opener(any(
        getattr(handler, "__name__", handler.__class__.__name__) == "NoRedirect"
        for handler in handlers
    ))

urllib.request.build_opener = build_opener
PY

run_push() {
  OUT="$(PYTHONPATH="$TMP/python" MOCK_HTTP_STATUS="${MOCK_HTTP_STATUS:-200}" \
    MOCK_REQUEST_FILE="$TMP/request.json" bash "$ROOT/heimdall/push.sh" "$TMP/snapshot.json" 2>&1)"
  RC=$?
}

unset BROKKR_TM_STATUS BROKKR_TM_DETAIL BROKKR_TM_OBSERVED_AT HEIMDALL_HUB_URL HEIMDALL_FLEET_TOKEN
MOCK_MOUNT_RC=0 MOCK_USED_PCT=70 bash "$ROOT/heimdall/report.sh" > "$TMP/snapshot.json"
run_push
check "fully unconfigured push is an explicit no-op" '[[ "$RC" -eq 0 && "$OUT" == *"unset — skipping"* ]]'

export HEIMDALL_HUB_URL=http://127.0.0.1:9/api/panels
unset HEIMDALL_FLEET_TOKEN
run_push
check "partial push configuration fails loudly" '[[ "$RC" -ne 0 && -s "$TMP/state/last-push-failure" ]]'

export MOCK_HTTP_STATUS=200 HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels HEIMDALL_FLEET_TOKEN=secret-sentinel
run_push
check "successful push records current success" '[[ "$RC" -eq 0 && -s "$TMP/state/last-push-success" && ! -e "$TMP/state/last-push-failure" ]]'
check "successful push includes only the three platform checks" 'python3 -c '\''import json,sys; r=json.load(open(sys.argv[1])); assert r["authorization"] == "Bearer secret-sentinel"; assert r["body"]["message"] == "3 checks, all nominal"; assert "timemachine" not in r["body"]["message"]'\'' "$TMP/request.json"'

rm -f "$TMP/state/last-push-success" "$TMP/state/last-push-failure"
export MOCK_DATE_FAIL=1
run_push
check "successful HTTP cannot pass when success evidence cannot be stamped" '[[ "$RC" -ne 0 && ! -e "$TMP/state/last-push-success" && "$OUT" == *"could not record last-push-success"* ]]'
unset MOCK_DATE_FAIL

touch "$TMP/not-a-directory"
saved_state_dir="$BROKKR_STATE_DIR"
export BROKKR_STATE_DIR="$TMP/not-a-directory/child"
run_push
check "unusable state directory fails before reporting success" '[[ "$RC" -ne 0 && ( "$OUT" == *"not a directory"* || "$OUT" == *"Not a directory"* ) ]]'
export BROKKR_STATE_DIR="$saved_state_dir"

export MOCK_HTTP_STATUS=500
run_push
check "HTTP failure is non-zero and locally timestamped" '[[ "$RC" -ne 0 && -s "$TMP/state/last-push-failure" && "$OUT" == *"HTTPError"* ]]'

export MOCK_HTTP_STATUS=302
run_push
check "redirect is refused rather than forwarding credentials" '[[ "$RC" -ne 0 && "$OUT" == *"HTTPError"* ]]'
check "push installs the no-redirect handler" 'python3 -c '\''import json,sys; assert json.load(open(sys.argv[1]))["no_redirect"] is True'\'' "$TMP/request.json"'

printf '{not-json}\n' > "$TMP/snapshot.json"
run_push
check "malformed snapshot cannot be reported as success" '[[ "$RC" -ne 0 && -s "$TMP/state/last-push-failure" ]]'

unset HEIMDALL_HUB_URL HEIMDALL_FLEET_TOKEN BROKKR_TM_STATUS BROKKR_TM_DETAIL BROKKR_TM_OBSERVED_AT
rm -f "$TMP/state/health.json"
# shellcheck disable=SC2034 # assertion consumes these through check/eval
OUT="$(bash "$ROOT/scripts/health-snapshot.sh" 2>&1)"
# shellcheck disable=SC2034 # assertion consumes these through check/eval
RC=$?
check "snapshot path succeeds unconfigured and writes valid JSON atomically" '[[ "$RC" -eq 0 && -f "$TMP/state/health.json" ]] && python3 -m json.tool "$TMP/state/health.json" >/dev/null'
check "snapshot exposes healthy platform checks as aggregate pass" '[[ "$(json_value '\''data["status"]'\'' < "$TMP/state/health.json")" == pass ]]'
check "snapshot contains exactly the three platform checks" '[[ "$(json_value '\''[c["name"] for c in data["checks"]]'\'' < "$TMP/state/health.json")" == "['"'"'disk-mount'"'"', '"'"'disk-capacity'"'"', '"'"'tailscale-auth'"'"']" ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
