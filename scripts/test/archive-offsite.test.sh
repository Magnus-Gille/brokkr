#!/usr/bin/env bash
# Hermetic tests for scripts/archive-offsite.sh. A real rclone runs against local-backend
# crypt remotes in a temp config; ssh and the Heimdall HTTP client are fakes. No cloud,
# network, real rclone config, or real host is touched.
# shellcheck disable=SC2016,SC2034 # assertions are evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/scripts/archive-offsite.sh"
# shellcheck source=scripts/test/lib/fixture-cleanup.sh
source "$HERE/lib/fixture-cleanup.sh"

R="${BROKKR_TEST_RCLONE:-$(command -v rclone 2>/dev/null || true)}"
if [ -z "$R" ]; then
  # CI installs rclone, so a missing binary there is a failure, not a skip.
  if [ "${CI:-}" = true ]; then echo "not ok - rclone is required in CI" >&2; exit 1; fi
  echo "skip - rclone not installed; archive-offsite tests need a real rclone"; exit 0
fi

TMP="$(fixture_cleanup_alloc)" || { echo "not ok - cannot allocate a test fixture" >&2; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "not ok - fixture allocation returned no directory" >&2; exit 1; }
# fixture_cleanup_on_exit reads the test status from $?, so restore it after the chmod.
trap 'status=$?; chmod -R u+w "$TMP" 2>/dev/null; (exit "$status"); fixture_cleanup_on_exit "$TMP"' EXIT
for name in $(compgen -e | grep '^RCLONE_' || true); do unset "$name"; done
export HOME="$TMP/home" RCLONE_CONFIG="$TMP/rclone.conf" BROKKR_STATE_DIR="$TMP/state"
export ARCHIVE_RCLONE="$R" ARCHIVE_LOG="$TMP/log" ARCHIVE_NODE=node-a
mkdir -p "$HOME" "$TMP/archive/photos/a b" "$TMP/store" "$TMP/bin" "$TMP/python" "$TMP/nas"
SRC="$TMP/archive/photos"
printf one >"$SRC/a b/x.jpg"
head -c 300000 /dev/urandom >"$SRC/big.nef"
printf esc >"$SRC/back\\slash.jpg"
printf nl >"$SRC/new"$'\n'"line.jpg"
# GNU sha256sum format, including the escaped form for a name with a backslash.
write_manifest() {
  python3 -I - "$SRC" "$1" <<'PY'
import hashlib, os, sys
src, out = sys.argv[1:]
lines = []
for root, _, files in os.walk(src):
    for f in files:
        rel = os.path.relpath(os.path.join(root, f), src)
        digest = hashlib.sha256(open(os.path.join(root, f), "rb").read()).hexdigest()
        if "\\" in rel or "\n" in rel:
            lines.append("\\" + digest + "  " + rel.replace("\\", "\\\\").replace("\n", "\\n"))
        else:
            lines.append(digest + "  " + rel)
open(out, "w").write("".join(sorted(l + "\n" for l in lines)))
PY
}
write_manifest "$TMP/archive/photos.sha256"
export ARCHIVE_SRC="$SRC" ARCHIVE_MANIFEST="$TMP/archive/photos.sha256"
cp -R "$SRC/." "$TMP/nas/"
P=$("$R" obscure pw1); S=$("$R" obscure salt1)
cat >"$RCLONE_CONFIG" <<EOF
[plain]
type = local

[good]
type = crypt
remote = $TMP/store
filename_encoding = base32768
password = $P
password2 = $S

[base32]
type = crypt
remote = $TMP/store
password = $P
password2 = $S

[nosalt]
type = crypt
remote = $TMP/store
filename_encoding = base32768
password = $P

[clearnames]
type = crypt
remote = $TMP/store
filename_encryption = off
filename_encoding = base32768
password = $P
password2 = $S

[cleardirs]
type = crypt
remote = $TMP/store
directory_name_encryption = false
filename_encoding = base32768
password = $P
password2 = $S

[nodata]
type = crypt
remote = $TMP/store
no_data_encryption = true
filename_encoding = base32768
password = $P
password2 = $S

[globalimm]
type = crypt
remote = $TMP/store
global.immutable = false
filename_encoding = base32768
password = $P
password2 = $S

[base]
type = local

[sizeonly]
type = local
override.size_only = true

[chained]
type = crypt
remote = base:$TMP/store
filename_encoding = base32768
password = $P
password2 = $S

[chainedover]
type = crypt
remote = sizeonly:$TMP/store
filename_encoding = base32768
password = $P
password2 = $S

[inlineopt]
type = crypt
remote = base,links=true:$TMP/store
filename_encoding = base32768
password = $P
password2 = $S

[base archive]
type = local

[spaced]
type = crypt
remote = base archive:$TMP/store
filename_encoding = base32768
password = $P
password2 = $S

[connstr]
type = crypt
remote = :s3,access_key_id=AKIDSENTINEL,secret_access_key=SECRETSENTINEL:bucket
filename_encoding = base32768
password = $P
password2 = $S
EOF

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -z "${OUT:-}" ] || printf '  output: %s\n' "${OUT:0:600}"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
expect() { # expect <0|1> <desc> cmd...
  local want=$1 desc=$2 got; shift 2
  if OUT=$("$@" 2>&1); then got=0; else got=1; fi
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc"; fi
}
G=(env ARCHIVE_REMOTE=good bash "$SCRIPT")

# --- remote guard and push (ported from the original 16 checks) --------------
# Each refusal must be for its own reason, not an unrelated preflight failure.
refused() { # desc remote expected-text
  WANT=$3
  expect 1 "$1" env ARCHIVE_REMOTE="$2" bash "$SCRIPT" --validate
  check "$1: for the stated reason" '[[ "$OUT" == *"remote validation failed: "*"$WANT"* ]]'
}
refused "missing remote refused"            nope        "not configured"
refused "non-crypt remote refused"          plain       "is not type crypt"
refused "crypt without salt refused"        nosalt      "salt (password2)"
refused "clear filenames refused"           clearnames  "filename_encryption must be standard"
refused "clear directory names refused"     cleardirs   "directory_name_encryption must be true"
refused "default base32 names refused"      base32      "filename_encoding must be base32768"
refused "plaintext contents (no_data_encryption) refused" nodata "no_data_encryption must be false"
refused "global.immutable override in the crypt section refused" globalimm "sets a global/override option"
refused "override.* in the underlying remote refused" chainedover "'sizeonly' sets a global/override option"
refused "inline options on the underlying remote refused" inlineopt "must point at a configured named remote (no inline options)"
refused "connection-string underlying remote refused" connstr "must point at a configured named remote"
expect 0 "underlying remote name with a space accepted" env ARCHIVE_REMOTE=spaced bash "$SCRIPT" --validate
# rclone reads [local] for every bare local path (the archive source included), so its
# overrides apply although no remote names it.
{ cat "$RCLONE_CONFIG"; printf '\n[local]\ntype = local\nglobal.immutable = false\n'; } >"$TMP/local-override.conf"
WANT="the implicit [local] section sets a global/override option"
expect 1 "global override in the implicit [local] section refused" env RCLONE_CONFIG="$TMP/local-override.conf" ARCHIVE_REMOTE=good bash "$SCRIPT" --validate
check "implicit [local] refusal is for the stated reason" '[[ "$OUT" == *"$WANT"* ]]'
check "inline credentials are never printed" '[[ "$OUT" != *SENTINEL* ]]'
expect 0 "named underlying remote accepted"  env ARCHIVE_REMOTE=chained bash "$SCRIPT" --validate
check "validate identifies the underlying remote without its path" '[[ "$OUT" == *"underlying: base type=local"* && "$OUT" != *"$TMP/store"* ]]'
expect 1 "relative archive path refused"  env ARCHIVE_SRC=archive/photos ARCHIVE_REMOTE=good bash "$SCRIPT" --validate
expect 1 "bad mode refused"               "${G[@]}" --nuke
expect 1 "missing archive settings refused" env -u ARCHIVE_SRC ARCHIVE_REMOTE=good bash "$SCRIPT" --validate
expect 1 "rclone config override in env refused" env RCLONE_CONFIG_GOOD_FILENAME_ENCRYPTION=off "${G[@]}" --validate
expect 1 "rclone flag override in env refused" env RCLONE_DRY_RUN=true "${G[@]}" --push
expect 0 "valid crypt accepted"           "${G[@]}" --validate
check "validate writes no state directory or log" '[ ! -e "$TMP/state" ] && [ ! -e "$TMP/log" ]'
expect 0 "validate runs when piped to bash -s" sh -c 'ARCHIVE_REMOTE=good bash -s -- --validate <"$1"' _ "$SCRIPT"
expect 0 "dry-run ok"                     "${G[@]}" --dry-run
check "dry-run wrote nothing" '[ -z "$(ls -A "$TMP/store")" ]'
expect 0 "push + cryptcheck ok"           "${G[@]}" --push
check "no plaintext names in store" '! find "$TMP/store" | grep -qE "x\.jpg|big\.nef|slash|a b|photos"'
expect 0 "check ok"                       "${G[@]}" --check
expect 0 "re-push idempotent"             "${G[@]}" --push
printf two >"$SRC/a b/x.jpg"
expect 1 "changed file not overwritten"   "${G[@]}" --push
check "remote still has original" '[ "$("$R" cat "good:photos/a b/x.jpg")" = one ]'
printf one >"$SRC/a b/x.jpg"
touch "$SRC/extra"
expect 1 "manifest/file mismatch refused" "${G[@]}" --validate
rm -f "$SRC/extra"

# --- strict config file -------------------------------------------------------
CONF="$TMP/archive.conf"
write_conf() { printf '%s\n' "$@" >"$CONF"; chmod 600 "$CONF"; }
write_conf "ARCHIVE_REMOTE=good" "# comment" "" "ARCHIVE_NAME='photos'"
expect 0 "config file supplies the remote"  env -u ARCHIVE_REMOTE bash "$SCRIPT" --config "$CONF" --validate
expect 0 "config overrides the environment" env ARCHIVE_REMOTE=plain bash "$SCRIPT" --config "$CONF" --validate
chmod 640 "$CONF"
expect 1 "group-readable config refused"    bash "$SCRIPT" --config "$CONF" --validate
ln -sf "$CONF" "$TMP/link.conf"; chmod 600 "$CONF"
expect 1 "symlinked config refused"         bash "$SCRIPT" --config "$TMP/link.conf" --validate
write_conf "ARCHIVE_REMOTE=good" "PATH=/tmp"
expect 1 "unknown config key refused"       bash "$SCRIPT" --config "$CONF" --validate
write_conf "ARCHIVE_REMOTE=good" "ARCHIVE_REMOTE=plain"
expect 1 "duplicate config key refused"     bash "$SCRIPT" --config "$CONF" --validate
write_conf "ARCHIVE_REMOTE=\$(touch $TMP/pwned)"
expect 1 "command substitution refused"     bash "$SCRIPT" --config "$CONF" --validate
check "config value was never executed" '[ ! -e "$TMP/pwned" ]'
cp "$ROOT/scripts/lib/archive-offsite.conf.example" "$CONF"; chmod 600 "$CONF"
expect 1 "shipped example config parses (fails only on its placeholder archive)" bash "$SCRIPT" --config "$CONF" --validate
check "example config reached the archive preflight" '[[ "$OUT" == *"archive directory missing: /srv/archive/example-archive"* ]]'

# --- --verify ----------------------------------------------------------------
cat >"$TMP/python/sitecustomize.py" <<'PY'
import json, os, urllib.request

class Response:
    status = 200
    def __enter__(self):
        return self
    def __exit__(self, *_args):
        return False

class Opener:
    def open(self, request, timeout):
        if os.environ.get("MOCK_HTTP_FAIL") == "1":
            raise OSError("mock delivery failure")
        with open(os.environ["MOCK_REQUEST_FILE"], "w", encoding="utf-8") as fh:
            json.dump(json.loads(request.data.decode()), fh)
        return Response()

urllib.request.build_opener = lambda *handlers: Opener()
PY
# Fake near-site host: runs the remote command locally, rooted at the fake NAS copy.
cat >"$TMP/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
while [[ "${1:-}" == -o ]]; do shift 2; done
printf '%s\n' "$*" >>"$MOCK_SSH_CALLS"
[[ "${MOCK_SSH_DOWN:-0}" != 1 ]] || exit 255
PATH="$MOCK_GNU:$PATH" exec bash -c "$2"
FAKE
chmod 755 "$TMP/bin/ssh"
# The near-site host is GNU (Debian): its sha256sum decodes escaped manifest names. Where
# the test host's sha256sum is not GNU, the fake host gets a GNU-compatible --check.
mkdir -p "$TMP/gnu"
if ! sha256sum --version 2>/dev/null | grep -q GNU; then
  cat >"$TMP/gnu/sha256sum" <<'FAKE'
#!/usr/bin/env python3
import hashlib, sys
assert sys.argv[1:] == ["--check", "--quiet", "--strict", "-"], sys.argv
failed = 0
for line in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\n")[:-1]:
    esc = line.startswith("\\")
    line = line[1:] if esc else line
    digest, name = line[:64], line[66:]
    if esc:
        name = name.replace("\\\\", "\0").replace("\\n", "\n").replace("\0", "\\")
    try:
        ok = hashlib.sha256(open(name, "rb").read()).hexdigest() == digest
    except OSError:
        ok = False
    if not ok:
        failed += 1
        print(f"{name}: FAILED")
sys.exit(1 if failed else 0)
FAKE
  chmod 755 "$TMP/gnu/sha256sum"
fi
export MOCK_GNU="$TMP/gnu" MOCK_SSH_CALLS="$TMP/ssh-calls" MOCK_REQUEST_FILE="$TMP/request.json"
export ARCHIVE_NEARSITE_SSH=nas-operator@nas.example ARCHIVE_NEARSITE_DIR="$TMP/nas"
export ARCHIVE_KEY_DRILL_DATE=2026-10-01 BROKKR_NOW_EPOCH=1792800000   # 2026-10-24
SNAP="$TMP/state/archive-verify.json"
verify() {
  rm -f "$MOCK_REQUEST_FILE" "$SNAP"
  if OUT=$(env PATH="$TMP/bin:$PATH" PYTHONPATH="$TMP/python" HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels \
    HEIMDALL_FLEET_TOKEN=secret-sentinel ARCHIVE_REMOTE=good "$@" bash "$SCRIPT" --verify 2>&1); then RC=0; else RC=$?; fi
}
row() { python3 -I -c 'import json,sys; d={c["name"]: c for c in json.load(open(sys.argv[1]))["checks"]}; c=d.get(sys.argv[2]); print(c["status"] + " " + c["detail"] if c else "absent")' "$SNAP" "$1"; }
panel() { python3 -I -c 'import json,sys; b=json.load(open(sys.argv[1])); print(b["panel"], b["state"])' "$MOCK_REQUEST_FILE"; }

OUT=$(env -u HEIMDALL_HUB_URL -u HEIMDALL_FLEET_TOKEN ARCHIVE_REMOTE=good bash "$SCRIPT" --verify 2>&1); RC=$?
check "verify refuses without Heimdall delivery" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"not configured"* ]]'

verify
check "healthy verify exits 0 and delivers a per-node panel" '[ "$RC" = 0 ] && [ "$(panel)" = "archive-verify-node-a pass" ]'
check "copy row counts remote files and the manifest" '[[ "$(row copy)" == "pass remote holds 4/4 files"*"and the manifest" ]]'
check "integrity row: cryptcheck coverage and byte-identical manifest" '[[ "$(row integrity)" == "pass cryptcheck matched 4/4 files; remote manifest byte-identical" ]]'
check "restore row: sampled files restored and hashed" '[[ "$(row restore)" == "pass restored 3 random files"*"scratch removed" ]]'
check "near-site row: sha256sum -c over ssh" '[[ "$(row nearsite)" == pass* ]] && grep -q "sha256sum --check --quiet --strict -" "$MOCK_SSH_CALLS"'
check "key-drill row reports the owner-recorded date" '[ "$(row key-drill)" = "pass owner-recorded key-custody drill 2026-10-01 (23 days ago); next due 2027-10-01" ]'
check "no restore scratch or work directory is left behind" '[ -z "$(find "$TMP/state" -name ".archive-verify.*")" ]'
check "token never reaches the snapshot or log" '! grep -q secret-sentinel "$SNAP" "$ARCHIVE_LOG"'
check "panel message carries every row status, not just alarms" \
  '[ "$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))[\"message\"])" "$MOCK_REQUEST_FILE")" = "copy=pass integrity=pass restore=pass nearsite=pass key-drill=pass" ]'

# rclone reports an object with an empty stored hash as a match and exits 0; only the
# "N hashes could not be checked" notice shows it. The wrapper injects that notice.
cat >"$TMP/bin/rclone-nohash" <<'FAKE'
#!/usr/bin/env bash
"$MOCK_REAL_RCLONE" "$@"; rc=$?
if [ "$1" = cryptcheck ]; then
  prev=; for arg in "$@"; do [ "$prev" != --log-file ] || log=$arg; prev=$arg; done
  printf "2026/10/24 00:00:00 NOTICE: Encrypted drive 'good:photos': 1 hashes could not be checked\n" >>"$log"
fi
exit "$rc"
FAKE
cat >"$TMP/bin/rm" <<'FAKE'
#!/usr/bin/env bash
if [ "${MOCK_RM_FAIL:-0}" = 1 ]; then
  for arg in "$@"; do case "$arg" in */restore) echo "rm: mock failure" >&2; exit 1 ;; esac; done
fi
exec /bin/rm "$@"
FAKE
chmod 755 "$TMP/bin/rclone-nohash" "$TMP/bin/rm"
verify MOCK_REAL_RCLONE="$R" ARCHIVE_RCLONE="$TMP/bin/rclone-nohash"
check "unchecked cryptcheck hashes fail integrity" '[ "$RC" = 1 ] && [[ "$(row integrity)" == *"1 hashes unchecked" ]]'
expect 1 "manual --check fails on unchecked hashes" env MOCK_REAL_RCLONE="$R" ARCHIVE_RCLONE="$TMP/bin/rclone-nohash" "${G[@]}" --check
check "manual --check names the unchecked hashes" '[[ "$OUT" == *"1 hashes unchecked"* ]]'
expect 1 "manual --push fails on unchecked hashes" env MOCK_REAL_RCLONE="$R" ARCHIVE_RCLONE="$TMP/bin/rclone-nohash" "${G[@]}" --push
verify MOCK_RM_FAIL=1
check "failed scratch removal is delivered as a restore failure" '[ "$RC" = 1 ] && [[ "$(row restore)" == "fail restored 3/3 sampled files but could not remove the scratch copy" ]] && [ "$(panel)" = "archive-verify-node-a fail" ]'
check "the work directory is still removed afterwards" '[ -z "$(find "$TMP/state" -name ".archive-verify.*")" ]'

verify ARCHIVE_RESTORE_SAMPLES=2
check "restore samples are bounded by ARCHIVE_RESTORE_SAMPLES" '[[ "$(row restore)" == "pass restored 2 random files"* ]]'
verify ARCHIVE_RESTORE_SAMPLES=0
check "invalid sample count refused" '[ "$RC" -ne 0 ] && [ ! -f "$MOCK_REQUEST_FILE" ]'

verify ARCHIVE_KEY_DRILL_DATE=2025-09-01
check "overdue key-custody drill warns" '[ "$RC" = 0 ] && [[ "$(row key-drill)" == "warn key-custody drill overdue"* ]] && [ "$(panel)" = "archive-verify-node-a warn" ]'
verify ARCHIVE_KEY_DRILL_DATE=
check "unrecorded key-custody drill warns" '[[ "$(row key-drill)" == "warn no key-custody drill recorded"* ]]'
verify ARCHIVE_KEY_DRILL_DATE=2027-01-01
check "future key-custody drill date fails" '[ "$RC" = 1 ] && [[ "$(row key-drill)" == fail* ]]'

verify ARCHIVE_NEARSITE_SSH= ARCHIVE_NEARSITE_DIR=
check "unconfigured near-site copy is a warning, never a pass" '[[ "$(row nearsite)" == "warn near-site copy not verified"* ]]'
verify ARCHIVE_NEARSITE=off ARCHIVE_NEARSITE_SSH= ARCHIVE_NEARSITE_DIR=
check "ARCHIVE_NEARSITE=off omits the row" '[ "$(row nearsite)" = absent ] && [ "$(panel)" = "archive-verify-node-a pass" ]'
verify MOCK_SSH_DOWN=1
check "unreachable near-site host fails" '[ "$RC" = 1 ] && [ "$(row nearsite)" = "fail near-site host unreachable over ssh" ]'
verify "ARCHIVE_NEARSITE_DIR=$TMP/nas;touch"
check "unsafe near-site path refused before any ssh" '[ "$RC" -ne 0 ] && [ ! -f "$MOCK_REQUEST_FILE" ]'
printf corrupt >"$TMP/nas/big.nef"
verify
check "corrupt near-site file fails only the near-site row" '[ "$RC" = 1 ] && [[ "$(row nearsite)" == *"1 of 4 entries FAILED" ]] && [[ "$(row integrity)" == pass* ]]'
cp "$SRC/big.nef" "$TMP/nas/big.nef"

verify MOCK_HTTP_FAIL=1
check "failed Heimdall delivery exits 2" '[ "$RC" = 2 ] && [[ "$OUT" == *"Heimdall delivery failed"* ]]'

verify ARCHIVE_REMOTE=clearnames
check "unsafe remote fails every off-site row and is still delivered" '[ "$RC" = 1 ] && [[ "$(row preflight)" == "fail remote validation failed"* ]] && [[ "$(row copy)" == fail* && "$(row integrity)" == fail* && "$(row restore)" == fail* ]] && [ "$(panel)" = "archive-verify-node-a fail" ]'

# Tamper with the remote: flip the stored manifest, then corrupt and drop objects.
cp "$ARCHIVE_MANIFEST" "$TMP/manifest.orig"
"$R" deletefile good:photos.sha256
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000  other" | "$R" rcat good:photos.sha256
verify
check "differing remote manifest fails integrity" '[ "$RC" = 1 ] && [[ "$(row integrity)" == "fail remote manifest missing or differs"* ]] && [[ "$(row copy)" == pass* ]]'
"$R" deletefile good:photos.sha256
"$R" copyto "$TMP/manifest.orig" good:photos.sha256
big=$(find "$TMP/store" -type f -size +100k | head -n 1)
chmod u+w "$big"; printf 'XXXX' | dd of="$big" bs=1 seek=1000 conv=notrunc 2>/dev/null
verify
check "corrupted remote object fails integrity and restore" '[ "$RC" = 1 ] && [[ "$(row integrity)" == "fail cryptcheck exit"* ]] && [[ "$(row restore)" == "fail only 2/3"* ]]'
check "failed restore still removes the scratch copy" '[ -z "$(find "$TMP/state" -name ".archive-verify.*")" ]'
rm -f "$big"
verify
check "missing remote object fails copy and integrity" '[ "$RC" = 1 ] && [[ "$(row copy)" == "fail remote holds only 3/4 files"* ]] && [[ "$(row integrity)" == fail* ]]'

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
