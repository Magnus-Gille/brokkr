#!/usr/bin/env bash
# Hermetic regression for Brokkr's systemd failure monitor (brokkr#6).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MONITOR="$ROOT/scripts/systemd-failure-monitor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/python"
CALLS="$TMP/calls"
REQUEST="$TMP/request.json"
UNEXPECTED="$TMP/unexpected-systemctl"
: >"$CALLS"; : >"$UNEXPECTED"

cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"list-units"*"--type=service"*"--state=failed"*)
    while IFS= read -r unit; do
      [ -n "$unit" ] && printf '%s loaded failed failed synthetic failure\n' "$unit"
    done <"$MOCK_FAILED_UNITS"
    ;;
  *"show"*)
    printf 'failed\nexit-code\n1\n'
    ;;
  *) printf '%s\n' "$*" >>"$MOCK_UNEXPECTED_SYSTEMCTL"; exit 64 ;;
esac
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$*" >>"$MOCK_NOTIFY_CALLS"
if [[ "$*" == *"-w %{http_code}"* ]]; then printf 200; fi
EOF
cat >"$TMP/bin/flock" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == '-n 9' ]] || exit 64
exit "${MOCK_FLOCK_RC:-0}"
EOF
cat >"$TMP/bin/node" <<'EOF'
#!/usr/bin/env bash
python3 -c 'import json, os; print(json.dumps(os.environ.get("MSG", "")), end="")'
EOF
chmod +x "$TMP/bin/systemctl" "$TMP/bin/curl" "$TMP/bin/flock" "$TMP/bin/node"

cat >"$TMP/python/sitecustomize.py" <<'PY'
import json, os, urllib.error, urllib.request

class Response:
    def __init__(self, status): self.status = status
    def __enter__(self): return self
    def __exit__(self, *_): return False

class Opener:
    def open(self, request, timeout):
        with open(os.environ['MOCK_REQUEST_FILE'], 'w', encoding='utf-8') as fh:
            json.dump({'body': json.loads(request.data.decode()), 'timeout': timeout}, fh)
        status = int(os.environ.get('MOCK_HTTP_STATUS', '200'))
        if 200 <= status < 300:
            return Response(status)
        raise urllib.error.HTTPError(request.full_url, status, 'mock', {}, None)

def build_opener(*_handlers): return Opener()
urllib.request.build_opener = build_opener
PY

FAILED_UNITS="$TMP/failed-units"
: >"$FAILED_UNITS"
export PATH="$TMP/bin:$PATH" PYTHONPATH="$TMP/python"
export MOCK_FAILED_UNITS="$FAILED_UNITS" MOCK_UNEXPECTED_SYSTEMCTL="$UNEXPECTED"
export MOCK_NOTIFY_CALLS="$CALLS" MOCK_REQUEST_FILE="$REQUEST"
export BROKKR_STATE_DIR="$TMP/state"
export HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels HEIMDALL_FLEET_TOKEN=test-token
export RATATOSKR_URL=http://ratatoskr.invalid/api/send RATATOSKR_SEND_API_KEY=test-key
export TELEGRAM_ALLOWED_USERS=123456789
export MOCK_HTTP_STATUS=200

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# shellcheck disable=SC2034 # checks consume OUT and RC through eval.
run() { OUT="$(bash "$MONITOR" "$@" 2>&1)"; RC=$?; }

echo "systemd-failure-monitor.test.sh"

mkdir -p "$TMP/state/systemd-failures/.lock"
printf 'alpha.service\n' >"$FAILED_UNITS"
run --sweep
check "stale lock path from a crashed predecessor does not suppress reporting" '[[ "$RC" -eq 0 && "$OUT" == *"new failure: alpha.service"* ]]'
check "initial failure writes durable dedup state" 'grep -qx "alpha.service" "$TMP/state/systemd-failures/failed-units"'
check "failure panel is pushed through Heimdall with failing state" 'python3 -c '\''import json,sys; d=json.load(open(sys.argv[1])); assert d["body"]["panel"] == "systemd-failures" and d["body"]["state"] == "fail" and "alpha.service" in d["body"]["message"]'\'' "$REQUEST"'
check "failure panel keeps its delivery stamp separate from hardware health" '[[ -s "$TMP/state/systemd-failures-last-push-success" && ! -e "$TMP/state/last-push-success" ]]'
check "new failure sends one operator notification" '[[ "$(wc -l < "$CALLS" | tr -d " ")" -eq 1 ]]'

run --sweep
check "unchanged failure is deduplicated" '[[ "$RC" -eq 0 && "$OUT" == *"no state change"* ]]'
check "unchanged failure sends no second operator notification" '[[ "$(wc -l < "$CALLS" | tr -d " ")" -eq 1 ]]'

printf 'alpha.service\nbeta.service\n' >"$FAILED_UNITS"
export MOCK_HTTP_STATUS=500
run --sweep
check "failed Heimdall push is non-zero" '[[ "$RC" -ne 0 && "$OUT" == *"failure state retained for retry"* ]]'
check "failed Heimdall push leaves prior state intact" 'grep -qx "alpha.service" "$TMP/state/systemd-failures/failed-units" && ! grep -qx "beta.service" "$TMP/state/systemd-failures/failed-units"'
check "failed Heimdall push sends no unacknowledged notification" '[[ "$(wc -l < "$CALLS" | tr -d " ")" -eq 1 ]]'
export MOCK_HTTP_STATUS=200
run --sweep
check "successful retry reports the previously undelivered unit" '[[ "$RC" -eq 0 && "$OUT" == *"new failure: beta.service"* ]]'
check "successful retry publishes the new state atomically" 'grep -qx "alpha.service" "$TMP/state/systemd-failures/failed-units" && grep -qx "beta.service" "$TMP/state/systemd-failures/failed-units"'
check "successful retry sends beta's exact operator notification" 'grep -Fq "Brokkr systemd failure on" "$CALLS" && grep -Fq "beta.service" "$CALLS"'

: >"$FAILED_UNITS"
run --sweep
check "clearing every failed unit emits recoveries" '[[ "$RC" -eq 0 && "$OUT" == *"recovered: alpha.service"* && "$OUT" == *"recovered: beta.service"* ]]'
check "recovery clears durable failed-unit state" '[[ ! -s "$TMP/state/systemd-failures/failed-units" ]]'
check "recovery updates Heimdall to pass" 'python3 -c '\''import json,sys; d=json.load(open(sys.argv[1])); assert d["body"]["state"] == "pass"'\'' "$REQUEST"'
check "recovery sends one notification per recovered unit" '[[ "$(wc -l < "$CALLS" | tr -d " ")" -eq 4 ]]'

printf 'brokkr-health.service\n' >"$FAILED_UNITS"
run --unit brokkr-health.service
check "OnFailure unit mode accepts the exact adopted unit instance" '[[ "$RC" -eq 0 && "$OUT" == *"new failure: brokkr-health.service"* ]]'
check "OnFailure unit mode includes the exact adopted unit in notification" 'grep -Fq "brokkr-health.service" "$CALLS"'
check "OnFailure template preserves the escaped instance with percent-i" 'grep -Fqx "Description=Brokkr report failed systemd service %i" "$ROOT/systemd/brokkr-systemd-failure@.service" && grep -Fqx "ExecStart=/opt/brokkr/scripts/systemd-failure-monitor.sh --unit %i" "$ROOT/systemd/brokkr-systemd-failure@.service"'

printf '%s\n' 'escaped\x2dunit.service' >"$FAILED_UNITS"
run --sweep
check "escaped systemd service names are retained and reported" '[[ "$RC" -eq 0 && "$OUT" == *"new failure: escaped\\x2dunit.service"* ]] && grep -Fqx "escaped\\x2dunit.service" "$TMP/state/systemd-failures/failed-units"'
run --unit 'bad unit.service'
check "unsafe OnFailure unit argument is rejected" '[[ "$RC" -eq 64 && "$OUT" == *"invalid unit"* ]]'
check "monitor talks only to the system systemctl API" '[[ ! -s "$UNEXPECTED" ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
