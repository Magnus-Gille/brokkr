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

TMP="$(fixture_cleanup_alloc)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; fixture_cleanup_on_exit "$TMP"' EXIT
for name in $(compgen -e | grep '^RCLONE_' || true); do unset "$name"; done
export HOME="$TMP/home" RCLONE_CONFIG="$TMP/rclone.conf" BROKKR_STATE_DIR="$TMP/state"
export ARCHIVE_RCLONE="$R" ARCHIVE_LOG="$TMP/log" ARCHIVE_NODE=node-a
mkdir -p "$HOME" "$TMP/archive/photos/a b" "$TMP/store" "$TMP/bin" "$TMP/python" "$TMP/nas"
SRC="$TMP/archive/photos"
printf one >"$SRC/a b/x.jpg"
head -c 300000 /dev/urandom >"$SRC/big.nef"
printf esc >"$SRC/back\\slash.jpg"
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
expect 1 "missing remote refused"         env ARCHIVE_REMOTE=nope bash "$SCRIPT" --validate
expect 1 "non-crypt remote refused"       env ARCHIVE_REMOTE=plain bash "$SCRIPT" --validate
expect 1 "crypt without salt refused"     env ARCHIVE_REMOTE=nosalt bash "$SCRIPT" --validate
expect 1 "clear filenames refused"        env ARCHIVE_REMOTE=clearnames bash "$SCRIPT" --validate
expect 1 "clear directory names refused"  env ARCHIVE_REMOTE=cleardirs bash "$SCRIPT" --validate
expect 1 "default base32 names refused"   env ARCHIVE_REMOTE=base32 bash "$SCRIPT" --validate
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
check "copy row counts remote files and the manifest" '[[ "$(row copy)" == "pass remote holds 3/3 files"*"and the manifest" ]]'
check "integrity row: cryptcheck coverage and byte-identical manifest" '[[ "$(row integrity)" == "pass cryptcheck matched 3/3 files; remote manifest byte-identical" ]]'
check "restore row: sampled files restored and hashed" '[[ "$(row restore)" == "pass restored 3 random files"*"scratch removed" ]]'
check "near-site row: sha256sum -c over ssh" '[[ "$(row nearsite)" == pass* ]] && grep -q "sha256sum --check --quiet --strict -" "$MOCK_SSH_CALLS"'
check "key-drill row reports the owner-recorded date" '[ "$(row key-drill)" = "pass owner-recorded key-custody drill 2026-10-01 (23 days ago); next due 2027-10-01" ]'
check "no restore scratch or work directory is left behind" '[ -z "$(find "$TMP/state" -name ".archive-verify.*")" ]'
check "token never reaches the snapshot or log" '! grep -q secret-sentinel "$SNAP" "$ARCHIVE_LOG"'

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
check "corrupt near-site file fails only the near-site row" '[ "$RC" = 1 ] && [[ "$(row nearsite)" == *"1 of 3 entries FAILED" ]] && [[ "$(row integrity)" == pass* ]]'
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
check "missing remote object fails copy and integrity" '[ "$RC" = 1 ] && [[ "$(row copy)" == "fail remote holds only 2/3 files"* ]] && [[ "$(row integrity)" == fail* ]]'

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
