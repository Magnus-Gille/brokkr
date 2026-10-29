#!/usr/bin/env bash
# Brokkr · self-check of the near-site copy of an immutable archive, run on the near-site
# host itself and reported as a per-node Heimdall panel. See docs/archive-nearsite.md.
#
#   archive-nearsite.sh [--config FILE] --validate | --verify
#
# --verify (monthly, from brokkr-archive-nearsite.timer) first proves that the manifest
# on this host is byte-identical to the one pinned in the config (the trust anchor), then
# runs `sha256sum --check` of that manifest against the near-site directory. --validate
# runs only the config and manifest checks: no hashing, no delivery, no state. The host
# computes the hashes itself, so no ssh access and no new credential is involved; delivery
# uses the Heimdall producer credential already present in the runtime environment.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
STATE_DIR="${BROKKR_STATE_DIR:-${HOME:-/var/lib/brokkr}/.local/state/brokkr}"

die() { echo "brokkr archive-nearsite: $*" >&2; exit 2; }
usage() { die "usage: $0 [--config FILE] --validate|--verify"; }

MODE=""
CONFIG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) [ "$#" -ge 2 ] || usage; CONFIG=$2; shift 2 ;;
    --validate|--verify) [ -z "$MODE" ] || usage; MODE=$1; shift ;;
    *) usage ;;
  esac
done
[ -n "$MODE" ] || usage
[ -n "$CONFIG" ] || CONFIG="${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/brokkr/archive-nearsite.conf"

# The config file is parsed, never sourced: only these keys, literal values, each at
# most once. What is verified comes from this file alone: the three path/pin keys are
# cleared from the environment first, so a shared EnvironmentFile (the Heimdall delivery
# env) cannot redirect the check or replace the pin.
CONFIG_KEYS=" ARCHIVE_NEARSITE_DIR ARCHIVE_NEARSITE_MANIFEST ARCHIVE_NEARSITE_MANIFEST_SHA256 ARCHIVE_NODE "
unset ARCHIVE_NEARSITE_DIR ARCHIVE_NEARSITE_MANIFEST ARCHIVE_NEARSITE_MANIFEST_SHA256
load_config() {
  local file=$1 meta line key value seen=" "
  local sq_re=$'^\'([^\']*)\'$' dq_re=$'^"([^"\\$`]*)"$' bad_re=$'[\'"\\$`[:space:]]'
  [ -f "$file" ] && [ ! -L "$file" ] || die "config must be a regular non-symlink file: $file"
  if ! meta=$(stat -c '%u %a' "$file" 2>/dev/null); then
    meta=$(stat -f '%u %Lp' "$file" 2>/dev/null) || die "cannot inspect config: $file"
  fi
  [ "${meta%% *}" = "$(id -u)" ] || die "config must be owned by the current user: $file"
  case "${meta##* }" in *00) ;; *) die "config must have no group/other permissions: $file" ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "config line is not KEY=value: $file"
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [[ "$CONFIG_KEYS" == *" $key "* ]] || die "config key $key is not allowed"
    [[ "$seen" != *" $key "* ]] || die "config key $key is set more than once"
    seen="$seen$key "
    if [[ "$value" =~ $sq_re || "$value" =~ $dq_re ]]; then
      value=${BASH_REMATCH[1]}
    elif [[ "$value" =~ $bad_re ]]; then
      die "config value for $key must be plain or wholly quoted"
    fi
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done <"$file"
}
load_config "$CONFIG"

NS_DIR="${ARCHIVE_NEARSITE_DIR:-}"
MAN="${ARCHIVE_NEARSITE_MANIFEST:-}"
PIN="${ARCHIVE_NEARSITE_MANIFEST_SHA256:-}"
[ -n "$NS_DIR" ] || die "ARCHIVE_NEARSITE_DIR is required"
[ -n "$MAN" ] || die "ARCHIVE_NEARSITE_MANIFEST is required"
[ -n "$PIN" ] || die "ARCHIVE_NEARSITE_MANIFEST_SHA256 is required (the pinned sha256 of the manifest)"
plain_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/@:+-]+$ && "$1" != *'//'* && "$1" != *'/.'* ]]
}
plain_path "$NS_DIR" || die "ARCHIVE_NEARSITE_DIR must be an absolute plain path"
plain_path "$MAN" || die "ARCHIVE_NEARSITE_MANIFEST must be an absolute plain path"
[[ "$PIN" =~ ^[0-9a-f]{64}$ ]] || die "ARCHIVE_NEARSITE_MANIFEST_SHA256 must be exactly 64 lowercase hex characters"

if [ "$MODE" = --verify ]; then
  [ -n "${HEIMDALL_HUB_URL:-}" ] && [ -n "${HEIMDALL_FLEET_TOKEN:-}" ] || die "Heimdall delivery is not configured"
  # One panel per node, as for link health: a shared panel would let one node hide another.
  node_raw="${ARCHIVE_NODE:-$(hostname -s 2>/dev/null || hostname 2>/dev/null)}"
  node="$(printf '%s' "${node_raw%%.*}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | tr -s '-' | sed 's/^-*//; s/-*$//')"
  [ -n "$node" ] || die "cannot derive a node name for the Heimdall panel (set ARCHIVE_NODE)"
  [ "${#node}" -le 40 ] || die "node name longer than 40 characters (set a shorter ARCHIVE_NODE)"
  mkdir -p "$STATE_DIR"
  # Two runs must not interleave on the same snapshot.
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$STATE_DIR/archive-nearsite.lock"
    flock -n 9 || die "another archive-nearsite run holds $STATE_DIR/archive-nearsite.lock"
  fi
  WORK=$(mktemp -d "$STATE_DIR/.archive-nearsite.XXXXXX") || die "cannot create a work directory"
else
  # --validate writes no state: the deploy preflight runs it on the node in a dry run.
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/.archive-nearsite.XXXXXX") || die "cannot create a work directory"
fi
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM
CHECKS="$WORK/checks.tsv"
: >"$CHECKS"
# Details carry counts only, never file names: names are personal data and must reach
# neither the panel nor the journal. A trailing info=1 puts the detail in the panel
# message even for a passing row.
record() { # name status detail [info]
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\t\r\n' '   ')" "${4:-0}" >>"$CHECKS"
  printf '%s %s\n' "$(date -u +%FT%TZ)" "verify $1: $2: $3"
}

# Reads the manifest once (no symlink, regular file), compares its sha256 with the pin,
# checks that every line is plain GNU text-mode `<hex>  <relative path>`, and stages a
# private copy so the hash run reads exactly the bytes that were pinned. Output is one
# line: status TAB detail TAB entries. Offending lines are reported by number, never by
# content. `extras` counts regular files under the directory that the manifest does not
# list, which sha256sum cannot notice.
IFS= read -r -d '' NEARSITE_PY <<'PY' || true
import hashlib, os, re, stat, sys

LINE = re.compile(rb"^[0-9a-f]{64}  (.+)$", re.DOTALL)
CONTROL = re.compile(rb"[\x00-\x1f\x7f]")

def finish(status, detail, entries=""):
    print(f"{status}\t{detail}\t{entries}")
    sys.exit(0)

def problem(data):
    if not data:
        return "manifest is empty"
    if not data.endswith(b"\n"):
        return "manifest does not end with a newline"
    for number, line in enumerate(data[:-1].split(b"\n"), 1):
        if b"\r" in line:
            return f"line {number} has a carriage return"
        if CONTROL.search(line):
            return f"line {number} has a control character"
        if line.startswith(b"\\"):
            return f"line {number} is backslash-escaped (an escaped GNU name is not accepted)"
        match = LINE.match(line)
        if not match:
            return f"line {number} is not in sha256sum text-mode format"
        path = match.group(1)
        if path.startswith(b"/"):
            return f"line {number} has an absolute path"
        if path.startswith(b"./"):
            return f"line {number} has a leading ./ in its path"
        parts = path.split(b"/")
        if b"" in parts:
            return f"line {number} has an empty path component"
        if b".." in parts:
            return f"line {number} has a .. component in its path"
        if b"." in parts:
            return f"line {number} has a . component in its path"
    return None

mode = sys.argv[1]
if mode == "manifest":
    path, pin, copy = sys.argv[2:5]
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as fh:
            if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
                raise OSError("not a regular file")
            data = fh.read()
    except OSError:
        finish("fail", "manifest is not a readable regular non-symlink file")
    digest = hashlib.sha256(data).hexdigest()
    if digest != pin:
        finish("fail", f"manifest sha256 does not match the pinned value (actual starts {digest[:12]})")
    reason = problem(data)
    if reason:
        finish("fail", reason)
    try:
        fd = os.open(copy, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
    except OSError:
        finish("fail", "cannot stage a private copy of the manifest")
    entries = data.count(b"\n")
    finish("pass", f"manifest matches the pinned sha256 and holds {entries} well-formed entries", entries)
elif mode == "extras":
    copy, directory = sys.argv[2:4]
    with open(copy, "rb") as fh:
        listed = {line[66:] for line in fh.read().split(b"\n")[:-1]}
    base = os.fsencode(directory)
    extra = 0
    for root, _dirs, files in os.walk(base):
        for name in files:
            full = os.path.join(root, name)
            try:
                regular = stat.S_ISREG(os.lstat(full).st_mode)
            except OSError:
                continue
            if regular and os.path.relpath(full, base) not in listed:
                extra += 1
    print(extra)
PY

# ---- manifest row: the pinned manifest is the trust anchor ----
man_ok=0 entries=0
if IFS=$'\t' read -r m_status m_detail m_entries < <(python3 -I -c "$NEARSITE_PY" manifest "$MAN" "$PIN" "$WORK/manifest" 2>/dev/null) \
  && [ -n "$m_status" ]; then
  :
else
  m_status=fail m_detail="manifest check could not run" m_entries=
fi
if [ "$MODE" = --validate ]; then
  [ "$m_status" = pass ] || die "manifest row failed: $m_detail"
  [ -d "$NS_DIR" ] || die "near-site directory missing"
  echo "validated: $m_entries manifest entries; the pinned manifest matches and the directory exists"
  exit 0
fi
record manifest "$m_status" "$m_detail"
if [ "$m_status" = pass ]; then man_ok=1; entries=$m_entries; fi

# ---- nearsite row: the host re-hashes its own copy against the pinned manifest ----
sha_banner=$(sha256sum --version 2>/dev/null || true)
if [ "$man_ok" != 1 ]; then
  record nearsite fail "not checked: manifest row failed"
elif [ ! -d "$NS_DIR" ]; then
  record nearsite fail "near-site directory missing"
elif [[ "$sha_banner" != *GNU* ]]; then
  record nearsite fail "GNU sha256sum is required on this host"
else
  # Output stays in files: failing names are personal data, so only counts are reported.
  if ( cd "$NS_DIR" && LC_ALL=C sha256sum --check --quiet --strict "$WORK/manifest" ) >"$WORK/hash.out" 2>"$WORK/hash.err"
  then src=0; else src=$?; fi
  if extras=$(python3 -I -c "$NEARSITE_PY" extras "$WORK/manifest" "$NS_DIR" 2>/dev/null) && [[ "$extras" =~ ^[0-9]+$ ]]; then
    if [ "$extras" = 1 ]; then extra_note="1 extra file"; else extra_note="$extras extra files"; fi
    extra_note="$extra_note in the directory are not in the manifest (informational)"
    if [ "$extras" = 0 ]; then extra_info=0; else extra_info=1; fi
  else
    extra_note="extra files could not be counted (informational)"
    extra_info=1
  fi
  if [ "$src" = 0 ]; then
    record nearsite pass "sha256sum -c matched all $entries manifest entries; $extra_note" "$extra_info"
  else
    mismatched=$(LC_ALL=C grep -c ': FAILED$' "$WORK/hash.out" || true)
    missing=$(LC_ALL=C grep -c ': FAILED open or read$' "$WORK/hash.out" || true)
    other=""
    if [ "$mismatched" = 0 ] && [ "$missing" = 0 ]; then other=" (sha256sum reported another problem)"; fi
    record nearsite fail "sha256sum -c exit $src: $mismatched mismatched, $missing missing of $entries manifest entries$other; $extra_note" 1
  fi
fi

snapshot="$STATE_DIR/archive-nearsite.json"
tmp="$STATE_DIR/.archive-nearsite.json.$$"
if ! python3 -I - "$CHECKS" "$tmp" <<'PY'
import json, sys
rank = {"pass": 0, "fail": 1}
checks, shown = [], []
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        name, status, detail, info = line.rstrip("\n").split("\t", 3)
        checks.append({"name": name, "status": status, "detail": detail})
        if status != "pass" or info == "1":
            shown.append(f"{name}: {detail}")
if not checks or any(c["status"] not in rank for c in checks):
    sys.exit("no valid verification rows")
status = max((c["status"] for c in checks), key=rank.get)
# Every row's status leads the panel message, so truncation can only shorten details.
summary = " ".join(f'{c["name"]}={c["status"]}' for c in checks)
if shown:
    summary += " | " + "; ".join(shown)
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump({"name": "brokkr", "namespace": "grimnir", "kind": "platform", "status": status,
               "summary": summary, "checks": checks}, fh, separators=(",", ":"))
    fh.write("\n")
PY
then
  rm -f "$tmp"; die "cannot generate the verification snapshot"
fi
mv "$tmp" "$snapshot" || { rm -f "$tmp"; die "cannot publish the verification snapshot"; }
overall=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$snapshot")
printf '%s %s\n' "$(date -u +%FT%TZ)" "verify complete: $overall"

# A failing result is still evidence and is delivered; the exit code then records it.
BROKKR_HEIMDALL_PANEL="archive-nearsite-$node" \
BROKKR_HEIMDALL_LABEL="Archive Near-site Verification ($node)" \
BROKKR_HEIMDALL_STAMP_PREFIX="archive-nearsite-" \
BROKKR_STATE_DIR="$STATE_DIR" \
  "$HERE/heimdall/push.sh" "$snapshot" || die "Heimdall delivery failed (verification result: $overall)"
[ "$overall" != fail ] || exit 1
exit 0
