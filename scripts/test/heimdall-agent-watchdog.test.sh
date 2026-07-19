#!/usr/bin/env bash
# Brokkr · unit test for scripts/heimdall-agent-watchdog.sh (brokkr#14).
# No real agent/systemd needed: a fake `systemctl` on PATH records restarts and
# reports active/inactive from env. Runs on macOS (BSD) and Linux (GNU).
#
#   ./scripts/test/heimdall-agent-watchdog.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$HERE/../heimdall-agent-watchdog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── fake systemctl: matches the EXACT argv the watchdog is expected to use, so a
#    script that talks to the wrong bus/unit fails loudly instead of passing. ────
mkdir -p "$TMP/bin"
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
argv="$*"
case "$argv" in
  "--user is-active --quiet heimdall-agent") exit "${MOCK_ACTIVE_RC:-0}" ;;
  "--user restart heimdall-agent") echo "restart" >>"$MOCK_RESTART_LOG"; exit "${MOCK_RESTART_RC:-0}" ;;
  *) echo "UNEXPECTED: $argv" >>"$MOCK_UNEXPECTED_LOG"; exit 3 ;;
esac
EOF
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

RESTART_LOG="$TMP/restarts.log"
UNEXPECTED_LOG="$TMP/unexpected.log"
export MOCK_RESTART_LOG="$RESTART_LOG" MOCK_UNEXPECTED_LOG="$UNEXPECTED_LOG"
: >"$RESTART_LOG"; : >"$UNEXPECTED_LOG"
export HEIMDALL_AGENT_STATE_DIR="$TMP/state"
export HEIMDALL_AGENT_STALE_SECS=150
mkdir -p "$HEIMDALL_AGENT_STATE_DIR"
HB="$HEIMDALL_AGENT_STATE_DIR/last-push"
MARKER="$HEIMDALL_AGENT_STATE_DIR/watchdog-last-restart"

set_mtime() { python3 -c 'import os,sys; t=float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
now() { date +%s; }
reset() { rm -f "$HB" "$MARKER"; : >"$RESTART_LOG"; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
restarts() { wc -l <"$RESTART_LOG" | tr -d ' '; }

# run [env-overrides...] -- ; sets OUT and RC
run() { OUT="$(bash "$WATCHDOG" 2>&1)"; RC=$?; }

check() { # desc want_restarts want_grep
  local desc="$1" want="$2" pat="${3:-}"
  local got; got="$(restarts)"
  [ "$RC" -eq 0 ]        || { bad "$desc (exit rc=$RC, want 0)"; return; }
  [ "$got" -eq "$want" ] || { bad "$desc (restarts want $want got $got)"; return; }
  if [ -n "$pat" ] && ! grep -q "$pat" <<<"$OUT"; then bad "$desc (missing '/$pat/' in output)"; return; fi
  ok "$desc"
}

echo "heimdall-agent-watchdog.test.sh"

# 1) fresh heartbeat + active  -> no restart
export MOCK_ACTIVE_RC=0
reset; touch "$HB"; set_mtime "$HB" "$(now)"
run; check "fresh heartbeat, active -> no restart" 0 'ok: last push'

# 2) stale heartbeat + active  -> restart (and marker stamped)
reset; touch "$HB"; set_mtime "$HB" "$(( $(now) - 300 ))"
run; check "stale heartbeat (300s), active -> restart" 1 'WEDGE'
[ -f "$MARKER" ] && ok "restart stamps cooldown marker" || bad "restart did not stamp cooldown marker"

# 3) stale heartbeat but within cooldown (marker fresh) -> NO restart (anti-storm)
: >"$RESTART_LOG"; touch "$MARKER"; set_mtime "$MARKER" "$(now)"   # just restarted
touch "$HB"; set_mtime "$HB" "$(( $(now) - 300 ))"                 # still stale
run; check "stale but restarted <cooldown ago -> skip" 0 'skip:'

# 4) stale heartbeat, cooldown elapsed -> restart again
reset; touch "$HB"; set_mtime "$HB" "$(( $(now) - 300 ))"
touch "$MARKER"; set_mtime "$MARKER" "$(( $(now) - 1000 ))"        # older than 900s default
run; check "stale, cooldown elapsed -> restart" 1 'WEDGE'

# 5) absent heartbeat + active -> no restart (safe no-op)
reset
run; check "absent heartbeat, active -> no restart" 0 'absent'

# 6) stale heartbeat but unit INACTIVE -> no restart
export MOCK_ACTIVE_RC=1
reset; touch "$HB"; set_mtime "$HB" "$(( $(now) - 300 ))"
run; check "stale heartbeat but inactive unit -> no restart" 0 'not active'
export MOCK_ACTIVE_RC=0

# 7) invalid STALE_SECS -> logged no-op, exit 0
reset; touch "$HB"; set_mtime "$HB" "$(( $(now) - 300 ))"
HEIMDALL_AGENT_STALE_SECS=abc run; check "non-numeric STALE_SECS -> no-op" 0 'invalid HEIMDALL_AGENT_STALE_SECS'
HEIMDALL_AGENT_STALE_SECS=0   run; check "zero STALE_SECS -> no-op"        0 'invalid HEIMDALL_AGENT_STALE_SECS'

# 8) unset HOME/XDG/STATE_DIR while active -> no-op, exit 0 (no set -u abort)
: >"$RESTART_LOG"
OUT="$(env -u HOME -u XDG_STATE_HOME -u HEIMDALL_AGENT_STATE_DIR \
        PATH="$PATH" MOCK_ACTIVE_RC=0 MOCK_RESTART_LOG="$RESTART_LOG" MOCK_UNEXPECTED_LOG="$UNEXPECTED_LOG" \
        bash "$WATCHDOG" 2>&1)"; RC=$?
check "unset HOME/XDG/STATE_DIR, active -> no-op exit 0" 0 'cannot resolve state dir'

# 9) the mock never saw an unexpected systemctl argv (wrong bus/unit)
if [ -s "$UNEXPECTED_LOG" ]; then bad "unexpected systemctl calls: $(cat "$UNEXPECTED_LOG")"; else ok "no unexpected systemctl argv"; fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
