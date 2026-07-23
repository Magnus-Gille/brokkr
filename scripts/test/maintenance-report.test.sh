#!/usr/bin/env bash
# Hermetic Munin namespace tests for maintenance-report.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-maintenance-report-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repos"

cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
payload=""
previous=""
for arg in "$@"; do
  if [[ "$previous" == "-d" ]]; then payload="$arg"; break; fi
  previous="$arg"
done
printf '%s\n' "$payload" >>"$MOCK_MUNIN_CALLS"
printf 'data: {}\n'
MOCK
cat >"$TMP/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
printf 'test-host\n'
MOCK
cat >"$TMP/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
if [[ "${!#}" == true ]]; then exit 0; fi
cat <<'OUT'
REBOOT=no
REBOOT_PKGS=0
UU_INSTALLED=1
SEC_PENDING=0
ALL_PENDING=0
DISK=50
KERNEL=fixture
FW_MECH=none
FW_STATUS=current
FW_PENDING=0
FW_CUR=
FW_LAT=
FW_DETAIL=
OUT
MOCK
chmod +x "$TMP/bin/curl" "$TMP/bin/hostname" "$TMP/bin/ssh"

cat >"$TMP/services.json" <<'JSON'
{"components":[{"name":"fixture","repo":"fixture","host":"other-host","deploy":true,"scan":false}]}
JSON

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

run_report() {
  : >"$TMP/calls.jsonl"
  env \
    PATH="$TMP/bin:$PATH" \
    MOCK_MUNIN_CALLS="$TMP/calls.jsonl" \
    MUNIN_TOKEN=fixture-token \
    REGISTRY_PATH="$TMP/services.json" \
    REGISTRY_NO_GIT=1 \
    REPOS_DIR="$TMP/repos" \
    bash "$ROOT/scripts/maintenance-report.sh" "$MODE" >/dev/null 2>&1
}

has_call() {
  local method="$1" namespace="$2" key="${3:-}"
  METHOD="$method" NAMESPACE="$namespace" KEY="$key" python3 - "$TMP/calls.jsonl" <<'PY'
import json, os, sys
method, namespace, key = os.environ['METHOD'], os.environ['NAMESPACE'], os.environ['KEY']
for line in open(sys.argv[1], encoding='utf-8'):
    call = json.loads(line)
    params = call['params']
    args = params['arguments']
    if params['name'] == method and args['namespace'] == namespace and (not key or args.get('key') == key):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

echo "maintenance-report.test.sh"

MODE=os run_report
check "OS summary stores the date in its key, not its namespace" has_call memory_write maintenance/os "$(date -u +%Y-%m-%d)"
check "OS run logs under the canonical maintenance namespace" has_call memory_log maintenance

MODE=deps run_report
check "dependency summary stores the date in its key, not its namespace" has_call memory_write maintenance/deps "$(date -u +%Y-%m-%d)"
check "dependency run logs under the canonical maintenance namespace" has_call memory_log maintenance

MODE=brew run_report
check "brew run logs under the canonical maintenance namespace" has_call memory_log maintenance

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
