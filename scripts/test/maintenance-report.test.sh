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
printf '%s\n' "$@" >>"$MOCK_MUNIN_ARGV"
if [[ "${MOCK_MUNIN_CURL_MODE:-}" == early-exit ]]; then exit 28; fi
cat >"$MOCK_MUNIN_STDIN"
for arg in "$@"; do
  if [[ "$previous" == "-d" ]]; then payload="$arg"; break; fi
  previous="$arg"
done
printf '%s\n' "$payload" >>"$MOCK_MUNIN_CALLS"
printf '%s\n' "${MOCK_MUNIN_RESPONSE:-data: {}}"
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
    MOCK_MUNIN_ARGV="$TMP/curl.argv" \
    MOCK_MUNIN_STDIN="$TMP/curl.stdin" \
    MOCK_MUNIN_CURL_MODE="${MOCK_MUNIN_CURL_MODE:-}" \
    MUNIN_TOKEN="${MOCK_MUNIN_TOKEN-fixture-token}" \
    REGISTRY_PATH="$TMP/services.json" \
    REGISTRY_NO_GIT=1 \
    REPOS_DIR="$TMP/repos" \
    bash "$ROOT/scripts/maintenance-report.sh" "$MODE" >/dev/null 2>&1
}

has_no_token_in_curl_argv() {
  ! grep -Fq 'fixture-token' "$TMP/curl.argv"
}
has_bearer_header_on_stdin() {
  grep -Fqx 'Authorization: Bearer fixture-token' "$TMP/curl.stdin"
}
curl_uses_stdin_header_file() {
  grep -Fqx '@-' "$TMP/curl.argv"
}
file_lacks_token() {
  ! grep -Fq "$1" "$2"
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
check "Munin bearer is absent from curl argv" has_no_token_in_curl_argv
check "Munin bearer reaches curl as a header on stdin" has_bearer_header_on_stdin
check "Munin curl reads its authorization header from stdin" curl_uses_stdin_header_file

# The replacement CLI reads a token from stdin, keeping it out of the caller's
# argv. It accepts a nonempty final line without a newline and rejects empty,
# malformed, or legacy token arguments before making a request.
run_cli_token() {
  : >"$TMP/calls.jsonl"; : >"$TMP/curl.argv"; : >"$TMP/curl.stdin"
  printf '%s' "$2" | env \
    PATH="$TMP/bin:$PATH" \
    MOCK_MUNIN_CALLS="$TMP/calls.jsonl" \
    MOCK_MUNIN_ARGV="$TMP/curl.argv" \
    MOCK_MUNIN_STDIN="$TMP/curl.stdin" \
    MUNIN_TOKEN=ambient-fixture-token \
    REGISTRY_PATH="$TMP/services.json" REGISTRY_NO_GIT=1 REPOS_DIR="$TMP/repos" \
    bash "$ROOT/scripts/maintenance-report.sh" os "$1" >/dev/null 2>"$TMP/cli.err"
}
if run_cli_token --munin-token-stdin 'cli-fixture-token'; then cli_rc=0; else cli_rc=$?; fi
check "stdin CLI accepts a nonempty final line without newline" test "$cli_rc" -eq 0
check "stdin CLI token is absent from curl argv" file_lacks_token cli-fixture-token "$TMP/curl.argv"
check "stdin CLI token reaches curl on stdin" grep -Fqx 'Authorization: Bearer cli-fixture-token' "$TMP/curl.stdin"

for malformed in '' $'bad\rtoken' $'bad\ntoken' $'bad\r\ntoken'; do
  if run_cli_token --munin-token-stdin "$malformed"; then malformed_rc=0; else malformed_rc=$?; fi
  check "empty or line-broken stdin token fails before request" test "$malformed_rc" -ne 0
  check "malformed stdin token causes no request" test ! -s "$TMP/curl.argv"
  check "malformed stdin token uses a fixed diagnostic" grep -Fq 'Invalid Munin token on stdin; expected one nonempty line without CR/LF' "$TMP/cli.err"
  if [[ -n "$malformed" ]]; then
    check "malformed stdin token value is not echoed" file_lacks_token bad "$TMP/cli.err"
  fi
done

for legacy in --munin-token --munin-token=legacy-fixture-token; do
  : >"$TMP/curl.argv"
  if env PATH="$TMP/bin:$PATH" MOCK_MUNIN_CALLS="$TMP/calls.jsonl" \
    MOCK_MUNIN_ARGV="$TMP/curl.argv" MOCK_MUNIN_STDIN="$TMP/curl.stdin" \
    MUNIN_TOKEN=fixture-token REGISTRY_PATH="$TMP/services.json" REGISTRY_NO_GIT=1 \
    REPOS_DIR="$TMP/repos" bash "$ROOT/scripts/maintenance-report.sh" os "$legacy" legacy-fixture-token \
    >"$TMP/legacy.out" 2>&1; then legacy_rc=0; else legacy_rc=$?; fi
  check "legacy token option fails early" test "$legacy_rc" -ne 0
  check "legacy error does not echo token" file_lacks_token legacy-fixture-token "$TMP/legacy.out"
  check "legacy token option causes no curl request" test ! -s "$TMP/curl.argv"
done

if MOCK_MUNIN_CURL_MODE=early-exit MODE=os run_report; then curl_early_rc=0; else curl_early_rc=$?; fi
check "Munin curl early exit does not fail maintenance report" test "$curl_early_rc" -eq 0
check "Munin curl early exit still kept token out of argv" has_no_token_in_curl_argv

if env PATH="$TMP/bin:$PATH" MUNIN_TOKEN=fixture-token \
  MOCK_MUNIN_ARGV="$TMP/curl.argv" MOCK_MUNIN_STDIN="$TMP/curl.stdin" \
  MOCK_MUNIN_CALLS="$TMP/calls.jsonl" MOCK_MUNIN_RESPONSE='data: {"ok":true}' \
  bash -c '. "$1"; munin_call "{}"' _ "$ROOT/scripts/lib/munin.sh" >"$TMP/sse.out"; then sse_rc=0; else sse_rc=$?; fi
check "Munin success response keeps first SSE data parsing" test "$sse_rc" -eq 0
check "Munin success response returns parsed JSON data" grep -Fq '{"ok":true}' "$TMP/sse.out"

MODE=deps run_report
check "dependency summary stores the date in its key, not its namespace" has_call memory_write maintenance/deps "$(date -u +%Y-%m-%d)"
check "dependency run logs under the canonical maintenance namespace" has_call memory_log maintenance

MODE=brew run_report
check "brew run logs under the canonical maintenance namespace" has_call memory_log maintenance

: >"$TMP/curl.argv"; : >"$TMP/calls.jsonl"
if MOCK_MUNIN_TOKEN='' MODE=brew run_report; then no_token_rc=0; else no_token_rc=$?; fi
check "missing Munin token preserves successful no-op behavior" test "$no_token_rc" -eq 0
check "missing Munin token sends no requests" test ! -s "$TMP/curl.argv"

# Regression (brokkr-maintenance-os exit 1, 2026-07-25): on the live host, os
# mode exited 1 daily even though it completed its report correctly. Root
# cause: a deploy-tier host was unreachable (nas.local), which is a normal,
# already-alerted condition (any_action=true) — NOT a script failure. Sending
# that alert calls notify_telegram(), which resolves its config from
# ratatoskr/.env. That file never sets RATATOSKR_URL (Ratatoskr doesn't need
# its own URL — only RATATOSKR_SEND_API_KEY/TELEGRAM_ALLOWED_USERS/
# TELEGRAM_BOT_TOKEN), and the lookup helper's pipeline propagated grep's
# "no match" status through `set -o pipefail`, aborting the whole script
# under `set -e`. Reproduce end-to-end: an unreachable deploy host + a
# prod-shaped notify config missing RATATOSKR_URL must still exit 0.
mkdir -p "$TMP/unreachable/bin"
cat >"$TMP/unreachable/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
# Every host, including the liveness check ("... true"), is unreachable.
exit 255
MOCK
cp "$TMP/bin/curl" "$TMP/bin/hostname" "$TMP/unreachable/bin/"
chmod +x "$TMP/unreachable/bin/ssh"

cat >"$TMP/unreachable-services.json" <<'JSON'
{"components":[{"name":"fixture","repo":"fixture","host":"nas-fixture.example","deploy":true,"scan":false}]}
JSON
cat >"$TMP/prod-shaped-notify.env" <<'EOF'
RATATOSKR_SEND_API_KEY=fake-send-key
TELEGRAM_ALLOWED_USERS=123456789
TELEGRAM_BOT_TOKEN=fake-bot-token
EOF

: >"$TMP/calls.jsonl"
set +e
env \
  PATH="$TMP/unreachable/bin:$PATH" \
  MOCK_MUNIN_CALLS="$TMP/calls.jsonl" \
  MUNIN_TOKEN=fixture-token \
  REGISTRY_PATH="$TMP/unreachable-services.json" \
  REGISTRY_NO_GIT=1 \
  REPOS_DIR="$TMP/repos" \
  RATATOSKR_ENV="$TMP/missing-ratatoskr.env" \
  NOTIFY_ENV="$TMP/prod-shaped-notify.env" \
  bash "$ROOT/scripts/maintenance-report.sh" os >"$TMP/unreachable.out" 2>&1
unreachable_rc=$?
set -e
check "an unreachable deploy host + prod-shaped notify config still exits 0" \
  test "$unreachable_rc" -eq 0
check "the run still reports the unreachable host, not a silent abort" \
  grep -q 'nas-fixture: UNREACHABLE' "$TMP/unreachable.out"

# ── Guarded-reboot audit projection (Grimnir ADR-009) ────────────────────────
# The probe emits GUARDED_REBOOT_* keys; the report folds them into the host's Munin status,
# logs reboot / post-boot-issues / health-issues events (reversal kind: irreversible), and
# alerts on an unrecovered reboot for every host tier. The probe parsing itself is covered by
# maintenance-report-probe.test.sh; here the ssh fake returns canned probe output per host.
mkdir -p "$TMP/mbin" "$TMP/probe-out"
cp "$TMP/bin/curl" "$TMP/bin/hostname" "$TMP/mbin/"
cat >"$TMP/mbin/ssh" <<'MOCK'
#!/usr/bin/env bash
# ssh [-o opt]... user@host COMMAND: per-host canned probe output; no file = unreachable.
target="${@: -2:1}"; host="${target#*@}"
[[ -f "$MOCK_PROBE_OUT/$host" ]] || exit 255
if [[ "${!#}" == true ]]; then exit 0; fi
cat "$MOCK_PROBE_OUT/$host"
MOCK
chmod +x "$TMP/mbin/ssh" "$TMP/mbin/curl" "$TMP/mbin/hostname"

cat >"$TMP/services-gr.json" <<'JSON'
{"components":[{"name":"fixture","repo":"fixture","host":"other-host","deploy":true,"scan":false}],
 "nodes":[{"name":"inf-node","hostname":"inference-fixture.example","role":"inference","status":"active"}]}
JSON

BASE_PROBE=$'REBOOT=no\nREBOOT_PKGS=0\nUU_INSTALLED=1\nSEC_PENDING=0\nALL_PENDING=0\nDISK=50\nKERNEL=fixture\nFW_MECH=none\nFW_STATUS=current\nFW_PENDING=0\nFW_CUR=\nFW_LAT=\nFW_DETAIL=\n'
set_probe() { # host [extra probe lines]
  printf '%s%s' "$BASE_PROBE" "${2:-}" >"$TMP/probe-out/$1"
}
clear_probe() { rm -f "$TMP/probe-out/$1"; }
not() { ! "$@"; }
NOW_E="$(date +%s)"
GR_ACTIVE=$'GUARDED_REBOOT=present\nGUARDED_REBOOT_LAST_ACTION=health-issues\nGUARDED_REBOOT_LAST_EPOCH='"$((NOW_E - 600))"$'\nGUARDED_REBOOT_REBOOTS_24H=1\nGUARDED_REBOOT_DEFERRALS_24H=2\nGUARDED_REBOOT_ALERTS_24H=1\nGUARDED_REBOOT_ISSUES_24H=1\nGUARDED_REBOOT_HEALTH_ISSUES_24H=1\nGUARDED_REBOOT_LAST_REBOOT_EPOCH='"$((NOW_E - 7200))"$'\nGUARDED_REBOOT_UNRECOVERED=0\nGUARDED_REBOOT_LATCHED=1\n'
REBOOT_EPOCH=1793000000
REBOOT_ISO="$(python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$REBOOT_EPOCH")"
GR_UNRECOVERED=$'GUARDED_REBOOT=present\nGUARDED_REBOOT_LAST_ACTION=reboot\nGUARDED_REBOOT_LAST_EPOCH='"$REBOOT_EPOCH"$'\nGUARDED_REBOOT_REBOOTS_24H=0\nGUARDED_REBOOT_DEFERRALS_24H=0\nGUARDED_REBOOT_ALERTS_24H=0\nGUARDED_REBOOT_ISSUES_24H=0\nGUARDED_REBOOT_HEALTH_ISSUES_24H=0\nGUARDED_REBOOT_LAST_REBOOT_EPOCH='"$REBOOT_EPOCH"$'\nGUARDED_REBOOT_UNRECOVERED=1\nGUARDED_REBOOT_LATCHED=0\n'

run_os() { # [extra args...]: os mode against the per-host fake; stdout in $TMP/os.out
  : >"$TMP/calls.jsonl"; : >"$TMP/curl.argv"
  env \
    PATH="$TMP/mbin:$PATH" \
    MOCK_PROBE_OUT="$TMP/probe-out" \
    MOCK_MUNIN_CALLS="$TMP/calls.jsonl" MOCK_MUNIN_ARGV="$TMP/curl.argv" MOCK_MUNIN_STDIN="$TMP/curl.stdin" \
    MUNIN_TOKEN="${MOCK_MUNIN_TOKEN-fixture-token}" \
    REGISTRY_PATH="$TMP/services-gr.json" REGISTRY_NO_GIT=1 REPOS_DIR="$TMP/repos" \
    RATATOSKR_ENV="$TMP/none.env" NOTIFY_ENV="$TMP/none.env" \
    bash "$ROOT/scripts/maintenance-report.sh" os "$@" >"$TMP/os.out" 2>"$TMP/os.err"
}
call_has_text() { # method namespace text [key]
  METHOD="$1" NAMESPACE="$2" TEXT="$3" KEY="${4:-}" python3 - "$TMP/calls.jsonl" <<'PY'
import json, os, sys
for line in open(sys.argv[1], encoding='utf-8'):
    params = json.loads(line)['params']
    args = params['arguments']
    if (params['name'] == os.environ['METHOD'] and args['namespace'] == os.environ['NAMESPACE']
            and (not os.environ['KEY'] or args.get('key') == os.environ['KEY'])
            and os.environ['TEXT'] in args.get('content', '')):
        raise SystemExit(0)
raise SystemExit(1)
PY
}
out_has() { grep -qF -- "$1" "$TMP/os.out"; }

clear_probe inference-fixture.example
set_probe other-host "$GR_ACTIVE"
run_os
check "guarded-reboot counters are part of the host's Munin status" \
  call_has_text memory_write maintenance/os/other-host "reboots_24h=1 deferrals_24h=2 alerts_24h=1 issues_24h=1 health_issues_24h=1 unrecovered=0 latched=1" latest
check "the Munin status shows the last guarded-reboot action" \
  call_has_text memory_write maintenance/os/other-host "guarded_reboot=last:health-issues@" latest
check "a 24 h reboot / post-boot-issues / health-issues event is logged for the host" \
  has_call memory_log maintenance/os/other-host
check "the audit-event log says the reversal kind is irreversible" \
  call_has_text memory_log maintenance/os/other-host "reversal: irreversible"
check "the audit-event log carries the 24 h counts" \
  call_has_text memory_log maintenance/os/other-host "reboots=1 post_boot_issues=1 health_issues=1"
check "no unrecovered alert when the reboot was followed by a post-boot record" \
  not out_has "never reported its post-boot check"

set_probe other-host $'GUARDED_REBOOT=absent\n'
run_os
check "absent audit file: status says guarded_reboot=absent" \
  call_has_text memory_write maintenance/os/other-host "guarded_reboot=absent" latest
check "absent audit file: no audit-event log" not has_call memory_log maintenance/os/other-host

set_probe other-host
run_os
check "a probe without guarded-reboot keys is tolerated (treated as absent)" \
  call_has_text memory_write maintenance/os/other-host "guarded_reboot=absent" latest

set_probe other-host $'GUARDED_REBOOT=present\nGUARDED_REBOOT_LAST_ACTION=deferred\nGUARDED_REBOOT_LAST_EPOCH=1\nGUARDED_REBOOT_REBOOTS_24H=0\nGUARDED_REBOOT_DEFERRALS_24H=3\nGUARDED_REBOOT_ALERTS_24H=0\nGUARDED_REBOOT_ISSUES_24H=0\nGUARDED_REBOOT_HEALTH_ISSUES_24H=0\nGUARDED_REBOOT_UNRECOVERED=0\nGUARDED_REBOOT_LATCHED=0\n'
run_os
check "deferrals alone do not produce an audit-event log" not has_call memory_log maintenance/os/other-host

set_probe other-host $'GUARDED_REBOOT=present\nGUARDED_REBOOT_LAST_ACTION=health-issues\nGUARDED_REBOOT_LAST_EPOCH=1\nGUARDED_REBOOT_REBOOTS_24H=0\nGUARDED_REBOOT_DEFERRALS_24H=0\nGUARDED_REBOOT_ALERTS_24H=0\nGUARDED_REBOOT_ISSUES_24H=0\nGUARDED_REBOOT_HEALTH_ISSUES_24H=2\nGUARDED_REBOOT_UNRECOVERED=0\nGUARDED_REBOOT_LATCHED=0\n'
run_os
check "a daily health regression alone is logged like post-boot issues" \
  call_has_text memory_log maintenance/os/other-host "health_issues=2"

# Hostile or garbled probe values degrade to zero / unknown instead of aborting the run.
set_probe other-host $'GUARDED_REBOOT=present\nGUARDED_REBOOT_LAST_ACTION=$(rm -rf /)\nGUARDED_REBOOT_LAST_EPOCH=abc\nGUARDED_REBOOT_REBOOTS_24H=x\nGUARDED_REBOOT_UNRECOVERED=7\nGUARDED_REBOOT_LATCHED=yes\n'
if run_os; then garbled_rc=0; else garbled_rc=$?; fi
check "garbled guarded-reboot values do not fail the run" test "$garbled_rc" -eq 0
check "garbled guarded-reboot values are not echoed into Munin" not grep -q 'rm -rf' "$TMP/calls.jsonl"
check "garbled flags are not read as set" call_has_text memory_write maintenance/os/other-host "unrecovered=0 latched=0" latest

set_probe other-host "$GR_ACTIVE"
run_os --dry-run
check "dry-run writes no Munin state or log for the guarded-reboot projection" test ! -s "$TMP/calls.jsonl"
if MOCK_MUNIN_TOKEN='' run_os; then notoken_rc=0; else notoken_rc=$?; fi
check "a missing Munin token is tolerated with guarded-reboot data" test "$notoken_rc" -eq 0
check "a missing Munin token sends no request" test ! -s "$TMP/curl.argv"

# Unrecovered reboot: alerted for every tier through the existing Telegram path.
set_probe other-host "$GR_UNRECOVERED"
set_probe inference-fixture.example "$GR_UNRECOVERED"
run_os --dry-run
check "unrecovered reboot on a deploy-tier host alerts with the reboot time" \
  out_has "other-host rebooted at $REBOOT_ISO but never reported its post-boot check"
check "unrecovered reboot on a node-tier host alerts too" \
  out_has "inference-fixture rebooted at $REBOOT_ISO but never reported its post-boot check"
run_os
check "unrecovered=1 is visible in the Munin status" \
  call_has_text memory_write maintenance/os/other-host "unrecovered=1" latest

# What the report already does when a host is unreachable over SSH, so that a host that never
# came back is surfaced even though it cannot report: a deploy-tier host is alerted as
# unreachable; a node-tier host is only recorded in Munin (it may be legitimately powered off)
# and gets no Telegram alert.
clear_probe other-host
clear_probe inference-fixture.example
run_os --dry-run
check "unreachable deploy-tier host is alerted" out_has "other-host unreachable for OS maintenance check"
check "unreachable node-tier host is recorded in the summary" out_has "inference-fixture: unreachable (node, best-effort)"
check "unreachable node-tier host is not alerted" not out_has "inference-fixture unreachable"
run_os
check "unreachable hosts overwrite their Munin status with UNREACHABLE" \
  call_has_text memory_write maintenance/os/other-host "UNREACHABLE" latest

# BROKKR_ALERT_UNREACHABLE_NODES: space-separated node IDs (the registry node name, or the short
# host name) whose unreachability alerts like a deploy-tier host (the guarded-reboot job may have
# rebooted them and they may not have come back). Unlisted nodes keep the Munin-only behaviour.
ALERT_TEXT="inference-fixture unreachable for OS maintenance check — if it was rebooted by the guarded-reboot job it may not have come back"
set_probe other-host
clear_probe inference-fixture.example
BROKKR_ALERT_UNREACHABLE_NODES="inf-node" run_os --dry-run
check "a listed unreachable node (by registry name) is alerted with the guarded-reboot hint" out_has "$ALERT_TEXT"
check "a listed unreachable node is flagged UNREACHABLE in the summary" out_has "inference-fixture: UNREACHABLE"
BROKKR_ALERT_UNREACHABLE_NODES="something-else inference-fixture" run_os --dry-run
check "a listed unreachable node (by short host name, among several IDs) is alerted" out_has "$ALERT_TEXT"
BROKKR_ALERT_UNREACHABLE_NODES="something-else" run_os --dry-run
check "an unlisted unreachable node stays Munin-only" not out_has "inference-fixture unreachable"
check "an unlisted unreachable node is still recorded in the summary" out_has "inference-fixture: unreachable (node, best-effort)"
set_probe inference-fixture.example
BROKKR_ALERT_UNREACHABLE_NODES="inf-node" run_os --dry-run
check "a listed node that is reachable is not alerted" not out_has "inference-fixture unreachable"
clear_probe inference-fixture.example
BROKKR_ALERT_UNREACHABLE_NODES="inf-node" run_os
check "a listed unreachable node still overwrites its Munin status" \
  call_has_text memory_write maintenance/os/inference-fixture "UNREACHABLE" latest

# An invalid or unmatched entry must not silently disable the alert: the run continues and
# says so in the alert. The invalid text is never echoed.
if BROKKR_ALERT_UNREACHABLE_NODES='inf-node bad;$(id) ghost-node' run_os --dry-run; then listed_rc=0; else listed_rc=$?; fi
check "a bad entry does not fail the run" test "$listed_rc" -eq 0
check "a valid entry beside a bad one still alerts" out_has "$ALERT_TEXT"
check "an invalid entry is reported as ignored, without echoing it" \
  out_has "BROKKR_ALERT_UNREACHABLE_NODES has an invalid entry (ignored)"
check "invalid entry text is not echoed" not out_has 'bad;'
check "an entry matching no active node is reported" out_has "BROKKR_ALERT_UNREACHABLE_NODES lists 'ghost-node', which matches no active registry node"
BROKKR_ALERT_UNREACHABLE_NODES='' run_os --dry-run
check "an empty setting (default) raises no configuration alert" not out_has "BROKKR_ALERT_UNREACHABLE_NODES"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
