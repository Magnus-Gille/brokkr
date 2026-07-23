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
  stat) printf '%s\n' "${MOCK_STAT_MODE:-600}" ;;
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
export BROKKR_SSH_TARGET=brokkr@control-node
export BROKKR_DEPLOY_TARGET=/srv/brokkr BROKKR_RUNTIME_USER=operator BROKKR_RUNTIME_HOME=/home/operator BROKKR_REGISTRY_PATH=/srv/grimnir/services.json

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# shellcheck disable=SC2034 # checks consume OUT and RC through eval.
run() { OUT="$(bash "$DEPLOY" 2>&1)"; RC=$?; }

echo "deploy-control-node.test.sh"

unset BROKKR_HEIMDALL_TOKEN_SOURCE BROKKR_HEIMDALL_URL
run
check "missing explicit Heimdall delivery inputs fail before enabling the sweep" '[[ "$RC" -ne 0 && "$OUT" == *"HEIMDALL"* ]] && ! grep -q "systemctl enable" "$CALLS"'

cat >"$TMP/heimdall-token.env" <<'EOF'
HEIMDALL_FLEET_TOKEN=secret-sentinel
EOF
: >"$CALLS"
export BROKKR_HEIMDALL_TOKEN_SOURCE="$TMP/heimdall-token.env"
export BROKKR_HEIMDALL_URL=http://heimdall.example/api/panels
run
check "valid explicit token source and URL permit enabling the sweep" '[[ "$RC" -eq 0 ]] && grep -q "sudo systemctl enable --now .*brokkr-systemd-failure-sweep.timer" "$CALLS"'
check "deployment renders units for the explicit runtime identity and target" 'grep -Fq "BROKKR_RUNTIME_USER=operator" "$CALLS" && grep -Fq "BROKKR_RUNTIME_HOME=/home/operator" "$CALLS" && grep -Fq "BROKKR_DEPLOY_TARGET=/srv/brokkr" "$CALLS" && grep -Fq "BROKKR_REGISTRY_PATH=/srv/grimnir/services.json" "$CALLS"'
check "token value is never printed or sent as an argument" '! grep -Fq "secret-sentinel" "$CALLS" && [[ "$OUT" != *"secret-sentinel"* ]]'

printf 'HEIMDALL_FLEET_TOKEN=one\nHEIMDALL_FLEET_TOKEN=two\n' >"$TMP/heimdall-token.env"
: >"$CALLS"
run
check "duplicate token assignment refuses before unit enablement" '[[ "$RC" -ne 0 && "$OUT" == *"exactly one"* ]] && ! grep -q "systemctl enable" "$CALLS"'

printf 'HEIMDALL_FLEET_TOKEN=secret-sentinel\n' >"$TMP/heimdall-token.env"
: >"$CALLS"
export MOCK_STAT_MODE=644
run
check "unsafe token-source mode refuses before unit enablement" '[[ "$RC" -ne 0 && "$OUT" == *"0400 or 0600"* ]] && ! grep -q "systemctl enable" "$CALLS"'
unset MOCK_STAT_MODE

: >"$CALLS"
export BROKKR_HEIMDALL_URL=not-a-url
run
check "invalid explicit Heimdall URL refuses before unit enablement" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_HEIMDALL_URL"* ]] && ! grep -q "systemctl enable" "$CALLS"'
export BROKKR_HEIMDALL_URL=http://heimdall.example/api/panels

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
