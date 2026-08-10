#!/usr/bin/env bash
# Hermetic Linux destination-probe and Heimdall consumer-contract tests.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../timemachine/telemetry.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/bands/0"
CONFIG="$TMP/probe.env"
NOW=1783947600 # 2026-07-13T13:00:00Z
# Resolve before the mock bin directory is prepended; GitHub's Linux images do
# not guarantee /usr/bin/python3, and invoking `python3` inside the shim would
# recurse back into the shim.
REAL_PYTHON="$(command -v python3)"
export BROKKR_TEST_REAL_PYTHON="$REAL_PYTHON"

cat > "$TMP/bin/tmutil" <<'EOF'
#!/usr/bin/env bash
echo 'tmutil must not run' >&2
exit 99
EOF
cat > "$TMP/bin/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${MOCK_PYTHON_FAIL:-}" = snapshot ] && [ "$1" = - ] && [ "$#" -eq 3 ]; then exit 70; fi
if [ "${MOCK_PYTHON_FAIL:-}" = probe ] && [[ "$1" == *destination-probe.py ]]; then exit 70; fi
if [ "${MOCK_PROBE_TIMEOUT:-}" = 1 ] && [[ "$1" == *destination-probe.py ]]; then
  printf '%s\n' '{"status":"warn","reason":"scan_timeout","observed_at":1783947600,"count":0,"size_bytes":0}'
  exit 1
fi
exec "$BROKKR_TEST_REAL_PYTHON" "$@"
EOF
chmod +x "$TMP/bin/tmutil" "$TMP/bin/python3"
mkdir -p "$TMP/python"
cat > "$TMP/python/sitecustomize.py" <<'PY'
import json, os, urllib.request
class Response:
    status = 200
    def __enter__(self): return self
    def __exit__(self, *_args): return False
class Opener:
    def open(self, request, timeout):
        if os.environ.get("MOCK_DELIVERY_FAIL"):
            raise OSError("delivery fixture failure")
        with open(os.environ["MOCK_REQUEST_FILE"], "w", encoding="utf-8") as fh:
            json.dump({"authorization":request.get_header("Authorization"), "body":json.loads(request.data.decode()), "timeout":timeout}, fh)
        return Response()
urllib.request.build_opener = lambda *_handlers: Opener()
PY

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
write_config() { printf 'BROKKR_TM_BANDS_DIR=%s\n' "$1" > "$CONFIG"; chmod 600 "$CONFIG"; }
run() {
  # shellcheck disable=SC2034 # assertions consume these through check/eval
  OUT="$(TZ=UTC PATH="$TMP/bin:$PATH" PYTHONPATH="$TMP/python" MOCK_REQUEST_FILE="$TMP/request.json" BROKKR_TM_PROBE_SOURCE="$CONFIG" BROKKR_TM_STATE_DIR="$TMP/state" BROKKR_TM_NOW_EPOCH="$NOW" HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels HEIMDALL_FLEET_TOKEN=secret-sentinel "$SCRIPT" 2>&1)"
  # shellcheck disable=SC2034 # assertions consume this through check/eval
  RC=$?
}
run_delivery() {
  # shellcheck disable=SC2034 # assertions consume these through check/eval
  OUT="$(TZ=UTC PATH="$TMP/bin:$PATH" PYTHONPATH="$TMP/python" MOCK_REQUEST_FILE="$TMP/request.json" BROKKR_TM_PROBE_SOURCE="$CONFIG" BROKKR_TM_STATE_DIR="$TMP/state" BROKKR_TM_NOW_EPOCH="$NOW" HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels HEIMDALL_FLEET_TOKEN=secret-sentinel "$SCRIPT" 2>&1)"
  # shellcheck disable=SC2034 # assertions consume this through check/eval
  RC=$?
}
state() { "$REAL_PYTHON" - "$TMP/state/timemachine-health.json" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {}, {"data": data}))
PY
}

echo "timemachine-telemetry.test.sh"
write_config "$TMP/bands"
printf x > "$TMP/bands/0/fresh-band"
TZ=UTC touch -t 202607131200 "$TMP/bands/0/fresh-band"
# shellcheck disable=SC2034 # assertions consume these through check/eval
OUT="$(TZ=UTC PATH="$TMP/bin:$PATH" BROKKR_TM_PROBE_SOURCE="$CONFIG" BROKKR_TM_STATE_DIR="$TMP/state" BROKKR_TM_NOW_EPOCH="$NOW" "$SCRIPT" 2>&1)"
# shellcheck disable=SC2034 # assertion consumes this through check/eval
RC=$?
check "missing delivery credentials fail before probe" '[[ "$RC" -eq 2 && "$OUT" == *"Heimdall delivery is not configured"* ]]'
run
check "M5 destination probe does not invoke tmutil" '[[ "$RC" -eq 0 && "$OUT" == *"200 (state=pass)"* ]]'
check "updated band evidence is fresh" '[[ "$(state "data[\"status\"]")" == pass && "$(state "data[\"checks\"][0][\"detail\"]")" == *"reason=fresh_band_files"* ]]'
check "private source is neither printed nor published" '! grep -Fq "$TMP/bands" "$TMP/state/timemachine-health.json" && [[ "$OUT" != *"$TMP/bands"* ]]'

mkdir -p "$TMP/Time Machine Backups/bands/0"
printf x > "$TMP/Time Machine Backups/bands/0/fresh-band"
TZ=UTC touch -t 202607131200 "$TMP/Time Machine Backups/bands/0/fresh-band"
write_config "$TMP/Time Machine Backups/bands"
run
check "canonical source with ordinary whitespace is accepted as data" '[[ "$RC" -eq 0 && "$(state "data[\"status\"]")" == pass ]]'
check "whitespace source is neither printed nor published" '! grep -Fq "$TMP/Time Machine Backups/bands" "$TMP/state/timemachine-health.json" && [[ "$OUT" != *"$TMP/Time Machine Backups/bands"* ]]'

printf 'BROKKR_TM_BANDS_DIR=%s\nBROKKR_TM_BANDS_DIR=%s\n' "$TMP/bands" "$TMP/bands" > "$CONFIG"; chmod 600 "$CONFIG"
run
check "multiple assignments fail closed" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* ]]'
printf 'BROKKR_TM_BANDS_DIR=%s\nBROKKR_TM_BANDS_DIR=%s' "$TMP/bands" "$TMP/bands" > "$CONFIG"; chmod 600 "$CONFIG"
run
check "multiple assignments without final newline fail closed" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* ]]'
printf 'BROKKR_TM_BANDS_DIR=%s\nnot-an-assignment\n' "$TMP/bands" > "$CONFIG"; chmod 600 "$CONFIG"
run
check "newline injection fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* ]]'
printf 'BROKKR_TM_BANDS_DIR=%s\nnot-an-assignment' "$TMP/bands" > "$CONFIG"; chmod 600 "$CONFIG"
run
check "unterminated second line fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* ]]'
printf 'BROKKR_TM_BANDS_DIR=%s\tcontrol\n' "$TMP/bands" > "$CONFIG"; chmod 600 "$CONFIG"
run
check "tab control in source fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* ]]'
printf 'BROKKR_TM_BANDS_DIR=%s\r\n' "$TMP/bands" > "$CONFIG"; chmod 600 "$CONFIG"
run
check "carriage-return control in source fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* ]]'
printf 'BROKKR_TM_BANDS_DIR= %s\n' "$TMP/bands" > "$CONFIG"; chmod 600 "$CONFIG"
run
check "leading whitespace before an absolute source fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* ]]'

write_config "$TMP/bands"
TZ=UTC touch -t 202607111200 "$TMP/bands/0/fresh-band"
run
check "stale band evidence is delivered as health failure" '[[ "$RC" -eq 0 && "$(state "data[\"status\"]")" == fail && "$(state "data[\"checks\"][0][\"detail\"]")" == *"reason=stale_band_files"* ]]'

write_config "$TMP/absent"
run
check "absent destination warning is delivered successfully" '[[ "$RC" -eq 0 && "$(state "data[\"status\"]")" == warn && "$(state "data[\"checks\"][0][\"detail\"]")" == *"reason=source_unavailable"* && "$OUT" == *"200 (state=warn)"* ]]'
check "source-unavailable delivery preserves warning state" '"$REAL_PYTHON" -c '\''import json,sys; r=json.load(open(sys.argv[1])); assert r["body"]["state"] == "warn"; assert "reason=source_unavailable" in r["body"]["message"]'\'' "$TMP/request.json"'

write_config "$TMP/bands"
chmod 000 "$TMP/bands"
run
check "unreadable destination warning is delivered" '[[ "$RC" -eq 0 && "$(state "data[\"checks\"][0][\"detail\"]")" == *"reason=source_unreadable"* ]]'
chmod 700 "$TMP/bands"

write_config "$TMP/bands"
export MOCK_PROBE_TIMEOUT=1
run
check "bounded timeout warning is delivered" '[[ "$RC" -eq 0 && "$(state "data[\"checks\"][0][\"detail\"]")" == *"reason=scan_timeout"* ]]'
unset MOCK_PROBE_TIMEOUT

ln -s "$TMP/bands" "$TMP/bands-link"
write_config "$TMP/bands-link"
run
check "symlink destination warning is delivered" '[[ "$RC" -eq 0 && "$(state "data[\"checks\"][0][\"detail\"]")" == *"reason=invalid_source"* ]]'

write_config "$TMP/bands/../bands"
run
check "traversal source fails before probe or publication" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* && "$OUT" != *"$TMP/bands/../bands"* ]]'

write_config /
run
check "root source fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* ]]'
write_config "$TMP/./bands"
run
check "dot source fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* ]]'
write_config "$TMP/bands/"
run
check "trailing-slash source fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* ]]'
write_config "$TMP//bands"
run
check "duplicate-separator source fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"protected source is invalid"* ]]'

write_config "$TMP/bands"
TZ=UTC touch -t 202607131200 "$TMP/bands/0/fresh-band"
run_delivery
check "authenticated delivery succeeds" '[[ "$RC" -eq 0 && "$OUT" == *"200 (state=pass)"* ]]'
check "actual Heimdall consumer shape uses the Time Machine panel" '"$REAL_PYTHON" -c '\''import json,sys; r=json.load(open(sys.argv[1])); assert r["authorization"] == "Bearer secret-sentinel"; assert r["body"] == {"service":"brokkr","panel":"timemachine","kind":"status","label":"Time Machine Freshness","state":"pass","message":"1 checks, all nominal"}; assert r["timeout"] == 10'\'' "$TMP/request.json"'

rm -f "$TMP/request.json"
export MOCK_DELIVERY_FAIL=1
run_delivery
check "delivery transport failure remains non-zero" '[[ "$RC" -ne 0 && "$OUT" == *"brokkr push failed"* && ! -e "$TMP/request.json" ]]'
unset MOCK_DELIVERY_FAIL

rm -f "$TMP/request.json"
export MOCK_PYTHON_FAIL=probe
run_delivery
check "probe execution failure remains non-zero" '[[ "$RC" -eq 2 && "$OUT" == *"probe produced no result"* && ! -e "$TMP/request.json" ]]'
unset MOCK_PYTHON_FAIL

# shellcheck disable=SC2034 # assertion consumes this through check/eval
previous_snapshot="$(cat "$TMP/state/timemachine-health.json")"
export MOCK_PYTHON_FAIL=snapshot
run_delivery
check "snapshot write failure fails before delivery" '[[ "$RC" -ne 0 && "$OUT" == *"cannot generate snapshot"* && ! -e "$TMP/request.json" ]]'
check "snapshot write failure does not replay or replace the old snapshot" '[[ "$(cat "$TMP/state/timemachine-health.json")" == "$previous_snapshot" ]]'
unset MOCK_PYTHON_FAIL

echo "----"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
