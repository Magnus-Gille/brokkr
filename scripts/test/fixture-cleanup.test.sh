#!/usr/bin/env bash
# Hermetic regression coverage for bounded test-fixture cleanup.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/test/lib/fixture-cleanup.sh
source "$HERE/lib/fixture-cleanup.sh"

TMP="$(mktemp -d)"
readonly TMP
FIXTURE_PARENTS=()
cleanup() {
  /bin/rm -rf -- "$TMP"
  local parent
  for parent in "${FIXTURE_PARENTS[@]}"; do
    /bin/rm -rf -- "$parent"
  done
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cat >"$TMP/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_RM_CALLS:?}"
: "${MOCK_RM_MODE:?}"
: "${MOCK_RM_STATE:?}"
: "${MOCK_RM_TARGET:?}"
: "${MOCK_RM_REPLACEMENT_TARGET:?}"
printf '%s\n' "$*" >>"$MOCK_RM_CALLS"
[[ "$#" -eq 3 && "$1" == -rf && "$2" == -- && "$3" != "$MOCK_RM_TARGET" ]]
count=$(<"$MOCK_RM_STATE")
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_RM_STATE"
if [[ "$MOCK_RM_MODE" == transient && "$count" -eq 1 ]]; then
  mkdir -p "$MOCK_RM_REPLACEMENT_TARGET"
  printf 'replacement\n' >"$MOCK_RM_REPLACEMENT_TARGET/marker"
  printf 'rm: %s: Directory not empty\n' "$MOCK_RM_TARGET" >&2
  exit 1
fi
if [[ "$MOCK_RM_MODE" == persistent ]]; then
  printf 'rm: %s: simulated persistent failure\n' "$MOCK_RM_TARGET" >&2
  exit 1
fi
/bin/rm -rf -- "$3"
EOF
chmod 700 "$TMP/rm"

cat >"$TMP/runner.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

HERE="$1"; fixture_target="$2"; requested_status="$3"
readonly fixture_target
# shellcheck source=/dev/null
source "$HERE/lib/fixture-cleanup.sh"
trap 'fixture_cleanup_on_exit "$fixture_target"' EXIT
exit "$requested_status"
EOF
chmod 700 "$TMP/runner.sh"

new_fixture() {
  local fixture
  fixture="$(fixture_cleanup_alloc)"
  mkdir -p "$fixture/.git"
  printf 'fixture\n' >"$fixture/.git/marker"
  printf '%s\n' "$fixture"
}

run_case() {
  local mode=$1 requested_status=$2 fixture=$3
  local state="$TMP/state-$mode-$requested_status" calls="$TMP/calls-$mode-$requested_status"
  printf '0\n' >"$state"
  : >"$calls"
  MOCK_RM_MODE="$mode" MOCK_RM_STATE="$state" MOCK_RM_CALLS="$calls" \
    MOCK_RM_TARGET="$fixture" MOCK_RM_REPLACEMENT_TARGET="$fixture" PATH="$TMP:$PATH" \
    bash "$TMP/runner.sh" "$ROOT/scripts/test" "$fixture" "$requested_status" \
    >"$TMP/out-$mode-$requested_status" 2>&1
}
first_call_target() { awk 'NR == 1 { print $3; exit }' "$1"; }

echo fixture-cleanup.test.sh

# These are all deliberately outside the allocation contract.
ordinary="$TMP/fixture.ABCDEF"
missing="$TMP/fixture.ABCDEG"
broad_parent="$TMP/broad-parent"
broad_target="$broad_parent/fixture.ABCDEH"
mkdir -p "$ordinary" "$broad_parent" "$broad_target"
chmod 755 "$broad_parent"
# shellcheck disable=SC2034 # assertion expressions consume these through eval
if fixture_cleanup_dir "" 2>/dev/null; then empty_rc=0; else empty_rc=$?; fi
# shellcheck disable=SC2034 # assertion expressions consume these through eval
if fixture_cleanup_dir / 2>/dev/null; then root_rc=0; else root_rc=$?; fi
# shellcheck disable=SC2034 # assertion expressions consume these through eval
if fixture_cleanup_dir /tmp 2>/dev/null; then tmp_rc=0; else tmp_rc=$?; fi
# shellcheck disable=SC2034 # assertion expressions consume these through eval
if fixture_cleanup_dir "$ordinary" 2>/dev/null; then ordinary_rc=0; else ordinary_rc=$?; fi
# shellcheck disable=SC2034 # assertion expressions consume these through eval
if fixture_cleanup_dir "$missing" 2>/dev/null; then missing_rc=0; else missing_rc=$?; fi
# shellcheck disable=SC2034 # assertion expressions consume these through eval
if fixture_cleanup_dir "$broad_target" 2>/dev/null; then broad_rc=0; else broad_rc=$?; fi
check "cleanup refuses empty target" '[[ "$empty_rc" -ne 0 ]]'
check "cleanup refuses root" '[[ "$root_rc" -ne 0 ]]'
check "cleanup refuses broad system temp parent" '[[ "$tmp_rc" -ne 0 ]]'
check "cleanup refuses ordinary existing directory" '[[ "$ordinary_rc" -ne 0 && -d "$ordinary" ]]'
check "cleanup refuses missing target" '[[ "$missing_rc" -ne 0 ]]'
check "cleanup refuses non-private parent" '[[ "$broad_rc" -ne 0 && -d "$broad_target" ]]'

outside="$TMP/outside"
link="$TMP/link"
mkdir -p "$outside"
printf 'protected\n' >"$outside/marker"
ln -s "$outside" "$link"
# shellcheck disable=SC2034 # assertion expressions consume unsafe_rc through eval
if fixture_cleanup_dir "$link"; then unsafe_rc=0; else unsafe_rc=$?; fi
check "cleanup refuses a symlink target" '[[ "$unsafe_rc" -ne 0 && -L "$link" ]]'
check "cleanup refusal leaves symlink destination untouched" '[[ -f "$outside/marker" ]]'

fixture="$(new_fixture)"
FIXTURE_PARENTS+=("${fixture%/*}")
# shellcheck disable=SC2034 # assertion expressions consume these through eval
if run_case transient 17 "$fixture"; then transient_rc=0; else transient_rc=$?; fi
check "transient cleanup preserves assertion status" '[[ "$transient_rc" -eq 17 ]]'
check "transient cleanup retries quarantined identity" '[[ "$(cat "$TMP/state-transient-17")" -eq 2 && ! -e "$(first_call_target "$TMP/calls-transient-17")" ]]'
check "transient cleanup preserves replacement at original path" '[[ -f "$fixture/marker" ]]'
check "transient cleanup attributes preserved replacement" 'grep -q "fixture cleanup preserved replacement at" "$TMP/out-transient-17"'
check "transient cleanup has no final failure attribution" '! grep -q "fixture cleanup failed" "$TMP/out-transient-17"'
check "transient cleanup lists the replacement residue" 'grep -q "residue: marker" "$TMP/out-transient-17"'

mkdir -p "$TMP/unrelated"
printf 'protected\n' >"$TMP/unrelated/marker"
fixture="$(new_fixture)"
FIXTURE_PARENTS+=("${fixture%/*}")
# shellcheck disable=SC2034 # assertion expressions consume these through eval
if run_case persistent 23 "$fixture"; then persistent_rc=0; else persistent_rc=$?; fi
check "persistent cleanup preserves assertion status" '[[ "$persistent_rc" -eq 23 ]]'
check "persistent cleanup is bounded" '[[ "$(cat "$TMP/state-persistent-23")" -eq 3 ]]'
check "persistent cleanup attributes final failure" 'grep -q "fixture cleanup failed after 3 attempts" "$TMP/out-persistent-23"'
check "persistent cleanup passes only the quarantined target" '[[ "$(grep -Fc -- "-rf -- $fixture" "$TMP/calls-persistent-23")" -eq 0 ]]'
check "persistent cleanup leaves quarantined fixture intact" '[[ -d "$(first_call_target "$TMP/calls-persistent-23")" ]]'
check "persistent cleanup leaves unrelated data intact" '[[ -f "$TMP/unrelated/marker" ]]'
check "persistent cleanup lists residue for attribution" 'grep -q "residue: .git/marker" "$TMP/out-persistent-23"'
check "persistent cleanup residue stays relative to the fixture" '! grep -q "residue: /" "$TMP/out-persistent-23"'

fixture="$(new_fixture)"
FIXTURE_PARENTS+=("${fixture%/*}")
# shellcheck disable=SC2034 # assertion expressions consume these through eval
if run_case persistent 0 "$fixture"; then clean_rc=0; else clean_rc=$?; fi
check "cleanup failure makes otherwise passing test fail" '[[ "$clean_rc" -eq 1 ]]'
check "passing test cleanup failure is attributed" 'grep -q "fixture cleanup failed after 3 attempts" "$TMP/out-persistent-0"'

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
