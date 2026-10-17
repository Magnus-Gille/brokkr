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
if [ "${MOCK_RCLONE_FAIL:-}" = mkdir ] && [ "${1:-}" = mkdir ]; then exit 23; fi
if [ "${1:-}" = lsd ]; then exit 0; fi
exit 0
MOCK
cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$MOCK_CURL_ARGV"
if [ "${MOCK_CURL_EARLY_EXIT:-}" = 1 ]; then exit 28; fi
cat >"$MOCK_CURL_STDIN"
exit "${MOCK_CURL_EXIT:-0}"
MOCK
chmod +x "$TMP/bin/rclone" "$TMP/bin/curl"

run_backup() {
  local env_file="$1" output="$2"
  BROKKR_OFFSITE_ENV_FILE="$env_file" \
    PATH="$TMP/bin:$PATH" \
    BROKKR_TEST_MARKER="$TMP/executed" \
    MIMIR_OFFSITE_ROOT="$TMP/source" \
    MIMIR_OFFSITE_REMOTE=test-crypt \
    MIMIR_OFFSITE_LOG="$TMP/backup.log" \
    MIMIR_OFFSITE_STAMP="$TMP/backup.stamp" \
    MOCK_CURL_ARGV="$TMP/curl.argv" \
    MOCK_CURL_STDIN="$TMP/curl.stdin" \
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

: >"$TMP/curl.argv"
if BROKKR_OFFSITE_ENV_FILE="$VALID" PATH="$TMP/bin:$PATH" \
  MIMIR_OFFSITE_ROOT="$TMP/source" MIMIR_OFFSITE_REMOTE=test-crypt \
  MIMIR_OFFSITE_LOG="$TMP/backup.log" MIMIR_OFFSITE_STAMP="$TMP/backup.stamp" \
  RCLONE_BIN="$TMP/bin/rclone" MOCK_CURL_ARGV="$TMP/curl.argv" \
  MOCK_CURL_STDIN="$TMP/curl.stdin" bash "$SCRIPT" >"$TMP/no-panel.out" 2>&1; then no_panel_rc=0; else no_panel_rc=$?; fi
check "backup without panel credentials still succeeds" test "$no_panel_rc" -eq 0
check "backup without panel credentials skips curl" test ! -s "$TMP/curl.argv"

has_no_fleet_token_in_curl_argv() {
  ! grep -Fq 'offsite-fixture-token' "$TMP/curl.argv"
}
has_fleet_header_on_curl_stdin() {
  grep -Fqx 'Authorization: Bearer offsite-fixture-token' "$TMP/curl.stdin"
}
curl_uses_stdin_header_file() {
  grep -Fqx '@-' "$TMP/curl.argv"
}
file_lacks_bad_token() {
  ! grep -Fq 'bad' "$TMP/bad-token.out"
}

HEIMDALL_ENV="$TMP/heimdall.env"
cat >"$HEIMDALL_ENV" <<EOF
HEIMDALL_HUB_URL=https://heimdall.example/api/panels
HEIMDALL_FLEET_TOKEN=offsite-fixture-token
EOF
chmod 0600 "$HEIMDALL_ENV"
: >"$TMP/curl.argv"; : >"$TMP/curl.stdin"
if BROKKR_OFFSITE_ENV_FILE="$HEIMDALL_ENV" \
  PATH="$TMP/bin:$PATH" \
  BROKKR_TEST_MARKER="$TMP/executed" MIMIR_OFFSITE_ROOT="$TMP/source" \
  MIMIR_OFFSITE_REMOTE=test-crypt MIMIR_OFFSITE_LOG="$TMP/backup.log" \
  MIMIR_OFFSITE_STAMP="$TMP/backup.stamp" RCLONE_BIN="$TMP/bin/rclone" \
  MOCK_CURL_ARGV="$TMP/curl.argv" MOCK_CURL_STDIN="$TMP/curl.stdin" \
  bash "$SCRIPT" >"$TMP/panel-pass.out" 2>&1; then pass_rc=0; else pass_rc=$?; fi
check "backup completes with configured panel" test "$pass_rc" -eq 0
check "fleet token is absent from curl argv" has_no_fleet_token_in_curl_argv
check "fleet header reaches curl on stdin" has_fleet_header_on_curl_stdin
check "panel curl reads authorization header from stdin" curl_uses_stdin_header_file
check "success panel state is preserved" grep -Fq '"state":"pass"' "$TMP/curl.argv"

# Panel delivery is best-effort for both success and failure states.
: >"$TMP/curl.argv"; : >"$TMP/curl.stdin"
if BROKKR_OFFSITE_ENV_FILE="$HEIMDALL_ENV" MIMIR_OFFSITE_ROOT="$TMP/source" \
  PATH="$TMP/bin:$PATH" \
  MIMIR_OFFSITE_REMOTE=test-crypt MIMIR_OFFSITE_LOG="$TMP/backup.log" \
  MIMIR_OFFSITE_STAMP="$TMP/backup.stamp" RCLONE_BIN="$TMP/bin/rclone" \
  MOCK_CURL_ARGV="$TMP/curl.argv" MOCK_CURL_STDIN="$TMP/curl.stdin" MOCK_CURL_EXIT=28 \
  bash "$SCRIPT" >"$TMP/panel-curl-fail.out" 2>&1; then curl_fail_pass_rc=0; else curl_fail_pass_rc=$?; fi
check "curl failure on success panel does not fail backup" test "$curl_fail_pass_rc" -eq 0

: >"$TMP/curl.argv"; : >"$TMP/curl.stdin"
if BROKKR_OFFSITE_ENV_FILE="$HEIMDALL_ENV" MIMIR_OFFSITE_ROOT="$TMP/source" \
  PATH="$TMP/bin:$PATH" MIMIR_OFFSITE_REMOTE=test-crypt MIMIR_OFFSITE_LOG="$TMP/backup.log" \
  MIMIR_OFFSITE_STAMP="$TMP/backup.stamp" RCLONE_BIN="$TMP/bin/rclone" \
  MOCK_CURL_ARGV="$TMP/curl.argv" MOCK_CURL_STDIN="$TMP/curl.stdin" MOCK_CURL_EARLY_EXIT=1 \
  bash "$SCRIPT" >"$TMP/panel-curl-early.out" 2>&1; then curl_early_pass_rc=0; else curl_early_pass_rc=$?; fi
check "early panel curl exit does not fail backup" test "$curl_early_pass_rc" -eq 0
check "early panel curl exit cannot expose token in argv" has_no_fleet_token_in_curl_argv

: >"$TMP/curl.argv"; : >"$TMP/curl.stdin"
if BROKKR_OFFSITE_ENV_FILE="$HEIMDALL_ENV" MIMIR_OFFSITE_ROOT="$TMP/source" \
  PATH="$TMP/bin:$PATH" \
  MIMIR_OFFSITE_REMOTE=test-crypt MIMIR_OFFSITE_LOG="$TMP/backup.log" \
  MIMIR_OFFSITE_STAMP="$TMP/backup.stamp" RCLONE_BIN="$TMP/bin/rclone" \
  MOCK_CURL_ARGV="$TMP/curl.argv" MOCK_CURL_STDIN="$TMP/curl.stdin" MOCK_CURL_EXIT=28 MOCK_RCLONE_FAIL=mkdir \
  bash "$SCRIPT" >"$TMP/panel-fail.out" 2>&1; then curl_fail_error_rc=0; else curl_fail_error_rc=$?; fi
check "backup failure remains failed when fail-panel curl fails" test "$curl_fail_error_rc" -ne 0
check "fail-panel request also keeps fleet token out of curl argv" has_no_fleet_token_in_curl_argv
check "failure panel state is preserved" grep -Fq '"state":"fail"' "$TMP/curl.argv"

printf '%s\n' \
  'HEIMDALL_HUB_URL=https://heimdall.example/api/panels' \
  "HEIMDALL_FLEET_TOKEN='bad" \
  "token'" >"$TMP/bad-token.env"
chmod 0600 "$TMP/bad-token.env"
: >"$TMP/curl.argv"
if BROKKR_OFFSITE_ENV_FILE="$TMP/bad-token.env" MIMIR_OFFSITE_ROOT="$TMP/source" \
  PATH="$TMP/bin:$PATH" \
  MIMIR_OFFSITE_REMOTE=test-crypt MIMIR_OFFSITE_LOG="$TMP/backup.log" \
  MIMIR_OFFSITE_STAMP="$TMP/backup.stamp" RCLONE_BIN="$TMP/bin/rclone" \
  MOCK_CURL_ARGV="$TMP/curl.argv" MOCK_CURL_STDIN="$TMP/curl.stdin" \
  bash "$SCRIPT" >"$TMP/bad-token.out" 2>&1; then bad_token_rc=0; else bad_token_rc=$?; fi
check "line-broken fleet token does not change backup success" test "$bad_token_rc" -eq 0
check "line-broken fleet token causes no curl request" test ! -s "$TMP/curl.argv"
check "line-broken fleet token emits fixed diagnostic" grep -Fq 'WARN: Heimdall token contains a line break — skipping panel push' "$TMP/backup.log"
check "line-broken token value is not echoed" file_lacks_bad_token

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
