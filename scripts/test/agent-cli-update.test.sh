#!/usr/bin/env bash
# Hermetic gates for scripts/agent-cli-update.sh. npm, brew, node, curl, uname, dpkg-query,
# systemctl and the four agent CLIs are stubs on PATH that log their argv to a file; curl serves
# release metadata and archives from fixture files keyed by URL, the clock is BROKKR_NOW_EPOCH,
# and HOME, the cgroup tree and the systemd unit state are temp directories. Nothing real is
# installed, updated, downloaded, or queried (python3, tar and sha256sum are real local tools).
# Set BASH_UNDER_TEST to run the updater with another bash (for example /bin/bash 3.2).
# shellcheck disable=SC2016,SC2034 # assertions are evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/test/lib/fixture-cleanup.sh
source "$HERE/lib/fixture-cleanup.sh"
TMP="$(fixture_cleanup_alloc)"
# fixture_cleanup_on_exit reads the test status from $?, so restore it after the chmod that
# makes the read-only fixtures removable.
cleanup_fixture() {
  local test_rc=$?
  chmod -R u+rwX "$TMP" 2>/dev/null
  (exit "$test_rc")
  fixture_cleanup_on_exit "$TMP"
}
trap cleanup_fixture EXIT
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
# <tool>.broken-at a version at which --version crashes, <tool>.update-fail makes update fail,
# <tool>.install-as is what the next update installs instead (once), whatever was asked for.
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
  update|upgrade|install)
    if [ -f "$MOCK_VER_DIR/$tool.update-fail" ]; then echo "$tool: update failed" >&2; exit 7; fi
    if [ -n "${2:-}" ]; then new=$2; else new=$(cat "$MOCK_VER_DIR/$tool.next" 2>/dev/null || echo "$ver"); fi
    if [ -f "$MOCK_VER_DIR/$tool.install-as" ]; then new=$(cat "$MOCK_VER_DIR/$tool.install-as"); rm -f "$MOCK_VER_DIR/$tool.install-as"; fi
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
      opencode-ai|@opencode/cli) t=opencode ;;
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
  info)
    for name; do :; done
    cat "$MOCK_VER_DIR/brew-info-$name.json" 2>/dev/null || exit 1 ;;
  upgrade)
    for name; do :; done
    new=$(cat "$MOCK_VER_DIR/$name.next" 2>/dev/null) || exit 1
    printf '%s\n' "$new" >"$MOCK_VER_DIR/$name" ;;
  *) exit 2 ;;
esac
FAKE
# Release metadata and archives come from $MOCK_WEB, one file per URL (scheme dropped, every
# character outside A-Za-z0-9._- replaced by _); a missing file is an HTTP 404.
cat >"$BIN/curl" <<'FAKE'
#!/bin/sh
printf 'curl %s\n' "$*" >>"$MOCK_CALLS"
out=; url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift ;;
    --max-time|--proto) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
key=$(printf '%s' "$url" | sed 's|^https://||' | tr -c 'A-Za-z0-9._-' '_')
[ -f "$MOCK_WEB/$key" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
if [ -n "$out" ]; then cat "$MOCK_WEB/$key" >"$out"; else cat "$MOCK_WEB/$key"; fi
FAKE
# MOCK_UNAME_S/MOCK_UNAME_M fake the platform; every other query reaches the real uname.
{
  printf '#!/bin/sh\nreal=%s\n' "$(command -v uname)"
  cat <<'FAKE'
case "${1:-}" in
  -s) if [ -n "${MOCK_UNAME_S:-}" ]; then echo "$MOCK_UNAME_S"; exit 0; fi ;;
  -m) if [ -n "${MOCK_UNAME_M:-}" ]; then echo "$MOCK_UNAME_M"; exit 0; fi ;;
esac
exec "$real" "$@"
FAKE
} >"$BIN/uname"
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

WEB="$TMP/web"
export MOCK_CALLS="$CALLS" MOCK_VER_DIR="$VERDIR" MOCK_SD="$SD" MOCK_DPKG_OWNS="$TMP/dpkg-owns" MOCK_WEB="$WEB"
export BROKKR_CGROUP_ROOT="$CG"
# Release endpoints and the clock are fixed for every run.
NPM_BASE=https://npm.example; GH_API=https://api.example; GH_DL=https://dl.example
NOW=1790000000
export BROKKR_NPM_REGISTRY="$NPM_BASE" BROKKR_GITHUB_API="$GH_API" BROKKR_GITHUB_DOWNLOAD="$GH_DL" BROKKR_NOW_EPOCH="$NOW"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; printf '        rc=%s out=%s\n' "${RC:-}" "${OUT:-}" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
skip() { printf '  SKIP  %s\n' "$1"; }
# The updater runs with a minimal PATH (stubs first), the fake HOME, and stdin carrying a
# sentinel that no child may read: every update command must be started with stdin closed.
run() {
  OUT="$(HOME="${RUN_HOME:-$HOME_DIR}" PATH="${PATH_ONLY:-${PATH_PRE:+$PATH_PRE:}$BIN:$HOME_DIR/.local/bin:$HOME_DIR/.opencode/bin:$TOOLBIN:/usr/bin:/bin}" \
    "$BASH_BIN" "$SCRIPT" "$@" <"$STDIN_FILE" 2>&1)"
  RC=$?
}
chmod_all() { chmod -R u+rwX "$TMP/npm" 2>/dev/null || true; }
reset() {
  chmod_all
  rm -rf "$HOME_DIR" "$TOOLBIN" "$NPM" "$VERDIR" "$CG" "$SD" "$BREW" "$MISC" "$USRBIN" "$WEB" "$TMP/realnode" "$TMP/home-link"
  mkdir -p "$HOME_DIR" "$TOOLBIN" "$NPM" "$VERDIR" "$CG" "$SD" "$BREW" "$MISC" "$USRBIN" "$WEB"
  rm -f "$BIN/timeout" "$BIN/gtimeout" "$TMP/dpkg-owns"
  [[ -x "$BIN/npm" ]] || mv "$BIN/npm.off" "$BIN/npm" 2>/dev/null || true
  [[ -x "$BIN/node" ]] || mv "$BIN/node.off" "$BIN/node" 2>/dev/null || true
  : >"$CALLS"
  unset BROKKR_AGENT_CLI_TOOLS BROKKR_AGENT_CLI_BUSY_UNITS BROKKR_STATE_DIR XDG_STATE_HOME RUN_HOME PATH_PRE PATH_ONLY
  unset BROKKR_AGENT_CLI_MIN_AGE_HOURS MOCK_UNAME_S MOCK_UNAME_M
}
mutations() { grep -E '^(npm install |brew upgrade|(claude|codex|pi|opencode) (update|upgrade|install))' "$CALLS" || true; }
no_mutation() { [[ -z "$(mutations)" ]]; }
no_stdin_leak() { ! grep -q '^stdin-leak' "$CALLS"; }
only_systemctl_calls() { [[ -z "$(grep -v '^systemctl' "$CALLS" || true)" ]]; }

# --- release metadata fixtures (served by the curl stub) -------------------------------------------
web_key() { printf '%s' "${1#https://}" | tr -c 'A-Za-z0-9._-' '_'; }
web_put() { cat >"$WEB/$(web_key "$1")"; } # url ; content on stdin
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
# "5" is five hours before NOW; "172799s" is that many seconds before NOW.
age_ts() { case $1 in *s) iso $((NOW - ${1%s})) ;; *) iso $((NOW - $1 * 3600)) ;; esac; }
npm_url() { printf '%s/%s' "$NPM_BASE" "$(printf '%s' "$1" | sed 's|/|%2f|')"; }
# npm_meta PACKAGE TAGS VERSION=AGE... : TAGS is "latest=1.2.0,stable=1.1.0" or "-".
npm_meta() {
  local pkg=$1 tags=$2 times='' tg='' sep='' tsep='' pair t
  shift 2
  for pair; do
    times="$times$sep\"${pair%%=*}\": \"$(age_ts "${pair#*=}" | sed 's/Z$/.000Z/')\""
    sep=", "
  done
  if [[ "$tags" != - ]]; then
    for t in $(printf '%s' "$tags" | tr ',' ' '); do
      tg="$tg$tsep\"${t%%=*}\": \"${t#*=}\""
      tsep=", "
    done
  fi
  printf '{"name": "%s", "dist-tags": {%s}, "time": {"created": "2020-01-01T00:00:00.000Z", "modified": "%s", %s}}\n' \
    "$pkg" "$tg" "$(iso "$NOW")" "$times" | web_put "$(npm_url "$pkg")"
}
# latest PACKAGE VERSION : a long-published release, so the default cooldown never gates it.
latest() { npm_meta "$1" "latest=$2" "$2=1000"; }
# gh_releases OWNER/REPO TAG=AGE[:draft|:pre]... : the releases list the GitHub API returns.
gh_releases() {
  local repo=$1 out='' sep='' pair tag rest flag draft pre
  shift
  for pair; do
    tag=${pair%%=*}; rest=${pair#*=}; flag=
    case $rest in *:*) flag=${rest#*:}; rest=${rest%%:*} ;; esac
    draft=false; pre=false
    if [[ "$flag" == draft ]]; then draft=true; fi
    if [[ "$flag" == pre ]]; then pre=true; fi
    out="$out$sep{\"tag_name\": \"$tag\", \"published_at\": \"$(age_ts "$rest")\", \"draft\": $draft, \"prerelease\": $pre}"
    sep=", "
  done
  printf '[%s]\n' "$out" | web_put "$GH_API/repos/$repo/releases?per_page=50"
}
curl_calls() { grep -c '^curl ' "$CALLS" || true; }
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

claude_stable() { npm_meta @anthropic-ai/claude-code "latest=$1,stable=$1" "$1=${2:-100}"; } # version [age-hours]
codex_release() { gh_releases openai/codex "rust-v$1=${2:-100}"; } # version [age-hours]
brew_info() { # cask|formula name version : what `brew info --json=v2` reports
  if [[ "$1" == cask ]]; then
    printf '{"formulae": [], "casks": [{"token": "%s", "version": "%s"}]}\n' "$2" "$3"
  else
    printf '{"formulae": [{"name": "%s", "versions": {"stable": "%s", "head": "HEAD", "bottle": true}}], "casks": []}\n' "$2" "$3"
  fi >"$VERDIR/brew-info-$2.json"
}
# Real core utilities, the stubs, and any extra real tool named (python3 and node only when asked),
# on a PATH of their own: the way to take python3 or node away without touching the system.
# shellcheck disable=SC2120 # the extra utilities are optional
only_path() { # extra-utility...
  local u p
  rm -rf "$TMP/only"; mkdir -p "$TMP/only"
  for p in "$BIN"/*; do [[ "$p" == "$BIN/node" ]] || ln -s "$p" "$TMP/only/${p##*/}"; done
  for u in awk basename cat chmod cp cut date dirname env find grep head hostname id ln mkdir mktemp mv readlink rm sed sh sleep sort stat tail tar tee tr wc "$@"; do
    p=$(type -P "$u") || continue
    [[ -e "$TMP/only/$u" ]] || ln -s "$p" "$TMP/only/$u"
  done
  PATH_ONLY="$TMP/only:$HOME_DIR/.local/bin:$HOME_DIR/.opencode/bin:$TOOLBIN"
}

echo "agent-cli-update.test.sh (bash: $("$BASH_BIN" -c 'echo $BASH_VERSION'))"

# --- static gates: portable to bash 3.2, no process inspection ---------------------------------
check "script exists and is executable" '[[ -x "$SCRIPT" ]]'
check "script parses under the bash being tested" '"$BASH_BIN" -n "$SCRIPT"'
CODE_ONLY="$(grep -v '^[[:space:]]*#' "$SCRIPT" 2>/dev/null)"
check "script avoids bash 4+ constructs" '! printf "%s\n" "$CODE_ONLY" | grep -Eq "(declare|local|typeset) -[a-zA-Z]*[An]|mapfile|readarray|wait -n|\$\{[A-Za-z_0-9]+(,,|\^\^)\}|\[-[0-9]+\]"'
check "script never inspects other processes" '! printf "%s\n" "$CODE_ONLY" | grep -Eq "(^|[[:space:];|&(])(ps|pgrep|pkill)[[:space:]]|/proc/"'
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
for unit in 'evil;touch.service' 'hugin' 'hugin.timer' '-x.service' '../x.service' '$(id).service' '*.service' 'a/b.service'; do
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
check "npm update: reads the registry metadata (scoped name encoded) and installs exactly that version into the owning prefix" 'grep -Fxq "curl -fsSL --proto =https --max-time 60 $NPM_BASE/@anthropic-ai%2fclaude-code" "$CALLS" && grep -Fxq "npm install -g --prefix $NPM/claude --no-fund --no-audit @anthropic-ai/claude-code@1.1.0" "$CALLS" && ! grep -q "^npm view" "$CALLS"'
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
check "npm current: still reads the registry metadata" 'grep -Fxq "curl -fsSL --proto =https --max-time 60 $NPM_BASE/@openai%2fcodex" "$CALLS"'

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
npm_meta @anthropic-ai/claude-code "latest=1.2.3" "1.2.3; touch pwned=1000" "1.0.0=1000"
run
check "a malformed version in the registry metadata is ignored, never passed to install" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.0.0 current"* ]] && no_mutation'

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
# A real npm/node in /usr/bin:/bin (common on Linux) would be found instead of the missing
# stub, and the run would reach the real registry; skip rather than leave the sandbox.
if PATH=/usr/bin:/bin command -v npm >/dev/null 2>&1; then
  skip "npm missing from PATH (a real npm exists in /usr/bin:/bin)"
else
  mv "$BIN/npm" "$BIN/npm.off"
  run
  check "npm missing from PATH: failed without crashing" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm"*"failed npm not found"* ]] && no_mutation'
  mv "$BIN/npm.off" "$BIN/npm"
fi
if PATH=/usr/bin:/bin command -v node >/dev/null 2>&1; then
  skip "node missing from PATH (a real node exists in /usr/bin:/bin)"
else
  mv "$BIN/node" "$BIN/node.off"
  run
  check "node missing from PATH: failed without crashing" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm"*"failed node not found"* ]] && no_mutation'
  mv "$BIN/node.off" "$BIN/node"
fi

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
check "smoke check needs a semver in the output; a failed rollback is a failure, not rolled-back" '[[ "$RC" -eq 1 && "$OUT" == *"claude npm"*failed* ]] && ! printf "%s\n" "$OUT" | grep -Eq "^claude .* rolled-back( |\$)"'

# --- cooldown: configuration -------------------------------------------------------------------
reset
for v in abc -1 721 1.5 "" " 5" 99999 0x10 5h; do
  BROKKR_AGENT_CLI_MIN_AGE_HOURS="$v" run
  check "invalid BROKKR_AGENT_CLI_MIN_AGE_HOURS '$v' exits 64 before touching anything" '[[ "$RC" -eq 64 && "$OUT" == *MIN_AGE_HOURS* ]] && [[ ! -s "$CALLS" ]]'
done
for v in 0 1 48 720 007; do
  BROKKR_AGENT_CLI_MIN_AGE_HOURS="$v" run --dry-run
  check "BROKKR_AGENT_CLI_MIN_AGE_HOURS=$v is accepted" '[[ "$RC" -eq 0 ]]'
done
for v in abc -5 1.5 "" 17000000000000; do
  BROKKR_NOW_EPOCH="$v" run
  check "invalid BROKKR_NOW_EPOCH '$v' exits 64 before touching anything" '[[ "$RC" -eq 64 && "$OUT" == *NOW_EPOCH* ]] && [[ ! -s "$CALLS" ]]'
done
BROKKR_NPM_REGISTRY=http://registry.example run
check "a non-https registry URL exits 64 before touching anything" '[[ "$RC" -eq 64 && "$OUT" == *BROKKR_NPM_REGISTRY* ]] && [[ ! -s "$CALLS" ]]'
BROKKR_GITHUB_API="https://api.example/x y" run
check "a GitHub API URL with a space exits 64" '[[ "$RC" -eq 64 && "$OUT" == *BROKKR_GITHUB_API* ]]'
BROKKR_GITHUB_DOWNLOAD="https://dl.example/?x=1" run
check "a GitHub download URL with a query string exits 64" '[[ "$RC" -eq 64 && "$OUT" == *BROKKR_GITHUB_DOWNLOAD* ]]'

# --- cooldown: npm picks the highest AGED version ------------------------------------------------
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.3.0" "1.0.0=2000" "1.1.0=200" "1.2.0=60" "1.3.0=5"
run
check "cooldown: the newest aged version is installed, not the newest one" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.2.0 updated"* ]] && grep -Fxq "npm install -g --prefix $NPM/claude --no-fund --no-audit @anthropic-ai/claude-code@1.2.0" "$CALLS"'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.0.0" "1.0.0=2000" "1.2.0=60" "1.1.0=70"
run
check "cooldown: the highest aged version wins whatever the latest tag or the order says" '[[ "$OUT" == *"claude npm 1.0.0 -> 1.2.0 updated"* ]]'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.1.0" "1.0.0=2000" "1.1.0=172800s"
run
check "cooldown: a release exactly as old as the cooldown is eligible" '[[ "$OUT" == *"claude npm 1.0.0 -> 1.1.0 updated"* ]]'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.1.0" "1.0.0=2000" "1.1.0=172799s"
run
check "cooldown: one second short of the cooldown is held" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.0.0 held"* ]] && no_mutation'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.3.0" "1.0.0=2000" "1.2.0=30" "1.3.0=5"
run
check "cooldown: when every newer version is too young the tool is held, exit 0, nothing mutated" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.0.0 held"* ]] && no_mutation'
check "held: the detail names the newest version and its age in hours" '[[ "$OUT" == *"claude npm 1.0.0 -> 1.0.0 held"*"1.3.0"*"5h"*"48h"* ]]'
check "held: the summary counts it and the run result stays ok" '[[ "$OUT" == *"summary: result=ok"*"held=1"*"failed=0"* ]]'
check "held: the state file records the action and an ok result" 'state_has "\"action\": \"held\"" && state_has "\"result\": \"ok\"" && json_ok "$STATE"'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.2.0" "1.0.0=2000" "1.2.0=1000"
npm_tool codex @openai/codex 0.9.0
npm_meta @openai/codex "latest=0.9.0" "0.9.0=2000"
run
check "cooldown: an aged newer version is installed while an equal one is current" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.2.0 updated"* && "$OUT" == *"codex npm 0.9.0 -> 0.9.0 current"* ]]'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.4.0-beta.1" "1.0.0=2000" "1.1.0=100" "1.4.0-beta.1=500" "1.5.0+build.7=500" "2.0.0-rc.1=900"
run
check "versions with a - or + suffix are never candidates" '[[ "$OUT" == *"claude npm 1.0.0 -> 1.1.0 updated"* ]] && ! grep -Fq "beta" "$CALLS" && ! grep -Fq "build" "$CALLS"'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.4.0-beta.1" "1.0.0=2000" "1.4.0-beta.1=500" "1.5.0+build.7=500"
run
check "only suffixed newer versions: nothing newer, so current (not held)" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.0.0 current"* ]] && no_mutation'

reset
npm_tool claude @anthropic-ai/claude-code 1.9.0
npm_meta @anthropic-ai/claude-code "latest=1.10.0" "1.9.0=3000" "1.2.0=900" "1.9.5=200" "1.10.0=100"
run
check "versions compare numerically per component: 1.10.0 is newer than 1.9.5" '[[ "$OUT" == *"claude npm 1.9.0 -> 1.10.0 updated"* ]]'

reset
npm_tool claude @anthropic-ai/claude-code 1.9.0
npm_meta @anthropic-ai/claude-code "latest=1.10.0" "1.9.0=3000" "1.10.0=3"
run
check "numeric compare also decides held vs current: young 1.10.0 is newer than installed 1.9.0" '[[ "$OUT" == *"claude npm 1.9.0 -> 1.9.0 held"*"1.10.0"* ]] && no_mutation'

reset
npm_tool claude @anthropic-ai/claude-code 9.9.9
npm_meta @anthropic-ai/claude-code "latest=10.0.0" "9.9.9=3000" "10.0.0=100"
run
check "numeric compare across digit counts: 10.0.0 is newer than 9.9.9" '[[ "$OUT" == *"claude npm 9.9.9 -> 10.0.0 updated"* ]]'

reset
npm_tool claude @anthropic-ai/claude-code 1.1.0
npm_meta @anthropic-ai/claude-code "latest=1.1.0" "1.0.0=3000" "1.1.0=3000"
run
check "an installed version at or beyond every release is current" '[[ "$OUT" == *"claude npm 1.1.0 -> 1.1.0 current"* ]]'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.1.0" "1.0.0=2000" "1.1.0=1"
run
check "the default cooldown is 48 hours" '[[ "$OUT" == *"claude npm 1.0.0 -> 1.0.0 held"*"48h"* ]]'
BROKKR_AGENT_CLI_MIN_AGE_HOURS=0 run
check "a cooldown of 0 disables the age check" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.1.0 updated"* ]]'
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.1.0" "1.0.0=2000" "1.1.0=1"
BROKKR_AGENT_CLI_MIN_AGE_HOURS=1 run
check "a cooldown of 1 hour admits a release 1 hour old" '[[ "$OUT" == *"claude npm 1.0.0 -> 1.1.0 updated"* ]]'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.1.0" "1.0.0=2000" "1.1.0=100"
BROKKR_AGENT_CLI_MIN_AGE_HOURS=720 run
check "a cooldown of 720 hours holds a release 100 hours old" '[[ "$OUT" == *"claude npm 1.0.0 -> 1.0.0 held"*"720h"* ]] && no_mutation'
BROKKR_NOW_EPOCH=$((NOW - 99 * 3600)) run
check "BROKKR_NOW_EPOCH is the clock: with it set back, the release is only 1h old" '[[ "$OUT" == *"claude npm 1.0.0 -> 1.0.0 held"*"1.1.0 is only 1h old"* ]]'

# --- cooldown: metadata that cannot be evaluated holds the tool ----------------------------------
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
run
check "metadata fetch failure: held with cannot evaluate release age, nothing installed" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.0.0 held"*"cannot evaluate release age"* ]] && no_mutation'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
echo "<html>not json</html>" | web_put "$(npm_url @anthropic-ai/claude-code)"
run
check "metadata that is not JSON: held" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm"*held*"cannot evaluate release age"* ]] && no_mutation'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
echo '{"name": "x"}' | web_put "$(npm_url @anthropic-ai/claude-code)"
run
check "metadata without a time map: held" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm"*held*"cannot evaluate release age"* ]] && no_mutation'

reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.1.0" "1.0.0=2000" "1.1.0=100"
run --dry-run
check "dry-run: an aged release is would-update with the exact install command and nothing is changed" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.1.0 would-update"*"npm install -g --prefix $NPM/claude @anthropic-ai/claude-code@1.1.0"* ]] && no_mutation'
npm_meta @anthropic-ai/claude-code "latest=1.1.0" "1.0.0=2000" "1.1.0=1"
run --dry-run
check "dry-run: a young release is held and counted" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.0.0 held"* && "$OUT" == *"held=1"* ]] && no_mutation'

# --- cooldown: the node fallback reads the same JSON ---------------------------------------------
reset
npm_tool claude @anthropic-ai/claude-code 1.0.0
npm_meta @anthropic-ai/claude-code "latest=1.3.0" "1.0.0=2000" "1.1.0=200" "1.2.0=60" "1.3.0=5" "1.4.0-rc.1=900"
if command -v node >/dev/null 2>&1; then
  mkdir -p "$TMP/realnode"
  ln -s "$(command -v node)" "$TMP/realnode/node"
  only_path
  PATH_ONLY="$TMP/realnode:$PATH_ONLY"
  run --tool claude
  check "without python3 the JSON is read with a real node, with the same candidate choice" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.2.0 updated"* ]]'
  unset PATH_ONLY
else
  skip "node fallback for the JSON reader (node unavailable)"
fi

# --- opencode over npm: @opencode/cli (v2) and opencode-ai (legacy 1.x) -------------------------------
reset
npm_tool opencode @opencode/cli 2.0.0
npm_meta @opencode/cli "latest=2.1.0" "2.0.0=900" "2.1.0=100"
run --tool opencode
check "opencode over npm: @opencode/cli is the v2 package and needs no legacy note" '[[ "$RC" -eq 0 && "$OUT" == *"opencode npm 2.0.0 -> 2.1.0 updated"* && "$OUT" != *legacy* ]] && grep -Fxq "npm install -g --prefix $NPM/opencode --no-fund --no-audit @opencode/cli@2.1.0" "$CALLS" && grep -Fq "$NPM_BASE/@opencode%2fcli" "$CALLS"'

reset
npm_tool opencode opencode-ai 1.0.0
latest opencode-ai 1.0.1
run --tool opencode
check "opencode over npm: opencode-ai is the legacy 1.x line, still updated, noted and not a failure" '[[ "$RC" -eq 0 && "$OUT" == *"opencode npm 1.0.0 -> 1.0.1 updated"*"legacy 1.x line; v2 is @opencode/cli"* ]] && grep -Fxq "npm install -g --prefix $NPM/opencode --no-fund --no-audit opencode-ai@1.0.1" "$CALLS"'

reset
npm_tool opencode opencode-ai 1.0.0
npm_meta opencode-ai "latest=1.0.1" "1.0.0=900" "1.0.1=2"
run --tool opencode
check "opencode-ai held: the legacy note is kept next to the hold reason" '[[ "$RC" -eq 0 && "$OUT" == *"opencode npm 1.0.0 -> 1.0.0 held"*"1.0.1"*"legacy 1.x line; v2 is @opencode/cli"* ]] && no_mutation'

reset
npm_tool codex @opencode/cli 0.9.0
run
check "an opencode package under codex is refused" '[[ "$RC" -eq 1 && "$OUT" == *"codex npm"*failed* ]] && no_mutation'

# --- native claude: gated on dist-tags.stable, installed with `claude install <version>` ---------------
reset
native_claude 2.0.0 2.0.1
claude_stable 2.0.1
run
check "native claude: installs the aged stable version with claude install and reports it" '[[ "$RC" -eq 0 && "$OUT" == *"claude native 2.0.0 -> 2.0.1 updated"* ]] && grep -Fxq "claude install 2.0.1" "$CALLS" && ! grep -Fxq "claude update" "$CALLS" && no_stdin_leak'
check "native claude: only the registry metadata is read, no npm" 'grep -Fxq "curl -fsSL --proto =https --max-time 60 $NPM_BASE/@anthropic-ai%2fclaude-code" "$CALLS" && ! grep -q "^npm" "$CALLS"'

reset
native_claude 2.0.0 2.0.9
npm_meta @anthropic-ai/claude-code "latest=2.0.9,stable=2.0.1" "2.0.1=100" "2.0.9=1"
run
check "native claude: the stable tag is the target even when latest is newer" '[[ "$OUT" == *"claude native 2.0.0 -> 2.0.1 updated"* ]] && grep -Fxq "claude install 2.0.1" "$CALLS"'

reset
native_claude 2.0.0 2.0.1
claude_stable 2.0.1 10
run
check "native claude: a stable release younger than the cooldown is held" '[[ "$RC" -eq 0 && "$OUT" == *"claude native 2.0.0 -> 2.0.0 held"*"2.0.1"*"10h"* ]] && no_mutation'
BROKKR_AGENT_CLI_MIN_AGE_HOURS=0 run
check "native claude: a cooldown of 0 installs it anyway" '[[ "$OUT" == *"claude native 2.0.0 -> 2.0.1 updated"* ]]'

reset
native_claude 2.0.0 2.0.0
claude_stable 2.0.0
run
check "native claude: stable equal to the installed version is current" '[[ "$RC" -eq 0 && "$OUT" == *"claude native 2.0.0 -> 2.0.0 current"* ]] && no_mutation'

reset
native_claude 2.0.5 2.0.5
claude_stable 2.0.1
run
check "native claude: stable older than the installed version is current, never a downgrade" '[[ "$OUT" == *"claude native 2.0.5 -> 2.0.5 current"* ]] && no_mutation'

reset
native_claude 2.0.0 2.0.1
npm_meta @anthropic-ai/claude-code "latest=2.0.1" "2.0.1=100"
run
check "native claude: no stable tag means the age cannot be evaluated: held" '[[ "$RC" -eq 0 && "$OUT" == *"claude native"*held*"cannot evaluate release age"* ]] && no_mutation'

reset
native_claude 2.0.0 2.0.1
npm_meta @anthropic-ai/claude-code "latest=2.0.1,stable=2.0.1" "2.0.0=100"
run
check "native claude: a stable version with no publish time is held" '[[ "$RC" -eq 0 && "$OUT" == *"claude native"*held*"cannot evaluate release age"* ]] && no_mutation'

reset
native_claude 2.0.0 2.0.1
run
check "native claude: a metadata fetch failure is held" '[[ "$RC" -eq 0 && "$OUT" == *"claude native"*held*"cannot evaluate release age"* ]] && no_mutation'

reset
native_claude 2.0.0 2.0.1
claude_stable 2.0.1
only_path
run
check "native claude: with neither python3 nor node the tool is held, not guessed at" '[[ "$RC" -eq 0 && "$OUT" == *"claude native 2.0.0 -> 2.0.0 held"*"cannot evaluate release age"* ]] && no_mutation'
unset PATH_ONLY

reset
native_claude 2.0.0 2.0.1
claude_stable 2.0.1
ln -s "$HOME_DIR" "$TMP/home-link"
RUN_HOME="$TMP/home-link" run --tool claude
check "native claude: a HOME that is itself a symlink still matches the resolved install path" '[[ "$RC" -eq 0 && "$OUT" == *"claude native"*updated* ]]'

reset
native_claude 2.0.0 2.0.1
claude_stable 2.0.1
echo 2.0.1 >"$VERDIR/claude.broken-at"
run
check "native smoke failure: failed, no automatic rollback, the manual rollback is named" '[[ "$RC" -eq 1 && "$OUT" == *"claude native"*failed*"smoke check failed; no automatic rollback"*"claude install 2.0.0"* ]] && ! grep -q "^npm" "$CALLS"'

reset
native_claude 2.0.0 2.0.1
claude_stable 2.0.1
echo 2.0.2 >"$VERDIR/claude.install-as"
run
check "native version mismatch: claude --version differs from the target, failed with the manual rollback" '[[ "$RC" -eq 1 && "$OUT" == *"claude native"*failed*"2.0.2"*"2.0.1"*"claude install 2.0.0"* ]]'

reset
native_claude 2.0.0 2.0.1
claude_stable 2.0.1
touch "$VERDIR/claude.update-fail"
npm_tool codex @openai/codex 0.9.0
latest @openai/codex 0.10.0
run
check "a failed update command is failed, others still run" '[[ "$RC" -eq 1 && "$OUT" == *"claude native"*failed*"exit 7"* ]] && grep -Fq "@openai/codex@0.10.0" "$CALLS"'

reset
native_claude 2.0.0 2.0.1
claude_stable 2.0.1
run --dry-run
check "native dry-run: would run claude install <target>, no mutation" '[[ "$RC" -eq 0 && "$OUT" == *"claude native 2.0.0 -> 2.0.1 would-update"*"would run: claude install 2.0.1"* ]] && no_mutation'

# --- codex standalone: gated on the newest stable GitHub release, verified after `codex update` --------
reset
standalone_codex 0.5.0 0.6.0
codex_release 0.6.0
run
check "codex standalone: runs codex update and verifies the version it gated" '[[ "$RC" -eq 0 && "$OUT" == *"codex codex-standalone 0.5.0 -> 0.6.0 updated"* ]] && grep -Fxq "codex update" "$CALLS" && no_stdin_leak'
check "codex standalone: reads the openai/codex release list" 'grep -Fxq "curl -fsSL --proto =https --max-time 60 $GH_API/repos/openai/codex/releases?per_page=50" "$CALLS"'

reset
standalone_codex 0.5.0 0.6.0
codex_release 0.6.0 10
run
check "codex standalone: a release younger than the cooldown is held, codex update never runs" '[[ "$RC" -eq 0 && "$OUT" == *"codex codex-standalone 0.5.0 -> 0.5.0 held"*"0.6.0"*"10h"* ]] && no_mutation'

reset
standalone_codex 0.5.0 0.6.0
codex_release 0.5.0
run
check "codex standalone: target equal to the installed version is current" '[[ "$RC" -eq 0 && "$OUT" == *"codex codex-standalone 0.5.0 -> 0.5.0 current"* ]] && no_mutation'

reset
standalone_codex 0.5.0 0.5.5
gh_releases openai/codex "rust-v0.6.0=200" "rust-v0.5.5=100" "rust-v0.5.0=900"
run
check "codex standalone: the target is the newest PUBLISHED release, which is what codex update installs" '[[ "$OUT" == *"codex codex-standalone 0.5.0 -> 0.5.5 updated"* ]]'

reset
standalone_codex 0.5.0 0.6.0
gh_releases openai/codex "rust-v0.6.0=100" "rust-v0.7.0=1:pre" "rust-v0.7.1=1:draft" "rust-v0.8.0-alpha.1=1" "v0.9.0=1" "rust-v0.5.0=900"
run
check "codex standalone: prereleases, drafts, suffixed versions and other tags never become the target" '[[ "$OUT" == *"codex codex-standalone 0.5.0 -> 0.6.0 updated"* ]]'

reset
standalone_codex 0.5.0 0.7.0
codex_release 0.6.0
run
check "codex standalone: codex update installs a different version than gated: failed" '[[ "$RC" -eq 1 && "$OUT" == *"codex codex-standalone"*failed*"codex update installed 0.7.0, expected 0.6.0"* ]]'

reset
standalone_codex 0.5.0 0.6.0
run
check "codex standalone: a release-list fetch failure is held" '[[ "$RC" -eq 0 && "$OUT" == *"codex codex-standalone"*held*"cannot evaluate release age"* ]] && no_mutation'

reset
standalone_codex 0.5.0 0.6.0
codex_release 0.6.0
only_path
run
check "codex standalone: with neither python3 nor node the tool is held" '[[ "$RC" -eq 0 && "$OUT" == *"codex codex-standalone"*held*"cannot evaluate release age"* ]] && no_mutation'
unset PATH_ONLY

reset
standalone_codex 0.5.0 0.6.0
codex_release 0.6.0
run --dry-run
check "codex standalone dry-run: would-update and nothing is run" '[[ "$OUT" == *"codex codex-standalone 0.5.0 -> 0.6.0 would-update"*"would run: codex update"* ]] && no_mutation'

# --- opencode installer: candidate from the registry line that matches the installed major ---------------
reset
installer_opencode 1.0.0 1.1.0
latest opencode-ai 1.1.0
run
check "opencode installer (1.x): upgrades to the aged opencode-ai version by name and verifies it" '[[ "$RC" -eq 0 && "$OUT" == *"opencode opencode-installer 1.0.0 -> 1.1.0 updated"* ]] && grep -Fxq "opencode upgrade 1.1.0" "$CALLS" && ! grep -Fxq "opencode upgrade" "$CALLS" && no_stdin_leak'
check "opencode installer (1.x): reads opencode-ai metadata only" 'grep -Fq "$NPM_BASE/opencode-ai" "$CALLS" && ! grep -Fq "@opencode%2fcli" "$CALLS"'

reset
installer_opencode 2.0.0 2.1.0
npm_meta @opencode/cli "latest=2.2.0" "2.0.0=900" "2.1.0=100" "2.2.0=3"
npm_meta opencode-ai "latest=1.9.9" "1.9.9=100"
run
check "opencode installer (2.x): candidates come from @opencode/cli, newest aged one" '[[ "$RC" -eq 0 && "$OUT" == *"opencode opencode-installer 2.0.0 -> 2.1.0 updated"* ]] && grep -Fxq "opencode upgrade 2.1.0" "$CALLS" && grep -Fq "$NPM_BASE/@opencode%2fcli" "$CALLS" && ! grep -Fq "$NPM_BASE/opencode-ai" "$CALLS"'

reset
installer_opencode 1.0.0 1.1.0
npm_meta opencode-ai "latest=1.1.0" "1.0.0=900" "1.1.0=2"
npm_meta @opencode/cli "latest=2.0.0" "2.0.0=900"
run
check "opencode installer: a young release is held and a 2.x release is not offered to a 1.x install" '[[ "$RC" -eq 0 && "$OUT" == *"opencode opencode-installer 1.0.0 -> 1.0.0 held"*"1.1.0"*"2h"* ]] && no_mutation'

reset
installer_opencode 1.0.0 1.1.0
latest opencode-ai 1.1.0
echo 1.1.0 >"$VERDIR/opencode.broken-at"
run
check "opencode smoke failure: reinstalls the previous version with opencode upgrade <before>" '[[ "$RC" -eq 1 && "$OUT" == *"opencode opencode-installer"*rolled-back* ]] && grep -Fxq "opencode upgrade 1.0.0" "$CALLS"'

reset
installer_opencode 1.0.0 1.1.0
latest opencode-ai 1.1.0
echo 1.1.5 >"$VERDIR/opencode.install-as"
run
check "opencode version mismatch after the upgrade counts as a smoke failure: rolled back" '[[ "$RC" -eq 1 && "$OUT" == *"opencode opencode-installer"*rolled-back* ]] && grep -Fxq "opencode upgrade 1.0.0" "$CALLS" && [[ "$(cat "$VERDIR/opencode")" == 1.0.0 ]]'

reset
installer_opencode 1.0.0 1.1.0
latest opencode-ai 1.1.0
touch "$VERDIR/opencode.noversion"
run
check "opencode installer: an installed version that cannot be read is a failure, nothing is upgraded" '[[ "$RC" -eq 1 && "$OUT" == *"opencode opencode-installer"*failed* ]] && no_mutation'

reset
installer_opencode 1.0.0 1.1.0
run
check "opencode installer: a metadata fetch failure is held" '[[ "$RC" -eq 0 && "$OUT" == *"opencode opencode-installer"*held*"cannot evaluate release age"* ]] && no_mutation'

reset
installer_opencode 1.0.0 1.1.0
latest opencode-ai 1.0.0
run
check "opencode installer: nothing newer is current" '[[ "$RC" -eq 0 && "$OUT" == *"opencode opencode-installer 1.0.0 -> 1.0.0 current"* ]] && no_mutation'

reset
installer_opencode 1.0.0 1.1.0
latest opencode-ai 1.1.0
run --dry-run
check "opencode installer dry-run: would run opencode upgrade <version>, nothing is run" '[[ "$OUT" == *"opencode opencode-installer 1.0.0 -> 1.1.0 would-update"*"would run: opencode upgrade 1.1.0"* ]] && no_mutation'

# --- brew: only codex has a known release source -----------------------------------------------------
reset
brew_cask codex 0.5.0 0.6.0
brew_info cask codex 0.6.0
codex_release 0.6.0
run
check "brew cask codex: the Homebrew version is age-checked against its GitHub release, then brew upgrade --cask" '[[ "$RC" -eq 0 && "$OUT" == *"codex brew 0.5.0 -> 0.6.0 updated"* ]] && grep -Fxq "brew info --json=v2 --cask codex" "$CALLS" && grep -Fxq "brew upgrade --cask codex" "$CALLS" && grep -Fq "$GH_API/repos/openai/codex/releases?per_page=50" "$CALLS" && no_stdin_leak'

reset
brew_cask codex 0.5.0 0.6.0
brew_info cask codex 0.6.0
codex_release 0.6.0 10
run
check "brew cask codex: a release younger than the cooldown is held, brew upgrade never runs" '[[ "$RC" -eq 0 && "$OUT" == *"codex brew 0.5.0 -> 0.5.0 held"*"0.6.0"*"10h"* ]] && no_mutation'

reset
brew_cask codex 0.5.0 0.6.0
brew_info cask codex 0.6.0
gh_releases openai/codex "rust-v0.5.0=900"
run
check "brew cask codex: a Homebrew version with no GitHub release is held" '[[ "$RC" -eq 0 && "$OUT" == *"codex brew"*held*"cannot evaluate release age"* ]] && no_mutation'

reset
brew_cask codex 0.6.0 0.6.0
brew_info cask codex 0.6.0
run
check "brew cask codex: target equal to the installed version is current without any GitHub lookup" '[[ "$RC" -eq 0 && "$OUT" == *"codex brew 0.6.0 -> 0.6.0 current"* ]] && no_mutation && [[ "$(curl_calls)" -eq 0 ]]'

reset
brew_cask codex 0.5.0 0.6.0
run
check "brew cask codex: brew info failing is held" '[[ "$RC" -eq 0 && "$OUT" == *"codex brew"*held*"cannot evaluate release age"* ]] && no_mutation'

reset
brew_cask codex 0.5.0 0.7.0
brew_info cask codex 0.6.0
codex_release 0.6.0
run
check "brew cask codex: brew upgrade installing a different version than gated is failed" '[[ "$RC" -eq 1 && "$OUT" == *"codex brew"*failed*"brew upgrade installed 0.7.0, expected 0.6.0"* ]]'

reset
brew_formula codex 1.0.0 1.1.0
brew_info formula codex 1.1.0
codex_release 1.1.0
run
check "brew formula codex: .formulae[0].versions.stable is the target, brew upgrade <name>" '[[ "$RC" -eq 0 && "$OUT" == *"codex brew 1.0.0 -> 1.1.0 updated"* ]] && grep -Fxq "brew info --json=v2 --formula codex" "$CALLS" && grep -Fxq "brew upgrade codex" "$CALLS"'

reset
brew_formula opencode 1.0.0 1.1.0
run
check "brew formula other than codex: held, release age unknown, fail closed" '[[ "$RC" -eq 0 && "$OUT" == *"opencode brew 1.0.0 -> 1.0.0 held"*"release age unknown for Homebrew package opencode"* ]] && no_mutation && [[ "$(curl_calls)" -eq 0 ]]'

reset
brew_cask pi 0.1.0 0.2.0
run
check "brew cask other than codex: held too" '[[ "$RC" -eq 0 && "$OUT" == *"pi brew 0.1.0 -> 0.1.0 held"*"release age unknown for Homebrew package pi"* ]] && no_mutation'

reset
brew_formula opencode 1.0.0 1.1.0
BROKKR_AGENT_CLI_MIN_AGE_HOURS=0 run
check "brew formula other than codex with the cooldown disabled: plain brew upgrade" '[[ "$RC" -eq 0 && "$OUT" == *"opencode brew 1.0.0 -> 1.1.0 updated"* ]] && grep -Fxq "brew upgrade opencode" "$CALLS"'

# Node-based formulae live under Cellar/<name>/<ver>/libexec/lib/node_modules; npm must never
# install into the Cellar behind Homebrew's back.
reset
write_tool_stub "$BREW/Cellar/codex/1.0.0/libexec/lib/node_modules/@openai/codex/bin/codex" codex
ln -s "$BREW/Cellar/codex/1.0.0/libexec/lib/node_modules/@openai/codex/bin/codex" "$TOOLBIN/codex"
echo 1.0.0 >"$VERDIR/codex"; echo 1.1.0 >"$VERDIR/codex.next"
brew_info formula codex 1.1.0
codex_release 1.1.0
run
check "brew formula with libexec node_modules: brew, not npm" '[[ "$RC" -eq 0 && "$OUT" == *"codex brew 1.0.0 -> 1.1.0 updated"* ]] && grep -Fxq "brew upgrade codex" "$CALLS" && ! grep -q "^npm install" "$CALLS"'

reset
write_tool_stub "$BREW/Cellar/opencode/1.0.0/libexec/lib/node_modules/opencode-ai/bin/opencode" opencode
ln -s "$BREW/Cellar/opencode/1.0.0/libexec/lib/node_modules/opencode-ai/bin/opencode" "$TOOLBIN/opencode"
echo 1.0.0 >"$VERDIR/opencode"; echo 1.1.0 >"$VERDIR/opencode.next"
latest opencode-ai 1.1.0
run
check "brew formula with libexec node_modules, not codex: held as a Homebrew package, npm untouched" '[[ "$RC" -eq 0 && "$OUT" == *"opencode brew 1.0.0 -> 1.0.0 held"* ]] && ! grep -q "^npm install" "$CALLS" && no_mutation'

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
latest opencode-ai 1.1.0
brew_cask pi 0.1.0 0.2.0
run --dry-run
check "--dry-run: exit 0, reports what would happen" '[[ "$RC" -eq 0 && "$OUT" == *"claude npm 1.0.0 -> 1.1.0 would-update"* && "$OUT" == *"codex npm 0.9.0 -> 0.9.0 current"* && "$OUT" == *"opencode opencode-installer"*would-update* && "$OUT" == *"pi brew 0.1.0 -> 0.1.0 held"* ]]'
check "--dry-run: makes no install, update, or upgrade call" 'no_mutation'
check "--dry-run: writes no state file" '[[ ! -e "$STATE" && ! -e "$STATE_DIR" ]]'
check "--dry-run: still reads the release metadata read-only" 'grep -Fxq "curl -fsSL --proto =https --max-time 60 $NPM_BASE/@anthropic-ai%2fclaude-code" "$CALLS"'

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
native_claude 2.0.0 2.0.1
claude_stable 2.0.1
npm_tool codex @openai/codex 0.9.0
latest @openai/codex 0.9.0
write_timeout timeout
run
check "version probes and update commands run under timeout when it exists" '[[ "$RC" -eq 0 ]] && grep -Eq "^timeout [0-9]+ claude --version\$" "$CALLS" && grep -Eq "^timeout [0-9]+ claude install 2.0.1\$" "$CALLS"'
check "the release metadata lookup runs under timeout too" 'grep -Eq "^timeout [0-9]+ curl -fsSL --proto =https --max-time 60 $NPM_BASE/@openai%2fcodex\$" "$CALLS"'
rm -f "$BIN/timeout"
if PATH=/usr/bin:/bin command -v timeout >/dev/null 2>&1; then
  skip "gtimeout fallback (a real timeout exists in /usr/bin:/bin)"
else
  reset
  native_claude 2.0.0 2.0.1
  claude_stable 2.0.1
  write_timeout gtimeout
  run --tool claude
  check "version probes fall back to gtimeout" '[[ "$RC" -eq 0 ]] && grep -Eq "^gtimeout [0-9]+ claude --version\$" "$CALLS"'
fi
rm -f "$BIN/gtimeout"
reset
native_claude 2.0.0 2.0.1
claude_stable 2.0.1
run --tool claude
check "without any timeout command the probes and update still run" '[[ "$RC" -eq 0 && "$OUT" == *"claude native 2.0.0 -> 2.0.1 updated"* ]]'

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
