#!/usr/bin/env bash
# Brokkr · take a platform-health snapshot. Runs ON the NAS Pi (under the systemd timer).
#
# Runs heimdall/report.sh, writes the heimdall.json-shaped payload to the state file, and
# logs a one-line summary to stdout (→ journald under brokkr-health.service). A legitimate
# WARN/FAIL still exits 0 after a successful push; report-generation or configured push
# failures exit non-zero so systemd records loss of observability instead of a false success.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${BROKKR_STATE_DIR:-$HOME/.local/state/brokkr}"
mkdir -p "$STATE_DIR"

if ! out="$("$HERE/heimdall/report.sh")"; then
  echo "brokkr health: report generation failed" >&2
  exit 1
fi

tmp="$STATE_DIR/.health.json.$$"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$out" > "$tmp"

if ! status="$(python3 - "$tmp" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    snapshot = json.load(fh)
status = snapshot.get("status") if isinstance(snapshot, dict) else None
if status not in ("pass", "warn", "fail"):
    raise SystemExit("invalid platform-health status")
print(status)
PY
)"; then
  echo "brokkr health: generated snapshot is invalid JSON" >&2
  exit 1
fi

mv "$tmp" "$STATE_DIR/health.json"
trap - EXIT
echo "brokkr health: $status → $STATE_DIR/health.json"

# A fully unconfigured push is still a documented no-op. A configured push failure is
# operationally meaningful and must make the oneshot red/fail in journald/systemd.
if ! "$HERE/heimdall/push.sh" "$STATE_DIR/health.json"; then
  echo "brokkr health: Heimdall push failed; snapshot retained locally" >&2
  exit 1
fi
