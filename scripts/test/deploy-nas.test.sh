#!/usr/bin/env bash
# Hermetic regression for the NAS deploy wrapper's final timer display. No network or systemd.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$HERE/../deploy-nas.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home"
CALLS="$TMP/calls"
: >"$CALLS"

cat >"$TMP/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >>"$MOCK_CALLS"
EOF

cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$1" >>"$MOCK_CALLS"
[[ "$#" -eq 2 ]] || exit 64
HOME="$MOCK_REMOTE_HOME" PATH="$MOCK_BIN:$PATH" bash -c "$2"
EOF

cat >"$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$MOCK_CALLS"
EOF

cat >"$TMP/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'mock journal'
EOF

cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
:
EOF

cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'list-timers brokkr-health.timer --no-pager') prefix=timer ;;
  'list-timers brokkr-systemd-failure-sweep.timer --no-pager') prefix=failure-monitor-timer ;;
  *) exit 64 ;;
esac
# More than a pipe buffer, with the production-observed failure code if a reader closes early.
trap 'exit 141' PIPE
for ((i = 1; i <= 20000; i++)); do
  printf '%s-%06d\n' "$prefix" "$i"
done
printf '%s\n' complete >"$MOCK_PRODUCER_STATE"
EOF

chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
export MOCK_BIN="$TMP/bin" MOCK_CALLS="$CALLS" MOCK_REMOTE_HOME="$TMP/home"
export MOCK_PRODUCER_STATE="$TMP/producer-state"
export BROKKR_SSH_TARGET="brokkr@nas-host" BROKKR_REMOTE_DIR="/opt/brokkr"
export BROKKR_HEIMDALL_SOURCE_ENV="$TMP/missing-heimdall.env"

# shellcheck disable=SC2034 # assertions consume these through check/eval
OUT="$(bash "$DEPLOY" 2>&1)"
# shellcheck disable=SC2034 # assertions consume these through check/eval
RC=$?

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "deploy-nas.test.sh"
check "deploy reaches success after the timer display" '[[ "$RC" -eq 0 && "$OUT" == *"==> Done."* ]]'
check "timer display keeps exactly two rows" '[[ "$(grep -c "^timer-" <<<"$OUT")" -eq 2 ]]'
check "timer display starts at the first row" 'grep -q "^timer-000001$" <<<"$OUT" && grep -q "^timer-000002$" <<<"$OUT"'
check "failure-monitor timer display is included" 'grep -q "^failure-monitor-timer-000001$" <<<"$OUT" && grep -q "^failure-monitor-timer-000002$" <<<"$OUT"'
check "timer producer is consumed rather than closed early" '[[ "$(cat "$MOCK_PRODUCER_STATE" 2>/dev/null)" == complete ]]'
check "rsync and ssh are mocked rather than reaching a host" '[[ "$(grep -c "^rsync " "$CALLS")" -eq 1 && "$(grep -c "^ssh " "$CALLS")" -eq 1 ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
