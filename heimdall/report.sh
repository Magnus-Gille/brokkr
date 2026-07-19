#!/usr/bin/env bash
# Brokkr · Heimdall self-describe.
#
# Brokkr is config + scripts, not a daemon, so instead of serving GET /heimdall.json it
# COMPOSES the platform checks into a heimdall.json-shaped payload (the same contract the
# services serve, e.g. mimir's /heimdall.json) and prints it to stdout.
#
# Runs ON the NAS Pi (it invokes the disk checks). The Time Machine check is macOS-only and
# is reported separately from the Mac; feed its result in via $BROKKR_TM_STATUS plus
# $BROKKR_TM_OBSERVED_AT (epoch seconds) if desired. Undated/stale evidence stays unknown.
#
# Wired to Heimdall: scripts/health-snapshot.sh runs this + heimdall/push.sh (hw-health panel),
# driven by brokkr-health.timer on the NAS Pi every 15 min. See ../CLAUDE.md (Health model).
#
# No `set -e`: we intentionally run checks that may exit non-zero and map their codes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

worst="pass"
rank() { case "$1" in fail) echo 2 ;; warn) echo 1 ;; *) echo 0 ;; esac; }
bump() { if [ "$(rank "$1")" -gt "$(rank "$worst")" ]; then worst="$1"; fi; }

json_escape() {
  local s="$1" code oct ch escaped
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  # JSON forbids raw U+0000-U+001F. Bash variables cannot contain NUL, but encode
  # every other control byte with builtins so hostile check output remains valid JSON
  # without spawning a Python/jq process for each row.
  for ((code = 1; code <= 31; code++)); do
    printf -v oct '%03o' "$code"
    printf -v ch '%b' "\\$oct"
    printf -v escaped '\\u%04x' "$code"
    s="${s//$ch/$escaped}"
  done
  printf '%s' "$s"
}

rows=()

# Run a check script, map its exit code to a status, and record a JSON row.
run_check() {
  local name="$1" path="$2" out rc st
  out="$("$path" 2>&1)"; rc=$?
  case "$rc" in 0) st=pass ;; 1) st=warn ;; *) st=fail ;; esac
  bump "$st"
  rows+=("$(printf '    {"name": "%s", "status": "%s", "detail": "%s"}' \
            "$name" "$st" "$(json_escape "$out")")")
}

run_check "disk-mount"    "$HERE/disk/check-mount.sh"
run_check "disk-capacity" "$HERE/disk/check-capacity.sh"

# Time Machine can only be observed on the Mac. An absent/invalid Mac-side result is
# therefore a WARN with explicit UNKNOWN detail, never an implicit platform PASS.
# This keeps Heimdall honest: NAS disk health is not evidence that a Mac backup ran.
tm_reported_status="${BROKKR_TM_STATUS:-unknown}"
tm_reported_detail="${BROKKR_TM_DETAIL:-}"
tm_observed_at="${BROKKR_TM_OBSERVED_AT:-}"
tm_now="${BROKKR_NOW_EPOCH:-$(date +%s)}"
tm_max_age="${BROKKR_TM_EVIDENCE_MAX_AGE_SECS:-108000}"
case "$tm_reported_status" in
  pass|warn|fail)
    if [[ ! "$tm_observed_at" =~ ^[0-9]+$ ]] \
      || [[ ! "$tm_now" =~ ^[0-9]+$ ]] \
      || [[ ! "$tm_max_age" =~ ^[1-9][0-9]*$ ]]; then
      tm_status="warn"
      tm_detail="UNKNOWN: Mac-side status lacks a valid observation timestamp"
    elif [ "$tm_observed_at" -gt "$((tm_now + 300))" ]; then
      tm_status="warn"
      tm_detail="UNKNOWN: Mac-side Time Machine observation is in the future"
    elif [ "$((tm_now - tm_observed_at))" -gt "$tm_max_age" ]; then
      tm_status="warn"
      tm_detail="UNKNOWN: Mac-side Time Machine observation is stale"
    else
      tm_status="$tm_reported_status"
      tm_detail="${tm_reported_detail:-Mac-side Time Machine check reported ${tm_status}}"
    fi
    ;;
  ""|unknown)
    tm_status="warn"
    tm_detail="UNKNOWN: no Mac-side Time Machine result was supplied"
    ;;
  *)
    tm_status="warn"
    tm_detail="UNKNOWN: invalid BROKKR_TM_STATUS; expected pass, warn, or fail"
    ;;
esac
bump "$tm_status"
rows+=("$(printf '    {"name": "timemachine", "status": "%s", "detail": "%s"}' \
          "$tm_status" "$(json_escape "$tm_detail")")")

# Emit the descriptor (commas between rows, none after the last).
echo '{'
echo '  "name": "brokkr",'
echo '  "namespace": "grimnir",'
echo '  "kind": "platform",'
printf '  "status": "%s",\n' "$worst"
echo '  "checks": ['
n=${#rows[@]}
for ((i = 0; i < n; i++)); do
  if (( i < n - 1 )); then printf '%s,\n' "${rows[i]}"; else printf '%s\n' "${rows[i]}"; fi
done
echo '  ]'
echo '}'
