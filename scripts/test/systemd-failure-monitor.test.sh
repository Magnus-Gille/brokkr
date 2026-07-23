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
chmod +x "$TMP/bin/systemctl" "$TMP/bin/curl"

cat >"$TMP/python/sitecustomize.py" <<'PY'
import json, os, urllib.error, urllib.request

class Response:
    status = 200
    def __enter__(self): return self
    def __exit__(self, *_): return False

class Opener:
    def open(self, request, timeout):
        with open(os.environ['MOCK_REQUEST_FILE'], 'w', encoding='utf-8') as fh:
            json.dump({'body': json.loads(request.data.decode()), 'timeout': timeout}, fh)
        return Response()

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

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# shellcheck disable=SC2034 # checks consume OUT and RC through eval.
run() { OUT="$(bash "$MONITOR" "$@" 2>&1)"; RC=$?; }

echo "systemd-failure-monitor.test.sh"

printf 'alpha.service\n' >"$FAILED_UNITS"
run --sweep
check "initial failed service is reported successfully" '[[ "$RC" -eq 0 && "$OUT" == *"new failure: alpha.service"* ]]'
check "initial failure writes durable dedup state" 'grep -qx "alpha.service" "$TMP/state/systemd-failures/failed-units"'
check "failure panel is pushed through Heimdall with failing state" 'python3 -c '\''import json,sys; d=json.load(open(sys.argv[1])); assert d["body"]["panel"] == "systemd-failures" and d["body"]["state"] == "fail" and "alpha.service" in d["body"]["message"]'\'' "$REQUEST"'
check "failure panel keeps its delivery stamp separate from hardware health" '[[ -s "$TMP/state/systemd-failures-last-push-success" && ! -e "$TMP/state/last-push-success" ]]'
check "new failure sends one operator notification" '[[ "$(wc -l < "$CALLS" | tr -d " ")" -eq 1 ]]'

run --sweep
check "unchanged failure is deduplicated" '[[ "$RC" -eq 0 && "$OUT" == *"no state change"* ]]'
check "unchanged failure sends no second operator notification" '[[ "$(wc -l < "$CALLS" | tr -d " ")" -eq 1 ]]'

: >"$FAILED_UNITS"
run --sweep
check "clearing every failed unit emits a recovery" '[[ "$RC" -eq 0 && "$OUT" == *"recovered: alpha.service"* ]]'
check "recovery clears durable failed-unit state" '[[ ! -s "$TMP/state/systemd-failures/failed-units" ]]'
check "recovery updates Heimdall to pass" 'python3 -c '\''import json,sys; d=json.load(open(sys.argv[1])); assert d["body"]["state"] == "pass"'\'' "$REQUEST"'
check "recovery sends exactly one additional operator notification" '[[ "$(wc -l < "$CALLS" | tr -d " ")" -eq 2 ]]'

printf 'beta.service\n' >"$FAILED_UNITS"
run --unit beta.service
check "OnFailure unit mode reconciles the named failed service" '[[ "$RC" -eq 0 && "$OUT" == *"new failure: beta.service"* ]]'
run --unit 'bad unit.service'
check "unsafe OnFailure unit argument is rejected" '[[ "$RC" -eq 64 && "$OUT" == *"invalid unit"* ]]'
check "monitor talks only to the system systemctl API" '[[ ! -s "$UNEXPECTED" ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
