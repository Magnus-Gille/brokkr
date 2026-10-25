#!/usr/bin/env bash
# Hermetic gates for launchd/install-agent-cli-update.sh and its plist. uname and launchctl are
# fakes on PATH, HOME is a temp directory, and the offsite-photos installer is not touched. No
# agent is ever loaded into the real launchd.
# shellcheck disable=SC2016,SC2034 # assertions are evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/test/lib/fixture-cleanup.sh
source "$HERE/lib/fixture-cleanup.sh"
TMP="$(fixture_cleanup_alloc)"
trap 'fixture_cleanup_on_exit "$TMP"' EXIT

INSTALL="$ROOT/launchd/install-agent-cli-update.sh"
PLIST_SRC="$ROOT/launchd/io.grimnir.brokkr.agent-cli-update.plist"
LABEL=io.grimnir.brokkr.agent-cli-update
BIN="$TMP/bin"; HOME_DIR="$TMP/home"; CALLS="$TMP/calls"
DEST="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$BIN" "$HOME_DIR"

cat >"$BIN/uname" <<'FAKE'
#!/bin/sh
if [ "${1:-}" = -s ]; then echo "${MOCK_UNAME:-Darwin}"; exit 0; fi
exec /usr/bin/uname "$@"
FAKE
cat >"$BIN/launchctl" <<'FAKE'
#!/bin/sh
printf 'launchctl %s\n' "$*" >>"$MOCK_CALLS"
case "${1:-}" in
  bootout) exit "${MOCK_BOOTOUT_RC:-0}" ;;
  print) printf '\tstate = waiting\n\tprogram = /x/agent-cli-update.sh\n\tlast exit code = 0\n' ;;
esac
exit 0
FAKE
chmod 755 "$BIN/"*
export MOCK_CALLS="$CALLS"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; printf '        rc=%s out=%s\n' "${RC:-}" "${OUT:-}" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() { OUT="$(HOME="${RUN_HOME:-$HOME_DIR}" PATH="$BIN:$PATH" "$INSTALL" "$@" 2>&1)"; RC=$?; }
reset() { rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR"; : >"$CALLS"; unset MOCK_UNAME MOCK_BOOTOUT_RC RUN_HOME; }
have_python() { command -v python3 >/dev/null 2>&1; }

echo "launchd-agent-cli-update.test.sh"

# --- the versioned plist ---------------------------------------------------------------------
check "the plist runs the updater from the repo checkout" 'grep -Fq "<string>__BROKKR_DIR__/scripts/agent-cli-update.sh</string>" "$PLIST_SRC"'
check "the plist ships placeholders, not machine paths" '! grep -Eq "/Users/|/home/" "$PLIST_SRC"'
if have_python; then
  cat >"$TMP/plist-check.py" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
assert d["Label"] == sys.argv[2]
assert d["ProgramArguments"] == ["__BROKKR_DIR__/scripts/agent-cli-update.sh"]
assert d["StartCalendarInterval"] == [{"Hour": h, "Minute": 17} for h in (4, 10, 16, 22)]
assert d["RunAtLoad"] is False
assert d["ProcessType"] == "Background" and d["LowPriorityIO"] is True and d["Nice"] == 10
assert d["EnvironmentVariables"]["PATH"] == "__HOME__/.local/bin:__HOME__/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
assert d["StandardOutPath"] == d["StandardErrorPath"] == "__HOME__/Library/Logs/brokkr/agent-cli-update.launchd.log"
PY
  check "the plist parses and carries the four daily firings, no RunAtLoad, and low priority" 'python3 -I "$TMP/plist-check.py" "$PLIST_SRC" "$LABEL"'
else
  printf '  SKIP  plist structure (python3 unavailable)\n'
fi

# --- install ---------------------------------------------------------------------------------------
reset
run
check "install exits 0 and renders into ~/Library/LaunchAgents" '[[ "$RC" -eq 0 && -f "$DEST" ]]'
check "install leaves no placeholder behind and points at this checkout and HOME" '! grep -q "__[A-Z_]*__" "$DEST" && grep -Fq "<string>$ROOT/scripts/agent-cli-update.sh</string>" "$DEST" && grep -Fq "$HOME_DIR/Library/Logs/brokkr/agent-cli-update.launchd.log" "$DEST"'
check "install creates the log directory and a 0644 plist" '[[ -d "$HOME_DIR/Library/Logs/brokkr" ]] && [[ "$(stat -c %a "$DEST" 2>/dev/null || stat -f %Lp "$DEST")" == 644 ]]'
check "install boots out, then bootstraps, then enables, in the gui domain" '[[ "$(grep -n "^launchctl bootout" "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n "^launchctl bootstrap" "$CALLS" | head -1 | cut -d: -f1)" ]] && grep -Fxq "launchctl bootstrap gui/$(id -u) $DEST" "$CALLS" && grep -Fxq "launchctl enable gui/$(id -u)/$LABEL" "$CALLS"'
check "install never starts a run" '! grep -q "^launchctl kickstart" "$CALLS"'
if have_python; then
  check "the rendered plist parses" 'python3 -I -c "import plistlib,sys; plistlib.load(open(sys.argv[1], \"rb\"))" "$DEST"'
fi
reset; MOCK_BOOTOUT_RC=3 run install
check "a bootout of a not-loaded agent is not an error" '[[ "$RC" -eq 0 ]] && grep -q "^launchctl bootstrap" "$CALLS"'

# --- run, status, uninstall -----------------------------------------------------------------------
reset; run run
check "run kicks a run without -k so an update in progress is not killed" '[[ "$RC" -eq 0 ]] && grep -Fxq "launchctl kickstart gui/$(id -u)/$LABEL" "$CALLS" && ! grep -q "kickstart -k" "$CALLS"'
reset; run status
check "status reports the agent state" '[[ "$RC" -eq 0 && "$OUT" == *"last exit code = 0"* ]]'
reset; run install; : >"$CALLS"; run uninstall
check "uninstall boots the agent out and removes the plist" '[[ "$RC" -eq 0 && ! -e "$DEST" ]] && grep -Fxq "launchctl bootout gui/$(id -u)/$LABEL" "$CALLS"'
reset; run bogus
check "an unknown command exits 2 with usage" '[[ "$RC" -eq 2 && "$OUT" == *usage* ]] && [[ ! -s "$CALLS" ]]'

# --- refusals ---------------------------------------------------------------------------------------
reset; export MOCK_UNAME=Linux
run
check "a non-Darwin host refuses before touching launchd" '[[ "$RC" -eq 1 && "$OUT" == *macOS-only* ]] && [[ ! -s "$CALLS" && ! -e "$DEST" ]]'
reset
mkdir -p "$TMP/home&evil"
RUN_HOME="$TMP/home&evil" run
check "a HOME that would corrupt the sed rendering is refused" '[[ "$RC" -eq 1 && "$OUT" == *"cannot be rendered"* ]] && [[ ! -s "$CALLS" ]]'

# --- the offsite-photos installer is untouched ----------------------------------------------------
check "install.sh still manages only the offsite-photos agent" 'grep -Fq "LABEL=\"io.grimnir.brokkr.offsite-photos\"" "$ROOT/launchd/install.sh" && ! grep -q agent-cli-update "$ROOT/launchd/install.sh"'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
