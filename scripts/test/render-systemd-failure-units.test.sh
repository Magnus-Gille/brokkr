#!/usr/bin/env bash
# Hermetic renderer regression for runtime-configurable systemd monitor units (brokkr#14).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RENDER="$ROOT/scripts/render-systemd-failure-units.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT_DIR="$TMP/units"
mkdir -p "$OUT_DIR"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# GNU stat uses -c while BSD stat uses -f. Probe the GNU form first rather
# than assuming the host that executes this hermetic test.
file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}
# shellcheck disable=SC2034 # assertions consume OUT and RC through eval.
run() { OUT="$(BROKKR_RUNTIME_USER=operator BROKKR_RUNTIME_HOME=/home/operator BROKKR_DEPLOY_TARGET=/srv/brokkr BROKKR_REGISTRY_PATH=/srv/grimnir/services.json "$RENDER" "$OUT_DIR" 2>&1)"; RC=$?; }

echo "render-systemd-failure-units.test.sh"

run
check "renderer accepts explicit runtime identity and target" '[[ "$RC" -eq 0 ]]'
check "renderer rewrites every control-node service user" 'grep -Fqx "User=operator" "$OUT_DIR/brokkr-maintenance-os.service" && grep -Fqx "User=operator" "$OUT_DIR/brokkr-maintenance-deps.service" && grep -Fqx "User=operator" "$OUT_DIR/brokkr-systemd-failure@.service" && grep -Fqx "User=operator" "$OUT_DIR/brokkr-systemd-failure-sweep.service"'
check "renderer rewrites monitor runtime home and independent deploy target" 'grep -Fqx "WorkingDirectory=/srv/brokkr" "$OUT_DIR/brokkr-systemd-failure-sweep.service" && grep -Fqx "EnvironmentFile=-/home/operator/.config/brokkr/env" "$OUT_DIR/brokkr-systemd-failure-sweep.service" && grep -Fqx "ExecStart=/srv/brokkr/scripts/systemd-failure-monitor.sh --sweep" "$OUT_DIR/brokkr-systemd-failure-sweep.service"'
check "renderer rewrites the control-node registry path" 'grep -Fqx "Environment=REGISTRY_PATH=/srv/grimnir/services.json" "$OUT_DIR/brokkr-maintenance-os.service" && grep -Fqx "Environment=REGISTRY_PATH=/srv/grimnir/services.json" "$OUT_DIR/brokkr-maintenance-deps.service"'
check "renderer preserves OnFailure wiring and mode" 'grep -Fqx "OnFailure=brokkr-systemd-failure@%n.service" "$OUT_DIR/brokkr-maintenance-os.service" && [[ "$(file_mode "$OUT_DIR/brokkr-systemd-failure-sweep.service")" == 644 ]]'

# shellcheck disable=SC2034 # assertion consumes OUT through eval.
OUT="$(BROKKR_RUNTIME_USER='bad/user' "$RENDER" "$OUT_DIR" 2>&1)"
# shellcheck disable=SC2034 # assertion consumes RC through eval.
RC=$?
check "unsafe runtime user is rejected" '[[ "$RC" -eq 64 && "$OUT" == *"invalid BROKKR_RUNTIME_USER"* ]]'
# shellcheck disable=SC2034 # assertion consumes OUT through eval.
OUT="$(BROKKR_DEPLOY_TARGET='relative/path' "$RENDER" "$OUT_DIR" 2>&1)"
# shellcheck disable=SC2034 # assertion consumes RC through eval.
RC=$?
check "relative deploy target is rejected" '[[ "$RC" -eq 64 && "$OUT" == *"invalid BROKKR_DEPLOY_TARGET"* ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
