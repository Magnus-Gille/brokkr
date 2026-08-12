#!/usr/bin/env bash
# Regression: an unavailable Time Machine source is warning evidence, not a
# failed one-shot run, when the warning is delivered successfully.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../timemachine/telemetry.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/python" "$TMP/state"

cat > "$TMP/probe.env" <<EOF
BROKKR_TM_BANDS_DIR=$TMP/missing-source
EOF
chmod 600 "$TMP/probe.env"
cat > "$TMP/python/sitecustomize.py" <<'PY'
import json
import os
import urllib.request


class Response:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


class Opener:
    def open(self, request, timeout):
        with open(os.environ["REQUEST_FILE"], "w", encoding="utf-8") as fh:
            json.dump({"body": json.loads(request.data.decode())}, fh)
        return Response()


urllib.request.build_opener = lambda *_handlers: Opener()
PY

OUT="$(PYTHONPATH="$TMP/python" BROKKR_TM_PROBE_SOURCE="$TMP/probe.env" \
  BROKKR_TM_STATE_DIR="$TMP/state" HEIMDALL_HUB_URL=http://example.invalid/api/panels \
  HEIMDALL_FLEET_TOKEN=test-token REQUEST_FILE="$TMP/request.json" \
  bash "$SCRIPT" 2>&1)"
RC=$?

python3 - "$TMP/state/timemachine-health.json" "$TMP/request.json" <<'PY'
import json
import sys

snapshot = json.load(open(sys.argv[1], encoding="utf-8"))
request = json.load(open(sys.argv[2], encoding="utf-8"))
assert snapshot["status"] == "warn"
assert snapshot["checks"][0]["status"] == "warn"
assert "source_unavailable" in snapshot["checks"][0]["detail"]
assert request["body"]["state"] == "warn"
PY

[[ "$RC" -eq 0 ]] || { printf '%s\n' "$OUT" >&2; exit 1; }
printf 'timemachine-telemetry-exit.test.sh: PASS\n'
