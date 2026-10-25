#!/usr/bin/env bash
# Brokkr · append-only encrypted off-site copy of an immutable archive, and its
# periodic verification. See docs/archive-offsite.md.
#
#   archive-offsite.sh [--config FILE] --validate | --dry-run | --push | --check | --verify
#
# --push never deletes or overwrites remote objects (rclone copy --immutable), uploads
# the sha256 manifest beside the archive, then runs cryptcheck. --verify (monthly, from
# brokkr-archive-verify.timer) re-proves the copy and reports a per-node Heimdall panel
# that keeps copy, integrity, and restore evidence separate. Every mode first refuses a
# remote that is not crypt with encrypted names, a salt, and base32768 names.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
STATE_DIR="${BROKKR_STATE_DIR:-${HOME:-/var/lib/brokkr}/.local/state/brokkr}"

die() { echo "brokkr archive-offsite: $*" >&2; exit 2; }
usage() { die "usage: $0 [--config FILE] --validate|--dry-run|--push|--check|--verify"; }

MODE=""
CONFIG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) [ "$#" -ge 2 ] || usage; CONFIG=$2; shift 2 ;;
    --validate|--dry-run|--push|--check|--verify) [ -z "$MODE" ] || usage; MODE=$1; shift ;;
    *) usage ;;
  esac
done
[ -n "$MODE" ] || usage

# The config file is parsed, never sourced: only these keys, literal values, each at
# most once. It is applied after the environment, so a shared EnvironmentFile (the
# Heimdall delivery env) cannot redirect what is verified.
CONFIG_KEYS=" ARCHIVE_SRC ARCHIVE_MANIFEST ARCHIVE_REMOTE ARCHIVE_NAME ARCHIVE_RCLONE ARCHIVE_LOG \
ARCHIVE_BWLIMIT ARCHIVE_RESTORE_SAMPLES ARCHIVE_NEARSITE ARCHIVE_NEARSITE_SSH ARCHIVE_NEARSITE_DIR \
ARCHIVE_KEY_DRILL_DATE ARCHIVE_NODE "
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
[ -z "$CONFIG" ] || load_config "$CONFIG"

# rclone reads RCLONE_CONFIG_<REMOTE>_<OPTION> and other RCLONE_* variables as config
# and flag overrides that `rclone config dump` does not show, so any of them could
# silently disable the crypt guard or turn a copy into a no-op.
while IFS= read -r name; do
  case "$name" in RCLONE_CONFIG|RCLONE_CONFIG_PASS) ;; *) die "refusing to run with $name set in the environment" ;; esac
done < <(compgen -e | grep '^RCLONE_' || true)

RCLONE="${ARCHIVE_RCLONE:-$(command -v rclone 2>/dev/null || true)}"
SRC="${ARCHIVE_SRC:-}"
MAN="${ARCHIVE_MANIFEST:-}"
REMOTE="${ARCHIVE_REMOTE:-}"
[ -n "$SRC" ] && [ -n "$MAN" ] && [ -n "$REMOTE" ] || die "ARCHIVE_SRC, ARCHIVE_MANIFEST and ARCHIVE_REMOTE are required"
NAME="${ARCHIVE_NAME:-$(basename "$SRC")}"
LOG="${ARCHIVE_LOG:-$STATE_DIR/archive-offsite.log}"
BWLIMIT="${ARCHIVE_BWLIMIT:-}"
[[ "$REMOTE" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "ARCHIVE_REMOTE must be a plain rclone remote name"
[[ "$NAME" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "ARCHIVE_NAME must be a plain name"
[ -n "$RCLONE" ] && [ -x "$RCLONE" ] || die "rclone not found (set ARCHIVE_RCLONE)"
# The unit runs from its release directory, so relative paths would silently change meaning.
for path in "$SRC" "$MAN" "$LOG" "$RCLONE"; do
  [[ "$path" == /* ]] || die "ARCHIVE_SRC, ARCHIVE_MANIFEST, ARCHIVE_LOG and ARCHIVE_RCLONE must be absolute paths"
done
# --validate writes no state or log: the deploy preflight runs it on the node in a dry run.
if [ "$MODE" = --validate ]; then LOG=/dev/null; else mkdir -p "$STATE_DIR" "$(dirname "$LOG")"; fi

note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

# Fails closed unless the archive and manifest agree on the file count.
preflight_archive() {
  local files mlines
  [ -d "$SRC" ] || { echo "archive directory missing: $SRC"; return 1; }
  [ -f "$MAN" ] || { echo "manifest missing: $MAN"; return 1; }
  # NUL-counted: a name containing a newline is one file (and one escaped manifest line).
  files=$(find "$SRC" -type f -print0 | tr -dc '\0' | wc -c | tr -d ' ')
  mlines=$(wc -l <"$MAN" | tr -d ' ')
  [ "$files" -eq "$mlines" ] || { echo "archive has $files files but manifest has $mlines lines"; return 1; }
  echo "$files"
}

# Fails closed unless REMOTE is crypt with content, filename and directory-name
# encryption and a salt. Reads the config dump on stdin and prints only a verdict and
# non-secret identification of the underlying remote, never key or credential values.
validate_remote() {
  "$RCLONE" config dump 2>/dev/null | python3 -I -c '
import json, re, sys
name = sys.argv[1]
try:
    dump = json.load(sys.stdin)
except ValueError:
    sys.exit("rclone config dump is not readable")
cfg = dump.get(name)
if cfg is None: sys.exit(f"remote {name!r} not configured")
if cfg.get("type") != "crypt": sys.exit(f"remote {name!r} is not type crypt")
if cfg.get("filename_encryption", "standard") != "standard": sys.exit("filename_encryption must be standard")
if str(cfg.get("directory_name_encryption", "true")).lower() != "true": sys.exit("directory_name_encryption must be true")
if str(cfg.get("no_data_encryption", "false")).lower() != "false": sys.exit("no_data_encryption must be false")
if str(cfg.get("pass_bad_blocks", "false")).lower() != "false": sys.exit("pass_bad_blocks must be false")
if not cfg.get("password") or not cfg.get("password2"): sys.exit("crypt password and salt (password2) are both required")
if not cfg.get("remote"): sys.exit("crypt remote has no underlying remote")
# OneDrive caps path length; base32 names overflow it (pathIsTooLong), base32768 fits.
if cfg.get("filename_encoding", "base32") != "base32768": sys.exit("filename_encoding must be base32768")
# Every section in the chain is checked: rclone applies `global.*` / `override.*` keys
# and connection-string options (`name,opt=value:` or `:backend,...:`) over command-line
# flags, so they could switch off --immutable or reduce cryptcheck to sizes.
section, chain, base = cfg, [name], None
while True:
    if any("." in key for key in section): sys.exit(f"remote {chain[-1]!r} sets a global/override option")
    if section.get("type") in ("union", "combine"): sys.exit(f"remote {chain[-1]!r} is a multi-upstream backend")
    spec = section.get("remote")
    if spec is None or spec.startswith("/"):
        break
    hop = re.fullmatch(r"([A-Za-z0-9_][A-Za-z0-9_.-]*):.*", spec, re.S)
    if hop is None: sys.exit(f"remote {chain[-1]!r} must point at a named remote or an absolute local path")
    if hop.group(1) in chain or len(chain) > 8: sys.exit("remote chain loops or is too deep")
    if hop.group(1) not in dump: sys.exit(f"underlying remote {hop.group(1)!r} not configured")
    base = base or hop.group(1)
    chain.append(hop.group(1)); section = dump[hop.group(1)]
u = dump.get(base, {}) if base else {"type": "local"}
print("underlying: %s type=%s drive_type=%s drive_id=%s" % (base or "(local path)", u.get("type"), u.get("drive_type"), u.get("drive_id")))
' "$REMOTE" 2>&1
}

# A push and a verify must not interleave: a half-pushed archive would fail cryptcheck.
if [ "$MODE" != --validate ] && command -v flock >/dev/null 2>&1; then
  exec 9>"$STATE_DIR/archive-offsite.lock"
  flock -n 9 || die "another archive-offsite run holds $STATE_DIR/archive-offsite.lock"
fi

if [ "$MODE" != --verify ]; then
  files=$(preflight_archive) || die "$files"
  verdict=$(validate_remote) || die "remote validation failed: $verdict"
  # Which drive the underlying remote points at, for a human check (no credentials).
  printf '%s\n' "$verdict" | tee -a "$LOG"
  note "validated remote=$REMOTE src=$SRC files=$files"

  args=(--immutable --transfers 4 --checkers 8 --stats 5m --stats-one-line --log-file "$LOG" --log-level INFO)
  [ -z "$BWLIMIT" ] || args+=(--bwlimit "$BWLIMIT")

  case "$MODE" in
    --validate) exit 0 ;;
    --dry-run)
      "$RCLONE" copy --dry-run "${args[@]}" "$SRC" "$REMOTE:$NAME"
      note "dry-run complete (see log)" ;;
    --push)
      note "push start"
      "$RCLONE" copy "${args[@]}" "$SRC" "$REMOTE:$NAME"
      "$RCLONE" copyto "${args[@]}" "$MAN" "$REMOTE:$NAME.sha256"
      note "push complete; running cryptcheck"
      "$RCLONE" cryptcheck --one-way --log-file "$LOG" --log-level NOTICE "$SRC" "$REMOTE:$NAME"
      note "cryptcheck OK" ;;
    --check)
      "$RCLONE" cryptcheck --one-way --log-file "$LOG" --log-level NOTICE "$SRC" "$REMOTE:$NAME"
      "$RCLONE" cat "$REMOTE:$NAME.sha256" | cmp -s - "$MAN" || die "remote manifest is missing or differs from $MAN"
      note "cryptcheck OK (remote manifest byte-identical)" ;;
  esac
  exit 0
fi

# ---- --verify: monthly re-proof, reported as one per-node Heimdall panel ----
[ -n "${HEIMDALL_HUB_URL:-}" ] && [ -n "${HEIMDALL_FLEET_TOKEN:-}" ] || die "Heimdall delivery is not configured"
# One panel per node, as for link health: a shared panel would let one node hide another.
node_raw="${ARCHIVE_NODE:-$(hostname -s 2>/dev/null || hostname 2>/dev/null)}"
node="$(printf '%s' "${node_raw%%.*}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | tr -s '-' | sed 's/^-*//; s/-*$//')"
[ -n "$node" ] || die "cannot derive a node name for the Heimdall panel (set ARCHIVE_NODE)"
[ "${#node}" -le 40 ] || die "node name longer than 40 characters (set a shorter ARCHIVE_NODE)"
SAMPLES="${ARCHIVE_RESTORE_SAMPLES:-32}"
[[ "$SAMPLES" =~ ^[1-9][0-9]{0,2}$ ]] || die "ARCHIVE_RESTORE_SAMPLES must be 1-999"
NEARSITE="${ARCHIVE_NEARSITE:-}"
NS_SSH="${ARCHIVE_NEARSITE_SSH:-}"
NS_DIR="${ARCHIVE_NEARSITE_DIR:-}"
case "$NEARSITE" in ''|off) ;; *) die "ARCHIVE_NEARSITE must be empty or off" ;; esac
if [ -n "$NS_SSH" ] || [ -n "$NS_DIR" ]; then
  [ "$NEARSITE" != off ] || die "ARCHIVE_NEARSITE=off conflicts with ARCHIVE_NEARSITE_SSH/DIR"
  [[ "$NS_SSH" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(@[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]] || die "ARCHIVE_NEARSITE_SSH must be a plain [user@]host"
  [[ "$NS_DIR" =~ ^/[A-Za-z0-9._/@:+-]+$ && "$NS_DIR" != *'//'* && "$NS_DIR" != *'/.'* ]] \
    || die "ARCHIVE_NEARSITE_DIR must be an absolute plain path"
fi

WORK=$(mktemp -d "$STATE_DIR/.archive-verify.XXXXXX") || die "cannot create a work directory"
cleanup() { chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM
CHECKS="$WORK/checks.tsv"
: >"$CHECKS"
record() { # name status detail
  printf '%s\t%s\t%s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\t\r\n' '   ')" >>"$CHECKS"
  note "verify $1: $2: $3"
}

# Parses the sha256sum manifest (text or binary mode, GNU-escaped names) and either
# writes a random restore sample or checks restored files against it.
IFS= read -r -d '' MANIFEST_PY <<'PY' || true
import hashlib, json, os, random, sys

def parse(path):
    entries = {}
    with open(path, "rb") as fh:
        lines = fh.read().split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    for raw in lines:
        line = raw.decode("utf-8", "surrogateescape")
        escaped = line.startswith("\\")
        if escaped:
            line = line[1:]
        digest, sep, name = line[:64], line[64:66], line[66:]
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest.lower()) or sep not in ("  ", " *") or not name:
            raise ValueError("malformed manifest line")
        if escaped:
            out, i = [], 0
            while i < len(name):
                if name[i] == "\\" and i + 1 < len(name) and name[i + 1] in "\\nr":
                    out.append({"\\": "\\", "n": "\n", "r": "\r"}[name[i + 1]]); i += 2
                else:
                    out.append(name[i]); i += 1
            name = "".join(out)
        if name.startswith("./"):
            name = name[2:]
        if name.startswith("/") or ".." in name.split("/") or name in entries:
            raise ValueError("unsafe or duplicate manifest path")
        entries[name] = digest.lower()
    return entries

mode, manifest = sys.argv[1], sys.argv[2]
try:
    entries = parse(manifest)
except (OSError, UnicodeError, ValueError) as error:
    sys.exit(f"manifest unusable: {error}")
if mode == "sample":
    count, listing, plan = int(sys.argv[3]), sys.argv[4], sys.argv[5]
    pool = sorted(n for n in entries if "\n" not in n and "\r" not in n)
    pick = random.SystemRandom().sample(pool, min(count, len(pool)))
    if not pick:
        sys.exit("manifest has no restorable entries")
    with open(listing, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.writelines(n + "\n" for n in pick)
    with open(plan, "w", encoding="utf-8", errors="surrogateescape") as fh:
        json.dump({n: entries[n] for n in pick}, fh)
    print(len(pick))
elif mode == "check":
    plan, restored = sys.argv[3], sys.argv[4]
    with open(plan, encoding="utf-8", errors="surrogateescape") as fh:
        want = json.load(fh)
    good = 0
    for name, digest in want.items():
        h = hashlib.sha256()
        try:
            with open(os.path.join(restored, name), "rb") as fh:
                for block in iter(lambda: fh.read(1 << 20), b""):
                    h.update(block)
        except OSError:
            continue
        good += h.hexdigest() == digest
    print(f"{good} {len(want)}")
PY

# Each row stands on its own evidence; a row that could not run is fail, never pass.
remote_ok=1
if ! files=$(preflight_archive); then
  record preflight fail "$files"; remote_ok=0; files=0
elif ! verdict=$(validate_remote); then
  record preflight fail "remote validation failed: $verdict"; remote_ok=0
fi

if [ "$remote_ok" = 1 ]; then
  # Copy: the remote holds as many objects as the manifest lists, plus the manifest.
  if size_json=$("$RCLONE" size --json "$REMOTE:$NAME" 2>>"$LOG") \
    && read -r count bytes < <(python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(int(d["count"]), int(d["bytes"]))' <<<"$size_json"); then
    gib=$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1073741824 }')
    if ! "$RCLONE" lsf "$REMOTE:$NAME.sha256" 2>>"$LOG" | grep -qxF "$NAME.sha256"; then
      record copy fail "remote holds $count/$files files ($gib GiB) but no manifest $NAME.sha256"
    elif [ "$count" -lt "$files" ]; then
      record copy fail "remote holds only $count/$files files ($gib GiB)"
    elif [ "$count" -gt "$files" ]; then
      record copy warn "remote holds $count objects for $files manifest entries ($gib GiB)"
    else
      record copy pass "remote holds $count/$files files ($gib GiB) and the manifest"
    fi
  else
    record copy fail "could not list the remote (rclone size failed; see log)"
  fi

  # Integrity: every archive file matches its encrypted remote copy, and the remote
  # manifest is byte-identical to the local one.
  if "$RCLONE" cryptcheck --one-way --combined "$WORK/combined" --log-file "$WORK/cryptcheck.log" --log-level NOTICE \
    "$SRC" "$REMOTE:$NAME" >/dev/null 2>&1; then crc=0; else crc=$?; fi
  cat "$WORK/cryptcheck.log" >>"$LOG" 2>/dev/null || true
  read -r match bad < <(awk '/^= /{m++; next} {b++} END {print m+0, b+0}' "$WORK/combined" 2>/dev/null || echo "0 0")
  # An object whose stored hash is empty is listed as `=` and still exits 0; rclone only
  # reports it in the "N hashes could not be checked" notice, so that must be zero.
  unchecked=$(sed -n 's/.* \([0-9][0-9]*\) hashes could not be checked.*/\1/p' "$WORK/cryptcheck.log" 2>/dev/null | tail -n 1)
  unchecked=${unchecked:-0}
  if "$RCLONE" cat "$REMOTE:$NAME.sha256" 2>>"$LOG" | cmp -s - "$MAN"; then man_ok=1; else man_ok=0; fi
  if [ "$crc" = 0 ] && [ "$match" = "$files" ] && [ "$bad" = 0 ] && [ "$unchecked" = 0 ] && [ "$man_ok" = 1 ]; then
    record integrity pass "cryptcheck matched $match/$files files; remote manifest byte-identical"
  elif [ "$man_ok" = 1 ]; then
    record integrity fail "cryptcheck exit $crc: $match/$files matched, $bad differ/missing/error, $unchecked hashes unchecked"
  else
    record integrity fail "remote manifest missing or differs; cryptcheck exit $crc: $match/$files matched"
  fi

  # Restore: random files come back through the crypt remote and match the manifest.
  mkdir -m 700 "$WORK/restore"
  if ! picked=$(python3 -I -c "$MANIFEST_PY" sample "$MAN" "$SAMPLES" "$WORK/sample.list" "$WORK/sample.json" 2>&1); then
    record restore fail "$picked"
  else
    "$RCLONE" copy --files-from-raw "$WORK/sample.list" --log-file "$LOG" --log-level NOTICE \
      "$REMOTE:$NAME" "$WORK/restore" >/dev/null 2>&1 || true
    read -r good total < <(python3 -I -c "$MANIFEST_PY" check "$MAN" "$WORK/sample.json" "$WORK/restore" 2>/dev/null || echo "0 $picked")
    chmod -R u+w "$WORK/restore" 2>/dev/null || true
    # A failed removal is restore evidence too: report it rather than abort under set -e.
    rm -rf "$WORK/restore" 2>/dev/null || true
    if [ -e "$WORK/restore" ]; then
      record restore fail "restored $good/$total sampled files but could not remove the scratch copy"
    elif [ "$good" = "$total" ] && [ "$total" -gt 0 ]; then
      record restore pass "restored $total random files; all sha256 match the manifest; scratch removed"
    else
      record restore fail "only $good/$total sampled files restored with a matching sha256"
    fi
  fi
else
  for row in copy integrity restore; do record "$row" fail "not verified: preflight failed"; done
fi

# Near-site: the NAS copy is checked against the local manifest on the NAS itself.
if [ "$NEARSITE" = off ]; then
  :
elif [ -z "$NS_SSH" ]; then
  record nearsite warn "near-site copy not verified (ARCHIVE_NEARSITE_SSH unset; ARCHIVE_NEARSITE=off omits this row)"
elif [ ! -f "$MAN" ]; then
  record nearsite fail "not verified: manifest missing"
else
  if ns_out=$(ssh -o BatchMode=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=5 "$NS_SSH" \
    "cd '$NS_DIR' && sha256sum --check --quiet --strict -" <"$MAN" 2>&1); then nrc=0; else nrc=$?; fi
  entries=$(wc -l <"$MAN" | tr -d ' ')
  if [ "$nrc" = 0 ]; then
    record nearsite pass "sha256sum -c on the near-site host matched all $entries manifest entries"
  elif [ "$nrc" = 255 ]; then
    record nearsite fail "near-site host unreachable over ssh"
  else
    failed=$(grep -c ': FAILED' <<<"$ns_out" || true)
    record nearsite fail "sha256sum -c exit $nrc on the near-site host: $failed of $entries entries FAILED"
  fi
fi

# Key custody: the owner records the date of the last drill that rebuilt the remote from
# the password-manager entry alone. This is the yearly reminder, not proof of recovery.
if drill=$(python3 -I - "${ARCHIVE_KEY_DRILL_DATE:-}" "${BROKKR_NOW_EPOCH:-}" <<'PY'
import datetime, sys, time
raw, now = sys.argv[1], sys.argv[2]
today = datetime.datetime.fromtimestamp(int(now) if now else time.time(), datetime.timezone.utc).date()
if not raw:
    print("warn\tno key-custody drill recorded (set ARCHIVE_KEY_DRILL_DATE after the yearly drill)"); sys.exit()
try:
    day = datetime.date.fromisoformat(raw)
except ValueError:
    print("fail\tARCHIVE_KEY_DRILL_DATE is not YYYY-MM-DD"); sys.exit()
age = (today - day).days
due = day + datetime.timedelta(days=365)
if age < 0:
    print(f"fail\tkey-custody drill date {raw} is in the future")
elif age > 365:
    print(f"warn\tkey-custody drill overdue: last {raw} ({age} days ago), due {due}")
else:
    print(f"pass\towner-recorded key-custody drill {raw} ({age} days ago); next due {due}")
PY
); then
  record key-drill "${drill%%$'\t'*}" "${drill#*$'\t'}"
else
  record key-drill fail "could not evaluate the key-custody drill date"
fi

snapshot="$STATE_DIR/archive-verify.json"
tmp="$STATE_DIR/.archive-verify.json.$$"
if ! python3 -I - "$CHECKS" "$tmp" <<'PY'
import json, sys
rank = {"pass": 0, "warn": 1, "fail": 2}
checks = []
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        name, status, detail = line.rstrip("\n").split("\t", 2)
        checks.append({"name": name, "status": status, "detail": detail})
if not checks or any(c["status"] not in rank for c in checks):
    sys.exit("no valid verification rows")
status = max((c["status"] for c in checks), key=rank.get)
# Every row's status leads the panel message, so truncation can only shorten details.
summary = " ".join(f'{c["name"]}={c["status"]}' for c in checks)
alarms = "; ".join(f'{c["name"]}: {c["detail"]}' for c in checks if c["status"] != "pass")
if alarms:
    summary += " | " + alarms
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
note "verify complete: $overall → $snapshot"

# A WARN/FAIL result is still evidence and is delivered; the exit code then records it.
BROKKR_HEIMDALL_PANEL="archive-verify-$node" \
BROKKR_HEIMDALL_LABEL="Archive Verification ($node)" \
BROKKR_HEIMDALL_STAMP_PREFIX="archive-verify-" \
BROKKR_STATE_DIR="$STATE_DIR" \
  "$HERE/heimdall/push.sh" "$snapshot" || die "Heimdall delivery failed (verification result: $overall)"
[ "$overall" != fail ] || exit 1
exit 0
