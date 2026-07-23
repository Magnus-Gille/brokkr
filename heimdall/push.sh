#!/usr/bin/env bash
# Brokkr · push platform health to Heimdall (POST /api/panels), following mimir's pattern.
# Reads a snapshot JSON (default $STATE/health.json) and upserts a 'hw-health' status panel
# for service "brokkr". Callers may select another validated Brokkr panel/label and separate
# stamp prefix (the systemd failure monitor does this). A completely unconfigured push remains an explicit no-op. Once
# configured, malformed input, partial configuration, HTTP errors, and redirects fail
# loudly and are timestamped locally so a reporting outage cannot look successful.
#
# Env: HEIMDALL_HUB_URL (e.g. http://192.0.2.30:3033/api/panels), HEIMDALL_FLEET_TOKEN.
# These come from the systemd EnvironmentFile (/home/brokkr/.config/brokkr/env), provisioned
# locally at deploy time and never stored in this repo.
set -euo pipefail

STATE_DIR="${BROKKR_STATE_DIR:-$HOME/.local/state/brokkr}"
SNAP="${1:-$STATE_DIR/health.json}"
PANEL="${BROKKR_HEIMDALL_PANEL:-hw-health}"
LABEL="${BROKKR_HEIMDALL_LABEL:-Hardware Health}"
STAMP_PREFIX="${BROKKR_HEIMDALL_STAMP_PREFIX:-}"

if [[ ! "$PANEL" =~ ^[a-z0-9-]+$ ]] || [ -z "$LABEL" ] || [[ ! "$STAMP_PREFIX" =~ ^[a-z0-9-]*$ ]]; then
  echo "brokkr push: invalid panel, label, or stamp prefix" >&2
  exit 2
fi

record_stamp() {
  local name="$1" tmp
  tmp="$STATE_DIR/.${STAMP_PREFIX}${name}.$$"
  if ! date +%s > "$tmp"; then
    rm -f "$tmp"
    echo "brokkr push: could not record $name" >&2
    return 1
  fi
  if ! mv "$tmp" "$STATE_DIR/${STAMP_PREFIX}${name}"; then
    rm -f "$tmp"
    echo "brokkr push: could not publish $name" >&2
    return 1
  fi
}

if [ -z "${HEIMDALL_HUB_URL:-}" ] && [ -z "${HEIMDALL_FLEET_TOKEN:-}" ]; then
  echo "brokkr push: HEIMDALL_HUB_URL/FLEET_TOKEN unset — skipping"; exit 0
fi
mkdir -p "$STATE_DIR"
if [ -z "${HEIMDALL_HUB_URL:-}" ] || [ -z "${HEIMDALL_FLEET_TOKEN:-}" ]; then
  echo "brokkr push: incomplete Heimdall configuration" >&2
  record_stamp last-push-failure
  exit 2
fi
if [ ! -f "$SNAP" ]; then
  echo "brokkr push: configured but no snapshot exists at $SNAP" >&2
  record_stamp last-push-failure
  exit 2
fi

if python3 - "$SNAP" <<'PY'
import json, os, sys, urllib.request
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        snap = json.load(fh)
    if not isinstance(snap, dict):
        raise ValueError("snapshot must be a JSON object")
    checks = snap.get("checks", [])
    state = snap.get("status")
    if state not in ("pass", "warn", "fail"):
        raise ValueError("snapshot status must be pass, warn, or fail")
    if not isinstance(checks, list) or any(not isinstance(c, dict) for c in checks):
        raise ValueError("snapshot checks must be an array of objects")
    if any(c.get("status") not in ("pass", "warn", "fail") for c in checks):
        raise ValueError("check status must be pass, warn, or fail")
except (OSError, TypeError, ValueError) as error:
    print(f"brokkr push failed: {type(error).__name__}", file=sys.stderr)
    sys.exit(1)
alarms = [c for c in checks if c.get("status") in ("warn", "fail")]
if alarms:
    msg = "; ".join(f'{c.get("name", "unnamed")}: {c.get("detail", "")}' for c in alarms)
else:
    msg = f'{len(checks)} checks, all nominal'
msg = msg[:240]
body = json.dumps({
    "service": "brokkr", "panel": os.environ.get("BROKKR_HEIMDALL_PANEL", "hw-health"), "kind": "status",
    "label": os.environ.get("BROKKR_HEIMDALL_LABEL", "Hardware Health"), "state": state, "message": msg,
}).encode()
req = urllib.request.Request(
    os.environ["HEIMDALL_HUB_URL"], data=body, method="POST",
    headers={"Content-Type": "application/json",
             "Authorization": "Bearer " + os.environ["HEIMDALL_FLEET_TOKEN"]})

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

try:
    with urllib.request.build_opener(NoRedirect).open(req, timeout=10) as response:
        print(f"brokkr push: {response.status} (state={state})")
except Exception as e:
    print(f"brokkr push failed: {type(e).__name__}", file=sys.stderr)
    sys.exit(1)
PY
then
  record_stamp last-push-success
  rm -f "$STATE_DIR/${STAMP_PREFIX}last-push-failure"
  exit 0
else
  rc=$?
  record_stamp last-push-failure
  exit "$rc"
fi
