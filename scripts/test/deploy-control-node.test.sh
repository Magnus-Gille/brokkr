#!/usr/bin/env bash
# Hermetic deployment gates for the control-node failure monitor (brokkr#6).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$HERE/../deploy-control-node.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
CALLS="$TMP/calls"
: >"$CALLS"

cat >"$TMP/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >>"$MOCK_CALLS"
EOF
cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$1" >>"$MOCK_CALLS"
HOME="$MOCK_HOME" PATH="$MOCK_BIN:$PATH" bash -c "$2"
EOF
cat >"$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$MOCK_CALLS"
case "${1:-}" in
  test|grep) "$@" ;;
  *) exit 0 ;;
esac
EOF
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_CALLS"
exit 0
EOF
chmod +x "$TMP/bin/"*

export PATH="$TMP/bin:$PATH" MOCK_CALLS="$CALLS" MOCK_BIN="$TMP/bin" MOCK_HOME="$TMP/home"
export BROKKR_SSH_TARGET=brokkr@control-node BROKKR_REMOTE_DIR=/opt/brokkr

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# shellcheck disable=SC2034 # checks consume OUT and RC through eval.
run() { OUT="$(bash "$DEPLOY" 2>&1)"; RC=$?; }

echo "deploy-control-node.test.sh"

export BROKKR_HEIMDALL_SOURCE_ENV="$TMP/missing-source.env"
run
check "missing Heimdall source fails before enabling the sweep" '[[ "$RC" -ne 0 && "$OUT" == *"Heimdall"* ]] && ! grep -q "systemctl enable" "$CALLS"'

cat >"$TMP/heimdall-source.env" <<'EOF'
HEIMDALL_HUB_URL=https://heimdall.example/api/panels
HEIMDALL_FLEET_TOKEN=test-token
EOF
: >"$CALLS"
export BROKKR_HEIMDALL_SOURCE_ENV="$TMP/heimdall-source.env"
run
check "valid Heimdall source permits enabling the sweep" '[[ "$RC" -eq 0 ]] && grep -q "sudo systemctl enable --now .*brokkr-systemd-failure-sweep.timer" "$CALLS"'
check "deployment derives only the expected Heimdall assignments" 'grep -q "HEIMDALL_(HUB_URL|FLEET_TOKEN)" "$DEPLOY"'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
