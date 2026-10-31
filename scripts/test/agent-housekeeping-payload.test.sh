#!/usr/bin/env bash
# Focused regression for payload_same's filesystem inspection boundary.
set -uo pipefail

if [[ $(id -u) -eq 0 ]]; then
  echo 'agent-housekeeping-payload.test.sh: must run as an unprivileged user to test permission denial' >&2
  exit 2
fi

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE="$HERE/../provision-agent-account.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/brokkr-agent-payload.XXXXXX")
PARENT="$TMP/private"
RENDERED="$TMP/rendered"
TARGET="$PARENT/target"
trap 'chmod 755 "$PARENT" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir "$PARENT"
printf '%s\n' expected >"$RENDERED"

fatal() { echo "fatal: $*" >&2; exit 1; }
# Keep this test bound to the production function; the test supplies only its fatal seam.
eval "$(sed -n '/^payload_same() /,/^}/p' "$SOURCE")"

PASS=0
FAIL=0
check() {
  local name=$1; shift
  if "$@"; then
    PASS=$((PASS + 1))
    printf 'PASS %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n' "$name" >&2
  fi
}

missing_is_changed() {
  local rc
  payload_same "$RENDERED" "$PARENT/missing" 'missing payload'
  rc=$?
  [[ $rc -eq 1 ]]
}

equal_is_same() {
  printf '%s\n' expected >"$TARGET"
  payload_same "$RENDERED" "$TARGET" 'equal payload'
}

different_is_changed() {
  printf '%s\n' different >"$TARGET"
  ! payload_same "$RENDERED" "$TARGET" 'different payload'
}

symlink_is_fatal() {
  local out rc
  rm -f "$TARGET"
  ln -s "$RENDERED" "$TARGET"
  out=$(payload_same "$RENDERED" "$TARGET" 'symlink payload' 2>&1)
  rc=$?
  [[ $rc -eq 1 && $out == *'not a readable regular non-symlink file'* ]]
}

inaccessible_parent_is_fatal() {
  local out rc
  rm -f "$TARGET"
  printf '%s\n' expected >"$TARGET"
  chmod 000 "$PARENT"
  out=$(payload_same "$RENDERED" "$TARGET" 'inaccessible payload' 2>&1)
  rc=$?
  chmod 755 "$PARENT"
  [[ $rc -eq 1 && $out == *'cannot inspect parent of'* ]]
}

check 'readable parent with missing target is changed' missing_is_changed
check 'equal readable regular payload is unchanged' equal_is_same
check 'different readable regular payload is changed' different_is_changed
check 'malformed symlink payload fails closed' symlink_is_fatal
check 'inaccessible parent fails closed with inspection diagnostic' inaccessible_parent_is_fatal

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
