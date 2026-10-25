#!/usr/bin/env bash
# Brokkr · keep the coding-agent CLIs (claude, codex, pi, opencode) at their latest release.
# Runs ON the host: from a launchd LaunchAgent on the macOS workstation (launchd/) and from a
# systemd user timer on Linux fleet nodes (systemd/user/, installed by
# scripts/deploy-agent-cli-update.sh). See docs/agent-cli-update.md.
#
# Each tool found on PATH is classified from its fully resolved binary path, and only that
# install method's own updater runs. A tool that is not installed is skipped (never installed),
# an apt-owned one is left to unattended-upgrades, and anything unrecognised is a failure rather
# than a guess. After a mutation the tool must still print a version; an npm, opencode-installer
# or pi-release install that does not is rolled back to the previous version. The script runs
# under macOS /bin/bash 3.2 and Linux bash 5: no associative arrays, mapfile, ${x,,}, namerefs or
# wait -n.
#
# Release-age cooldown: a release is only installed once it has been published for
# BROKKR_AGENT_CLI_MIN_AGE_HOURS (default 48), so a bad release can be pulled upstream before it
# reaches the fleet. Every method decides from release metadata (the npm registry, or GitHub
# releases), never from "whatever the vendor's updater would fetch"; a newer version that is too
# young, or whose age cannot be evaluated, leaves the tool `held` (not a failure).
#
#   scripts/agent-cli-update.sh [--dry-run] [--tool NAME]... [--adopt pi]
#
# Exit 0: everything ok, current, held, absent, external, or the run was deferred. Exit 1: a tool
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
  echo "usage: $0 [--dry-run] [--tool NAME]... [--adopt pi]"
  echo "  tools: $KNOWN_TOOLS (default; or BROKKR_AGENT_CLI_TOOLS, space separated)"
  echo "  --dry-run  classify and look versions up; run no install/update and write no state"
  echo "  --adopt pi install pi as a checksum-verified release binary (migration from npm; only pi)"
  echo "  env: BROKKR_AGENT_CLI_MIN_AGE_HOURS (0..720, default 48; 0 disables the release-age cooldown),"
  echo "       BROKKR_AGENT_CLI_BUSY_UNITS (space-separated systemd user units; defer while one has spawned work),"
  echo "       BROKKR_STATE_DIR (default \${XDG_STATE_HOME:-~/.local/state}/brokkr)"
}
usage() { usage_text >&2; exit 64; }

DRY_RUN=0
ADOPT=
TOOL_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --tool)
      [ "$#" -ge 2 ] || usage
      TOOL_ARGS[${#TOOL_ARGS[@]}]=$2
      shift ;;
    --adopt)
      [ "$#" -ge 2 ] || usage
      ADOPT=$2
      shift ;;
    -h|--help) usage_text; exit 0 ;;
    *) usage ;;
  esac
  shift
done
case "$ADOPT" in
  ''|pi) ;;
  *) die "--adopt supports only pi, not '$ADOPT'" ;;
esac

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
elif [ "$ADOPT" = pi ]; then
  # A migration is one deliberate action: --adopt pi alone touches only pi.
  TOOL_WORDS=(pi)
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
if [ "$ADOPT" = pi ]; then
  i=0
  adopt_selected=0
  while [ "$i" -lt "${#TOOLS[@]}" ]; do
    if [ "${TOOLS[$i]}" = pi ]; then adopt_selected=1; fi
    i=$((i + 1))
  done
  [ "$adopt_selected" -eq 1 ] || die "--adopt pi needs pi among the selected tools"
fi

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

# Release-age cooldown (0 disables it) and the clock it is measured against. The digits are
# checked before any arithmetic: bash evaluates names inside $(( )) recursively.
MIN_AGE_HOURS=${BROKKR_AGENT_CLI_MIN_AGE_HOURS-48}
if ! [[ "$MIN_AGE_HOURS" =~ ^[0-9]{1,3}$ ]] || [ "$((10#$MIN_AGE_HOURS))" -gt 720 ]; then
  die "invalid BROKKR_AGENT_CLI_MIN_AGE_HOURS (an integer from 0 to 720)"
fi
MIN_AGE_HOURS=$((10#$MIN_AGE_HOURS))
if [ -n "${BROKKR_NOW_EPOCH+set}" ]; then
  [[ "$BROKKR_NOW_EPOCH" =~ ^[0-9]{1,12}$ ]] || die "invalid BROKKR_NOW_EPOCH (epoch seconds)"
  NOW_EPOCH=$((10#$BROKKR_NOW_EPOCH))
else
  NOW_EPOCH=$(date +%s)
fi

# Release endpoints; overridable so tests never reach the network. curl is limited to https.
URL_RE='^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)*$'
NPM_REGISTRY=${BROKKR_NPM_REGISTRY:-https://registry.npmjs.org}
GITHUB_API=${BROKKR_GITHUB_API:-https://api.github.com}
GITHUB_DOWNLOAD=${BROKKR_GITHUB_DOWNLOAD:-https://github.com}
NPM_REGISTRY=${NPM_REGISTRY%/}; GITHUB_API=${GITHUB_API%/}; GITHUB_DOWNLOAD=${GITHUB_DOWNLOAD%/}
[[ "$NPM_REGISTRY" =~ $URL_RE ]] || die "invalid BROKKR_NPM_REGISTRY (an https:// base URL)"
[[ "$GITHUB_API" =~ $URL_RE ]] || die "invalid BROKKR_GITHUB_API (an https:// base URL)"
[[ "$GITHUB_DOWNLOAD" =~ $URL_RE ]] || die "invalid BROKKR_GITHUB_DOWNLOAD (an https:// base URL)"

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

# The npm packages a tool may be installed from. opencode has two: @opencode/cli is the v2 line and
# opencode-ai the legacy 1.x line, which is still released under its own name.
npm_expected() { # tool -> text for messages
  case "$1" in
    claude) echo '@anthropic-ai/claude-code' ;;
    codex) echo '@openai/codex' ;;
    pi) echo '@earendil-works/pi-coding-agent' ;;
    opencode) echo '@opencode/cli or opencode-ai' ;;
  esac
}
package_allowed() { # tool package
  case "$1:$2" in
    claude:@anthropic-ai/claude-code|codex:@openai/codex|pi:@earendil-works/pi-coding-agent) return 0 ;;
    opencode:@opencode/cli|opencode:opencode-ai) return 0 ;;
  esac
  return 1
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
hold() { T_ACTION=held; T_AFTER=$T_BEFORE; T_DETAIL=$1; }
hold_unknown() { hold "cannot evaluate release age ($1)"; }

# --- release metadata and the cooldown ----------------------------------------------------------------
# Only plain MAJOR.MINOR.PATCH versions are ever candidates; anything with a - or + suffix is a
# prerelease or a build and is ignored. Components are bounded so the arithmetic below cannot overflow.
PLAIN_RE='^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$'
is_plain() { [[ "$1" =~ $PLAIN_RE ]]; }

# True when version $1 is newer than $2, compared component by component as numbers.
ver_gt() {
  local a=$1 b=$2 ax bx
  is_plain "$a" && is_plain "$b" || return 1
  while :; do
    ax=$((10#${a%%.*})); bx=$((10#${b%%.*}))
    if [ "$ax" -ne "$bx" ]; then [ "$ax" -gt "$bx" ]; return; fi
    case $a in *.*) a=${a#*.}; b=${b#*.} ;; *) return 1 ;; esac
  done
}

# The JSON reader for release metadata: python3 in isolated mode when present, else node. Both
# programs are fixed strings; the metadata arrives on stdin and the kind as the one argument, so
# nothing fetched is ever evaluated. Output: "v <key> <epoch>" for a published version or tag (drafts
# and prereleases are skipped) and "t <name> <value>" for an npm dist-tag or a Homebrew version. Keys
# and values are limited to [A-Za-z0-9._+-]; anything else is dropped. A document of the wrong shape
# makes the reader exit non-zero.
JSON_PY='
import datetime, json, re, sys
kind = sys.argv[1]
word = re.compile(r"[A-Za-z0-9._+-]+\Z")
stamp = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?Z\Z")
def good(s):
    return isinstance(s, str) and word.match(s) is not None
def epoch(s):
    m = stamp.match(s) if isinstance(s, str) else None
    if m is None:
        return None
    try:
        parts = [int(g) for g in m.groups()]
        return int(datetime.datetime(*parts, tzinfo=datetime.timezone.utc).timestamp())
    except ValueError:
        return None
data = json.load(sys.stdin)
if kind == "npm":
    for k, v in data["time"].items():
        e = epoch(v)
        if good(k) and e is not None:
            print("v", k, e)
    for k, v in data["dist-tags"].items():
        if good(k) and good(v):
            print("t", k, v)
elif kind == "github":
    for r in data:
        e = epoch(r["published_at"])
        if r["draft"] is False and r["prerelease"] is False and good(r["tag_name"]) and e is not None:
            print("v", r["tag_name"], e)
elif kind == "brew-cask" or kind == "brew-formula":
    v = data["casks"][0]["version"] if kind == "brew-cask" else data["formulae"][0]["versions"]["stable"]
    if good(v):
        print("t", "version", v)
else:
    sys.exit(2)
'
JSON_JS='
const fs = require("fs");
const kind = process.argv[1];
const word = /^[A-Za-z0-9._+-]+$/;
const stamp = /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?Z$/;
const good = (s) => typeof s === "string" && word.test(s);
function epoch(s) {
  const m = typeof s === "string" ? stamp.exec(s) : null;
  if (m === null) return null;
  const n = m.slice(1).map(Number);
  const t = Date.UTC(n[0], n[1] - 1, n[2], n[3], n[4], n[5]);
  if (!Number.isFinite(t) || new Date(t).toISOString().slice(0, 19) !== s.slice(0, 19)) return null;
  return Math.floor(t / 1000);
}
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const out = [];
if (kind === "npm") {
  for (const k of Object.keys(data.time)) {
    const e = epoch(data.time[k]);
    if (good(k) && e !== null) out.push("v " + k + " " + e);
  }
  for (const k of Object.keys(data["dist-tags"])) {
    if (good(k) && good(data["dist-tags"][k])) out.push("t " + k + " " + data["dist-tags"][k]);
  }
} else if (kind === "github") {
  for (const r of data) {
    const e = epoch(r.published_at);
    if (r.draft === false && r.prerelease === false && good(r.tag_name) && e !== null) out.push("v " + r.tag_name + " " + e);
  }
} else if (kind === "brew-cask" || kind === "brew-formula") {
  const v = kind === "brew-cask" ? data.casks[0].version : data.formulae[0].versions.stable;
  if (good(v)) out.push("t version " + v);
} else {
  process.exit(2);
}
if (out.length > 0) process.stdout.write(out.join("\n") + "\n");
'
have_json_reader() { command -v python3 >/dev/null 2>&1 || command -v node >/dev/null 2>&1; }
json_reader() { # kind ; metadata on stdin
  if command -v python3 >/dev/null 2>&1; then
    python3 -I -c "$JSON_PY" "$1"
  else
    node -e "$JSON_JS" "$1"
  fi
}

# Release data read by load_releases: versions with their publish time, and npm dist-tags.
REL_N=0; REL_VER=(); REL_EPOCH=(); TAG_N=0; TAG_NAME=(); TAG_VAL=(); LOAD_ERR=
# Fetches one metadata document and loads it. GitHub tags must start with the given prefix, which is
# stripped. Returns 1 with LOAD_ERR set when the document cannot be fetched or read; callers hold the
# tool then, because a release whose age is unknown is never treated as old enough.
load_releases() { # kind url [tag-prefix]
  local kind=$1 url=$2 prefix=${3-} body out k key val ver
  REL_N=0; REL_VER=(); REL_EPOCH=(); TAG_N=0; TAG_NAME=(); TAG_VAL=(); LOAD_ERR=
  if ! have_json_reader; then LOAD_ERR="python3 or node is needed to read release metadata"; return 1; fi
  if ! body=$(run_limited "$LOOKUP_TIMEOUT" curl -fsSL --proto =https --max-time 60 "$url" </dev/null 2>/dev/null); then
    LOAD_ERR="release metadata could not be fetched"; return 1
  fi
  if ! out=$(printf '%s' "$body" | json_reader "$kind" 2>/dev/null); then
    LOAD_ERR="release metadata could not be read"; return 1
  fi
  while IFS=' ' read -r k key val; do
    case $k in
      v)
        case $key in "$prefix"*) ver=${key#"$prefix"} ;; *) continue ;; esac
        is_plain "$ver" || continue
        [[ "$val" =~ ^[0-9]{1,12}$ ]] || continue
        REL_VER[$REL_N]=$ver; REL_EPOCH[$REL_N]=$((10#$val)); REL_N=$((REL_N + 1)) ;;
      t)
        TAG_NAME[$TAG_N]=$key; TAG_VAL[$TAG_N]=$val; TAG_N=$((TAG_N + 1)) ;;
    esac
  done <<<"$out"
  return 0
}

tag_value() { # dist-tag name -> its version, or fail
  local i=0
  while [ "$i" -lt "$TAG_N" ]; do
    if [ "${TAG_NAME[$i]}" = "$1" ]; then printf '%s\n' "${TAG_VAL[$i]}"; return 0; fi
    i=$((i + 1))
  done
  return 1
}
epoch_of() { # version -> its publish epoch, or fail
  local i=0
  while [ "$i" -lt "$REL_N" ]; do
    if [ "${REL_VER[$i]}" = "$1" ]; then printf '%s\n' "${REL_EPOCH[$i]}"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# A release has cleared the cooldown when it was published at least MIN_AGE_HOURS ago (always, at 0).
aged() { [ "$MIN_AGE_HOURS" -eq 0 ] || [ $((NOW_EPOCH - $1)) -ge $((MIN_AGE_HOURS * 3600)) ]; }
young_text() { # version epoch
  local secs=$((NOW_EPOCH - $2))
  if [ "$secs" -lt 0 ]; then secs=0; fi
  printf '%s is only %sh old, below the %sh release-age cooldown' "$1" $((secs / 3600)) "$MIN_AGE_HOURS"
}

# Picks among the loaded releases the highest version newer than $1 (which may be empty) that has
# cleared the cooldown. PICK is none (nothing newer at all), young (newer ones exist but every one
# is inside the cooldown) or ready (PICK_VER/PICK_EPOCH). NEWEST_* is the highest newer version,
# eligible or not, for the message.
PICK=; PICK_VER=; PICK_EPOCH=; NEWEST_VER=; NEWEST_EPOCH=
pick_highest() { # installed-or-empty
  local i=0 v e
  PICK=none; PICK_VER=; PICK_EPOCH=; NEWEST_VER=; NEWEST_EPOCH=
  while [ "$i" -lt "$REL_N" ]; do
    v=${REL_VER[$i]}; e=${REL_EPOCH[$i]}
    i=$((i + 1))
    if [ -n "$1" ] && ! ver_gt "$v" "$1"; then continue; fi
    if [ -z "$NEWEST_VER" ] || ver_gt "$v" "$NEWEST_VER"; then NEWEST_VER=$v; NEWEST_EPOCH=$e; fi
    if aged "$e" && { [ -z "$PICK_VER" ] || ver_gt "$v" "$PICK_VER"; }; then PICK_VER=$v; PICK_EPOCH=$e; fi
  done
  if [ -z "$NEWEST_VER" ]; then PICK=none; elif [ -z "$PICK_VER" ]; then PICK=young; else PICK=ready; fi
  return 0
}
# The most recently published release (ties: the higher version), as PICK_VER/PICK_EPOCH. This is
# what an updater that only knows "latest" will install. Fails when there is no release.
pick_newest_published() {
  local i=0 v e
  PICK_VER=; PICK_EPOCH=
  while [ "$i" -lt "$REL_N" ]; do
    v=${REL_VER[$i]}; e=${REL_EPOCH[$i]}
    i=$((i + 1))
    if [ -z "$PICK_VER" ] || [ "$e" -gt "$PICK_EPOCH" ] || { [ "$e" -eq "$PICK_EPOCH" ] && ver_gt "$v" "$PICK_VER"; }; then
      PICK_VER=$v; PICK_EPOCH=$e
    fi
  done
  [ -n "$PICK_VER" ]
}
# Gate for a method with one target version: sets T_ACTION and fails when nothing is to be
# installed, because the target is not newer than $3 (the installed version, possibly empty) or has
# not cleared the cooldown (or its age is unknown).
gate_target() { # target epoch-or-empty installed-or-empty
  if [ -n "$3" ] && ! ver_gt "$1" "$3"; then T_ACTION=current; T_AFTER=$T_BEFORE; return 1; fi
  if [ "$MIN_AGE_HOURS" -gt 0 ]; then
    if [ -z "$2" ]; then hold_unknown "no publish time for $1"; return 1; fi
    if ! aged "$2"; then hold "$(young_text "$1" "$2")"; return 1; fi
  fi
  return 0
}

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
# previous version; every other method is reported, not guessed at. $2 says why, when the CLI
# still ran but reported the wrong version.
smoke_failed() { # tool [reason]
  local tool=$1 why=
  if [ -n "${2-}" ]; then why=" ($2)"; fi
  case "$T_METHOD" in
    npm)
      echo "smoke check failed for $tool; reinstalling $NPM_PKG@$T_BEFORE"
      if run_limited "$UPDATE_TIMEOUT" npm install -g --prefix "$NPM_PREFIX" --no-fund --no-audit "$NPM_PKG@$T_BEFORE" </dev/null \
        && T_AFTER=$(tool_version "$tool"); then
        T_ACTION=rolled-back; T_DETAIL="smoke check failed after the update$why; restored $T_BEFORE"
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
          T_ACTION=rolled-back; T_DETAIL="smoke check failed after the update$why; restored $T_BEFORE"
        else
          T_AFTER=
          fail "smoke check failed and rollback to $T_BEFORE did not restore a working CLI"
        fi
      fi ;;
    native)
      if [ -n "$T_BEFORE" ]; then
        fail "smoke check failed; no automatic rollback (manual rollback: claude install $T_BEFORE)"
      else
        fail "smoke check failed; no automatic rollback"
      fi ;;
    *) fail "smoke check failed; no automatic rollback" ;;
  esac
  return 0
}

# The CLI ran after a gated update but reports another version than the one the gate approved.
# opencode goes back to the previous version; the others cannot be pinned or rolled back here.
wrong_version() { # tool target command-label
  local tool=$1 target=$2 label=$3
  case "$T_METHOD" in
    opencode-installer) smoke_failed "$tool" "reports $T_AFTER, expected $target" ;;
    native)
      if [ -n "$T_BEFORE" ]; then
        fail "claude --version reports $T_AFTER, expected $target; roll back manually with: claude install $T_BEFORE"
      else
        fail "claude --version reports $T_AFTER, expected $target; no earlier version is known to roll back to"
      fi ;;
    *) fail "$label installed $T_AFTER, expected $target" ;;
  esac
  return 0
}

# Runs a command that installs the version the gate approved, then checks the CLI reports exactly
# that version. The command's own idea of "latest" is never trusted: methods that cannot be pinned
# are gated beforehand and verified here afterwards.
gated_update() { # tool target command...
  local tool=$1 target=$2 rc=0 label
  shift 2
  label="$1 $2"
  if [ "$DRY_RUN" -eq 1 ]; then T_ACTION=would-update; T_AFTER=$target; T_DETAIL="would run: $*"; return 0; fi
  run_limited "$UPDATE_TIMEOUT" "$@" </dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then fail "update command failed (exit $rc)"; return 0; fi
  if ! T_AFTER=$(tool_version "$tool"); then smoke_failed "$tool"; return 0; fi
  if [ "$T_AFTER" != "$target" ]; then wrong_version "$tool" "$target" "$label"; return 0; fi
  T_ACTION=updated
  return 0
}

# Runs a command without a gated target (only a Homebrew package with the cooldown disabled), then
# smoke-checks the result.
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

# Appends a note to the detail of a tool that is working as it should (never to a failure).
note_detail() {
  case "$T_ACTION" in current|updated|would-update|held) ;; *) return 0 ;; esac
  if [ -n "$T_DETAIL" ]; then T_DETAIL="$T_DETAIL; $1"; else T_DETAIL=$1; fi
  return 0
}

update_npm() { # tool
  update_npm_package "$1"
  # opencode-ai is the legacy 1.x line: it is still released under its own name, so it keeps
  # updating in place, but its owner should know v2 is a different package.
  if [ "$1" = opencode ] && [ "$NPM_PKG" = opencode-ai ]; then note_detail "legacy 1.x line; v2 is @opencode/cli"; fi
  return 0
}

update_npm_package() { # tool
  local tool=$1 rest first remainder expected pj base rc=0 latest
  NPM_PREFIX=${T_PATH%%/lib/node_modules/*}
  rest=${T_PATH#*/lib/node_modules/}
  case "$rest" in
    @*/*) first=${rest%%/*}; remainder=${rest#*/}; NPM_PKG=$first/${remainder%%/*} ;;
    *) NPM_PKG=${rest%%/*} ;;
  esac
  expected=$(npm_expected "$tool")
  if [ "$tool" = pi ] && [ "$NPM_PKG" = @mariozechner/pi-coding-agent ]; then
    fail "legacy package; migrate to @earendil-works/pi-coding-agent"; return 0
  fi
  if ! package_allowed "$tool" "$NPM_PKG"; then
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
  if ! load_releases npm "$NPM_REGISTRY/${NPM_PKG//\//%2f}"; then hold_unknown "$LOAD_ERR"; return 0; fi
  base=${T_BEFORE%%[-+]*}
  pick_highest "$base"
  case "$PICK" in
    none) T_ACTION=current; T_AFTER=$T_BEFORE; return 0 ;;
    young) hold "newer release $(young_text "$NEWEST_VER" "$NEWEST_EPOCH")"; return 0 ;;
  esac
  latest=$PICK_VER
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

# Homebrew: only the codex cask/formula has a release source whose age can be read (the GitHub
# release of the version Homebrew offers). Any other package is held, never updated blind, unless
# the cooldown is disabled.
update_brew() { # tool
  local tool=$1 info out target tepoch=
  if ! [[ "$BREW_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]]; then fail "unexpected Homebrew package name"; return 0; fi
  if ! command -v brew >/dev/null 2>&1; then fail "brew not found on PATH"; return 0; fi
  if [ "$tool" != codex ] || [ "$BREW_NAME" != codex ]; then
    if [ "$MIN_AGE_HOURS" -gt 0 ]; then
      hold "release age unknown for Homebrew package $BREW_NAME"
    elif [ "$BREW_KIND" = cask ]; then
      update_with_command "$tool" brew upgrade --cask "$BREW_NAME"
    else
      update_with_command "$tool" brew upgrade "$BREW_NAME"
    fi
    return 0
  fi
  if ! have_json_reader; then hold_unknown "python3 or node is needed to read release metadata"; return 0; fi
  if [ "$BREW_KIND" = cask ]; then
    info=$(run_limited "$LOOKUP_TIMEOUT" brew info --json=v2 --cask "$BREW_NAME" </dev/null 2>/dev/null) || info=
    out=$(printf '%s' "$info" | json_reader brew-cask 2>/dev/null) || out=
  else
    info=$(run_limited "$LOOKUP_TIMEOUT" brew info --json=v2 --formula "$BREW_NAME" </dev/null 2>/dev/null) || info=
    out=$(printf '%s' "$info" | json_reader brew-formula 2>/dev/null) || out=
  fi
  target=${out#t version }
  if ! is_plain "$target" || [ "$out" != "t version $target" ]; then
    hold_unknown "Homebrew did not report a plain version for $BREW_NAME"; return 0
  fi
  if [ -n "$T_BEFORE" ] && ! ver_gt "$target" "$T_BEFORE"; then T_ACTION=current; T_AFTER=$T_BEFORE; return 0; fi
  if [ "$MIN_AGE_HOURS" -gt 0 ]; then
    if ! load_releases github "$GITHUB_API/repos/openai/codex/releases?per_page=50" rust-v; then hold_unknown "$LOAD_ERR"; return 0; fi
    tepoch=$(epoch_of "$target") || tepoch=
  fi
  gate_target "$target" "$tepoch" "$T_BEFORE" || return 0
  if [ "$BREW_KIND" = cask ]; then
    gated_update "$tool" "$target" brew upgrade --cask "$BREW_NAME"
  else
    gated_update "$tool" "$target" brew upgrade "$BREW_NAME"
  fi
  return 0
}

# claude's own installer, driven to an exact version: the target is the registry's stable dist-tag.
update_native() { # tool
  local target tepoch=
  if ! load_releases npm "$NPM_REGISTRY/@anthropic-ai%2fclaude-code"; then hold_unknown "$LOAD_ERR"; return 0; fi
  if ! target=$(tag_value stable) || ! is_plain "$target"; then hold_unknown "no stable release in the registry metadata"; return 0; fi
  tepoch=$(epoch_of "$target") || tepoch=
  gate_target "$target" "$tepoch" "$T_BEFORE" || return 0
  gated_update "$1" "$target" claude install "$target"
  return 0
}

# codex update cannot be pinned, so it runs only when the newest published release has cleared the
# cooldown, and the version it leaves behind must be that release.
update_codex_standalone() { # tool
  local target tepoch
  if ! load_releases github "$GITHUB_API/repos/openai/codex/releases?per_page=50" rust-v; then hold_unknown "$LOAD_ERR"; return 0; fi
  if ! pick_newest_published; then hold_unknown "no stable release found"; return 0; fi
  target=$PICK_VER; tepoch=$PICK_EPOCH
  gate_target "$target" "$tepoch" "$T_BEFORE" || return 0
  gated_update "$1" "$target" codex update
  return 0
}

# opencode's installer takes an exact version. Its major picks the release line: 2.x and later are
# published as @opencode/cli, the legacy 1.x line as opencode-ai.
update_opencode_installer() { # tool
  local pkg
  if [ -z "$T_BEFORE" ]; then fail "cannot read the installed version"; return 0; fi
  if [ "$((10#${T_BEFORE%%.*}))" -ge 2 ]; then pkg=@opencode/cli; else pkg=opencode-ai; fi
  if ! load_releases npm "$NPM_REGISTRY/${pkg//\//%2f}"; then hold_unknown "$LOAD_ERR"; return 0; fi
  pick_highest "$T_BEFORE"
  case "$PICK" in
    none) T_ACTION=current; T_AFTER=$T_BEFORE; return 0 ;;
    young) hold "newer release $(young_text "$NEWEST_VER" "$NEWEST_EPOCH")"; return 0 ;;
  esac
  gated_update "$1" "$PICK_VER" opencode upgrade "$PICK_VER"
  return 0
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
    native) update_native "$tool" ;;
    brew) update_brew "$tool" ;;
    codex-standalone) update_codex_standalone "$tool" ;;
    opencode-installer) update_opencode_installer "$tool" ;;
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
  summary="$summary current=$(count_action current) held=$(count_action held) external=$(count_action external) absent=$(count_action absent)"
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
