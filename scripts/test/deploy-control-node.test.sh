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
cp "$REPO_SOURCE/scripts/verify-heimdall-delivery.sh" "$SOURCE/scripts/verify-heimdall-delivery.sh"
cp "$REPO_SOURCE/scripts/prepare-heimdall-runtime-env.sh" "$SOURCE/scripts/prepare-heimdall-runtime-env.sh"
git -C "$SOURCE" config user.name test
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" add scripts/deploy-control-node.sh scripts/lib/deploy-source.sh scripts/verify-heimdall-delivery.sh scripts/prepare-heimdall-runtime-env.sh
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
    case "$*" in
      *"/.config/brokkr/env"*) "$@"; exit $? ;;
    esac
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
    if [[ "${3:-}" == -- ]]; then
      shift 3
      MOCK_AS_USER=1 "$@"
      exit $?
    fi
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
    if [[ "${!#}" == "$MOCK_RELEASE_TARGET" ]]; then
      stat -c '%a' "${!#}" 2>/dev/null || stat -f '%Lp' "${!#}"
    elif [[ "${!#}" == */.config/brokkr/env ]]; then
      printf '%s\n' "${MOCK_ENV_MODE:-600}"
    else
      printf '%s\n' "${MOCK_STAT_MODE:-600}"
    fi
    ;;
  chmod)
    if [[ "$3" == "$MOCK_RELEASE_TARGET" ]]; then chmod "$2" "$3"; fi
    ;;
  */verify-heimdall-delivery.sh|*/prepare-heimdall-runtime-env.sh) "$@" ;;
  *) exit 0 ;;
esac
EOF
cat >"$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
exit "${MOCK_ID_RC:-0}"
EOF
# Record who (root vs the runtime user, via the sudo mock) runs each
# filesystem-mutating command, then run the real one. Root operating on a path
# in the runtime user's writable directory would be a symlink-swap escalation.
cat >"$TMP/bin/fswrap" <<'EOF'
#!/usr/bin/env bash
who=root
[[ -z "${MOCK_AS_USER:-}" ]] || who=user
name="$(basename "$0")"
printf '%s %s %s\n' "$who" "$name" "$*" >>"$MOCK_FSLOG"
PATH=/usr/bin:/bin exec "$name" "$@"
EOF
for fscmd in chown chmod mv; do cp "$TMP/bin/fswrap" "$TMP/bin/$fscmd"; done
# The preflight staging directory is requested under a production parent (/run
# or /tmp). Log the request, but create it beneath the private fixture root so
# an unprivileged runner never touches the real /run.
cat >"$TMP/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
who=root
[[ -z "${MOCK_AS_USER:-}" ]] || who=user
printf '%s mktemp %s\n' "$who" "$*" >>"$MOCK_FSLOG"
args=()
for a in "$@"; do
  case "$a" in
    /run/brokkr-heimdall-stage.*|/tmp/brokkr-heimdall-stage.*)
      mkdir -p "$MOCK_STAGE_ROOT${a%/*}"
      a="$MOCK_STAGE_ROOT$a"
      ;;
  esac
  args+=("$a")
done
PATH=/usr/bin:/bin exec mktemp "${args[@]}"
EOF
# Deterministic metadata for the candidate staging parents. MOCK_STAT_RUN and
# MOCK_STAT_TMP hold "uid mode type" (or "fail"); MOCK_STAT_STYLE selects the
# GNU (Linux, the CI path) or BSD (macOS) stat dialect the helper must speak.
# Anything else goes to the real stat.
cat >"$TMP/bin/stat" <<'EOF'
#!/usr/bin/env bash
cand="${!#}"
case "$cand" in
  /run|/tmp)
    if [[ "$cand" == /run ]]; then spec="${MOCK_STAT_RUN-0 755 directory}"; else spec="${MOCK_STAT_TMP-0 1777 directory}"; fi
    [[ "$spec" != fail ]] || exit 1
    read -r uid mode type <<<"$spec"
    case "${MOCK_STAT_STYLE:-gnu}" in
      gnu)
        [[ "$1 $2 $3" == "-L -c %u %a %F" ]] || exit 1
        printf '%s %s %s\n' "$uid" "$mode" "$type"
        ;;
      bsd)
        [[ "$1 $2 $3" == "-L -f %u %Mp%Lp %HT" ]] || exit 1
        [[ "$type" != directory ]] || type=Directory
        printf '%s %04d %s\n' "$uid" "$mode" "$type"
        ;;
    esac
    exit 0
    ;;
esac
PATH=/usr/bin:/bin exec stat "$@"
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$MOCK_CALLS"
config="$(cat)"
[[ "$config" == *"Authorization: Bearer ${MOCK_CURL_EXPECT:-secret-sentinel}"* ]] || exit 9
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

FSLOG="$TMP/fslog"
: >"$FSLOG"
export MOCK_STAGE_ROOT="$TMP/stage-root"
export PATH="$TMP/bin:$PATH" MOCK_CALLS="$CALLS" MOCK_FSLOG="$FSLOG" MOCK_BIN="$TMP/bin" MOCK_HOME="$TMP/home"
export BROKKR_SSH_TARGET=brokkr@control-node
export BROKKR_DEPLOY_TARGET="$TMP/release" BROKKR_RUNTIME_USER=operator BROKKR_RUNTIME_HOME="$TMP/runtime-home" BROKKR_REGISTRY_PATH=/srv/grimnir/services.json
export MOCK_RUNTIME_HOME="$BROKKR_RUNTIME_HOME" MOCK_REGISTRY_PATH="$BROKKR_REGISTRY_PATH" MOCK_RELEASE_TARGET="$BROKKR_DEPLOY_TARGET"
export BROKKR_EXPECTED_SOURCE="$SOURCE"
BROKKR_EXPECTED_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
export BROKKR_EXPECTED_COMMIT
mkdir -p "$TMP/payload-tmp" "$BROKKR_RUNTIME_HOME"
export TMPDIR="$TMP/payload-tmp"
printf 'ignored-secret\n' >"$SOURCE/.env"
printf 'ignored-status\n' >"$SOURCE/STATUS.md"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
# shellcheck disable=SC2034 # checks consume OUT and RC through eval.
run() { : >"$FSLOG"; OUT="$(cd "$SOURCE" && bash "$DEPLOY" 2>&1)"; RC=$?; }

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
ENV_FILE="$BROKKR_RUNTIME_HOME/.config/brokkr/env"
check "first deploy provisions the token from the protected source and says so" '[[ "$OUT" == *"Heimdall token provisioned from protected source"* ]] && [[ "$(wc -l <"$ENV_FILE" | tr -d " ")" == 2 ]] && grep -Fxq "HEIMDALL_HUB_URL=$BROKKR_HEIMDALL_URL" "$ENV_FILE" && grep -Fxq "HEIMDALL_FLEET_TOKEN=secret-sentinel" "$ENV_FILE" && [[ "$(mode "$ENV_FILE")" == 600 ]]'
check "archive payload excludes ignored live files" '[[ ! -e "$BROKKR_DEPLOY_TARGET/.env" && ! -e "$BROKKR_DEPLOY_TARGET/STATUS.md" ]]'
check "archive payload preserves executable bits without making data files executable" '[[ -x "$BROKKR_DEPLOY_TARGET/scripts/deploy-control-node.sh" && ! -x "$BROKKR_DEPLOY_TARGET/README.md" ]]'
check "release synchronization avoids propagating permissions while preserving executability" 'grep -Fq -- "--no-perms --executability" "$CALLS"'
check "archive payload parent is cleaned after deploy" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name "brokkr-deploy.*" -print)" ]]'
check "remote release root keeps intentional mode" '[[ "$(mode "$BROKKR_DEPLOY_TARGET")" == 750 ]]'
check "first install prepares the nested release target before rsync" '[[ -d "$BROKKR_DEPLOY_TARGET" ]] && [[ "$(grep -n -F "sudo install -d" "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n -F "rsync " "$CALLS" | head -1 | cut -d: -f1)" ]]'
check "deployment renders units for the explicit runtime identity and target" 'grep -Fq "BROKKR_RUNTIME_USER=$BROKKR_RUNTIME_USER" "$CALLS" && grep -Fq "BROKKR_RUNTIME_HOME=$BROKKR_RUNTIME_HOME" "$CALLS" && grep -Fq "BROKKR_DEPLOY_TARGET=$BROKKR_DEPLOY_TARGET" "$CALLS" && grep -Fq "BROKKR_REGISTRY_PATH=$BROKKR_REGISTRY_PATH" "$CALLS"'
check "probe uses authenticated non-mutating readback without leaking token or source path" 'grep -q "curl .*--config -.*--request GET.*service=brokkr" "$CALLS" && ! grep -Fq "secret-sentinel" "$CALLS" && ! grep -Fq "$BROKKR_HEIMDALL_TOKEN_SOURCE" "$CALLS" && [[ "$OUT" != *"secret-sentinel"* && "$OUT" != *"$BROKKR_HEIMDALL_TOKEN_SOURCE"* ]]'
check "probe suppresses transport diagnostics that could reveal the endpoint" '! grep -Fq -- "--show-error" "$CALLS"'

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
rm -f "$ENV_FILE"  # a source token is only used when the runtime env has none
: >"$CALLS"
run
check "adversarial token syntax refuses before curl or timer enablement" '[[ "$RC" -ne 0 && "$OUT" == *"unsupported fleet token value"* ]] && ! grep -q "curl\|systemctl enable" "$CALLS" && [[ "$OUT" != *"unsafe\"token"* ]]'

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

# --- Heimdall producer-token preservation (heimdall#101) ---------------------
# The runtime env may hold this node's own producer token under the same key as
# the legacy shared token in the source; a redeploy must not put the legacy one back.
write_env() { printf 'HEIMDALL_HUB_URL=http://stale.example/api/panels\nHEIMDALL_FLEET_TOKEN=%s\n' "$1" >"$ENV_FILE"; chmod 600 "$ENV_FILE"; }
no_leak() { [[ "$OUT" != *producer-sentinel* && "$OUT" != *legacy-sentinel* ]] && ! grep -Eq 'producer-sentinel|legacy-sentinel' "$CALLS" && ! grep -Fq "$BROKKR_HEIMDALL_TOKEN_SOURCE" "$CALLS" && [[ "$OUT" != *"$BROKKR_HEIMDALL_TOKEN_SOURCE"* ]]; }
no_stage_dirs() { [[ -z "$(find "$MOCK_STAGE_ROOT" -name 'brokkr-heimdall-stage.*' -print 2>/dev/null)" ]]; }
leftover_temp() { find "$(dirname "$ENV_FILE")" -name '.env.*' | grep -q .; }
printf 'HEIMDALL_FLEET_TOKEN=legacy-sentinel\n' >"$TMP/heimdall-token.env"
export BROKKR_HEIMDALL_URL=http://heimdall.example/api/panels

write_env producer-sentinel
: >"$CALLS"
export MOCK_CURL_EXPECT=producer-sentinel
run
check "existing producer token is preserved by default while the URL is refreshed" '[[ "$RC" -eq 0 && "$OUT" == *"Heimdall token preserved from existing runtime env"* ]] && grep -Fxq "HEIMDALL_FLEET_TOKEN=producer-sentinel" "$ENV_FILE" && ! grep -Fq legacy-sentinel "$ENV_FILE" && grep -Fxq "HEIMDALL_HUB_URL=$BROKKR_HEIMDALL_URL" "$ENV_FILE" && [[ "$(wc -l <"$ENV_FILE" | tr -d " ")" == 2 ]] && [[ "$(mode "$ENV_FILE")" == 600 ]] && ! leftover_temp'
check "preserved-token deploy prints no token value or source path and keeps them off argv" 'no_leak'
check "preflight authenticates with the token actually written (not the legacy source)" 'grep -q "curl .*service=brokkr" "$CALLS" && grep -q "systemctl enable" "$CALLS"'
check "root never chowns, chmods, renames or creates temp files inside the runtime user's config directory" '! grep -E "^root (chown|chmod|mv|mktemp) .*/\.config/brokkr" "$FSLOG"'
check "no root-run chown is issued at all (ownership comes from the runtime user writing the file)" '! grep -q "^root chown" "$FSLOG"'
check "root-created preflight staging lives outside the runtime user directory" 'grep -q "^root mktemp -d .*brokkr-heimdall-stage" "$FSLOG" && ! grep -E "^root mktemp .*/runtime-home" "$FSLOG" && no_stage_dirs'
check "the temp file and the final rename are performed as the runtime user in its config directory" 'grep -Eq "^user mktemp .*/\.config/brokkr/\.env\." "$FSLOG" && grep -Eq "^user mv -f .*/\.config/brokkr/\.env\.[^ ]+ .*/\.config/brokkr/env$" "$FSLOG" && grep -Fq "sudo -u $BROKKR_RUNTIME_USER -- sh -c" "$CALLS"'

write_env producer-sentinel
cp "$ENV_FILE" "$TMP/env.before"
: >"$CALLS"
export MOCK_CURL_EXPECT=legacy-sentinel
run
check "preflight rejecting the preserved token refuses before touching the env or enabling timers" '[[ "$RC" -ne 0 && "$OUT" == *"endpoint preflight failed"* ]] && cmp -s "$ENV_FILE" "$TMP/env.before" && ! leftover_temp && ! grep -q "systemctl enable" "$CALLS"'
check "failed preflight removes its staging directory" 'grep -q "^root mktemp -d .*brokkr-heimdall-stage" "$FSLOG" && no_stage_dirs'
check "failed preflight leaks no token value" 'no_leak'

rm -f "$ENV_FILE"
: >"$CALLS"
run
check "token is provisioned from the source when the runtime env has none" '[[ "$RC" -eq 0 && "$OUT" == *"Heimdall token provisioned from protected source"* ]] && grep -Fxq "HEIMDALL_FLEET_TOKEN=legacy-sentinel" "$ENV_FILE" && ! leftover_temp'
check "provisioning leaks no token value" 'no_leak'

printf 'HEIMDALL_HUB_URL=http://stale.example/api/panels\n' >"$ENV_FILE"
: >"$CALLS"
run
check "a runtime env without a token assignment is provisioned from the source" '[[ "$RC" -eq 0 && "$OUT" == *"Heimdall token provisioned from protected source"* ]] && grep -Fxq "HEIMDALL_FLEET_TOKEN=legacy-sentinel" "$ENV_FILE"'

write_env producer-sentinel
: >"$CALLS"
BROKKR_REPLACE_HEIMDALL_TOKEN=1 run
check "BROKKR_REPLACE_HEIMDALL_TOKEN=1 replaces the runtime token from the source" '[[ "$RC" -eq 0 && "$OUT" == *"Heimdall token provisioned from protected source"* ]] && grep -Fxq "HEIMDALL_FLEET_TOKEN=legacy-sentinel" "$ENV_FILE" && ! grep -Fq producer-sentinel "$ENV_FILE" && ! leftover_temp'
check "replacement leaks no token value" 'no_leak'

for bad_flag in 0 yes true 2 ' '; do
  write_env producer-sentinel
  cp "$ENV_FILE" "$TMP/env.before"
  : >"$CALLS"
  BROKKR_REPLACE_HEIMDALL_TOKEN="$bad_flag" run
  check "invalid BROKKR_REPLACE_HEIMDALL_TOKEN value '$bad_flag' is refused before ssh with the env unchanged" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_REPLACE_HEIMDALL_TOKEN"* ]] && ! grep -q "ssh\|rsync" "$CALLS" && cmp -s "$ENV_FILE" "$TMP/env.before"'
done

printf 'HEIMDALL_FLEET_TOKEN=producer-sentinel\nHEIMDALL_FLEET_TOKEN=other-sentinel\n' >"$ENV_FILE"
chmod 600 "$ENV_FILE"
cp "$ENV_FILE" "$TMP/env.before"
: >"$CALLS"
run
check "duplicate token assignments in the runtime env fail closed with exit 2 and the file unchanged" '[[ "$RC" -eq 2 && "$OUT" == *"duplicate"* ]] && cmp -s "$ENV_FILE" "$TMP/env.before" && ! leftover_temp && ! grep -q "systemctl enable" "$CALLS" && [[ "$OUT" != *producer-sentinel* && "$OUT" != *other-sentinel* ]]'
: >"$CALLS"
BROKKR_REPLACE_HEIMDALL_TOKEN=1 run
check "duplicate runtime tokens are refused even when replacement is requested" '[[ "$RC" -eq 2 ]] && cmp -s "$ENV_FILE" "$TMP/env.before"'

printf 'HEIMDALL_HUB_URL=http://stale.example/api/panels\nHEIMDALL_FLEET_TOKEN=\n' >"$ENV_FILE"
chmod 600 "$ENV_FILE"
cp "$ENV_FILE" "$TMP/env.before"
: >"$CALLS"
run
check "empty token assignment in the runtime env fails closed with exit 2 and the file unchanged" '[[ "$RC" -eq 2 && "$OUT" == *"empty"* ]] && cmp -s "$ENV_FILE" "$TMP/env.before" && ! leftover_temp && ! grep -q "systemctl enable" "$CALLS"'

rm -f "$ENV_FILE"
printf 'HEIMDALL_FLEET_TOKEN=producer-sentinel\n' >"$TMP/env.target"
ln -s "$TMP/env.target" "$ENV_FILE"
: >"$CALLS"
run
check "symlinked runtime env is refused with exit 2 and its target unchanged" '[[ "$RC" -eq 2 && -L "$ENV_FILE" ]] && [[ "$(cat "$TMP/env.target")" == "HEIMDALL_FLEET_TOKEN=producer-sentinel" ]] && ! grep -q "systemctl enable" "$CALLS"'
rm -f "$ENV_FILE"

write_env producer-sentinel
cp "$ENV_FILE" "$TMP/env.before"
: >"$CALLS"
export MOCK_ENV_MODE=644
run
check "unsafe runtime env mode is refused with exit 2 and the file unchanged" '[[ "$RC" -eq 2 ]] && cmp -s "$ENV_FILE" "$TMP/env.before" && ! grep -q "systemctl enable" "$CALLS"'
unset MOCK_ENV_MODE

# systemd EnvironmentFile= tolerates leading whitespace, `export` and blanks
# around `=`; none of those spellings may be miscounted as absent or unique.
export MOCK_CURL_EXPECT=legacy-sentinel
noncanonical_cases=(
  ' HEIMDALL_FLEET_TOKEN=producer-sentinel\n'
  '\tHEIMDALL_FLEET_TOKEN=producer-sentinel\n'
  'export HEIMDALL_FLEET_TOKEN=producer-sentinel\n'
  'HEIMDALL_FLEET_TOKEN = producer-sentinel\n'
  'HEIMDALL_FLEET_TOKEN=producer-sentinel\n  HEIMDALL_FLEET_TOKEN=other-sentinel\n'
)
case_n=0
for case_text in "${noncanonical_cases[@]}"; do
  case_n=$((case_n + 1))
  # shellcheck disable=SC2059 # the case text is a printf format by design.
  printf "HEIMDALL_HUB_URL=http://stale.example/api/panels\n$case_text" >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  cp "$ENV_FILE" "$TMP/env.before"
  : >"$CALLS"
  run
  check "non-canonical runtime token spelling #$case_n is refused with exit 2 and the file unchanged" '[[ "$RC" -eq 2 && "$OUT" == *"non-canonical"* ]] && cmp -s "$ENV_FILE" "$TMP/env.before" && ! leftover_temp && ! grep -q "systemctl enable" "$CALLS" && no_leak && [[ "$OUT" != *other-sentinel* ]]'
  : >"$CALLS"
  BROKKR_REPLACE_HEIMDALL_TOKEN=1 run
  check "non-canonical runtime token spelling #$case_n is refused even when replacement is requested" '[[ "$RC" -eq 2 && "$OUT" == *"non-canonical"* ]] && cmp -s "$ENV_FILE" "$TMP/env.before"'
done

rm -f "$ENV_FILE"
printf 'HEIMDALL_FLEET_TOKEN=legacy-sentinel\n  HEIMDALL_FLEET_TOKEN=other-sentinel\n' >"$TMP/heimdall-token.env"
: >"$CALLS"
run
check "a source with a hidden indented duplicate token is refused without writing the env" '[[ "$RC" -eq 2 && "$OUT" == *"non-canonical"* && ! -e "$ENV_FILE" ]] && ! grep -q "systemctl enable" "$CALLS" && no_leak && [[ "$OUT" != *other-sentinel* ]]'
printf 'HEIMDALL_FLEET_TOKEN=legacy-sentinel\n' >"$TMP/heimdall-token.env"

# Token values must be a single unquoted b64token (verify-heimdall-delivery.sh's
# alphabet); quoted, blank or otherwise unsupported values are refused, in the
# runtime env and in the source, in normal and in replacement mode.
unsupported_values=(
  '""'
  "''"
  '   '
  '"producer-sentinel"'
  'producer-sentinel '
  'producer\\sentinel'
  'producer sentinel'
)
case_n=0
for value in "${unsupported_values[@]}"; do
  case_n=$((case_n + 1))
  # shellcheck disable=SC2059 # the value is a printf format by design (backslash case).
  printf "HEIMDALL_HUB_URL=http://stale.example/api/panels\nHEIMDALL_FLEET_TOKEN=$value\n" >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  cp "$ENV_FILE" "$TMP/env.before"
  printf 'HEIMDALL_FLEET_TOKEN=legacy-sentinel\n' >"$TMP/heimdall-token.env"
  for flag in "" 1; do
    : >"$CALLS"
    BROKKR_REPLACE_HEIMDALL_TOKEN="$flag" run
    check "unsupported runtime token value #$case_n is refused with exit 2 and the file unchanged (replace='${flag:-0}')" '[[ "$RC" -eq 2 && "$OUT" == *"unsupported"* ]] && cmp -s "$ENV_FILE" "$TMP/env.before" && ! leftover_temp && ! grep -q "systemctl enable" "$CALLS" && no_leak'
  done
  # shellcheck disable=SC2059
  printf "HEIMDALL_FLEET_TOKEN=$value\n" >"$TMP/heimdall-token.env"
  write_env producer-sentinel
  cp "$ENV_FILE" "$TMP/env.before"
  for flag in "" 1; do
    : >"$CALLS"
    BROKKR_REPLACE_HEIMDALL_TOKEN="$flag" run
    check "unsupported source token value #$case_n is refused with exit 2 and the env unchanged (replace='${flag:-0}')" '[[ "$RC" -eq 2 && "$OUT" == *"unsupported"* ]] && cmp -s "$ENV_FILE" "$TMP/env.before" && ! grep -q "systemctl enable" "$CALLS" && no_leak'
  done
  rm -f "$ENV_FILE"
  : >"$CALLS"
  run
  check "unsupported source token value #$case_n is refused when the runtime env has no token" '[[ "$RC" -eq 2 && "$OUT" == *"unsupported"* && ! -e "$ENV_FILE" ]] && no_leak'
done
printf 'HEIMDALL_FLEET_TOKEN=legacy-sentinel\n' >"$TMP/heimdall-token.env"

# Staging-parent selection, exercised deterministically through the stat shim in
# both stat dialects (GNU is what Linux CI uses). Each row: /run metadata, /tmp
# metadata, expected outcome.
stage_rows=(
  '0 755 directory|0 1777 directory|/run'
  '0 777 directory|0 1777 directory|/tmp'
  '0 770 directory|0 1777 directory|/tmp'
  '1000 755 directory|0 1777 directory|/tmp'
  'fail|0 1777 directory|/tmp'
  '0 755 regular|0 1777 directory|/tmp'
  '0 777 directory|0 777 directory|refuse'
  '1000 755 directory|1000 1777 directory|refuse'
  'fail|fail|refuse'
)
export MOCK_CURL_EXPECT=producer-sentinel
for stat_style in gnu bsd; do
  row_n=0
  for row in "${stage_rows[@]}"; do
    row_n=$((row_n + 1))
    IFS='|' read -r run_spec tmp_spec expect <<<"$row"
    write_env producer-sentinel
    cp "$ENV_FILE" "$TMP/env.before"
    : >"$CALLS"
    MOCK_STAT_STYLE="$stat_style" MOCK_STAT_RUN="$run_spec" MOCK_STAT_TMP="$tmp_spec" run
    if [[ "$expect" == refuse ]]; then
      check "staging parent row $row_n ($stat_style stat): no trusted parent refuses before probing or writing" '[[ "$RC" -eq 2 && "$OUT" == *"no root-trusted directory"* ]] && cmp -s "$ENV_FILE" "$TMP/env.before" && ! grep -q "^root mktemp -d .*brokkr-heimdall-stage" "$FSLOG" && ! grep -q "curl \|systemctl enable" "$CALLS" && no_stage_dirs'
    else
      other=/tmp
      if [[ "$expect" == /tmp ]]; then other=/run; fi
      export other_parent="$other"
      check "staging parent row $row_n ($stat_style stat): $expect is chosen" '[[ "$RC" -eq 0 ]] && grep -q "^root mktemp -d $expect/brokkr-heimdall-stage\." "$FSLOG" && ! grep -q "^root mktemp -d $other_parent/brokkr-heimdall-stage" "$FSLOG" && no_stage_dirs'
    fi
  done
done
unset MOCK_CURL_EXPECT

# An inherited TMPDIR must never decide where root stages the probe copy.
write_env producer-sentinel
export MOCK_CURL_EXPECT=producer-sentinel
mkdir -p "$TMP/hostile-tmp"
: >"$CALLS"
TMPDIR="$TMP/hostile-tmp" run
check "a hostile TMPDIR is ignored for preflight staging" '[[ "$RC" -eq 0 ]] && grep -Eq "^root mktemp -d (/run|/tmp)/brokkr-heimdall-stage\." "$FSLOG" && ! grep -q "hostile-tmp/brokkr-heimdall-stage" "$FSLOG" && [[ -z "$(find "$TMP/hostile-tmp" -name "brokkr-heimdall-stage.*" -print)" ]] && no_stage_dirs'
unset MOCK_CURL_EXPECT

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
