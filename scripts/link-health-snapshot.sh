#!/usr/bin/env bash
# Brokkr · publish this host's wired-link health to Heimdall (`link-health-<node>` panel).
#
# For fleet nodes that do not run the NAS platform report (heimdall/report.sh, which
# carries the same check as an optional row). Driven by brokkr-link-health.timer. The
# probe only reads ethtool and the kernel journal; it never changes link settings.
#
# A WARN/FAIL link observation is valid evidence and exits 0 once delivered. Missing
# delivery configuration, snapshot publication, or push failures exit non-zero so
# systemd records the loss of observability instead of a false success.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${BROKKR_STATE_DIR:-${HOME:-/var/lib/brokkr}/.local/state/brokkr}"

fail() { echo "brokkr link health: $1" >&2; exit 2; }

[ -n "${HEIMDALL_HUB_URL:-}" ] && [ -n "${HEIMDALL_FLEET_TOKEN:-}" ] || fail "Heimdall delivery is not configured"
# One Heimdall panel per node: a shared panel would let the last node to push hide
# another node's failing link. The name defaults to the short hostname.
node_raw="${BROKKR_LINK_HEALTH_NODE:-$(hostname -s 2>/dev/null || hostname 2>/dev/null)}"
node="$(printf '%s' "${node_raw%%.*}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | tr -s '-' | sed 's/^-*//; s/-*$//' | cut -c1-40)"
[ -n "$node" ] || fail "cannot derive a node name for the Heimdall panel (set BROKKR_LINK_HEALTH_NODE)"
mkdir -p "$STATE_DIR" || fail "cannot create state directory"

detail="$(BROKKR_STATE_DIR="$STATE_DIR" python3 "$HERE/network/check-link-health.py" 2>&1)"
case "$?" in 0) status=pass ;; 1) status=warn ;; *) status=fail ;; esac
[ -n "$detail" ] || fail "probe produced no result"

snapshot="$STATE_DIR/link-health.json"
tmp="$STATE_DIR/.link-health.json.$$"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT
if ! python3 - "$tmp" "$status" "$detail" <<'PY'
import json, sys
path, status, detail = sys.argv[1:]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"name": "brokkr", "namespace": "grimnir", "kind": "platform", "status": status,
               "checks": [{"name": "link-health", "status": status, "detail": detail}]}, fh, separators=(",", ":"))
    fh.write("\n")
PY
then
  fail "cannot generate snapshot"
fi
mv "$tmp" "$snapshot" || fail "cannot publish snapshot"
trap - EXIT
echo "brokkr link health: $status → $snapshot"

BROKKR_HEIMDALL_PANEL="link-health-$node" \
BROKKR_HEIMDALL_LABEL="Network Link Health ($node)" \
BROKKR_HEIMDALL_STAMP_PREFIX="link-health-" \
BROKKR_STATE_DIR="$STATE_DIR" \
  "$HERE/heimdall/push.sh" "$snapshot"
