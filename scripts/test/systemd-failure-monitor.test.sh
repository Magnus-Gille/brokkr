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
SYSTEMCTL_CALLS="$TMP/systemctl-calls"
ORDER_LOG="$TMP/order"
: >"$CALLS"; : >"$UNEXPECTED"; : >"$SYSTEMCTL_CALLS"; : >"$ORDER_LOG"

cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"list-units"*"--type=service"*"--state=failed"*)
    printf 'list\n' >>"$MOCK_SYSTEMCTL_CALLS"
    printf 'list\n' >>"$MOCK_ORDER_LOG"
    while IFS= read -r unit; do
      [ -n "$unit" ] && printf '%s loaded failed failed synthetic failure\n' "$unit"
    done <"$MOCK_FAILED_UNITS"
    ;;
  *"reset-failed"*)
    unit="${@: -1}"
    printf 'reset-failed:%s\n' "$unit" >>"$MOCK_SYSTEMCTL_CALLS"
    printf 'reset-failed:%s\n' "$unit" >>"$MOCK_ORDER_LOG"
    if [[ "${MOCK_RESET_RC:-0}" -eq 0 ]]; then
      filtered="${MOCK_FAILED_UNITS}.filtered"
      grep -Fvx "$unit" "$MOCK_FAILED_UNITS" >"$filtered" || :
      mv "$filtered" "$MOCK_FAILED_UNITS"
      producer="${unit#brokkr-systemd-failure@}"
      producer="${producer%.service}"
      if [[ "${MOCK_PRODUCER_REFAIL_AFTER_RESET:-0}" -eq 1 ]]; then
        printf '%s\n' "$producer" >>"$MOCK_FAILED_UNITS"
      fi
      if [[ "${MOCK_REPORTER_REFAIL_AFTER_RESET:-0}" -eq 1 ]]; then
        printf '%s\n' "$unit" >>"$MOCK_FAILED_UNITS"
      fi
      LC_ALL=C sort -u "$MOCK_FAILED_UNITS" -o "$MOCK_FAILED_UNITS"
    fi
    exit "${MOCK_RESET_RC:-0}"
    ;;
  *"show"*)
    unit="${@: -1}"
    printf 'show:%s\n' "$unit" >>"$MOCK_SYSTEMCTL_CALLS"
    printf 'show:%s\n' "$unit" >>"$MOCK_ORDER_LOG"
    if [[ "$unit" == brokkr-systemd-failure@* && "${MOCK_PRODUCER_REFAIL_BEFORE_REPORTER_READBACK:-0}" -eq 1 ]]; then
      producer="${unit#brokkr-systemd-failure@}"
      producer="${producer%.service}"
      printf '%s\n' "$producer" >>"$MOCK_FAILED_UNITS"
      LC_ALL=C sort -u "$MOCK_FAILED_UNITS" -o "$MOCK_FAILED_UNITS"
    fi
    if grep -Fqx "$unit" "$MOCK_FAILED_UNITS"; then
      case "$unit" in
        brokkr-systemd-failure@*) state="${MOCK_REPORTER_STATE:-failed}" ;;
        *) state=failed ;;
      esac
    else
      state="${MOCK_UNIT_STATE:-inactive}"
    fi
    printf '%s\n' "$state"
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
        with open(os.environ['MOCK_ORDER_LOG'], 'a', encoding='utf-8') as fh:
            fh.write('delivery\n')
        status = int(os.environ.get('MOCK_HTTP_STATUS', '200'))
        count_file = os.environ.get('MOCK_HTTP_COUNT_FILE')
        if os.environ.get('MOCK_FAIL_SECOND_PUSH') == '1' and count_file:
            try:
                count = int(open(count_file, encoding='utf-8').read())
            except (FileNotFoundError, ValueError):
                count = 0
            with open(count_file, 'w', encoding='utf-8') as fh:
                fh.write(str(count + 1))
            if count == 1:
                status = 500
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
export MOCK_SYSTEMCTL_CALLS="$SYSTEMCTL_CALLS" MOCK_ORDER_LOG="$ORDER_LOG"
export MOCK_HTTP_COUNT_FILE="$TMP/http-count"
export BROKKR_STATE_DIR="$TMP/state"
export HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels HEIMDALL_FLEET_TOKEN=test-token
export RATATOSKR_URL=http://ratatoskr.invalid/api/send RATATOSKR_SEND_API_KEY=test-key
export TELEGRAM_ALLOWED_USERS=123456789
export MOCK_HTTP_STATUS=200
export MOCK_UNIT_STATE=failed

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
export MOCK_UNIT_STATE=inactive
run --sweep
check "clearing every failed unit emits recoveries" '[[ "$RC" -eq 0 && "$OUT" == *"recovered: alpha.service"* && "$OUT" == *"recovered: beta.service"* ]]'
check "recovery clears durable failed-unit state" '[[ ! -s "$TMP/state/systemd-failures/failed-units" ]]'
check "recovery updates Heimdall to pass" 'python3 -c '\''import json,sys; d=json.load(open(sys.argv[1])); assert d["body"]["state"] == "pass"'\'' "$REQUEST"'
check "recovery sends one notification per recovered unit" '[[ "$(wc -l < "$CALLS" | tr -d " ")" -eq 4 ]]'

# The immediate OnFailure path must reconcile the explicitly reported unit even
# when a concurrent list-units snapshot omits it. A positive failed-state
# readback preserves a genuine failure; a positive inactive-state readback
# permits a recovered unit to leave durable reporter state.
printf 'alpha.service\nbeta.service\n' >"$FAILED_UNITS"
run --sweep
check "mixed failure baseline is durable before immediate reconciliation" '[[ "$RC" -eq 0 ]] && grep -qx "alpha.service" "$TMP/state/systemd-failures/failed-units" && grep -qx "beta.service" "$TMP/state/systemd-failures/failed-units"'

: >"$FAILED_UNITS"
export MOCK_UNIT_STATE=failed
run --unit beta.service
check "still-failing OnFailure unit survives a list snapshot race" '[[ "$RC" -eq 0 ]] && grep -qx "beta.service" "$TMP/state/systemd-failures/failed-units"'
check "still-failing unit is not reported as recovered" '[[ "$OUT" != *"recovered: beta.service"* ]]'

export MOCK_UNIT_STATE=inactive
run --unit beta.service
check "recovered OnFailure unit is removed from durable reporter state" '[[ "$RC" -eq 0 ]] && [[ ! -s "$TMP/state/systemd-failures/failed-units" ]] && [[ "$OUT" == *"recovered: beta.service"* ]]'

# A previously failed immediate reporter can outlive its recovered producer.
# The monitor must clear only that exact reporter instance, after delivery and
# after a direct producer recovery readback.
REPORTER="brokkr-systemd-failure@alpha.service.service"
printf 'alpha.service\n%s\n' "$REPORTER" >"$TMP/state/systemd-failures/failed-units"
printf '%s\n' "$REPORTER" >"$FAILED_UNITS"
: >"$SYSTEMCTL_CALLS"; : >"$ORDER_LOG"
export MOCK_UNIT_STATE=inactive MOCK_REPORTER_STATE=failed MOCK_RESET_RC=0
run --sweep
check "recovered producer with stale reporter succeeds" '[[ "$RC" -eq 0 && "$OUT" == *"cleared failed reporter: $REPORTER"* ]]'
check "reset-failed clears only the exact Brokkr reporter instance" 'grep -Fxq "reset-failed:$REPORTER" "$SYSTEMCTL_CALLS" && ! grep -Fqx "$REPORTER" "$FAILED_UNITS" && ! grep -Fqx "$REPORTER" "$TMP/state/systemd-failures/failed-units"'
check "reporter reset and convergence are enclosed by producer and reporter readbacks" '[[ "$(tr "\n" " " < "$ORDER_LOG")" == "list show:alpha.service delivery show:alpha.service show:$REPORTER reset-failed:$REPORTER show:alpha.service show:$REPORTER delivery " ]]'
check "final panel omits the reset reporter" 'python3 -c '\''import json,sys; d=json.load(open(sys.argv[1])); assert d["body"]["state"] == "pass"'\'' "$REQUEST" && ! grep -Fq "$REPORTER" "$REQUEST"'

export MOCK_UNIT_STATE=inactive
run --sweep
check "next sweep does not emit a misleading reporter recovery" '[[ "$RC" -eq 0 && "$OUT" != *"recovered: $REPORTER"* ]]'

# If the converged second delivery fails, keep the reset marker and durable
# pre-reset state so the next retry suppresses only the already-cleared
# reporter, while still publishing the producer recovery.
printf 'alpha.service\n%s\n' "$REPORTER" >"$TMP/state/systemd-failures/failed-units"
printf '%s\n' "$REPORTER" >"$FAILED_UNITS"
: >"$SYSTEMCTL_CALLS"; : >"$ORDER_LOG"; : >"$TMP/http-count"
export MOCK_UNIT_STATE=inactive MOCK_REPORTER_STATE=failed MOCK_RESET_RC=0 MOCK_FAIL_SECOND_PUSH=1
run --sweep
check "failed converged panel push is visible" '[[ "$RC" -ne 0 && "$OUT" == *"final Heimdall push failed"* ]]'
check "failed converged push leaves reset marker and retryable state" 'grep -Fqx "$REPORTER" "$TMP/state/systemd-failures/reset-reporters" && grep -Fqx "$REPORTER" "$TMP/state/systemd-failures/failed-units"'

export MOCK_FAIL_SECOND_PUSH=0
run --sweep
check "retry after failed converged push clears stale reporter without recovery noise" '[[ "$RC" -eq 0 && "$OUT" != *"recovered: $REPORTER"* ]] && [[ ! -s "$TMP/state/systemd-failures/reset-reporters" ]] && [[ ! -s "$TMP/state/systemd-failures/failed-units" ]]'

# reset-failed is not a synchronization barrier. If the producer fails again
# before the converged recovery publication, retain the durable pre-reset
# state, keep the pending marker, and leave the fresh producer failure in the
# mocked current systemd state. No clean second delivery is permitted.
printf 'alpha.service\n%s\n' "$REPORTER" >"$TMP/state/systemd-failures/failed-units"
printf '%s\n' "$REPORTER" >"$FAILED_UNITS"
: >"$SYSTEMCTL_CALLS"; : >"$ORDER_LOG"; : >"$TMP/http-count"
export MOCK_UNIT_STATE=inactive MOCK_REPORTER_STATE=failed MOCK_RESET_RC=0
export MOCK_PRODUCER_REFAIL_AFTER_RESET=1
run --sweep
check "producer refailure after reporter reset fails closed" '[[ "$RC" -ne 0 && "$OUT" == *"failed again after reporter reset"* ]]'
check "post-reset producer failure remains current and durable" 'grep -Fqx "alpha.service" "$FAILED_UNITS" && grep -Fqx "alpha.service" "$TMP/state/systemd-failures/failed-units" && grep -Fqx "$REPORTER" "$TMP/state/systemd-failures/failed-units"'
check "post-reset producer failure retains pending reset" 'grep -Fqx "$REPORTER" "$TMP/state/systemd-failures/reset-reporters"'
check "post-reset producer failure never publishes a clean panel" '[[ "$(grep -cFx delivery "$ORDER_LOG")" -eq 1 ]] && python3 -c '\''import json,sys; d=json.load(open(sys.argv[1])); assert d["body"]["state"] == "fail"'\'' "$REQUEST" && grep -Fq "$REPORTER" "$REQUEST"'
unset MOCK_PRODUCER_REFAIL_AFTER_RESET

# A reporter that fails again after reset is equally ambiguous and must not be
# removed from CURRENT or durable state before a later retry.
printf 'alpha.service\n%s\n' "$REPORTER" >"$TMP/state/systemd-failures/failed-units"
printf '%s\n' "$REPORTER" >"$FAILED_UNITS"
: >"$SYSTEMCTL_CALLS"; : >"$ORDER_LOG"; : >"$TMP/http-count"
export MOCK_UNIT_STATE=inactive MOCK_REPORTER_STATE=failed MOCK_RESET_RC=0
export MOCK_REPORTER_REFAIL_AFTER_RESET=1
run --sweep
check "reporter refailure after reset fails closed" '[[ "$RC" -ne 0 && "$OUT" == *"failed again after reset"* ]]'
check "post-reset reporter failure retains durable state" 'grep -Fqx "alpha.service" "$TMP/state/systemd-failures/failed-units" && grep -Fqx "$REPORTER" "$TMP/state/systemd-failures/failed-units"'
check "post-reset reporter failure does not publish a clean panel" '[[ "$(grep -cFx delivery "$ORDER_LOG")" -eq 1 ]]'
unset MOCK_REPORTER_REFAIL_AFTER_RESET

# A reporter can self-clear before reset-failed, but the producer can fail
# again before the reporter readback completes. The common post-readback gate
# must retain both durable failures and the already-delivered failure panel.
printf 'alpha.service\n%s\n' "$REPORTER" >"$TMP/state/systemd-failures/failed-units"
printf '%s\n' "$REPORTER" >"$FAILED_UNITS"
rm -f "$TMP/state/systemd-failures/reset-reporters"
: >"$SYSTEMCTL_CALLS"; : >"$ORDER_LOG"; : >"$TMP/http-count"
export MOCK_UNIT_STATE=inactive MOCK_REPORTER_STATE=inactive MOCK_RESET_RC=0
export MOCK_PRODUCER_REFAIL_BEFORE_REPORTER_READBACK=1
run --sweep
check "producer refailure before self-cleared reporter readback fails closed" '[[ "$RC" -ne 0 && "$OUT" == *"failed again before reporter recovery commit"* ]]'
check "pre-readback producer failure remains current and durable" 'grep -Fqx "alpha.service" "$FAILED_UNITS" && grep -Fqx "alpha.service" "$TMP/state/systemd-failures/failed-units" && grep -Fqx "$REPORTER" "$TMP/state/systemd-failures/failed-units"'
check "pre-readback producer failure does not reset reporter" '! grep -Fq "reset-failed:" "$SYSTEMCTL_CALLS" && [[ ! -s "$TMP/state/systemd-failures/reset-reporters" ]]'
check "pre-readback producer failure never publishes a clean panel" '[[ "$(grep -cFx delivery "$ORDER_LOG")" -eq 1 ]] && python3 -c '\''import json,sys; d=json.load(open(sys.argv[1])); assert d["body"]["state"] == "fail"'\'' "$REQUEST" && grep -Fq "$REPORTER" "$REQUEST"'
unset MOCK_PRODUCER_REFAIL_BEFORE_REPORTER_READBACK

# The non-racing self-cleared reporter path still publishes the producer
# recovery, even though no pending reset marker exists.
printf 'alpha.service\n%s\n' "$REPORTER" >"$TMP/state/systemd-failures/failed-units"
printf '%s\n' "$REPORTER" >"$FAILED_UNITS"
: >"$SYSTEMCTL_CALLS"; : >"$ORDER_LOG"; : >"$TMP/http-count"
export MOCK_UNIT_STATE=inactive MOCK_REPORTER_STATE=inactive MOCK_RESET_RC=0
run --sweep
check "self-cleared reporter recovery succeeds without reset" '[[ "$RC" -eq 0 && "$OUT" == *"recovered: alpha.service"* ]] && ! grep -Fq "reset-failed:" "$SYSTEMCTL_CALLS"'
check "self-cleared reporter recovery publishes pass" '[[ ! -s "$TMP/state/systemd-failures/failed-units" ]] && python3 -c '\''import json,sys; d=json.load(open(sys.argv[1])); assert d["body"]["state"] == "pass"'\'' "$REQUEST"'

# Recovery is only clearable for a stable producer state. Transitional states
# must fail closed before delivery or reset-failed, preserving both states for
# a later sweep.
for transitional in reloading activating deactivating maintenance; do
  printf 'alpha.service\n%s\n' "$REPORTER" >"$TMP/state/systemd-failures/failed-units"
  printf '%s\n' "$REPORTER" >"$FAILED_UNITS"
  : >"$SYSTEMCTL_CALLS"; : >"$ORDER_LOG"
  export MOCK_UNIT_STATE="$transitional" MOCK_REPORTER_STATE=failed MOCK_RESET_RC=0
  run --sweep
  check "producer $transitional state remains ambiguous" '[[ "$RC" -ne 0 && "$OUT" == *"ambiguous producer state"* ]] && ! grep -Fq "reset-failed:" "$SYSTEMCTL_CALLS" && ! grep -Fq "delivery" "$ORDER_LOG"'
  check "producer $transitional state preserves durable failure" 'grep -Fqx "alpha.service" "$TMP/state/systemd-failures/failed-units" && grep -Fqx "$REPORTER" "$TMP/state/systemd-failures/failed-units"'
done

# A producer that is still failed must keep both the producer and reporter
# failures visible; no reset-failed command is permitted.
printf 'alpha.service\n%s\n' "$REPORTER" >"$FAILED_UNITS"
: >"$SYSTEMCTL_CALLS"; : >"$ORDER_LOG"
export MOCK_UNIT_STATE=failed
run --sweep
check "still-failing producer preserves reporter failure" '[[ "$RC" -eq 0 ]] && grep -Fqx "$REPORTER" "$FAILED_UNITS" && ! grep -Fq "reset-failed:" "$SYSTEMCTL_CALLS"'

# Unknown producer state and reset failure both fail closed before durable state
# publication; the failed reporter remains observable for a later retry.
printf 'alpha.service\n%s\n' "$REPORTER" >"$TMP/state/systemd-failures/failed-units"
printf '%s\n' "$REPORTER" >"$FAILED_UNITS"
: >"$SYSTEMCTL_CALLS"; : >"$ORDER_LOG"
export MOCK_UNIT_STATE=unknown MOCK_RESET_RC=0
run --sweep
check "ambiguous producer recovery refuses before delivery" '[[ "$RC" -ne 0 && "$OUT" == *"unknown state"* ]] && ! grep -Fq "delivery" "$ORDER_LOG"'
check "ambiguous producer recovery preserves durable state" 'grep -Fqx "alpha.service" "$TMP/state/systemd-failures/failed-units" && grep -Fqx "$REPORTER" "$TMP/state/systemd-failures/failed-units"'

export MOCK_UNIT_STATE=inactive MOCK_RESET_RC=1
run --sweep
check "failed reporter reset is non-zero and attributable" '[[ "$RC" -ne 0 && "$OUT" == *"could not clear failed reporter"* ]]'
check "failed reporter reset preserves durable state" 'grep -Fqx "alpha.service" "$TMP/state/systemd-failures/failed-units" && grep -Fqx "$REPORTER" "$TMP/state/systemd-failures/failed-units"'

export MOCK_RESET_RC=0

export MOCK_UNIT_STATE=failed

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
