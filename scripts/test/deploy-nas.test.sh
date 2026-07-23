#!/usr/bin/env bash
# Hermetic deployment gates for NAS runtime rendering (brokkr#20).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SOURCE="$(cd "$HERE/../.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
SOURCE="$TMP/bound-source"
BASE_SHA="$(git -C "$REPO_SOURCE" rev-parse HEAD)"
git clone -q "$REPO_SOURCE" "$SOURCE"
git -C "$SOURCE" checkout --detach -q "$BASE_SHA"
# Exercise the current implementation while retaining a detached worktree.
cp "$REPO_SOURCE/scripts/deploy-nas.sh" "$SOURCE/scripts/deploy-nas.sh"
cp "$REPO_SOURCE/scripts/lib/deploy-source.sh" "$SOURCE/scripts/lib/deploy-source.sh"
git -C "$SOURCE" config user.name test
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" add scripts/deploy-nas.sh scripts/lib/deploy-source.sh
git -C "$SOURCE" commit -qm 'fixture deploy binding'
SOURCE_SHA="$(git -C "$SOURCE" rev-parse HEAD)"
STALE_SOURCE="$TMP/stale-source"
git clone -q "$SOURCE" "$STALE_SOURCE"
git -C "$STALE_SOURCE" checkout --detach -q "$BASE_SHA"
cp "$REPO_SOURCE/scripts/deploy-nas.sh" "$STALE_SOURCE/scripts/deploy-nas.sh"
cp "$REPO_SOURCE/scripts/lib/deploy-source.sh" "$STALE_SOURCE/scripts/lib/deploy-source.sh"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT
DEPLOY="$SOURCE/scripts/deploy-nas.sh"

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/installed-units"
CALLS="$TMP/calls"
: >"$CALLS"

cat >"$TMP/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >>"$MOCK_CALLS"
source="${@: -2:1}"
source="${source%/}"
if [[ -n "${MOCK_MUTATE_SOURCE:-}" ]]; then
  printf '\npost-archive mutation\n' >>"$MOCK_MUTATE_SOURCE/README.md"
fi
destination="${!#}"
release="${destination#*:}"
if [[ ! -d "$release" ]]; then
  echo 'mock rsync: release target was not prepared' >&2
  exit 11
fi
chmod 755 "$release"
if [[ -x "$release/scripts/deploy-nas.sh" ]]; then
  exit 0
fi
cp -R "$source/." "$release"
EOF

cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$1" >>"$MOCK_CALLS"
[[ "$#" -eq 2 ]] || exit 64
HOME="$MOCK_REMOTE_HOME" PATH="$MOCK_BIN:$PATH" bash -c "$2"
EOF

cat >"$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
exit "${MOCK_ID_RC:-0}"
EOF

cat >"$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
safe_args="${*//$MOCK_HEIMDALL_SOURCE_ENV/<protected-source>}"
printf 'sudo %s\n' "$safe_args" >>"$MOCK_CALLS"
case "${1:-}" in
  test)
    if [[ "${MOCK_PROTECTED_SOURCE_TESTS:-0}" == 1 ]]; then
      case "${2:-}" in
        -f|-O) exit 0 ;;
        -L) exit 1 ;;
      esac
    fi
    "$@"
    ;;
  -u)
    case "$*" in
      *"$MOCK_RELEASE_TARGET"*)
        if [[ "$*" == *' -O '* ]]; then exit "${MOCK_RELEASE_OWNER_RC:-0}"; fi
        if [[ "$*" == *' -w '* ]]; then exit "${MOCK_RELEASE_WRITABLE_RC:-0}"; fi
        ;;
      *"$MOCK_RUNTIME_HOME"*) exit "${MOCK_RUNTIME_HOME_RC:-0}" ;;
      *"$MOCK_REGISTRY_PATH"*) exit "${MOCK_REGISTRY_RC:-0}" ;;
    esac
    exit 0
    ;;
  install)
    if [[ "${2:-}" == -d && "$*" == *"$MOCK_RELEASE_TARGET"* ]]; then
      [[ "${MOCK_RELEASE_PREP_RC:-0}" -eq 0 ]] || exit "$MOCK_RELEASE_PREP_RC"
      mkdir -p "${!#}"
      chmod "${4:-755}" "${!#}"
      exit 0
    fi
    destination="${!#}"
    if [[ "$destination" == /etc/systemd/system/* ]]; then
      source="${@: -2:1}"
      cp "$source" "$MOCK_INSTALLED_UNITS/$(basename "$destination")"
    fi
    exit 0
    ;;
  stat)
    if [[ "${!#}" == "$MOCK_RELEASE_TARGET" ]]; then
      stat -c '%a' "${!#}" 2>/dev/null || stat -f '%Lp' "${!#}"
    elif [[ "${!#}" == "$MOCK_RUNTIME_ENV" ]]; then
      printf 'mock-runtime-mode %s\n' "${MOCK_RUNTIME_MODE:-600}" >>"$MOCK_CALLS"
      printf '%s\n' "${MOCK_RUNTIME_MODE:-600}"
    else
      printf 'mock-source-mode %s\n' "${MOCK_SOURCE_MODE:-600}" >>"$MOCK_CALLS"
      printf '%s\n' "${MOCK_SOURCE_MODE:-600}"
    fi
    ;;
  chmod)
    if [[ "$3" == "$MOCK_RELEASE_TARGET" ]]; then chmod "$2" "$3"; fi
    ;;
  grep) "$@" ;;
  sh) exit 0 ;;
  env) shift; while [[ "$1" == *=* ]]; do shift; done; "$@" ;;
  systemd-analyze) exit "${MOCK_UNIT_VERIFY_RC:-0}" ;;
  systemctl|journalctl|sleep) exit 0 ;;
  *) exit 0 ;;
esac
EOF

chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" MOCK_BIN="$TMP/bin" MOCK_CALLS="$CALLS" MOCK_REMOTE_HOME="$TMP/home"
export MOCK_INSTALLED_UNITS="$TMP/installed-units"
export BROKKR_SSH_TARGET=operator@nas-host
export BROKKR_DEPLOY_TARGET="$TMP/releases/nas/brokkr" BROKKR_RUNTIME_USER=operator
export BROKKR_RUNTIME_HOME="$TMP/home/operator" BROKKR_REGISTRY_PATH="$TMP/registry/services.json"
export MOCK_RELEASE_TARGET="$BROKKR_DEPLOY_TARGET" MOCK_RUNTIME_HOME="$BROKKR_RUNTIME_HOME" MOCK_REGISTRY_PATH="$BROKKR_REGISTRY_PATH"
export MOCK_RUNTIME_ENV="$BROKKR_RUNTIME_HOME/.config/brokkr/env"
mkdir -p "$BROKKR_RUNTIME_HOME" "$(dirname "$BROKKR_REGISTRY_PATH")"
printf '{"components":[]}\n' >"$BROKKR_REGISTRY_PATH"
export BROKKR_HEIMDALL_SOURCE_ENV="$TMP/heimdall-source.env"
export MOCK_HEIMDALL_SOURCE_ENV="$BROKKR_HEIMDALL_SOURCE_ENV"
export BROKKR_EXPECTED_SOURCE="$SOURCE" BROKKR_EXPECTED_COMMIT="$SOURCE_SHA"
mkdir -p "$TMP/payload-tmp"
export TMPDIR="$TMP/payload-tmp"
export MOCK_MUTATE_SOURCE="$SOURCE"
printf 'ignored-secret\n' >"$SOURCE/.env"
printf 'ignored-status\n' >"$SOURCE/STATUS.md"
printf 'HEIMDALL_HUB_URL=https://heimdall.example/api/panels\nHEIMDALL_FLEET_TOKEN=secret-sentinel\n' >"$BROKKR_HEIMDALL_SOURCE_ENV"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
# shellcheck disable=SC2034 # checks consume OUT and RC through eval.
run() {
  local deploy=${1:-$DEPLOY}
  OUT="$(cd "$SOURCE" && bash "$deploy" 2>&1)"
  RC=$?
}

echo "deploy-nas.test.sh"

unset BROKKR_EXPECTED_COMMIT
run
check "missing source revision refuses before SSH or rsync" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_EXPECTED_SOURCE and BROKKR_EXPECTED_COMMIT"* ]] && [[ ! -s "$CALLS" ]]'
export BROKKR_EXPECTED_COMMIT="$SOURCE_SHA"

: >"$CALLS"
run "$STALE_SOURCE/scripts/deploy-nas.sh"
check "stale entry script refuses from an accepted detached cwd before SSH or rsync" '[[ "$RC" -ne 0 && "$OUT" == *"entry point source root does not match"* ]] && [[ ! -s "$CALLS" ]]'

: >"$CALLS"
ln -s "$STALE_SOURCE/scripts/deploy-nas.sh" "$SOURCE/scripts/deploy-via-link.sh"
run "$SOURCE/scripts/deploy-via-link.sh"
check "symlinked entry script refuses before SSH or rsync" '[[ "$RC" -ne 0 && "$OUT" == *"path must not contain symlinks"* ]] && [[ ! -s "$CALLS" ]]'
rm -f "$SOURCE/scripts/deploy-via-link.sh"

: >"$CALLS"
printf '\n# dirty fixture\n' >>"$SOURCE/scripts/health-snapshot.sh"
run
check "dirty tracked source refuses before SSH or rsync" '[[ "$RC" -ne 0 && "$OUT" == *"tracked changes"* ]] && [[ ! -s "$CALLS" ]]'
git -C "$SOURCE" checkout -- scripts/health-snapshot.sh

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
export BROKKR_EXPECTED_COMMIT="$SOURCE_SHA"

unset BROKKR_RUNTIME_USER
run
check "missing explicit runtime identity refuses before SSH" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_RUNTIME_USER is required"* ]] && [[ ! -s "$CALLS" ]]'
export BROKKR_RUNTIME_USER=operator

run
check "first install with a non-default runtime layout succeeds" '[[ "$RC" -eq 0 && "$OUT" == *"==> Done."* ]]'
check "archive payload excludes ignored live files" '[[ ! -e "$BROKKR_DEPLOY_TARGET/.env" && ! -e "$BROKKR_DEPLOY_TARGET/STATUS.md" ]]'
check "archive payload resists a post-materialization tracked mutation" '! grep -q "post-archive mutation" "$BROKKR_DEPLOY_TARGET/README.md"'
check "archive payload preserves executable bits without making data files executable" '[[ -x "$BROKKR_DEPLOY_TARGET/scripts/deploy-nas.sh" && ! -x "$BROKKR_DEPLOY_TARGET/README.md" ]]'
check "archive payload parent is cleaned after deploy" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name "brokkr-deploy.*" -print)" ]]'
check "remote release root keeps intentional mode" '[[ "$(mode "$BROKKR_DEPLOY_TARGET")" == 750 ]]'
unset MOCK_MUTATE_SOURCE
git -C "$SOURCE" checkout -- README.md
check "nested runtime-user release target is prepared before rsync" '[[ -d "$BROKKR_DEPLOY_TARGET" ]] && [[ "$(grep -n "sudo install -d" "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n "^rsync " "$CALLS" | head -1 | cut -d: -f1)" ]]'
check "release synchronization uses the runtime identity and preserves executability" 'grep -Fq -- "--rsync-path=sudo -u $BROKKR_RUNTIME_USER rsync" "$CALLS" && grep -Fq -- "--no-perms --executability" "$CALLS"'
check "health unit is rendered for the explicit runtime layout" 'grep -Fqx "User=$BROKKR_RUNTIME_USER" "$MOCK_INSTALLED_UNITS/brokkr-health.service" && grep -Fqx "WorkingDirectory=$BROKKR_DEPLOY_TARGET" "$MOCK_INSTALLED_UNITS/brokkr-health.service" && grep -Fqx "EnvironmentFile=-$BROKKR_RUNTIME_HOME/.config/brokkr/env" "$MOCK_INSTALLED_UNITS/brokkr-health.service" && grep -Fqx "ExecStart=$BROKKR_DEPLOY_TARGET/scripts/health-snapshot.sh" "$MOCK_INSTALLED_UNITS/brokkr-health.service"'
check "failure services are rendered for the explicit runtime layout" 'grep -Fqx "User=$BROKKR_RUNTIME_USER" "$MOCK_INSTALLED_UNITS/brokkr-systemd-failure@.service" && grep -Fqx "WorkingDirectory=$BROKKR_DEPLOY_TARGET" "$MOCK_INSTALLED_UNITS/brokkr-systemd-failure-sweep.service" && grep -Fqx "ExecStart=$BROKKR_DEPLOY_TARGET/scripts/systemd-failure-monitor.sh --sweep" "$MOCK_INSTALLED_UNITS/brokkr-systemd-failure-sweep.service"'
check "registry and executable/unit validation happen before systemd mutation" 'grep -q "sudo systemd-analyze verify" "$CALLS" && [[ "$(grep -n "sudo systemd-analyze verify" "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n "/etc/systemd/system/brokkr-health.service" "$CALLS" | head -1 | cut -d: -f1)" ]]'
check "protected Heimdall values and source path are not printed" '[[ "$OUT" != *secret-sentinel* && "$OUT" != *"$BROKKR_HEIMDALL_SOURCE_ENV"* ]] && ! grep -Fq secret-sentinel "$CALLS" && ! grep -Fq "$BROKKR_HEIMDALL_SOURCE_ENV" "$CALLS"'

: >"$CALLS"
runtime_env="$BROKKR_RUNTIME_HOME/.config/brokkr/env"
mkdir -p "$(dirname "$runtime_env")"
printf 'HEIMDALL_HUB_URL=https://heimdall.example/api/panels\nHEIMDALL_FLEET_TOKEN=preserved-secret-sentinel\n' >"$runtime_env"
chmod 600 "$runtime_env"
unset BROKKR_HEIMDALL_SOURCE_ENV
run
check "omitted source preserves and reports an existing protected runtime env" '[[ "$RC" -eq 0 && "$OUT" == *"Heimdall runtime environment preserved"* && "$OUT" != *"pushes will be skipped"* ]]'
check "preserved runtime credentials are not printed" '[[ "$OUT" != *preserved-secret-sentinel* ]] && ! grep -Fq preserved-secret-sentinel "$CALLS"'

: >"$CALLS"
export MOCK_RUNTIME_MODE=644
run
check "unsafe preserved runtime env fails closed before systemd mutation" '[[ "$RC" -ne 0 && "$OUT" == *"preserved Heimdall runtime environment has unsafe permissions"* ]] && ! grep -q "/etc/systemd/system\|systemctl" "$CALLS"'
check "unsafe preserved runtime env output contains no credential value" '[[ "$OUT" != *preserved-secret-sentinel* ]]'
unset MOCK_RUNTIME_MODE

: >"$CALLS"
rm -f "$runtime_env"
run
check "omitted source with no runtime env remains an explicit unconfigured success" '[[ "$RC" -eq 0 && "$OUT" == *"runtime environment not configured; pushes will be skipped"* && "$OUT" != *"environment preserved"* ]]'
export BROKKR_HEIMDALL_SOURCE_ENV="$MOCK_HEIMDALL_SOURCE_ENV"

: >"$CALLS"
export MOCK_PROTECTED_SOURCE_TESTS=1 MOCK_SOURCE_MODE=644
run
check "unsafe Heimdall source returns non-zero" '[[ "$RC" -ne 0 ]]'
check "unsafe Heimdall source fixture supplies mode 0644" 'grep -Fqx "mock-source-mode 644" "$CALLS"'
check "unsafe Heimdall source installs no systemd unit" '! grep -Fq "/etc/systemd/system/" "$CALLS"'
check "unsafe Heimdall source invokes no systemctl mutation" '! grep -Fq "systemctl" "$CALLS"'
check "unsafe Heimdall source output contains no secret value" '[[ "$OUT" != *secret-sentinel* ]]'
check "unsafe Heimdall source output contains no source path" '[[ "$OUT" != *"$BROKKR_HEIMDALL_SOURCE_ENV"* ]]'
check "unsafe Heimdall source call log contains no secret value" '! grep -Fq secret-sentinel "$CALLS"'
check "unsafe Heimdall source call log contains no source path" '! grep -Fq "$BROKKR_HEIMDALL_SOURCE_ENV" "$CALLS"'
unset MOCK_PROTECTED_SOURCE_TESTS MOCK_SOURCE_MODE

: >"$CALLS"
rm -rf "$BROKKR_DEPLOY_TARGET"
mkdir -p "$(dirname "$BROKKR_DEPLOY_TARGET")" "$TMP/symlink-target"
ln -s "$TMP/symlink-target" "$BROKKR_DEPLOY_TARGET"
run
check "symlink deploy target refuses before rsync or systemd mutation" '[[ "$RC" -ne 0 && "$OUT" == *"existing release target"* ]] && ! grep -q "^rsync \|systemctl\|/etc/systemd/system" "$CALLS"'
rm -f "$BROKKR_DEPLOY_TARGET"

: >"$CALLS"
mkdir -p "$BROKKR_DEPLOY_TARGET"
export MOCK_RELEASE_OWNER_RC=1
run
check "wrong-owner deploy target refuses before rsync or systemd mutation" '[[ "$RC" -ne 0 && "$OUT" == *"existing release target"* ]] && ! grep -q "^rsync \|systemctl\|/etc/systemd/system" "$CALLS"'
unset MOCK_RELEASE_OWNER_RC

: >"$CALLS"
export MOCK_RELEASE_WRITABLE_RC=1
run
check "unwritable deploy target refuses before rsync or systemd mutation" '[[ "$RC" -ne 0 && "$OUT" == *"existing release target"* ]] && ! grep -q "^rsync \|systemctl\|/etc/systemd/system" "$CALLS"'
unset MOCK_RELEASE_WRITABLE_RC

: >"$CALLS"
rm -rf "$BROKKR_DEPLOY_TARGET"
export MOCK_UNIT_VERIFY_RC=1
run
check "invalid rendered unit refuses before systemd mutation" '[[ "$RC" -ne 0 ]] && grep -q "sudo systemd-analyze verify" "$CALLS" && ! grep -q "/etc/systemd/system\|systemctl" "$CALLS"'
unset MOCK_UNIT_VERIFY_RC

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
