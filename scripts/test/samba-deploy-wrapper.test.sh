#!/usr/bin/env bash
# Brokkr · hermetic state forwarding tests for samba/deploy.sh (brokkr#131).
set -uo pipefail
# shellcheck disable=SC2034 # run's RC and OUT are consumed through eval checks.
# shellcheck disable=SC2016 # Assertions are evaluated by chk, not at declaration.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-samba-wrapper-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"
mkdir -p "$MOCKBIN"
CALLS="$WORK/calls"
CONFIG="$WORK/timemachine.conf"
printf '[TimeMachine]\n   available = no\n   fruit:time machine = no\n' >"$CONFIG"
mkdir -p "$WORK/source/samba" "$WORK/source/scripts/lib"
SOURCE="$(cd "$WORK/source" && pwd -P)"
cp "$HERE/../../samba/deploy.sh" "$HERE/../../samba/deploy-remote.sh" "$SOURCE/samba/"
cp "$HERE/../../scripts/lib/deploy-source.sh" "$SOURCE/scripts/lib/"
git -C "$SOURCE" init -q
git -C "$SOURCE" config user.name 'Brokkr hermetic test'
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" add samba scripts
git -C "$SOURCE" commit -qm fixture
REVISION="$(git -C "$SOURCE" rev-parse HEAD)"
WRAPPER="$SOURCE/samba/deploy.sh"

cat >"$MOCKBIN/ssh" <<'MOCK'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >>"${MOCK_CALLS:?MOCK_CALLS is required}"
if [ "${!#}" = '/usr/bin/mktemp /tmp/brokkr-tm.XXXXXX' ]; then
  printf '%s\n' "${MOCK_STAGE_PATH:-/tmp/brokkr-tm.ABCXYZ}"
elif [[ "${!#}" == *'/bin/bash -s' ]]; then
  cat >"${MOCK_REMOTE_PAYLOAD:?MOCK_REMOTE_PAYLOAD is required}"
fi
MOCK

cat >"$MOCKBIN/scp" <<'MOCK'
#!/usr/bin/env bash
printf 'scp %s\n' "$*" >>"${MOCK_CALLS:?MOCK_CALLS is required}"
MOCK

chmod +x "$MOCKBIN/ssh" "$MOCKBIN/scp"

PASS=0
FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS + 1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
chk(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }
run(){
  # shellcheck disable=SC2034 # RC and OUT are consumed by chk/eval below.
  : >"$CALLS"
  # shellcheck disable=SC2034
  OUT="$(cd "$SOURCE" && PATH="$MOCKBIN:$PATH" MOCK_CALLS="$CALLS" MOCK_REMOTE_PAYLOAD="$WORK/payload" \
    BROKKR_EXPECTED_SOURCE="$SOURCE" BROKKR_EXPECTED_COMMIT="$REVISION" BROKKR_SAMBA_CONFIG="$CONFIG" "$@" 2>&1)"
  # shellcheck disable=SC2034
  RC=$?
}

echo "samba-deploy-wrapper.test.sh"
unset BROKKR_SAMBA_TIME_MACHINE_STATE
run bash "$WRAPPER" nas@example.invalid
chk "default retired state reaches remote command" '[ "$RC" -eq 0 ] && grep -q "BROKKR_SAMBA_TIME_MACHINE_STATE=retired" "$CALLS"'
chk "default run stages and invokes remote once" '[ "$(grep -c "^ssh " "$CALLS")" = 3 ] && [ "$(grep -c "^scp " "$CALLS")" = 1 ]'
chk "remote payload is exactly the committed helper" 'cmp -s "$WORK/payload" "$SOURCE/samba/deploy-remote.sh"'
chk "SSH transport rejects unknown host keys and agent forwarding" 'grep -q "StrictHostKeyChecking=yes" "$CALLS" && grep -q "ForwardAgent=no" "$CALLS"'

printf '[TimeMachine]\n   fruit:time machine = yes\n' >"$CONFIG"
run bash "$WRAPPER" nas@example.invalid
chk "default rejects an old enabled operator config before network" '[ "$RC" -ne 0 ] && [ ! -s "$CALLS" ]'
export BROKKR_SAMBA_TIME_MACHINE_STATE=active
run bash "$WRAPPER" nas@example.invalid
chk "explicit active state reaches remote command" '[ "$RC" -eq 0 ] && grep -q "BROKKR_SAMBA_TIME_MACHINE_STATE=active" "$CALLS"'

export BROKKR_SAMBA_TIME_MACHINE_STATE=invalid
run bash "$WRAPPER" nas@example.invalid
chk "invalid state refuses before network" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"invalid"* ]] && [ ! -s "$CALLS" ]'
unset BROKKR_SAMBA_TIME_MACHINE_STATE
printf '[TimeMachine]\n   available = no\n   fruit:time machine = no\n' >"$CONFIG"
printf '\n# dirty fixture\n' >>"$SOURCE/samba/deploy-remote.sh"
run bash "$WRAPPER" nas@example.invalid
chk "dirty source refuses before network" '[ "$RC" -ne 0 ] && [ ! -s "$CALLS" ]'
git -C "$SOURCE" show "$REVISION:samba/deploy-remote.sh" >"$SOURCE/samba/deploy-remote.sh"
export MOCK_STAGE_PATH="/tmp/unsafe'; touch /tmp/unwanted"
run bash "$WRAPPER" nas@example.invalid
chk "malformed remote path refuses copy and cleanup" '[ "$RC" -ne 0 ] && [ "$(grep -c "^ssh " "$CALLS")" = 1 ] && ! grep -q "^scp " "$CALLS"'
unset MOCK_STAGE_PATH
run bash "$WRAPPER" '-oProxyCommand=unexpected'
chk "option-shaped target refuses before network" '[ "$RC" -ne 0 ] && [ ! -s "$CALLS" ]'
run env -u BROKKR_NAS_TARGET bash "$WRAPPER"
chk "missing explicit target refuses before network" '[ "$RC" -ne 0 ] && [ ! -s "$CALLS" ]'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
