#!/usr/bin/env bash
# Hermetic deployment gates for the control-node failure monitor (brokkr#6).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SOURCE="$(cd "$HERE/../.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
SOURCE="$TMP/bound-source"
BASE_SHA="$(git -C "$REPO_SOURCE" rev-parse HEAD)"
git clone -q "$REPO_SOURCE" "$SOURCE"
git -C "$SOURCE" checkout --detach -q "$BASE_SHA"
cp "$REPO_SOURCE/scripts/deploy-control-node.sh" "$SOURCE/scripts/deploy-control-node.sh"
cp "$REPO_SOURCE/scripts/lib/deploy-source.sh" "$SOURCE/scripts/lib/deploy-source.sh"
git -C "$SOURCE" config user.name test
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" add scripts/deploy-control-node.sh scripts/lib/deploy-source.sh
git -C "$SOURCE" commit -qm 'fixture deploy binding'
DEPLOY="$SOURCE/scripts/deploy-control-node.sh"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
CALLS="$TMP/calls"
: >"$CALLS"

cat >"$TMP/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >>"$MOCK_CALLS"
source="${@: -2:1}"
source="${source%/}"
destination="${!#}"
release="${destination#*:}"
if [[ ! -d "$release" ]]; then
  echo 'mock rsync: release target was not prepared' >&2
  exit 11
fi
chmod 755 "$release"
cp -R "$source/." "$release"
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
      *"$MOCK_RELEASE_TARGET"*) exit "${MOCK_RELEASE_OWNER_RC:-0}" ;;
      *"$MOCK_RUNTIME_HOME"*) exit "${MOCK_RUNTIME_HOME_RC:-0}" ;;
      *"$MOCK_REGISTRY_PATH"*) exit "${MOCK_REGISTRY_RC:-0}" ;;
    esac
    ;;
  install)
    if [[ "${2:-}" == -d && "$*" == *"$MOCK_RELEASE_TARGET"* ]]; then
      [[ "${MOCK_RELEASE_PREP_RC:-0}" -eq 0 ]] || exit "$MOCK_RELEASE_PREP_RC"
      mkdir -p "${!#}"
    fi
    ;;
  grep) "$@" ;;
  stat)
    if [[ "${!#}" == "$MOCK_RELEASE_TARGET" ]]; then stat -c '%a' "${!#}" 2>/dev/null || stat -f '%Lp' "${!#}"; else printf '%s\n' "${MOCK_STAT_MODE:-600}"; fi
    ;;
  chmod)
    if [[ "$3" == "$MOCK_RELEASE_TARGET" ]]; then chmod "$2" "$3"; fi
    ;;
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
export BROKKR_SSH_TARGET=brokkr@control-node
export BROKKR_DEPLOY_TARGET="$TMP/release" BROKKR_RUNTIME_USER=operator BROKKR_RUNTIME_HOME=/home/operator BROKKR_REGISTRY_PATH=/srv/grimnir/services.json
export MOCK_RUNTIME_HOME="$BROKKR_RUNTIME_HOME" MOCK_REGISTRY_PATH="$BROKKR_REGISTRY_PATH" MOCK_RELEASE_TARGET="$BROKKR_DEPLOY_TARGET"
export BROKKR_EXPECTED_SOURCE="$SOURCE"
BROKKR_EXPECTED_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
export BROKKR_EXPECTED_COMMIT
mkdir -p "$TMP/payload-tmp"
export TMPDIR="$TMP/payload-tmp"
printf 'ignored-secret\n' >"$SOURCE/.env"
printf 'ignored-status\n' >"$SOURCE/STATUS.md"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
# shellcheck disable=SC2034 # checks consume OUT and RC through eval.
run() { OUT="$(cd "$SOURCE" && bash "$DEPLOY" 2>&1)"; RC=$?; }

echo "deploy-control-node.test.sh"

unset BROKKR_EXPECTED_COMMIT
run
check "missing source revision refuses before SSH or rsync" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_EXPECTED_SOURCE and BROKKR_EXPECTED_COMMIT"* ]] && [[ ! -s "$CALLS" ]]'
BROKKR_EXPECTED_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
export BROKKR_EXPECTED_COMMIT

: >"$CALLS"
mkdir -p "$TMP/wrong-source"
export BROKKR_EXPECTED_SOURCE="$TMP/wrong-source"
run
check "wrong source path refuses before SSH or rsync" '[[ "$RC" -ne 0 && "$OUT" == *"different directory"* ]] && [[ ! -s "$CALLS" ]]'
export BROKKR_EXPECTED_SOURCE="$SOURCE"

: >"$CALLS"
export BROKKR_EXPECTED_COMMIT=0000000000000000000000000000000000000000
run
check "stale clean revision refuses before SSH or rsync" '[[ "$RC" -ne 0 && "$OUT" == *"revision does not match"* ]] && [[ ! -s "$CALLS" ]]'
BROKKR_EXPECTED_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
export BROKKR_EXPECTED_COMMIT

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
check "archive payload excludes ignored live files" '[[ ! -e "$BROKKR_DEPLOY_TARGET/.env" && ! -e "$BROKKR_DEPLOY_TARGET/STATUS.md" ]]'
check "archive payload preserves executable bits without making data files executable" '[[ -x "$BROKKR_DEPLOY_TARGET/scripts/deploy-control-node.sh" && ! -x "$BROKKR_DEPLOY_TARGET/README.md" ]]'
check "release synchronization avoids propagating permissions while preserving executability" 'grep -Fq -- "--no-perms --executability" "$CALLS"'
check "archive payload parent is cleaned after deploy" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name "brokkr-deploy.*" -print)" ]]'
check "remote release root keeps intentional mode" '[[ "$(mode "$BROKKR_DEPLOY_TARGET")" == 750 ]]'
check "first install prepares the nested release target before rsync" '[[ -d "$BROKKR_DEPLOY_TARGET" ]] && [[ "$(grep -n -F "sudo install -d" "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n -F "rsync " "$CALLS" | head -1 | cut -d: -f1)" ]]'
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

: >"$CALLS"
export BROKKR_HEIMDALL_URL='http://heimdall.example/api/"panels'
run
check "quote-bearing Heimdall URL refuses before ssh or timer enablement" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_HEIMDALL_URL"* ]] && ! grep -q "ssh\|systemctl enable" "$CALLS"'

: >"$CALLS"
export BROKKR_HEIMDALL_URL='http://heimdall.example/api/$panels'
run
check "dollar-bearing Heimdall URL refuses before ssh or timer enablement" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_HEIMDALL_URL"* ]] && ! grep -q "ssh\|systemctl enable" "$CALLS"'

: >"$CALLS"
export BROKKR_HEIMDALL_URL='http://heimdall.example/api/`panels`'
run
check "backtick-bearing Heimdall URL refuses before ssh or timer enablement" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_HEIMDALL_URL"* ]] && ! grep -q "ssh\|systemctl enable" "$CALLS"'

: >"$CALLS"
export BROKKR_HEIMDALL_URL=http://heimdall.example/api/panels
export BROKKR_DEPLOY_TARGET="$TMP/release/../escape"
run
check "traversal deploy target refuses before ssh or timer enablement" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_DEPLOY_TARGET"* ]] && ! grep -q "ssh\|systemctl enable" "$CALLS"'
export BROKKR_DEPLOY_TARGET="$TMP/release"
export MOCK_RELEASE_TARGET="$BROKKR_DEPLOY_TARGET"

export BROKKR_HEIMDALL_URL=http://heimdall.example/api/panels

: >"$CALLS"
export MOCK_RELEASE_OWNER_RC=1
run
check "unsafe existing release target refuses before rsync or timer enablement" '[[ "$RC" -ne 0 && "$OUT" == *"existing release target"* ]] && ! grep -q "rsync\|systemctl enable" "$CALLS"'
unset MOCK_RELEASE_OWNER_RC

: >"$CALLS"
export BROKKR_DEPLOY_TARGET="$TMP/failed-first-install/nested/release"
export MOCK_RELEASE_TARGET="$BROKKR_DEPLOY_TARGET" MOCK_RELEASE_PREP_RC=1
run
check "release-target preparation failure refuses before rsync or timer enablement" '[[ "$RC" -ne 0 && "$OUT" == *"could not prepare"* ]] && ! grep -q "rsync\|systemctl enable" "$CALLS"'
unset MOCK_RELEASE_PREP_RC
export BROKKR_DEPLOY_TARGET="$TMP/release"
export MOCK_RELEASE_TARGET="$BROKKR_DEPLOY_TARGET"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
