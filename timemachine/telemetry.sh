#!/usr/bin/env bash
# Brokkr · publish M5-local Time Machine destination freshness (brokkr#53).
# Reads only bounded sparsebundle band-file metadata; it never invokes tmutil,
# traverses a client, mounts storage, or changes a backup.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${BROKKR_TM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/brokkr}"
CONFIG="${BROKKR_TM_PROBE_SOURCE:-${XDG_CONFIG_HOME:-$HOME/.config}/brokkr/timemachine-probe.env}"

fail() { echo "brokkr Time Machine telemetry: $1" >&2; exit 2; }
stat_attr() { # GNU stat first: GNU accepts -f with unrelated filesystem semantics.
  local gnu=$1 bsd=$2 path=$3 value
  if value="$(stat -c "$gnu" "$path" 2>/dev/null)"; then
    printf '%s' "$value"
  else
    stat -f "$bsd" "$path"
  fi
}
case "$CONFIG" in /*) ;; *) fail "protected source is invalid" ;; esac
[ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || fail "protected source is unavailable"
owner="$(stat_attr '%u' '%u' "$CONFIG")"
mode="$(stat_attr '%a' '%Lp' "$CONFIG")"
[ "$owner" = "$(id -u)" ] && [ "$mode" = 600 ] || fail "protected source is unsafe"
[ "$(grep -Ec '^BROKKR_TM_BANDS_DIR=/.*$' "$CONFIG")" -eq 1 ] || fail "protected source is invalid"
awk 'END { exit (NR == 1 ? 0 : 1) }' "$CONFIG" || fail "protected source is invalid"
if grep -q '[[:cntrl:]]' "$CONFIG"; then
  fail "protected source is invalid"
fi
BROKKR_TM_BANDS_DIR="${CONFIG:+$(sed -n 's/^BROKKR_TM_BANDS_DIR=//p' "$CONFIG")}"
case "$BROKKR_TM_BANDS_DIR" in /*) ;; *) fail "protected source is invalid" ;; esac
case "$BROKKR_TM_BANDS_DIR" in /|*/|*'//'*|*'/./'*|*'/../'*|./*|../*|*/.|*/..|.) fail "protected source is invalid" ;; esac
export BROKKR_TM_BANDS_DIR

mkdir -p "$STATE_DIR" || fail "cannot create state directory"
[ -n "${HEIMDALL_HUB_URL:-}" ] && [ -n "${HEIMDALL_FLEET_TOKEN:-}" ] || fail "Heimdall delivery is not configured"
probe="$(python3 "$HERE/destination-probe.py")"
probe_rc=$?
[ -n "$probe" ] || fail "probe produced no result"
snapshot="$STATE_DIR/timemachine-health.json"
tmp="$STATE_DIR/.timemachine-health.json.$$"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT

if ! python3 - "$tmp" "$probe" <<'PY'
import json, sys
path, probe = sys.argv[1:]
data = json.loads(probe)
if data.get("status") not in ("pass", "warn", "fail"):
    raise ValueError("invalid probe status")
allowed = {"status", "reason", "observed_at", "count", "size_bytes", "latest_epoch", "age_seconds"}
if set(data) - allowed:
    raise ValueError("unexpected probe field")
detail = "Time Machine destination result={status} reason={reason} observed_at={observed_at} count={count} size_bytes={size_bytes}".format(**data)
if "latest_epoch" in data:
    detail += " latest_epoch={latest_epoch} age_seconds={age_seconds}".format(**data)
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"name":"brokkr", "namespace":"grimnir", "kind":"platform", "status":data["status"],
               "checks":[{"name":"timemachine", "status":data["status"], "detail":detail}]}, fh, separators=(",", ":"))
    fh.write("\n")
PY
then
  fail "cannot generate snapshot"
fi
if ! mv "$tmp" "$snapshot"; then
  fail "cannot publish snapshot"
fi
trap - EXIT

BROKKR_HEIMDALL_PANEL="timemachine" \
BROKKR_HEIMDALL_LABEL="Time Machine Freshness" \
BROKKR_HEIMDALL_STAMP_PREFIX="timemachine-" \
BROKKR_STATE_DIR="$STATE_DIR" \
  "$HERE/../heimdall/push.sh" "$snapshot"
exit "$probe_rc"
