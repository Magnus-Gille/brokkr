#!/usr/bin/env bash
# Hermetic offline-rotation freshness tests. No disks, hosts, network, or systemd.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../offline-rotation-freshness.sh"
# Every fixture path is built under $TMP, so stop before anything else if it is unusable.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-offline-fresh.XXXXXX")" || exit 1
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "cannot create test workspace" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

NOW=1800000000
DAY=86400
FORMAT_LINE='format=brokkr-offline-rotation-receipt-v1'
TOKEN='test-token-do-not-leak-0123456789'

# Mock Heimdall push: records argv, panel env, and a copy of the snapshot.
cat > "$TMP/bin/push.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_PUSH_ARGV"
{
  printf 'panel=%s\n' "${BROKKR_HEIMDALL_PANEL:-}"
  printf 'label=%s\n' "${BROKKR_HEIMDALL_LABEL:-}"
  printf 'prefix=%s\n' "${BROKKR_HEIMDALL_STAMP_PREFIX:-}"
  printf 'state=%s\n' "${BROKKR_STATE_DIR:-}"
} > "$MOCK_PUSH_ENV"
[ -f "${1:-}" ] && cp "$1" "$MOCK_PUSH_SNAP"
exit "${MOCK_PUSH_RC:-0}"
EOF
chmod +x "$TMP/bin/push.sh"
export MOCK_PUSH_ARGV="$TMP/push.argv" MOCK_PUSH_ENV="$TMP/push.env" MOCK_PUSH_SNAP="$TMP/push.snapshot"

unset BROKKR_OFFLINE_ENV_FILE BROKKR_OFFLINE_MAX_AGE_DAYS HEIMDALL_HUB_URL HEIMDALL_FLEET_TOKEN \
  BROKKR_HEIMDALL_PUSH BROKKR_STATE_DIR
export BROKKR_OFFLINE_NOW_EPOCH="$NOW"

new_dir() {
  RDIR="$TMP/receipts.$1"
  rm -rf "$RDIR"
  mkdir -p "$RDIR"
  export BROKKR_OFFLINE_RECEIPT_DIR="$RDIR"
}
# mk_receipt NAME EPOCH
mk_receipt() {
  printf '%s\ncompleted_epoch=%s\nluks_uuid=ignored\n' "$FORMAT_LINE" "$2" > "$RDIR/$1"
}
run_check() {
  # shellcheck disable=SC2034 # assertions consume these through check/eval
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  # shellcheck disable=SC2034 # assertions consume these through check/eval
  RC=$?
}

echo "offline-rotation-freshness.test.sh"

new_dir fresh
mk_receipt 2026-10-20T120000Z.receipt $((NOW - 5 * DAY))
run_check
check "fresh receipt is OK with age and basename" \
  '[[ "$RC" -eq 0 && "$OUT" == "OK: last offline rotation 5d ago (2026-10-20T120000Z.receipt)" ]]'

new_dir stale
mk_receipt 2026-06-01T120000Z.receipt $((NOW - 120 * DAY))
run_check
check "stale receipt is WARN with day count" \
  '[[ "$RC" -eq 1 && "$OUT" == WARN:*"120d ago (>= 90d)"*"rotate the offline disk"* ]]'

new_dir default
mk_receipt a.receipt $((NOW - 89 * DAY))
run_check
check "default threshold 90: 89d is OK" '[[ "$RC" -eq 0 && "$OUT" == OK:*"89d ago"* ]]'
mk_receipt a.receipt $((NOW - 90 * DAY))
run_check
check "default threshold 90: 90d is WARN" '[[ "$RC" -eq 1 && "$OUT" == WARN:*"90d ago (>= 90d)"* ]]'
BROKKR_OFFLINE_MAX_AGE_DAYS=100 run_check
check "explicit threshold is honoured" '[[ "$RC" -eq 0 && "$OUT" == OK:*"90d ago"* ]]'

new_dir numeric
# Lexicographic order of both name and epoch disagrees with numeric order.
mk_receipt 2026-99-zzz.receipt 999999999
mk_receipt 2026-01-aaa.receipt $((NOW - 3 * DAY))
run_check
check "newest chosen by numeric epoch, not filename or string order" \
  '[[ "$RC" -eq 0 && "$OUT" == OK:*"3d ago (2026-01-aaa.receipt)" ]]'

new_dir empty
run_check
check "empty readable dir proves absence: FAIL exit 2" \
  '[[ "$RC" -eq 2 && "$OUT" == "FAIL: no offline rotation receipts in $RDIR" ]]'

BROKKR_OFFLINE_RECEIPT_DIR="$TMP/does-not-exist" run_check
check "missing dir is unknown: WARN exit 1" '[[ "$RC" -eq 1 && "$OUT" == WARN:*"state unknown"* ]]'

new_dir malformed
printf 'format=wrong\ncompleted_epoch=%s\n' "$((NOW - DAY))" > "$RDIR/bad-format.receipt"
printf '%s\nother=1\n' "$FORMAT_LINE" > "$RDIR/no-epoch.receipt"
printf '%s\ncompleted_epoch=12x\n' "$FORMAT_LINE" > "$RDIR/bad-epoch.receipt"
printf '%s\ncompleted_epoch=%s\ncompleted_epoch=%s\n' "$FORMAT_LINE" "$((NOW - DAY))" "$((NOW - 2 * DAY))" > "$RDIR/dup-epoch.receipt"
printf 'completed_epoch=%s\n%s\n' "$((NOW - DAY))" "$FORMAT_LINE" > "$RDIR/format-not-first.receipt"
run_check
check "only malformed receipts: WARN unknown, exit 1" \
  '[[ "$RC" -eq 1 && "$OUT" == WARN:*"no valid"*"state unknown"* ]]'
mk_receipt good.receipt $((NOW - 4 * DAY))
run_check
check "malformed receipts ignored when a valid one exists" \
  '[[ "$RC" -eq 0 && "$OUT" == OK:*"4d ago (good.receipt)" ]]'

new_dir future
mk_receipt future.receipt $((NOW + DAY))
run_check
check "future epoch is WARN, not fresh" '[[ "$RC" -eq 1 && "$OUT" == WARN:*"future"* ]]'

new_dir maxage
mk_receipt a.receipt $((NOW - DAY))
for v in abc 0 -5 3651 1.5 ""; do
  BROKKR_OFFLINE_MAX_AGE_DAYS="$v" run_check
  check "invalid max age '$v' is WARN exit 1" \
    '[[ "$RC" -eq 1 && "$OUT" == "WARN: invalid BROKKR_OFFLINE_MAX_AGE_DAYS; offline rotation state unknown" ]]'
done
BROKKR_OFFLINE_MAX_AGE_DAYS=3650 run_check
check "max age 3650 is accepted" '[[ "$RC" -eq 0 ]]'
BROKKR_OFFLINE_NOW_EPOCH=12x run_check
check "invalid now override is WARN exit 1" '[[ "$RC" -eq 1 && "$OUT" == WARN:* ]]'

new_dir symlink
mkdir -p "$TMP/outside"
printf '%s\ncompleted_epoch=%s\n' "$FORMAT_LINE" "$((NOW - DAY))" > "$TMP/outside/newer.receipt"
ln -s "$TMP/outside/newer.receipt" "$RDIR/2026-10-24T000000Z.receipt"
run_check
check "symlink-only receipts are not trusted: WARN exit 1" '[[ "$RC" -eq 1 && "$OUT" == WARN:* ]]'
mk_receipt real.receipt $((NOW - 10 * DAY))
run_check
check "symlinked receipt ignored in favour of regular file" \
  '[[ "$RC" -eq 0 && "$OUT" == OK:*"10d ago (real.receipt)" ]]'

new_dir envfile
mk_receipt a.receipt $((NOW - 20 * DAY))
MARK="$TMP/env-marker"
printf 'touch "%s"\nBROKKR_OFFLINE_MAX_AGE_DAYS=10\n' "$MARK" > "$TMP/bad.env"
chmod 644 "$TMP/bad.env"
BROKKR_OFFLINE_ENV_FILE="$TMP/bad.env" run_check
check "rejected (0644) env file is WARN exit 1" '[[ "$RC" -eq 1 && "$OUT" == *WARN:* ]]'
check "rejected env file was not executed" '[[ ! -e "$MARK" ]]'
printf 'BROKKR_OFFLINE_MAX_AGE_DAYS=10\n' > "$TMP/good.env"
chmod 600 "$TMP/good.env"
BROKKR_OFFLINE_ENV_FILE="$TMP/good.env" run_check
check "private env file is sourced (threshold 10d makes 20d stale)" \
  '[[ "$RC" -eq 1 && "$OUT" == WARN:*"20d ago (>= 10d)"* ]]'
BROKKR_OFFLINE_ENV_FILE="$TMP/absent.env" run_check
check "missing env file that was requested is WARN exit 1" '[[ "$RC" -eq 1 && "$OUT" == *WARN:* ]]'

# --- --push -----------------------------------------------------------------
export HEIMDALL_HUB_URL="https://hub.example.invalid" HEIMDALL_FLEET_TOKEN="$TOKEN"
export BROKKR_HEIMDALL_PUSH="$TMP/bin/push.sh" BROKKR_STATE_DIR="$TMP/state"
SNAP="$TMP/state/offline-rotation.json"
reset_push() { rm -f "$MOCK_PUSH_ARGV" "$MOCK_PUSH_ENV" "$MOCK_PUSH_SNAP" "$SNAP"; unset MOCK_PUSH_RC; }

new_dir pushpass
mk_receipt a.receipt $((NOW - 2 * DAY))
reset_push
run_check --push
check "--push pass: exit 0" '[[ "$RC" -eq 0 ]]'
check "--push pass: snapshot status pass with check name" \
  'grep -q "\"status\":\"pass\"" "$MOCK_PUSH_SNAP" && grep -q "\"name\":\"offline-rotation\"" "$MOCK_PUSH_SNAP"'
check "--push snapshot shape (brokkr/grimnir/platform)" \
  'grep -q "\"name\":\"brokkr\"" "$MOCK_PUSH_SNAP" && grep -q "\"namespace\":\"grimnir\"" "$MOCK_PUSH_SNAP" && grep -q "\"kind\":\"platform\"" "$MOCK_PUSH_SNAP"'
check "--push published snapshot at state path and passed it as argv" \
  '[[ -f "$SNAP" && "$(cat "$MOCK_PUSH_ARGV")" == "$SNAP" ]]'
check "--push exports panel/label/prefix/state env" \
  'grep -qx "panel=offline-rotation" "$MOCK_PUSH_ENV" && grep -qx "label=Offline Rotation Disk" "$MOCK_PUSH_ENV" && grep -qx "prefix=offline-rotation-" "$MOCK_PUSH_ENV" && grep -qx "state=$TMP/state" "$MOCK_PUSH_ENV"'
check "--push does not expose the token" \
  '! grep -q "$TOKEN" "$MOCK_PUSH_ARGV" && [[ "$OUT" != *"$TOKEN"* ]]'

new_dir pushwarn
mk_receipt a.receipt $((NOW - 200 * DAY))
reset_push
run_check --push
check "--push stale: delivered WARN observation exits 0" '[[ "$RC" -eq 0 && "$OUT" == *WARN:* ]]'
check "--push stale: snapshot status warn" 'grep -q "\"status\":\"warn\"" "$MOCK_PUSH_SNAP"'

new_dir pushfail
reset_push
run_check --push
check "--push proven absence: delivered, exit 0" '[[ "$RC" -eq 0 ]]'
check "--push proven absence: snapshot status fail" 'grep -q "\"status\":\"fail\"" "$MOCK_PUSH_SNAP"'

new_dir pushnocfg
mk_receipt a.receipt $((NOW - DAY))
reset_push
HEIMDALL_FLEET_TOKEN="" run_check --push
check "--push without Heimdall config exits 2, no push" '[[ "$RC" -eq 2 && ! -e "$MOCK_PUSH_ARGV" ]]'
HEIMDALL_HUB_URL="" run_check --push
check "--push without hub URL exits 2" '[[ "$RC" -eq 2 ]]'

reset_push
MOCK_PUSH_RC=7 run_check --push
check "--push with failing push exits non-zero" '[[ "$RC" -ne 0 ]]'

reset_push
run_check --bogus
check "unknown argument exits 64" '[[ "$RC" -eq 64 && ! -e "$MOCK_PUSH_ARGV" ]]'
run_check --push extra
check "extra argument exits 64" '[[ "$RC" -eq 64 ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
