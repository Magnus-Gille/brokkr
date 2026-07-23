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
destination="${!#}"
release="${destination#*:}"
mkdir -p "$release/scripts"
cp "$MOCK_HEIMDALL_PROBE" "$release/scripts/verify-heimdall-delivery.sh"
EOF
cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$1" >>"$MOCK_CALLS"
HOME="$MOCK_HOME" PATH="$MOCK_BIN:$PATH" bash -c "$2"
EOF
cat >"$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
safe_args="${*//$MOCK_TOKEN_SOURCE/<protected-token-source>}"
printf 'sudo %s\n' "$safe_args" >>"$MOCK_CALLS"
case "${1:-}" in
  test)
    case "${2:-}" in
      -L) exit 1 ;;
    esac
    case "$*" in
      *"$MOCK_RUNTIME_HOME"*) exit "${MOCK_RUNTIME_HOME_RC:-0}" ;;
      *"$MOCK_REGISTRY_PATH"*) exit "${MOCK_REGISTRY_RC:-0}" ;;
    esac
    "$@"
    ;;
  -u)
    case "$*" in
      *"$MOCK_RUNTIME_HOME"*) exit "${MOCK_RUNTIME_HOME_RC:-0}" ;;
      *"$MOCK_REGISTRY_PATH"*) exit "${MOCK_REGISTRY_RC:-0}" ;;
    esac
    ;;
  grep) "$@" ;;
  stat) printf '%s\n' "${MOCK_STAT_MODE:-600}" ;;
  */verify-heimdall-delivery.sh) "$@" ;;
  *) exit 0 ;;
esac
EOF
cat >"$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
exit "${MOCK_ID_RC:-0}"
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$MOCK_CALLS"
config="$(cat)"
[[ "$config" == *'Authorization: Bearer secret-sentinel'* ]] || exit 9
case "${MOCK_CURL_RESULT:-ok}" in
  ok) printf '204' ;;
  unauthorized) printf '401' ;;
  unreachable) exit 7 ;;
  *) exit 8 ;;
esac
EOF
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_CALLS"
exit 0
EOF
chmod +x "$TMP/bin/"*

export PATH="$TMP/bin:$PATH" MOCK_CALLS="$CALLS" MOCK_BIN="$TMP/bin" MOCK_HOME="$TMP/home"
export MOCK_HEIMDALL_PROBE="$HERE/../verify-heimdall-delivery.sh"
export BROKKR_SSH_TARGET=brokkr@control-node
export BROKKR_DEPLOY_TARGET="$TMP/release" BROKKR_RUNTIME_USER=operator BROKKR_RUNTIME_HOME=/home/operator BROKKR_REGISTRY_PATH=/srv/grimnir/services.json
export MOCK_RUNTIME_HOME="$BROKKR_RUNTIME_HOME" MOCK_REGISTRY_PATH="$BROKKR_REGISTRY_PATH"

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
export MOCK_TOKEN_SOURCE="$BROKKR_HEIMDALL_TOKEN_SOURCE"
export BROKKR_HEIMDALL_URL=http://heimdall.example/api/panels
run
check "valid explicit token source and URL permit enabling the sweep" '[[ "$RC" -eq 0 ]] && grep -q "sudo systemctl enable --now .*brokkr-systemd-failure-sweep.timer" "$CALLS"'
check "deployment renders units for the explicit runtime identity and target" 'grep -Fq "BROKKR_RUNTIME_USER=$BROKKR_RUNTIME_USER" "$CALLS" && grep -Fq "BROKKR_RUNTIME_HOME=$BROKKR_RUNTIME_HOME" "$CALLS" && grep -Fq "BROKKR_DEPLOY_TARGET=$BROKKR_DEPLOY_TARGET" "$CALLS" && grep -Fq "BROKKR_REGISTRY_PATH=$BROKKR_REGISTRY_PATH" "$CALLS"'
check "probe uses authenticated non-mutating readback without leaking token or source path" 'grep -q "curl .*--config -.*--request GET.*service=brokkr" "$CALLS" && ! grep -Fq "secret-sentinel" "$CALLS" && ! grep -Fq "$BROKKR_HEIMDALL_TOKEN_SOURCE" "$CALLS" && [[ "$OUT" != *"secret-sentinel"* && "$OUT" != *"$BROKKR_HEIMDALL_TOKEN_SOURCE"* ]]'

: >"$CALLS"
export MOCK_CURL_RESULT=unreachable
run
check "unreachable endpoint refuses before timer enablement without secret or path leakage" '[[ "$RC" -ne 0 && "$OUT" == *"endpoint preflight failed"* ]] && ! grep -q "systemctl enable" "$CALLS" && [[ "$OUT" != *"secret-sentinel"* && "$OUT" != *"$BROKKR_HEIMDALL_TOKEN_SOURCE"* ]] && ! grep -Fq "secret-sentinel" "$CALLS" && ! grep -Fq "$BROKKR_HEIMDALL_TOKEN_SOURCE" "$CALLS"'

: >"$CALLS"
export MOCK_CURL_RESULT=unauthorized
run
check "unauthorized endpoint refuses before timer enablement without secret or path leakage" '[[ "$RC" -ne 0 && "$OUT" == *"endpoint preflight failed"* ]] && ! grep -q "systemctl enable" "$CALLS" && [[ "$OUT" != *"secret-sentinel"* && "$OUT" != *"$BROKKR_HEIMDALL_TOKEN_SOURCE"* ]] && ! grep -Fq "secret-sentinel" "$CALLS" && ! grep -Fq "$BROKKR_HEIMDALL_TOKEN_SOURCE" "$CALLS"'
unset MOCK_CURL_RESULT

: >"$CALLS"
export MOCK_ID_RC=1
run
check "missing runtime user refuses before delivery probe or timer enablement" '[[ "$RC" -ne 0 && "$OUT" == *"runtime user or home"* ]] && ! grep -q "curl\|systemctl enable" "$CALLS"'
unset MOCK_ID_RC

: >"$CALLS"
export MOCK_REGISTRY_RC=1
run
check "registry unreadable by runtime user refuses before delivery probe or timer enablement" '[[ "$RC" -ne 0 && "$OUT" == *"registry path"* ]] && ! grep -q "curl\|systemctl enable" "$CALLS"'
unset MOCK_REGISTRY_RC

printf 'HEIMDALL_FLEET_TOKEN=unsafe"token\n' >"$TMP/heimdall-token.env"
: >"$CALLS"
run
check "adversarial token syntax refuses before curl or timer enablement" '[[ "$RC" -ne 0 && "$OUT" == *"endpoint preflight failed"* ]] && ! grep -q "curl\|systemctl enable" "$CALLS" && [[ "$OUT" != *"unsafe\"token"* ]]'

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
