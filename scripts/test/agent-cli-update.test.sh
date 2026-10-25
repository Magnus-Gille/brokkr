#!/usr/bin/env bash
# Hermetic gates for scripts/agent-cli-update.sh. npm, brew, node, dpkg-query, systemctl and the
# four agent CLIs are stubs on PATH that log their argv to a file; HOME, the cgroup tree and the
# systemd unit state are temp directories. Nothing real is installed, updated, or queried.
# Set BASH_UNDER_TEST to run the updater with another bash (for example /bin/bash 3.2).
# shellcheck disable=SC2016,SC2034 # assertions are evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/test/lib/fixture-cleanup.sh
source "$HERE/lib/fixture-cleanup.sh"
TMP="$(fixture_cleanup_alloc)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; fixture_cleanup_on_exit "$TMP"' EXIT
# Tool paths are compared after symlink resolution (macOS /var is a symlink).
TMP="$(cd "$TMP" && pwd -P)"

SCRIPT="$ROOT/scripts/agent-cli-update.sh"
BASH_BIN="$(command -v "${BASH_UNDER_TEST:-bash}")"

HOME_DIR="$TMP/home"; BIN="$TMP/bin"; TOOLBIN="$TMP/toolbin"; CALLS="$TMP/calls"
VERDIR="$TMP/ver"; CG="$TMP/cgroup"; SD="$TMP/sd"; NPM="$TMP/npm"; BREW="$TMP/brewroot"
MISC="$TMP/misc"; USRBIN="$TMP/usr-bin"; STDIN_FILE="$TMP/stdin"
STATE_DIR="$HOME_DIR/.local/state/brokkr"; STATE="$STATE_DIR/agent-cli-update.json"
mkdir -p "$BIN"
printf 'stdin-sentinel\n' >"$STDIN_FILE"

# --- stubs ---------------------------------------------------------------------------------
# Body shared by every fake agent CLI. The generated file sets $tool first. State lives in
# $MOCK_VER_DIR: <tool> is the installed version, <tool>.next what `update`/`upgrade` installs,
# <tool>.broken-at a version at which --version crashes, <tool>.update-fail makes update fail.
cat >"$TMP/tool-body.sh" <<'FAKE'
printf '%s %s\n' "$tool" "$*" >>"$MOCK_CALLS"
if IFS= read -r _line; then printf 'stdin-leak %s %s\n' "$tool" "$*" >>"$MOCK_CALLS"; fi
ver=$(cat "$MOCK_VER_DIR/$tool" 2>/dev/null || echo 0.0.0)
case "${1:-}" in
  --version)
    bad=$(cat "$MOCK_VER_DIR/$tool.broken-at" 2>/dev/null || true)
    if [ -n "$bad" ] && [ "$bad" = "$ver" ]; then echo "$tool: crashed" >&2; exit 1; fi
    if [ -f "$MOCK_VER_DIR/$tool.noversion" ]; then echo "no version here"; exit 0; fi
    echo "$tool-cli $ver (api 9.9.9)" ;;
  update|upgrade)
    if [ -f "$MOCK_VER_DIR/$tool.update-fail" ]; then echo "$tool: update failed" >&2; exit 7; fi
    if [ -n "${2:-}" ]; then new=$2; else new=$(cat "$MOCK_VER_DIR/$tool.next" 2>/dev/null || echo "$ver"); fi
    printf '%s\n' "$new" >"$MOCK_VER_DIR/$tool" ;;
esac
FAKE
write_tool_stub() { # path tool
  mkdir -p "$(dirname "$1")"
  { printf '#!/bin/sh\ntool=%s\n' "$2"; cat "$TMP/tool-body.sh"; } >"$1"
  chmod 755 "$1"
}
cat >"$BIN/systemctl" <<'FAKE'
#!/bin/sh
printf 'systemctl %s\n' "$*" >>"$MOCK_CALLS"
if [ -f "$MOCK_SD/systemctl-fail" ]; then echo "Failed to connect to bus" >&2; exit 1; fi
[ "$1" = --user ] && [ "$2" = show ] && [ "$3" = -p ] && [ "$5" = --value ] || exit 2
unit=$6
case "$4" in
  ActiveState) cat "$MOCK_SD/$unit.state" 2>/dev/null || echo inactive ;;
  ControlGroup) cat "$MOCK_SD/$unit.cg" 2>/dev/null || true ;;
  *) exit 2 ;;
esac
FAKE
cat >"$BIN/npm" <<'FAKE'
#!/bin/sh
printf 'npm %s\n' "$*" >>"$MOCK_CALLS"
case "${1:-}" in
  view)
    [ ! -f "$MOCK_VER_DIR/npm-view-fail" ] || { echo "npm ERR! network" >&2; exit 1; }
    key=$(printf '%s' "$2" | tr '/@' '__')
    cat "$MOCK_VER_DIR/latest-$key" ;;
  install)
    shift
    prefix=; spec=
    while [ $# -gt 0 ]; do
      case $1 in --prefix) prefix=$2; shift ;; -*) ;; *) spec=$1 ;; esac
      shift
    done
    pkg=${spec%@*}; ver=${spec##*@}
    [ ! -f "$MOCK_VER_DIR/npm-install-fail" ] || { echo "npm ERR! install failed" >&2; exit 1; }
    if [ "$(cat "$MOCK_VER_DIR/npm-install-fail-ver" 2>/dev/null)" = "$ver" ]; then echo "npm ERR! no such version" >&2; exit 1; fi
    mkdir -p "$prefix/lib/node_modules/$pkg"
    printf '{\n  "name": "%s",\n  "version": "%s"\n}\n' "$pkg" "$ver" >"$prefix/lib/node_modules/$pkg/package.json"
    case $pkg in
      @anthropic-ai/claude-code) t=claude ;;
      @openai/codex) t=codex ;;
      @earendil-works/pi-coding-agent) t=pi ;;
      opencode-ai) t=opencode ;;
      *) t=unknown ;;
    esac
    printf '%s\n' "$ver" >"$MOCK_VER_DIR/$t" ;;
  *) exit 2 ;;
esac
FAKE
cat >"$BIN/brew" <<'FAKE'
#!/bin/sh
printf 'brew %s\n' "$*" >>"$MOCK_CALLS"
if IFS= read -r _line; then printf 'stdin-leak brew %s\n' "$*" >>"$MOCK_CALLS"; fi
case "${1:-}" in
  upgrade)
    for name; do :; done
    new=$(cat "$MOCK_VER_DIR/$name.next" 2>/dev/null) || exit 1
    printf '%s\n' "$new" >"$MOCK_VER_DIR/$name" ;;
  *) exit 2 ;;
esac
FAKE
cat >"$BIN/node" <<'FAKE'
#!/bin/sh
printf 'node %s\n' "$*" >>"$MOCK_CALLS"
for path; do :; done
[ -f "$path" ] || { echo "node: cannot open $path" >&2; exit 1; }
sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$path"
FAKE
cat >"$BIN/dpkg-query" <<'FAKE'
#!/bin/sh
printf 'dpkg-query %s\n' "$*" >>"$MOCK_CALLS"
if [ "$1" = -S ] && [ "$2" = "$(cat "$MOCK_DPKG_OWNS" 2>/dev/null)" ]; then echo "claude-code: $2"; exit 0; fi
echo "dpkg-query: no path found matching pattern $2" >&2
exit 1
FAKE
chmod 755 "$BIN/"*
# A logging timeout wrapper, installed per test.
write_timeout() { # name
  cat >"$BIN/$1" <<FAKE
#!/bin/sh
printf '$1 %s\n' "\$*" >>"\$MOCK_CALLS"
shift
exec "\$@"
FAKE
  chmod 755 "$BIN/$1"
}

export MOCK_CALLS="$CALLS" MOCK_VER_DIR="$VERDIR" MOCK_SD="$SD" MOCK_DPKG_OWNS="$TMP/dpkg-owns"
export BROKKR_CGROUP_ROOT="$CG"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; printf '        rc=%s out=%s\n' "${RC:-}" "${OUT:-}" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
skip() { printf '  SKIP  %s\n' "$1"; }
# The updater runs with a minimal PATH (stubs first), the fake HOME, and stdin carrying a
# sentinel that no child may read: every update command must be started with stdin closed.
run() {
  OUT="$(HOME="${RUN_HOME:-$HOME_DIR}" PATH="${PATH_PRE:+$PATH_PRE:}$BIN:$HOME_DIR/.local/bin:$HOME_DIR/.opencode/bin:$TOOLBIN:/usr/bin:/bin" \
    "$BASH_BIN" "$SCRIPT" "$@" <"$STDIN_FILE" 2>&1)"
  RC=$?
}
chmod_all() { chmod -R u+rwX "$TMP/npm" 2>/dev/null || true; }
reset() {
  chmod_all
  rm -rf "$HOME_DIR" "$TOOLBIN" "$NPM" "$VERDIR" "$CG" "$SD" "$BREW" "$MISC" "$USRBIN" "$TMP/realnode" "$TMP/home-link"
  mkdir -p "$HOME_DIR" "$TOOLBIN" "$NPM" "$VERDIR" "$CG" "$SD" "$BREW" "$MISC" "$USRBIN"
  rm -f "$BIN/timeout" "$BIN/gtimeout" "$TMP/dpkg-owns"
  [[ -x "$BIN/npm" ]] || mv "$BIN/npm.off" "$BIN/npm" 2>/dev/null || true
  [[ -x "$BIN/node" ]] || mv "$BIN/node.off" "$BIN/node" 2>/dev/null || true
  : >"$CALLS"
  unset BROKKR_AGENT_CLI_TOOLS BROKKR_AGENT_CLI_BUSY_UNITS BROKKR_STATE_DIR XDG_STATE_HOME RUN_HOME PATH_PRE
}
mutations() { grep -E '^(npm install |brew upgrade|(claude|codex|pi|opencode) (update|upgrade))' "$CALLS" || true; }
no_mutation() { [[ -z "$(mutations)" ]]; }
no_stdin_leak() { ! grep -q '^stdin-leak' "$CALLS"; }
only_systemctl_calls() { [[ -z "$(grep -v '^systemctl' "$CALLS" || true)" ]]; }
latest() { printf '%s\n' "$2" >"$VERDIR/latest-$(printf '%s' "$1" | tr '/@' '__')"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
state_has() { grep -Fq -- "$1" "$STATE"; }
have_python() { command -v python3 >/dev/null 2>&1; }
json_ok() { if have_python; then python3 -I -m json.tool "$1" >/dev/null; else grep -q '^{' "$1"; fi; }
is_root() { [[ "$(id -u)" -eq 0 ]]; }

# --- fixtures: each helper installs one fake CLI the way real installers lay it out ---------
npm_tool() { # tool pkg version [prefix]
  local tool=$1 pkg=$2 ver=$3 prefix=${4:-$NPM/$1}
  mkdir -p "$prefix/lib/node_modules/$pkg/bin" "$prefix/bin"
  write_tool_stub "$prefix/lib/node_modules/$pkg/bin/cli.js" "$tool"
  printf '{\n  "name": "%s",\n  "version": "%s"\n}\n' "$pkg" "$ver" >"$prefix/lib/node_modules/$pkg/package.json"
  ln -s "../lib/node_modules/$pkg/bin/cli.js" "$prefix/bin/$tool"
  ln -s "$prefix/bin/$tool" "$TOOLBIN/$tool"
  printf '%s\n' "$ver" >"$VERDIR/$tool"
}
native_claude() { # version next
  mkdir -p "$HOME_DIR/.local/share/claude/versions" "$HOME_DIR/.local/bin"
  write_tool_stub "$HOME_DIR/.local/share/claude/versions/$1" claude
  ln -s "$HOME_DIR/.local/share/claude/versions/$1" "$HOME_DIR/.local/bin/claude"
  printf '%s\n' "$1" >"$VERDIR/claude"; printf '%s\n' "$2" >"$VERDIR/claude.next"
}
standalone_codex() { # version next
  write_tool_stub "$HOME_DIR/.codex/packages/standalone/releases/$1/codex" codex
  mkdir -p "$HOME_DIR/.local/bin"
  ln -s "$HOME_DIR/.codex/packages/standalone/releases/$1/codex" "$HOME_DIR/.local/bin/codex"
  printf '%s\n' "$1" >"$VERDIR/codex"; printf '%s\n' "$2" >"$VERDIR/codex.next"
}
installer_opencode() { # version next
  write_tool_stub "$HOME_DIR/.opencode/bin/opencode" opencode
  printf '%s\n' "$1" >"$VERDIR/opencode"; printf '%s\n' "$2" >"$VERDIR/opencode.next"
}
brew_cask() { # tool version next
  write_tool_stub "$BREW/Caskroom/$1/$2/$1" "$1"
  ln -s "$BREW/Caskroom/$1/$2/$1" "$TOOLBIN/$1"
  printf '%s\n' "$2" >"$VERDIR/$1"; printf '%s\n' "$3" >"$VERDIR/$1.next"
}
brew_formula() { # tool version next
  write_tool_stub "$BREW/Cellar/$1/$2/bin/$1" "$1"
  ln -s "$BREW/Cellar/$1/$2/bin/$1" "$TOOLBIN/$1"
  printf '%s\n' "$2" >"$VERDIR/$1"; printf '%s\n' "$3" >"$VERDIR/$1.next"
}
plain_tool() { # tool dir version: a binary of unknown provenance
  write_tool_stub "$2/$1" "$1"
  ln -s "$2/$1" "$TOOLBIN/$1"
  printf '%s\n' "$3" >"$VERDIR/$1"
}
busy_unit() { # unit state cgroup-path pids-in-main-file
  printf '%s\n' "$2" >"$SD/$1.state"
  printf '%s\n' "$3" >"$SD/$1.cg"
  mkdir -p "$CG$3"
  : >"$CG$3/cgroup.procs"
  local n=$4
  while [[ "$n" -gt 0 ]]; do echo "$((1000 + n))" >>"$CG$3/cgroup.procs"; n=$((n - 1)); done
}

echo "agent-cli-update.test.sh (bash: $("$BASH_BIN" -c 'echo $BASH_VERSION'))"

# --- static gates: portable to bash 3.2, no process inspection ---------------------------------
check "script exists and is executable" '[[ -x "$SCRIPT" ]]'
check "script parses under the bash being tested" '"$BASH_BIN" -n "$SCRIPT"'
check "script avoids bash 4+ constructs" '! grep -Eq "(declare|local|typeset) -[a-zA-Z]*[An]|mapfile|readarray|wait -n|\$\{[A-Za-z_0-9]+(,,|\^\^)\}|\[-[0-9]+\]" "$SCRIPT"'
check "script never inspects other processes" '! grep -Eq "(^|[[:space:];|&(])(ps|pgrep|pkill)[[:space:]]|/proc/" "$SCRIPT"'
check "script runs with strict mode" 'grep -Fxq "set -euo pipefail" "$SCRIPT"'

# --- usage and configuration errors --------------------------------------------------------
reset
run --help
check "--help prints usage and exits 0" '[[ "$RC" -eq 0 && "$OUT" == *usage* ]]'
run --bogus
check "unknown option exits 64 with usage" '[[ "$RC" -eq 64 && "$OUT" == *usage* ]] && no_mutation'
run extra-arg
check "positional argument exits 64" '[[ "$RC" -eq 64 ]]'
run --tool
check "--tool without a name exits 64" '[[ "$RC" -eq 64 ]]'
run --tool bogus
check "unknown tool exits 64 before touching anything" '[[ "$RC" -eq 64 && "$OUT" == *bogus* ]] && [[ ! -s "$CALLS" ]]'
BROKKR_AGENT_CLI_TOOLS="claude bogus" run
check "unknown tool in BROKKR_AGENT_CLI_TOOLS exits 64" '[[ "$RC" -eq 64 ]] && [[ ! -s "$CALLS" ]]'
BROKKR_AGENT_CLI_TOOLS="" run
check "an empty tool list exits 64" '[[ "$RC" -eq 64 ]]'
BROKKR_STATE_DIR="relative/dir" run --tool claude
check "a relative state directory exits 64" '[[ "$RC" -eq 64 ]]'
for unit in 'evil;touch.service' 'hugin' 'hugin.timer' '../x.service' '$(id).service' '*.service' 'a/b.service'; do
  BROKKR_AGENT_CLI_BUSY_UNITS="hugin.service $unit" run
  check "invalid busy unit '$unit' exits 64 before touching anything" '[[ "$RC" -eq 64 ]] && [[ ! -s "$CALLS" ]]'
done
BROKKR_AGENT_CLI_BUSY_UNITS=$'hugin.service\nother.service' run
check "a newline inside the busy unit list exits 64" '[[ "$RC" -eq 64 ]] && [[ ! -s "$CALLS" ]]'

# --- npm: newer release is installed at the exact looked-up version ---------------------------
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
run
check "npm update: exits 0" '[[ "$RC" -eq 0 ]]'
check "npm update: looks the package up and installs exactly that version into the owning prefix" 'grep -Fxq "npm view @anthropic-ai/claude-code version" "$CALLS" && grep -Fxq "npm install -g --prefix $NPM/claude --no-fund --no-audit @anthropic-ai/claude-code@1.1.0" "$CALLS"'
check "npm update: the installed version is read with node -p and the path as a separate argument" 'line=$(grep "^node -p" "$CALLS" | head -1); [[ "$line" == *" $NPM/claude/lib/node_modules/@anthropic-ai/claude-code/package.json" && "${line% *}" != *"$NPM"* ]]'
check "npm update: reports method, before, after, action" '[[ "$OUT" == *"claude npm 1.0.0 -> 1.1.0 updated"* ]]'
check "npm update: missing tools are reported absent, not failed" '[[ "$OUT" == *"codex - - -> - absent"* && "$OUT" == *"pi - - -> - absent"* && "$OUT" == *"opencode - - -> - absent"* ]]'
check "npm update: no command was started with a readable stdin" 'no_stdin_leak'
check "npm update: prints a summary line" '[[ "$OUT" == *"summary: result=ok"*"updated=1"*"absent=3"*"failed=0"* ]]'
check "npm update: writes the state file atomically with private modes" '[[ -f "$STATE" && "$(mode_of "$STATE")" == 600 && -z "$(find "$STATE_DIR" -name ".agent-cli-update*" -print)" ]]'
check "npm update: state file records result, host, and the tool" 'state_has "\"result\": \"ok\"" && state_has "\"hostname\": \"" && state_has "\"name\": \"claude\", \"method\": \"npm\"" && state_has "\"before\": \"1.0.0\", \"after\": \"1.1.0\", \"action\": \"updated\"" && grep -Eq "\"timestamp\": \"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\"" "$STATE"'
check "npm update: state file is valid JSON" 'json_ok "$STATE"'
check "npm update: the CLI really is at the new version afterwards" '[[ "$(cat "$VERDIR/claude")" == 1.1.0 ]]'

reset
npm_tool codex @openai/codex 0.9.0
latest @openai/codex 0.9.0
run
check "npm current: no install call" '[[ "$RC" -eq 0 && "$OUT" == *"codex npm 0.9.0 -> 0.9.0 current"* ]] && no_mutation'
check "npm current: still looks the latest version up" 'grep -Fxq "npm view @openai/codex version" "$CALLS"'

reset
npm_tool pi @earendil-works/pi-coding-agent 0.1.0
npm_tool opencode opencode-ai 1.0.0
latest @earendil-works/pi-coding-agent 0.2.0
latest opencode-ai 1.0.1
run
check "npm: scoped and unscoped packages are parsed and installed" 'grep -Fxq "npm install -g --prefix $NPM/pi --no-fund --no-audit @earendil-works/pi-coding-agent@0.2.0" "$CALLS" && grep -Fxq "npm install -g --prefix $NPM/opencode --no-fund --no-audit opencode-ai@1.0.1" "$CALLS"'

# A prefix like ~/.local keeps the package below lib/node_modules and bin elsewhere.
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0 "$HOME_DIR/.local"
latest @anthropic-ai/claude-code 1.0.1
run --tool claude
check "npm: a home-directory prefix is derived from everything before /lib/node_modules/" 'grep -Fxq "npm install -g --prefix $HOME_DIR/.local --no-fund --no-audit @anthropic-ai/claude-code@1.0.1" "$CALLS"'

# --- npm refusals ---------------------------------------------------------------------------
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
chmod 555 "$NPM/claude/lib/node_modules"
if is_root; then skip "npm prefix not writable (running as root)"; else
  run
  check "npm prefix not writable: failed without installing" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm"*"failed npm prefix not writable (root-managed)"* ]] && no_mutation'
fi
chmod_all

reset
npm_tool codex @someone/else 0.9.0
latest @someone/else 1.0.0
run
check "wrong package for the tool: failed, nothing installed" '[[ "$RC" -eq 1 && "$OUT" == *"codex npm"*failed* && "$OUT" == *"@someone/else"* ]] && no_mutation'

reset
npm_tool codex opencode-ai 0.9.0
run
check "a package that belongs to another tool is refused" '[[ "$RC" -eq 1 && "$OUT" == *"codex npm"*failed* ]] && no_mutation'

reset
npm_tool pi @mariozechner/pi-coding-agent 0.1.0
run
check "legacy pi package: failed with the migration hint, nothing installed" '[[ "$RC" -eq 1 && "$OUT" == *"legacy package; migrate to @earendil-works/pi-coding-agent"* ]] && no_mutation'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
rm "$NPM/claude/lib/node_modules/@anthropic-ai/claude-code/package.json"
latest @anthropic-ai/claude-code 1.1.0
run
check "unreadable installed version: failed without installing" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm"*failed* ]] && no_mutation'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
touch "$VERDIR/npm-view-fail"
run
check "npm view failure: failed without installing" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm"*failed* ]] && no_mutation'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code "1.2.3; touch pwned"
run
check "a malformed npm view answer is refused, never passed to install" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm"*failed* ]] && no_mutation'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
touch "$VERDIR/npm-install-fail"
npm_tool codex @openai/codex 0.9.0
latest @openai/codex 0.9.0
run
check "a failing install is reported failed and the next tool is still processed" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm"*failed* && "$OUT" == *"codex npm 0.9.0 -> 0.9.0 current"* ]]'
check "a failed run records result failed in the state file" 'state_has "\"result\": \"failed\"" && json_ok "$STATE"'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
mv "$BIN/npm" "$BIN/npm.off"
run
check "npm missing from PATH: failed without crashing" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm"*"failed npm not found"* ]] && no_mutation'
mv "$BIN/npm.off" "$BIN/npm"
mv "$BIN/node" "$BIN/node.off"
run
check "node missing from PATH: failed without crashing" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm"*"failed node not found"* ]] && no_mutation'
mv "$BIN/node.off" "$BIN/node"

# --- npm: smoke check and rollback --------------------------------------------------------------
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 2.0.0
echo 2.0.0 >"$VERDIR/claude.broken-at"
run
check "smoke failure after npm install: rolls back to the previous version" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm 1.0.0"*"rolled-back"* ]]'
check "rollback reinstalls the exact previous version after the new one" 'first=$(grep -n "claude-code@2.0.0" "$CALLS" | head -1 | cut -d: -f1); second=$(grep -n "claude-code@1.0.0" "$CALLS" | head -1 | cut -d: -f1); [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]]'
check "rollback leaves a working CLI" '[[ "$(cat "$VERDIR/claude")" == 1.0.0 ]] && state_has "\"action\": \"rolled-back\"" && state_has "\"result\": \"failed\""'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 2.0.0
touch "$VERDIR/claude.noversion"
echo 1.0.0 >"$VERDIR/npm-install-fail-ver"
run
check "smoke check needs a semver in the output; a failed rollback is a failure, not rolled-back" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm"*failed* && "$OUT" != *rolled-back* ]]'

# --- native, standalone, installer, brew ------------------------------------------------------------
reset
native_claude 2.0.0 2.0.1
run
check "native claude: runs claude update and reports the new version" '[[ "$RC" -eq 0 && "$OUT" == *"claude native 2.0.0 -> 2.0.1 updated"* ]] && grep -Fxq "claude update" "$CALLS" && ! grep -q "^npm" "$CALLS" && no_stdin_leak'

reset
native_claude 2.0.0 2.0.0
run
check "native claude: unchanged version is current" '[[ "$RC" -eq 0 && "$OUT" == *"claude native 2.0.0 -> 2.0.0 current"* ]]'

reset
native_claude 2.0.0 2.0.1
ln -s "$HOME_DIR" "$TMP/home-link"
RUN_HOME="$TMP/home-link" run --tool claude
check "native claude: a HOME that is itself a symlink still matches the resolved install path" '[[ "$RC" -eq 0 && "$OUT" == *"claude native"*updated* ]]'

reset
native_claude 2.0.0 2.0.1
echo 2.0.1 >"$VERDIR/claude.broken-at"
run
check "native smoke failure: failed, no automatic rollback" '[[ "$RC" -eq 1 && "$OUT" == *"claude native"*failed*"smoke check failed; no automatic rollback"* ]] && ! grep -q "^npm" "$CALLS"'

reset
native_claude 2.0.0 2.0.1
touch "$VERDIR/claude.update-fail"
npm_tool codex @openai/codex 0.9.0
latest @openai/codex 0.10.0
run
check "a failed update command is failed, others still run" '[[ "$RC" -eq 1 && "$OUT" == *"claude native"*failed*"exit 7"* ]] && grep -Fq "@openai/codex@0.10.0" "$CALLS"'

reset
standalone_codex 0.5.0 0.6.0
run
check "codex standalone: runs codex update" '[[ "$RC" -eq 0 && "$OUT" == *"codex codex-standalone 0.5.0 -> 0.6.0 updated"* ]] && grep -Fxq "codex update" "$CALLS" && no_stdin_leak'

reset
installer_opencode 1.0.0 1.1.0
run
check "opencode installer: runs opencode upgrade" '[[ "$RC" -eq 0 && "$OUT" == *"opencode opencode-installer 1.0.0 -> 1.1.0 updated"* ]] && grep -Fxq "opencode upgrade" "$CALLS" && no_stdin_leak'

reset
installer_opencode 1.0.0 1.1.0
echo 1.1.0 >"$VERDIR/opencode.broken-at"
run
check "opencode smoke failure: reinstalls the previous version with opencode upgrade <before>" '[[ "$RC" -eq 1 && "$OUT" == *"opencode opencode-installer"*rolled-back* ]] && grep -Fxq "opencode upgrade 1.0.0" "$CALLS"'

reset
brew_cask codex 0.5.0 0.6.0
run
check "brew cask: runs brew upgrade --cask <name>" '[[ "$RC" -eq 0 && "$OUT" == *"codex brew 0.5.0 -> 0.6.0 updated"* ]] && grep -Fxq "brew upgrade --cask codex" "$CALLS" && no_stdin_leak'

reset
brew_formula opencode 1.0.0 1.0.0
run
check "brew formula: runs brew upgrade <name>; unchanged version is current" '[[ "$RC" -eq 0 && "$OUT" == *"opencode brew 1.0.0 -> 1.0.0 current"* ]] && grep -Fxq "brew upgrade opencode" "$CALLS"'

# --- apt-owned and unknown installs ------------------------------------------------------------
reset
plain_tool claude "$USRBIN" 1.0.0
printf '%s\n' "$USRBIN/claude" >"$TMP/dpkg-owns"
run
check "dpkg-owned binary: external, never mutated, not an error" '[[ "$RC" -eq 0 && "$OUT" == *"claude apt 1.0.0 -> 1.0.0 external"*"managed by apt/unattended-upgrades"* ]] && no_mutation && grep -Fxq "dpkg-query -S $USRBIN/claude" "$CALLS"'

reset
plain_tool pi "$MISC" 0.1.0
npm_tool codex @openai/codex 0.9.0
latest @openai/codex 0.10.0
run
check "unknown install method: exit 1 while other tools are still processed" '[[ "$RC" -eq 1 && "$OUT" == *"pi"*failed*"unknown install method"* ]] && grep -Fq "@openai/codex@0.10.0" "$CALLS"'
check "unknown install method is recorded in the state file" 'state_has "\"name\": \"pi\"" && state_has "unknown install method" && json_ok "$STATE"'

# --- absent -----------------------------------------------------------------------------------
reset
run
check "no tools installed: all absent, exit 0, nothing installed" '[[ "$RC" -eq 0 && "$OUT" == *"claude - - -> - absent"* ]] && no_mutation && [[ "$OUT" == *"absent=4"* ]]'

# --- tool selection ---------------------------------------------------------------------------
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_tool codex @openai/codex 0.9.0
latest @anthropic-ai/claude-code 1.0.0
latest @openai/codex 0.9.0
run --tool codex
check "--tool limits the run to the named tool" '[[ "$RC" -eq 0 && "$OUT" == *"codex npm"* && "$OUT" != *"claude "* ]]'
run --tool codex --tool claude --tool codex
check "--tool is repeatable and de-duplicated" '[[ "$RC" -eq 0 && "$(printf "%s\n" "$OUT" | grep -c "^codex ")" -eq 1 && "$OUT" == *"claude npm"* ]]'
BROKKR_AGENT_CLI_TOOLS="codex" run
check "BROKKR_AGENT_CLI_TOOLS selects the default tool list" '[[ "$RC" -eq 0 && "$OUT" == *"codex npm"* && "$OUT" != *"claude "* ]]'

# --- busy guard -------------------------------------------------------------------------------
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
busy_unit hugin.service active /user.slice/hugin.service 2
BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service run
check "busy unit (2 PIDs): the whole run is deferred, exit 0" '[[ "$RC" -eq 0 && "$OUT" == *deferred* && "$OUT" == *hugin.service* ]]'
check "busy unit: no tool command of any kind is run" 'only_systemctl_calls && no_mutation'
check "busy unit: deferral is recorded in the state file" 'state_has "\"result\": \"deferred\"" && json_ok "$STATE"'
check "busy unit: the unit is queried through systemctl --user show" 'grep -Fxq "systemctl --user show -p ActiveState --value hugin.service" "$CALLS" && grep -Fxq "systemctl --user show -p ControlGroup --value hugin.service" "$CALLS"'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
busy_unit hugin.service active /user.slice/hugin.service 1
mkdir -p "$CG/user.slice/hugin.service/task-1/inner"
echo 4242 >"$CG/user.slice/hugin.service/task-1/inner/cgroup.procs"
BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service run
check "busy unit: PIDs in nested cgroups count" '[[ "$RC" -eq 0 && "$OUT" == *deferred* ]] && only_systemctl_calls'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
busy_unit hugin.service active /user.slice/hugin.service 1
BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service run
check "idle unit (1 PID, the service itself): the run proceeds" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.1.0 updated"* && "$OUT" != *deferred* ]]'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
busy_unit hugin.service inactive /user.slice/hugin.service 5
BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service run
check "inactive unit: its leftover PIDs are ignored and the run proceeds" '[[ "$RC" -eq 0 && "$OUT" == *updated* ]] && ! grep -q "ControlGroup" "$CALLS"'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
busy_unit hugin.service active /user.slice/hugin.service 1
busy_unit other.service active /user.slice/other.service 3
BROKKR_AGENT_CLI_BUSY_UNITS="hugin.service  other.service" run
check "several busy units: any one busy unit defers the run" '[[ "$RC" -eq 0 && "$OUT" == *deferred* && "$OUT" == *other.service* ]] && only_systemctl_calls'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
printf 'active\n' >"$SD/hugin.service.state"
printf '/user.slice/gone.service\n' >"$SD/hugin.service.cg"
BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service run
check "unreadable cgroup: fails closed and defers, saying so" '[[ "$RC" -eq 0 && "$OUT" == *deferred* && "$OUT" == *cgroup* ]] && only_systemctl_calls'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
printf 'active\n' >"$SD/hugin.service.state"
: >"$SD/hugin.service.cg"
BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service run
check "active unit without a ControlGroup: fails closed and defers" '[[ "$RC" -eq 0 && "$OUT" == *deferred* ]] && only_systemctl_calls'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
printf 'active\n' >"$SD/hugin.service.state"
printf '/user.slice/../../etc\n' >"$SD/hugin.service.cg"
BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service run
check "a ControlGroup that climbs out of the cgroup root is never read: deferred" '[[ "$RC" -eq 0 && "$OUT" == *deferred* ]] && only_systemctl_calls'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
busy_unit hugin.service active /user.slice/hugin.service 1
touch "$SD/systemctl-fail"
BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service run
check "systemctl cannot answer: fails closed and defers" '[[ "$RC" -eq 0 && "$OUT" == *deferred* ]] && no_mutation'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
busy_unit hugin.service active /user.slice/hugin.service 1
chmod 000 "$CG/user.slice/hugin.service/cgroup.procs"
if is_root; then skip "unreadable cgroup.procs (running as root)"; else
  BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service run
  check "unreadable cgroup.procs: fails closed and defers" '[[ "$RC" -eq 0 && "$OUT" == *deferred* ]] && only_systemctl_calls'
fi
chmod 644 "$CG/user.slice/hugin.service/cgroup.procs"

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
run
check "no busy units configured: systemctl is never consulted" '[[ "$RC" -eq 0 ]] && ! grep -q "^systemctl" "$CALLS"'

# --- dry-run ----------------------------------------------------------------------------------
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
npm_tool codex @openai/codex 0.9.0
latest @openai/codex 0.9.0
installer_opencode 1.0.0 1.1.0
brew_cask pi 0.1.0 0.2.0
run --dry-run
check "--dry-run: exit 0, reports what would happen" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.1.0 would-update"* && "$OUT" == *"codex npm 0.9.0 -> 0.9.0 current"* && "$OUT" == *"opencode opencode-installer"*would-update* ]]'
check "--dry-run: makes no install, update, or upgrade call" 'no_mutation'
check "--dry-run: writes no state file" '[[ ! -e "$STATE" && ! -e "$STATE_DIR" ]]'
check "--dry-run: still looks versions up read-only" 'grep -Fxq "npm view @anthropic-ai/claude-code version" "$CALLS"'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.1.0
busy_unit hugin.service active /user.slice/hugin.service 4
BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service run --dry-run
check "--dry-run honours the busy guard and writes no state" '[[ "$RC" -eq 0 && "$OUT" == *deferred* && ! -e "$STATE" ]] && only_systemctl_calls'

# --- state file ---------------------------------------------------------------------------------
reset
npm_tool codex @openai/codex 0.9.0 "$NPM/we\"ird\\dir"$'\t'"tab"
latest @openai/codex 0.9.0
run
check "state file: awkward path characters (quote, backslash, tab) stay valid JSON" '[[ "$RC" -eq 0 ]] && json_ok "$STATE"'
if have_python; then
  want="$NPM/we\"ird\\dir"$'\t'"tab/lib/node_modules/@openai/codex/bin/cli.js"
  check "state file: the escaped path round-trips exactly" 'python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(t[\"path\"]==sys.argv[2] for t in d[\"tools\"]) else 1)" "$STATE" "$want"'
else
  skip "state file path round-trip (python3 unavailable)"
fi

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.0.0
BROKKR_STATE_DIR="$TMP/custom-state" run
check "BROKKR_STATE_DIR relocates the state file" '[[ -f "$TMP/custom-state/agent-cli-update.json" && ! -e "$STATE" ]]'
rm -rf "$TMP/custom-state"
XDG_STATE_HOME="$TMP/xdg-state" run
check "XDG_STATE_HOME is honoured when BROKKR_STATE_DIR is unset" '[[ -f "$TMP/xdg-state/brokkr/agent-cli-update.json" ]]'
rm -rf "$TMP/xdg-state"

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.0.0
mkdir -p "$STATE_DIR"; chmod 555 "$STATE_DIR"
if is_root; then skip "unwritable state directory (running as root)"; else
  run
  check "an unwritable state directory is a failure, not silent" '[[ "$RC" -eq 1 && "$OUT" == *"state"* ]]'
fi
chmod 755 "$STATE_DIR"

# --- timeouts ---------------------------------------------------------------------------------------
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.0.0
write_timeout timeout
run --tool claude
check "version probes run under timeout when it exists" '[[ "$RC" -eq 0 ]] && grep -Eq "^timeout [0-9]+ claude --version\$" "$CALLS"'
rm -f "$BIN/timeout"
if PATH=/usr/bin:/bin command -v timeout >/dev/null 2>&1; then
  skip "gtimeout fallback (a real timeout exists in /usr/bin:/bin)"
else
  write_timeout gtimeout
  run --tool claude
  check "version probes fall back to gtimeout" '[[ "$RC" -eq 0 ]] && grep -Eq "^gtimeout [0-9]+ claude --version\$" "$CALLS"'
fi
rm -f "$BIN/gtimeout"
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
latest @anthropic-ai/claude-code 1.0.0
run --tool claude
check "without any timeout command the probes still run" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.0.0 current"* ]]'

# --- real node reads the real package.json ----------------------------------------------------------
reset
if command -v node >/dev/null 2>&1; then
  mkdir -p "$TMP/realnode"
  ln -s "$(command -v node)" "$TMP/realnode/node"
  npm_tool claude @anthropic-ai/claude-code 1.0.0
  latest @anthropic-ai/claude-code 1.0.0
  PATH_PRE="$TMP/realnode" run --tool claude
  check "the node -p expression works with a real node" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.0.0 current"* ]]'
else
  skip "real node check (node unavailable)"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
