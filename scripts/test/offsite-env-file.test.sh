#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/offsite-photos-backup.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-offsite-env-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
check() {
  local label="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'not ok - %s\n' "$label" >&2
    FAIL=$((FAIL + 1))
  fi
}

mkdir -p "$TMP/bin" "$TMP/source"
cat >"$TMP/bin/rclone" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = config ] && [ "${2:-}" = show ]; then
  printf 'type = crypt\nfilename_encryption = standard\ndirectory_name_encryption = true\n'
  exit 0
fi
if [ "${1:-}" = lsd ]; then exit 0; fi
exit 0
MOCK
chmod +x "$TMP/bin/rclone"

run_backup() {
  local env_file="$1" output="$2"
  BROKKR_OFFSITE_ENV_FILE="$env_file" \
    BROKKR_TEST_MARKER="$TMP/executed" \
    MIMIR_OFFSITE_ROOT="$TMP/source" \
    MIMIR_OFFSITE_REMOTE=test-crypt \
    MIMIR_OFFSITE_LOG="$TMP/backup.log" \
    MIMIR_OFFSITE_STAMP="$TMP/backup.stamp" \
    RCLONE_BIN="$TMP/bin/rclone" \
    bash "$SCRIPT" --dry-run >"$output" 2>&1
}

# A public operational script must not source a file that another account can
# replace or modify. These checks intentionally run before any backup preflight.
UNSAFE="$TMP/unsafe.env"
printf 'touch "$BROKKR_TEST_MARKER"\n' >"$UNSAFE"
chmod 0644 "$UNSAFE"
if run_backup "$UNSAFE" "$TMP/unsafe.out"; then unsafe_rc=0; else unsafe_rc=$?; fi
check "group/world-readable env file is rejected" test "$unsafe_rc" -ne 0
check "unsafe env file is not executed" test ! -e "$TMP/executed"
check "unsafe-mode error is attributable" grep -qi 'mode\|permission' "$TMP/unsafe.out"

rm -f "$TMP/executed"
SAFE_TARGET="$TMP/safe-target.env"
printf 'touch "$BROKKR_TEST_MARKER"\n' >"$SAFE_TARGET"
chmod 0600 "$SAFE_TARGET"
ln -s "$SAFE_TARGET" "$TMP/link.env"
if run_backup "$TMP/link.env" "$TMP/link.out"; then link_rc=0; else link_rc=$?; fi
check "symlink env file is rejected" test "$link_rc" -ne 0
check "symlink target is not executed" test ! -e "$TMP/executed"
check "symlink error is attributable" grep -qi 'symlink' "$TMP/link.out"

if [ "$(id -u)" -eq 0 ]; then
  WRONG_OWNER="$TMP/wrong-owner.env"
  printf 'BROKKR_TEST_VALUE=wrong-owner\n' >"$WRONG_OWNER"
  chown 65534 "$WRONG_OWNER"
  chmod 0600 "$WRONG_OWNER"
else
  WRONG_OWNER=/etc/passwd
fi
if run_backup "$WRONG_OWNER" "$TMP/owner.out"; then owner_rc=0; else owner_rc=$?; fi
check "env file owned by another account is rejected" test "$owner_rc" -ne 0
check "wrong-owner error is attributable" grep -qi 'owner' "$TMP/owner.out"

VALID="$TMP/valid.env"
cat >"$VALID" <<EOF
MIMIR_OFFSITE_ROOT='$TMP/source'
MIMIR_OFFSITE_REMOTE='test-crypt'
MIMIR_OFFSITE_LOG='$TMP/backup.log'
MIMIR_OFFSITE_STAMP='$TMP/backup.stamp'
RCLONE_BIN='$TMP/bin/rclone'
EOF
chmod 0600 "$VALID"
if run_backup "$VALID" "$TMP/valid.out"; then valid_rc=0; else valid_rc=$?; fi
check "owner-only regular env file is accepted" test "$valid_rc" -eq 0
check "accepted env reaches dry-run completion" grep -q 'dry-run complete' "$TMP/backup.log"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
