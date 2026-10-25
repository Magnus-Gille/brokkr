#!/usr/bin/env bash
# Brokkr · keep the coding-agent CLIs (claude, codex, pi, opencode) at their latest release.
# Runs ON the host: from a launchd LaunchAgent on the macOS workstation (launchd/) and from a
# systemd user timer on Linux fleet nodes (systemd/user/, installed by
# scripts/deploy-agent-cli-update.sh). See docs/agent-cli-update.md.
#
# Each tool found on PATH is classified from its fully resolved binary path, and only that
# install method's own updater runs. A tool that is not installed is skipped (never installed),
# an apt-owned one is left to unattended-upgrades, and anything unrecognised is a failure rather
# than a guess. After a mutation the tool must still print a version; an npm or opencode-installer
# install that does not is rolled back to the previous version. The script runs under macOS
# /bin/bash 3.2 and Linux bash 5: no associative arrays, mapfile, ${x,,}, namerefs or wait -n.
#
#   scripts/agent-cli-update.sh [--dry-run] [--tool NAME]...
#
# Exit 0: everything ok, current, absent, external, or the run was deferred. Exit 1: a tool
# failed or was rolled back (the others are still attempted) or the state file could not be
# written. Exit 64: usage or configuration error.
set -euo pipefail

# Bounds so one hung child cannot block every later scheduled run (used only where a
# timeout command exists; stock macOS has none).
VERSION_TIMEOUT=60
LOOKUP_TIMEOUT=120
UPDATE_TIMEOUT=1200
KNOWN_TOOLS="claude codex pi opencode"

die() { echo "brokkr agent-cli-update: $*" >&2; exit 64; }
usage_text() {
  echo "usage: $0 [--dry-run] [--tool NAME]..."
  echo "  tools: $KNOWN_TOOLS (default; or BROKKR_AGENT_CLI_TOOLS, space separated)"
  echo "  --dry-run  classify and look versions up; run no install/update and write no state"
  echo "  env: BROKKR_AGENT_CLI_BUSY_UNITS (space-separated systemd user units; defer while one has spawned work),"
  echo "       BROKKR_STATE_DIR (default \${XDG_STATE_HOME:-~/.local/state}/brokkr)"
}
usage() { usage_text >&2; exit 64; }

DRY_RUN=0
TOOL_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --tool)
      [ "$#" -ge 2 ] || usage
      TOOL_ARGS[${#TOOL_ARGS[@]}]=$2
      shift ;;
    -h|--help) usage_text; exit 0 ;;
    *) usage ;;
  esac
  shift
done

case "${HOME:-}" in /*) ;; *) die "HOME must be set to an absolute path" ;; esac
# Install paths are compared after symlink resolution, so also accept the resolved HOME.
HOME_REAL=$(cd "$HOME" 2>/dev/null && pwd -P) || die "HOME is not accessible"

# --- configuration (validated before anything runs) ---------------------------------------------
TOOLS=()
add_tool() {
  local t=$1 i=0
  case "$t" in
    claude|codex|pi|opencode) ;;
    *) die "unknown tool '$t' (known: $KNOWN_TOOLS)" ;;
  esac
  while [ "$i" -lt "${#TOOLS[@]}" ]; do
    [ "${TOOLS[$i]}" != "$t" ] || return 0
    i=$((i + 1))
  done
  TOOLS[${#TOOLS[@]}]=$t
}
TOOL_WORDS=()
if [ "${#TOOL_ARGS[@]}" -gt 0 ]; then
  # --tool replaces the environment/default list.
  TOOL_WORDS=("${TOOL_ARGS[@]}")
else
  TOOL_LIST=${BROKKR_AGENT_CLI_TOOLS-$KNOWN_TOOLS}
  case "$TOOL_LIST" in
    *[!A-Za-z0-9._\ -]*) die "invalid BROKKR_AGENT_CLI_TOOLS (space-separated tool names)" ;;
  esac
  IFS=' ' read -r -a TOOL_WORDS <<<"$TOOL_LIST"
fi
[ "${#TOOL_WORDS[@]}" -gt 0 ] || die "no tools selected"
i=0
while [ "$i" -lt "${#TOOL_WORDS[@]}" ]; do
  add_tool "${TOOL_WORDS[$i]}"
  i=$((i + 1))
done

# A unit name must not start with '-': it is passed to systemctl as a plain argument.
UNIT_RE='^[A-Za-z0-9@_.][A-Za-z0-9@._-]*\.service$'
BUSY_RAW=${BROKKR_AGENT_CLI_BUSY_UNITS-}
case "$BUSY_RAW" in
  *[!A-Za-z0-9@._\ -]*) die "invalid BROKKR_AGENT_CLI_BUSY_UNITS (space-separated .service unit names)" ;;
esac
BUSY_WORDS=()
IFS=' ' read -r -a BUSY_WORDS <<<"$BUSY_RAW"
BUSY_UNITS=()
i=0
while [ "$i" -lt "${#BUSY_WORDS[@]}" ]; do
  [[ "${BUSY_WORDS[$i]}" =~ $UNIT_RE ]] || die "invalid BROKKR_AGENT_CLI_BUSY_UNITS entry '${BUSY_WORDS[$i]}' (a .service unit name is required)"
  BUSY_UNITS[${#BUSY_UNITS[@]}]=${BUSY_WORDS[$i]}
  i=$((i + 1))
done

CGROUP_ROOT=${BROKKR_CGROUP_ROOT:-/sys/fs/cgroup}
STATE_DIR=${BROKKR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/brokkr}
case "$STATE_DIR" in /*) ;; *) die "the state directory must be an absolute path" ;; esac
STATE_FILE=$STATE_DIR/agent-cli-update.json

TIMEOUT_BIN=
for candidate in timeout gtimeout; do
  if TIMEOUT_BIN=$(command -v "$candidate" 2>/dev/null); then break; fi
  TIMEOUT_BIN=
done

# --- helpers ---------------------------------------------------------------------------------------
run_limited() { # seconds command... ; no timeout command means no bound
  local secs=$1
  shift
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$secs" "$@"; else "$@"; fi
}

# Prints the first MAJOR.MINOR.PATCH that "$1 --version" reports. It fails when the command
# exits non-zero or prints none, which doubles as the post-update smoke check.
tool_version() {
  local out ver
  out=$(run_limited "$VERSION_TIMEOUT" "$1" --version </dev/null 2>&1) || return 1
  ver=$(printf '%s\n' "$out" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1) || true
  [ -n "$ver" ] || return 1
  printf '%s\n' "$ver"
}

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]*)?$'
is_semver() { [[ "$1" =~ $SEMVER_RE ]]; }

# Free text from the filesystem is reduced to a safe set before it reaches the log line.
safe_text() { printf '%s' "$1" | tr -c 'A-Za-z0-9@/._+: -' '?'; }

allowed_package() {
  case "$1" in
    claude) echo '@anthropic-ai/claude-code' ;;
    codex) echo '@openai/codex' ;;
    pi) echo '@earendil-works/pi-coding-agent' ;;
    opencode) echo 'opencode-ai' ;;
  esac
}

# True when $1 lies below $HOME/$2/ (as written or with HOME resolved).
under_home() {
  case "$1" in
    "$HOME/$2/"*|"$HOME_REAL/$2/"*) return 0 ;;
  esac
  return 1
}

# --- busy guard -----------------------------------------------------------------------------------
# Counts PIDs across every cgroup.procs below a cgroup directory. Fails when nothing can be read.
count_cgroup_pids() {
  local dir=$1 files f n total=0
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 1
  files=$(find "$dir" -type f -name cgroup.procs 2>/dev/null) || return 1
  [ -n "$files" ] || return 1
  while IFS= read -r f; do
    n=$(wc -l <"$f" 2>/dev/null) || return 1
    total=$((total + n))
  done <<EOF
$files
EOF
  printf '%s\n' "$total"
}

# A service's own cgroup holds its main process; more than one PID means it has spawned work
# (an agent task). Sets DEFER_REASON and returns 1 when the run must not touch anything. Anything
# unreadable also defers: an unattended update must not guess that nothing is running.
DEFER_REASON=
check_busy_units() {
  local i=0 unit state cg dir pids
  while [ "$i" -lt "${#BUSY_UNITS[@]}" ]; do
    unit=${BUSY_UNITS[$i]}
    i=$((i + 1))
    if ! state=$(systemctl --user show -p ActiveState --value "$unit" 2>/dev/null); then
      DEFER_REASON="cannot query $unit with systemctl --user (failing closed)"
      return 1
    fi
    [ "$state" = active ] || continue
    if ! cg=$(systemctl --user show -p ControlGroup --value "$unit" 2>/dev/null) || [ -z "$cg" ]; then
      DEFER_REASON="cannot read the control group of active unit $unit (failing closed)"
      return 1
    fi
    case "$cg" in
      */../*|*/..|*//*) DEFER_REASON="unsafe control group for $unit (failing closed)"; return 1 ;;
      /*) ;;
      *) DEFER_REASON="unsafe control group for $unit (failing closed)"; return 1 ;;
    esac
    dir=$CGROUP_ROOT$cg
    if ! pids=$(count_cgroup_pids "$dir"); then
      DEFER_REASON="cannot read cgroup $dir of unit $unit (failing closed)"
      return 1
    fi
    if [ "$pids" -gt 1 ]; then
      DEFER_REASON="$unit is active with $pids processes in its cgroup (an agent task is running)"
      return 1
    fi
  done
  return 0
}

# --- per-tool results ----------------------------------------------------------------------------
NRES=0
R_NAME=(); R_METHOD=(); R_PATH=(); R_BEFORE=(); R_AFTER=(); R_ACTION=(); R_DETAIL=()
record() { # name method path before after action detail
  R_NAME[$NRES]=$1; R_METHOD[$NRES]=$2; R_PATH[$NRES]=$3; R_BEFORE[$NRES]=$4
  R_AFTER[$NRES]=$5; R_ACTION[$NRES]=$6; R_DETAIL[$NRES]=$7
  NRES=$((NRES + 1))
}
dash() { if [ -n "$1" ]; then printf '%s' "$1"; else printf '%s' -; fi; }
report_line() { # name method before after action detail
  printf '%s %s %s -> %s %s' "$1" "$(dash "$2")" "$(dash "$3")" "$(dash "$4")" "$5"
  if [ -n "$6" ]; then printf ' %s' "$6"; fi
  printf '\n'
}
count_action() {
  local n=0 i=0
  while [ "$i" -lt "$NRES" ]; do
    if [ "${R_ACTION[$i]}" = "$1" ]; then n=$((n + 1)); fi
    i=$((i + 1))
  done
  printf '%s' "$n"
}

# Fields of the tool being processed.
T_METHOD=; T_PATH=; T_BEFORE=; T_AFTER=; T_ACTION=; T_DETAIL=
NPM_PREFIX=; NPM_PKG=; BREW_KIND=; BREW_NAME=
fail() { T_ACTION=failed; T_DETAIL=$1; }

classify() { # tool real-path -> T_METHOD
  local tool=$1 real=$2 rest
  T_METHOD=unknown
  if [ "$tool" = claude ] && under_home "$real" .local/share/claude/versions; then T_METHOD=native; return 0; fi
  # Homebrew first: node-based formulae keep a private lib/node_modules under
  # Cellar/<name>/<ver>/libexec, and npm must never install into the Cellar.
  case "$real" in
    */Caskroom/*/*)
      rest=${real#*/Caskroom/}
      BREW_KIND=cask; BREW_NAME=${rest%%/*}; T_METHOD=brew
      return 0 ;;
    */Cellar/*/*)
      rest=${real#*/Cellar/}
      BREW_KIND=formula; BREW_NAME=${rest%%/*}; T_METHOD=brew
      return 0 ;;
    */lib/node_modules/*) T_METHOD=npm; return 0 ;;
  esac
  if [ "$tool" = codex ] && under_home "$real" .codex/packages/standalone; then T_METHOD=codex-standalone; return 0; fi
  if [ "$tool" = opencode ] && under_home "$real" .opencode; then T_METHOD=opencode-installer; return 0; fi
  if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S "$real" >/dev/null 2>&1; then T_METHOD=apt; return 0; fi
  return 0
}

# The post-update smoke check failed: npm and opencode-installer installs go back to the
# previous version; every other method is reported, not guessed at.
smoke_failed() { # tool
  local tool=$1
  case "$T_METHOD" in
    npm)
      echo "smoke check failed for $tool; reinstalling $NPM_PKG@$T_BEFORE"
      if run_limited "$UPDATE_TIMEOUT" npm install -g --prefix "$NPM_PREFIX" --no-fund --no-audit "$NPM_PKG@$T_BEFORE" </dev/null \
        && T_AFTER=$(tool_version "$tool"); then
        T_ACTION=rolled-back; T_DETAIL="smoke check failed after the update; restored $T_BEFORE"
      else
        T_AFTER=
        fail "smoke check failed and rollback to $T_BEFORE did not restore a working CLI"
      fi ;;
    opencode-installer)
      if [ -z "$T_BEFORE" ]; then
        fail "smoke check failed; previous version unknown, no rollback possible"
      else
        echo "smoke check failed for $tool; running: opencode upgrade $T_BEFORE"
        if run_limited "$UPDATE_TIMEOUT" opencode upgrade "$T_BEFORE" </dev/null && T_AFTER=$(tool_version "$tool"); then
          T_ACTION=rolled-back; T_DETAIL="smoke check failed after the update; restored $T_BEFORE"
        else
          T_AFTER=
          fail "smoke check failed and rollback to $T_BEFORE did not restore a working CLI"
        fi
      fi ;;
    *) fail "smoke check failed; no automatic rollback" ;;
  esac
  return 0
}

# Methods that update by running their own command: run it, then smoke-check the result.
update_with_command() { # tool command...
  local tool=$1 rc=0
  shift
  if [ "$DRY_RUN" -eq 1 ]; then T_ACTION=would-update; T_DETAIL="would run: $*"; return 0; fi
  run_limited "$UPDATE_TIMEOUT" "$@" </dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then fail "update command failed (exit $rc)"; return 0; fi
  if ! T_AFTER=$(tool_version "$tool"); then smoke_failed "$tool"; return 0; fi
  if [ "$T_AFTER" = "$T_BEFORE" ]; then T_ACTION=current; else T_ACTION=updated; fi
  return 0
}

update_npm() { # tool
  local tool=$1 rest first remainder expected pj latest rc=0
  NPM_PREFIX=${T_PATH%%/lib/node_modules/*}
  rest=${T_PATH#*/lib/node_modules/}
  case "$rest" in
    @*/*) first=${rest%%/*}; remainder=${rest#*/}; NPM_PKG=$first/${remainder%%/*} ;;
    *) NPM_PKG=${rest%%/*} ;;
  esac
  expected=$(allowed_package "$tool")
  if [ "$tool" = pi ] && [ "$NPM_PKG" = @mariozechner/pi-coding-agent ]; then
    fail "legacy package; migrate to @earendil-works/pi-coding-agent"; return 0
  fi
  if [ "$NPM_PKG" != "$expected" ]; then
    fail "package $(safe_text "$NPM_PKG") is not the expected $expected"; return 0
  fi
  if [ -z "$NPM_PREFIX" ]; then fail "cannot determine the npm prefix"; return 0; fi
  if [ ! -w "$NPM_PREFIX/lib/node_modules" ]; then fail "npm prefix not writable (root-managed)"; return 0; fi
  if ! command -v node >/dev/null 2>&1; then fail "node not found on PATH"; return 0; fi
  if ! command -v npm >/dev/null 2>&1; then fail "npm not found on PATH"; return 0; fi
  pj=$NPM_PREFIX/lib/node_modules/$NPM_PKG/package.json
  # The path is an argument, never interpolated into the JavaScript.
  if ! T_BEFORE=$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version' "$pj" 2>/dev/null) \
    || ! is_semver "$T_BEFORE"; then
    T_BEFORE=
    fail "cannot read the installed version from package.json"; return 0
  fi
  if ! latest=$(run_limited "$LOOKUP_TIMEOUT" npm view "$NPM_PKG" version </dev/null) || ! is_semver "$latest"; then
    fail "cannot determine the latest version (npm view failed or answered unexpectedly)"; return 0
  fi
  if [ "$latest" = "$T_BEFORE" ]; then T_ACTION=current; T_AFTER=$T_BEFORE; return 0; fi
  if [ "$DRY_RUN" -eq 1 ]; then
    T_ACTION=would-update; T_AFTER=$latest
    T_DETAIL="would run: npm install -g --prefix $(safe_text "$NPM_PREFIX") $NPM_PKG@$latest"
    return 0
  fi
  run_limited "$UPDATE_TIMEOUT" npm install -g --prefix "$NPM_PREFIX" --no-fund --no-audit "$NPM_PKG@$latest" </dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    T_AFTER=$(tool_version "$tool") || T_AFTER=
    fail "npm install failed (exit $rc)"
    if [ -z "$T_AFTER" ]; then T_DETAIL="$T_DETAIL; the CLI no longer reports a version"; fi
    return 0
  fi
  if ! T_AFTER=$(tool_version "$tool"); then smoke_failed "$tool"; return 0; fi
  T_ACTION=updated
  if [ "$T_AFTER" != "$latest" ]; then T_DETAIL="installed $latest but --version reports $T_AFTER"; fi
  return 0
}

update_brew() { # tool
  local tool=$1
  if ! [[ "$BREW_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]]; then fail "unexpected Homebrew package name"; return 0; fi
  if ! command -v brew >/dev/null 2>&1; then fail "brew not found on PATH"; return 0; fi
  if [ "$BREW_KIND" = cask ]; then
    update_with_command "$tool" brew upgrade --cask "$BREW_NAME"
  else
    update_with_command "$tool" brew upgrade "$BREW_NAME"
  fi
}

process_tool() { # tool -> T_* fields
  local tool=$1 bin real
  T_METHOD=; T_PATH=; T_BEFORE=; T_AFTER=; T_ACTION=; T_DETAIL=
  bin=$(command -v "$tool" 2>/dev/null) || bin=
  if [ -z "$bin" ]; then T_ACTION=absent; return 0; fi
  T_METHOD=unknown
  case "$bin" in /*) ;; *) fail "resolves to a non-file command"; return 0 ;; esac
  real=$(readlink -f "$bin" 2>/dev/null) || real=
  if [ -z "$real" ]; then T_PATH=$bin; fail "cannot resolve the real path of the binary"; return 0; fi
  T_PATH=$real
  classify "$tool" "$real"
  case "$T_METHOD" in
    npm) update_npm "$tool"; return 0 ;;
  esac
  T_BEFORE=$(tool_version "$tool") || T_BEFORE=
  case "$T_METHOD" in
    native) update_with_command "$tool" claude update ;;
    brew) update_brew "$tool" ;;
    codex-standalone) update_with_command "$tool" codex update ;;
    opencode-installer) update_with_command "$tool" opencode upgrade ;;
    apt) T_ACTION=external; T_AFTER=$T_BEFORE; T_DETAIL="managed by apt/unattended-upgrades" ;;
    *) fail "unknown install method" ;;
  esac
  return 0
}

# --- state file ------------------------------------------------------------------------------------
# JSON strings in pure shell: escape \ and ", and every control character as \u00XX. Callers run
# this under LC_ALL=C so bytes, not locale characters, are walked; other bytes pass through.
JSTR=
json_str() {
  local s=$1 out='' c i=0 n code
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c=${s:$i:1}
    case "$c" in
      '\') out="$out\\\\" ;;
      '"') out="$out\\\"" ;;
      [[:cntrl:]])
        code=$(printf '%d' "'$c")
        out="$out$(printf '\\u%04x' "$code")" ;;
      *) out="$out$c" ;;
    esac
    i=$((i + 1))
  done
  JSTR="\"$out\""
}

RESULT=ok
RESULT_DETAIL=
RUN_TS=
RUN_HOST=
render_state_json() {
  local i=0 sep j1 j2 j3 j4 j5 j6 j7
  printf '{\n'
  json_str "$RUN_TS"; printf '  "timestamp": %s,\n' "$JSTR"
  json_str "$RUN_HOST"; printf '  "hostname": %s,\n' "$JSTR"
  json_str "$RESULT"; printf '  "result": %s,\n' "$JSTR"
  json_str "$RESULT_DETAIL"; printf '  "detail": %s,\n' "$JSTR"
  if [ "$NRES" -eq 0 ]; then
    printf '  "tools": []\n'
  else
    printf '  "tools": [\n'
    while [ "$i" -lt "$NRES" ]; do
      json_str "${R_NAME[$i]}"; j1=$JSTR
      json_str "${R_METHOD[$i]}"; j2=$JSTR
      json_str "${R_PATH[$i]}"; j3=$JSTR
      json_str "${R_BEFORE[$i]}"; j4=$JSTR
      json_str "${R_AFTER[$i]}"; j5=$JSTR
      json_str "${R_ACTION[$i]}"; j6=$JSTR
      json_str "${R_DETAIL[$i]}"; j7=$JSTR
      sep=,
      if [ "$i" -eq $((NRES - 1)) ]; then sep=; fi
      printf '    {"name": %s, "method": %s, "path": %s, "before": %s, "after": %s, "action": %s, "detail": %s}%s\n' \
        "$j1" "$j2" "$j3" "$j4" "$j5" "$j6" "$j7" "$sep"
      i=$((i + 1))
    done
    printf '  ]\n'
  fi
  printf '}\n'
}

# Written atomically (temp file in the same directory, then rename) and privately.
write_state() {
  local tmp
  (umask 077; mkdir -p "$STATE_DIR") || return 1
  tmp=$(umask 077; mktemp "$STATE_DIR/.agent-cli-update.json.XXXXXX") || return 1
  if ! (LC_ALL=C; render_state_json) >"$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv -f "$tmp" "$STATE_FILE"; then rm -f "$tmp"; return 1; fi
}

finish() { # prints the summary, records the state, and exits
  local summary rc=0
  summary="summary: result=$RESULT tools=$NRES updated=$(count_action updated)"
  if [ "$DRY_RUN" -eq 1 ]; then summary="$summary would-update=$(count_action would-update)"; fi
  summary="$summary current=$(count_action current) external=$(count_action external) absent=$(count_action absent)"
  summary="$summary failed=$(count_action failed) rolled-back=$(count_action rolled-back)"
  echo "$summary"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry-run: nothing was installed or updated and no state file was written"
  elif ! write_state; then
    echo "brokkr agent-cli-update: cannot write the state file in $STATE_DIR" >&2
    rc=1
  fi
  if [ "$RESULT" = failed ]; then rc=1; fi
  exit "$rc"
}

# --- run ---------------------------------------------------------------------------------------------
RUN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_HOST=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)
echo "brokkr agent-cli-update: $RUN_TS tools: ${TOOLS[*]}"

if [ "${#BUSY_UNITS[@]}" -gt 0 ] && ! check_busy_units; then
  RESULT=deferred
  RESULT_DETAIL=$DEFER_REASON
  echo "deferred: $DEFER_REASON; no agent CLI was touched"
  finish
fi

i=0
while [ "$i" -lt "${#TOOLS[@]}" ]; do
  process_tool "${TOOLS[$i]}"
  record "${TOOLS[$i]}" "$T_METHOD" "$T_PATH" "$T_BEFORE" "$T_AFTER" "$T_ACTION" "$T_DETAIL"
  report_line "${TOOLS[$i]}" "$T_METHOD" "$T_BEFORE" "$T_AFTER" "$T_ACTION" "$T_DETAIL"
  case "$T_ACTION" in failed|rolled-back) RESULT=failed ;; esac
  i=$((i + 1))
done
finish
