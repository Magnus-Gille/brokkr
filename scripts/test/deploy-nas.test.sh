#!/usr/bin/env bash
# Hermetic deployment gates for NAS runtime rendering (brokkr#20).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$HERE/../deploy-nas.sh"
SOURCE="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/installed-units"
CALLS="$TMP/calls"
: >"$CALLS"

cat >"$TMP/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >>"$MOCK_CALLS"
destination="${!#}"
release="${destination#*:}"
if [[ ! -d "$release" ]]; then
  echo 'mock rsync: release target was not prepared' >&2
  exit 11
fi
cp -R "$MOCK_RELEASE_SOURCE/." "$release"
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
      exit 0
    fi
    destination="${!#}"
    if [[ "$destination" == /etc/systemd/system/* ]]; then
      source="${@: -2:1}"
      cp "$source" "$MOCK_INSTALLED_UNITS/$(basename "$destination")"
    fi
    exit 0
    ;;
  stat) printf '%s\n' "${MOCK_SOURCE_MODE:-600}" ;;
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
export MOCK_RELEASE_SOURCE="$SOURCE" MOCK_INSTALLED_UNITS="$TMP/installed-units"
export BROKKR_SSH_TARGET=operator@nas-host
export BROKKR_DEPLOY_TARGET="$TMP/releases/nas/brokkr" BROKKR_RUNTIME_USER=operator
export BROKKR_RUNTIME_HOME="$TMP/home/operator" BROKKR_REGISTRY_PATH="$TMP/registry/services.json"
export MOCK_RELEASE_TARGET="$BROKKR_DEPLOY_TARGET" MOCK_RUNTIME_HOME="$BROKKR_RUNTIME_HOME" MOCK_REGISTRY_PATH="$BROKKR_REGISTRY_PATH"
mkdir -p "$BROKKR_RUNTIME_HOME" "$(dirname "$BROKKR_REGISTRY_PATH")"
printf '{"components":[]}\n' >"$BROKKR_REGISTRY_PATH"
export BROKKR_HEIMDALL_SOURCE_ENV="$TMP/heimdall-source.env"
export MOCK_HEIMDALL_SOURCE_ENV="$BROKKR_HEIMDALL_SOURCE_ENV"
printf 'HEIMDALL_HUB_URL=https://heimdall.example/api/panels\nHEIMDALL_FLEET_TOKEN=secret-sentinel\n' >"$BROKKR_HEIMDALL_SOURCE_ENV"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# shellcheck disable=SC2034 # checks consume OUT and RC through eval.
run() { OUT="$(bash "$DEPLOY" 2>&1)"; RC=$?; }

echo "deploy-nas.test.sh"

unset BROKKR_RUNTIME_USER
run
check "missing explicit runtime identity refuses before SSH" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_RUNTIME_USER is required"* ]] && [[ ! -s "$CALLS" ]]'
export BROKKR_RUNTIME_USER=operator

run
check "first install with a non-default runtime layout succeeds" '[[ "$RC" -eq 0 && "$OUT" == *"==> Done."* ]]'
check "nested runtime-user release target is prepared before rsync" '[[ -d "$BROKKR_DEPLOY_TARGET" ]] && [[ "$(grep -n "sudo install -d" "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n "^rsync " "$CALLS" | head -1 | cut -d: -f1)" ]]'
check "release synchronization uses the runtime identity" 'grep -Fq -- "--rsync-path=sudo -u $BROKKR_RUNTIME_USER rsync" "$CALLS"'
check "health unit is rendered for the explicit runtime layout" 'grep -Fqx "User=$BROKKR_RUNTIME_USER" "$MOCK_INSTALLED_UNITS/brokkr-health.service" && grep -Fqx "WorkingDirectory=$BROKKR_DEPLOY_TARGET" "$MOCK_INSTALLED_UNITS/brokkr-health.service" && grep -Fqx "EnvironmentFile=-$BROKKR_RUNTIME_HOME/.config/brokkr/env" "$MOCK_INSTALLED_UNITS/brokkr-health.service" && grep -Fqx "ExecStart=$BROKKR_DEPLOY_TARGET/scripts/health-snapshot.sh" "$MOCK_INSTALLED_UNITS/brokkr-health.service"'
check "failure services are rendered for the explicit runtime layout" 'grep -Fqx "User=$BROKKR_RUNTIME_USER" "$MOCK_INSTALLED_UNITS/brokkr-systemd-failure@.service" && grep -Fqx "WorkingDirectory=$BROKKR_DEPLOY_TARGET" "$MOCK_INSTALLED_UNITS/brokkr-systemd-failure-sweep.service" && grep -Fqx "ExecStart=$BROKKR_DEPLOY_TARGET/scripts/systemd-failure-monitor.sh --sweep" "$MOCK_INSTALLED_UNITS/brokkr-systemd-failure-sweep.service"'
check "registry and executable/unit validation happen before systemd mutation" 'grep -q "sudo systemd-analyze verify" "$CALLS" && [[ "$(grep -n "sudo systemd-analyze verify" "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n "/etc/systemd/system/brokkr-health.service" "$CALLS" | head -1 | cut -d: -f1)" ]]'
check "protected Heimdall values and source path are not printed" '[[ "$OUT" != *secret-sentinel* && "$OUT" != *"$BROKKR_HEIMDALL_SOURCE_ENV"* ]] && ! grep -Fq secret-sentinel "$CALLS" && ! grep -Fq "$BROKKR_HEIMDALL_SOURCE_ENV" "$CALLS"'

: >"$CALLS"
export MOCK_SOURCE_MODE=644
run
check "unsafe Heimdall source refuses before systemd mutation without leakage" '[[ "$RC" -ne 0 && "$OUT" == *"unsafe permissions"* ]] && ! grep -q "/etc/systemd/system\|systemctl" "$CALLS" && [[ "$OUT" != *secret-sentinel* && "$OUT" != *"$BROKKR_HEIMDALL_SOURCE_ENV"* ]] && ! grep -Fq secret-sentinel "$CALLS" && ! grep -Fq "$BROKKR_HEIMDALL_SOURCE_ENV" "$CALLS"'
unset MOCK_SOURCE_MODE

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
