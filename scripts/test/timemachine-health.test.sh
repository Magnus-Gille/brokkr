#!/usr/bin/env bash
# Hermetic Time Machine truth-state tests. No real backups or tmutil calls.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../timemachine/check-health.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/tmutil" <<'EOF'
#!/usr/bin/env bash
case "${MOCK_TM_MODE:-path}" in
  path) printf '%s\n' "/Volumes/.timemachine/mock/2026-07-13-120000.backup" ;;
  malformed) printf '%s\n' "/Volumes/.timemachine/mock/not-a-timestamp.backup" ;;
  empty) : ;;
  fail) echo "backup destination unavailable" >&2; exit 72 ;;
esac
EOF
chmod +x "$TMP/bin/tmutil"
export PATH="$TMP/bin:$PATH"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run_check() {
  # shellcheck disable=SC2034 # assertions consume these through check/eval
  OUT="$(bash "$SCRIPT" 2>&1)"
  # shellcheck disable=SC2034 # assertions consume these through check/eval
  RC=$?
}
epoch() {
  date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null \
    || date -d "$1" +%s
}

echo "timemachine-health.test.sh"

export MOCK_TM_MODE=path BROKKR_TM_NOW_EPOCH
BROKKR_TM_NOW_EPOCH="$(epoch '2026-07-13 13:00:00')"
run_check
check "fresh successful query is pass" '[[ "$RC" -eq 0 && "$OUT" == OK:*"1h ago"* ]]'

BROKKR_TM_NOW_EPOCH="$(epoch '2026-07-14 15:00:00')"
run_check
check "proven stale backup is fail" '[[ "$RC" -eq 2 && "$OUT" == FAIL:*"27h ago"* ]]'

export MOCK_TM_MODE=empty
run_check
check "successful empty query proves no backups" '[[ "$RC" -eq 2 && "$OUT" == *"successfully reported no"* ]]'

export MOCK_TM_MODE=fail
run_check
check "tmutil failure is unknown, not a false no-backup claim" '[[ "$RC" -eq 1 && "$OUT" == WARN:*"state unknown"* ]]'

export MOCK_TM_MODE=malformed
run_check
check "unparseable latest backup is unknown" '[[ "$RC" -eq 1 && "$OUT" == WARN:*"could not be parsed"* ]]'

export MOCK_TM_MODE=path
BROKKR_TM_NOW_EPOCH="$(epoch '2026-07-13 11:00:00')"
run_check
check "future timestamp is unknown rather than fresh" '[[ "$RC" -eq 1 && "$OUT" == WARN:*"in the future"* ]]'

BROKKR_TM_MAX_AGE_HOURS=invalid run_check
check "invalid threshold is unknown and non-zero" '[[ "$RC" -eq 1 && "$OUT" == WARN:*"invalid BROKKR_TM_MAX_AGE_HOURS"* ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
