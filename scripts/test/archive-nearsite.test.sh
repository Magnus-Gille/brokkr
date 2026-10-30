#!/usr/bin/env bash
# Hermetic tests for scripts/archive-nearsite.sh. A real GNU sha256sum checks a fixture
# copy in a temp dir; the Heimdall HTTP client is a fake. No network, ssh, or real host.
# shellcheck disable=SC2016,SC2034 # assertions are evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/scripts/archive-nearsite.sh"
# shellcheck source=scripts/test/lib/fixture-cleanup.sh
source "$HERE/lib/fixture-cleanup.sh"

# The verifier needs GNU sha256sum (text-mode manifests, --strict, --quiet).
GNU_SHA=""
for cand in sha256sum gsha256sum; do
  # Captured first: `grep -q` closing the pipe early would fail the pipeline under pipefail.
  banner="$("$cand" --version 2>/dev/null || true)"
  if [[ "$banner" == *GNU* ]]; then GNU_SHA="$(command -v "$cand")"; break; fi
done
if [ -z "$GNU_SHA" ]; then
  # CI is Linux with GNU coreutils, so a missing GNU sha256sum there is a failure.
  if [ "${CI:-}" = true ]; then echo "not ok - GNU sha256sum is required in CI" >&2; exit 1; fi
  echo "skip - GNU sha256sum not installed; archive-nearsite tests need it"; exit 0
fi

TMP="$(fixture_cleanup_alloc)" || { echo "not ok - cannot allocate a test fixture" >&2; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "not ok - fixture allocation returned no directory" >&2; exit 1; }
trap 'fixture_cleanup_on_exit "$TMP"' EXIT
export HOME="$TMP/home" BROKKR_STATE_DIR="$TMP/state" ARCHIVE_NODE=nas-host TMPDIR="$TMP/tmp"
mkdir -p "$HOME" "$TMPDIR" "$TMP/python" "$TMP/gnu" "$TMP/nas"
unset XDG_CONFIG_HOME

# Fake near-site copy. The names include spaces and UTF-8; one carries a sentinel that
# must never reach the panel, the snapshot, or any output.
NAS="$TMP/nas"
mkdir -p "$NAS/a b" "$NAS/ünï cödé"
printf one >"$NAS/a b/x.jpg"
printf two >"$NAS/ünï cödé/ärkiv ö.txt"
printf three >"$NAS/private-person-name.jpg"
head -c 300000 /dev/urandom >"$NAS/big.nef"
MAN="$TMP/archive.sha256"
write_manifest() { # manifest of the current $NAS tree
  python3 -I - "$NAS" "$MAN" <<'PY'
import hashlib, os, sys
src, out = sys.argv[1:]
lines = []
for root, _, files in os.walk(src):
    for f in files:
        full = os.path.join(root, f)
        lines.append(hashlib.sha256(open(full, "rb").read()).hexdigest() + "  " + os.path.relpath(full, src))
open(out, "wb").write("".join(sorted(l + "\n" for l in lines)).encode("utf-8"))
PY
}
pin_of() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
CONF="$TMP/archive-nearsite.conf"
write_conf() { # extra config lines; pins the manifest as it is now
  printf '%s\n' "ARCHIVE_NEARSITE_DIR=$NAS" "ARCHIVE_NEARSITE_MANIFEST=$MAN" "ARCHIVE_NEARSITE_MANIFEST_SHA256=$(pin_of "$MAN")" "$@" >"$CONF"
  chmod 600 "$CONF"
}
raw_conf() { printf '%s\n' "$@" >"$CONF"; chmod 600 "$CONF"; }
write_manifest; write_conf
cp "$MAN" "$TMP/manifest.good"

# sha256sum wrapper: records every invocation so a skipped hash run is provable.
#   MOCK_SWAP_MANIFEST=file  appends junk to that file just before a hash run (a manifest
#                            changed after it was pinned);
#   MOCK_SHA_SLEEP=n         keeps the hash run busy for n seconds (a window for a signal).
# stdin bytes are recorded to prove the hash run reads /dev/null, never the caller's stdin.
cat >"$TMP/gnu/sha256sum" <<FAKE
#!/usr/bin/env bash
printf 'sha256sum %s\n' "\$*" >>"\$MOCK_SHA_CALLS"
if [[ "\$*" == *--check* ]]; then
  printf 'stdin_bytes=%s\n' "\$(wc -c | tr -d ' ')" >>"\$MOCK_SHA_CALLS"
  [ -z "\${MOCK_SWAP_MANIFEST:-}" ] || printf junk >>"\$MOCK_SWAP_MANIFEST"
  [ -z "\${MOCK_SHA_SLEEP:-}" ] || sleep "\$MOCK_SHA_SLEEP"
fi
exec $GNU_SHA "\$@"
FAKE
chmod 755 "$TMP/gnu/sha256sum"
# rm wrapper: MOCK_RM_FAIL=1 makes removing the verifier's work directory fail (any other rm works).
cat >"$TMP/gnu/rm" <<'FAKE'
#!/usr/bin/env bash
if [ "${MOCK_RM_FAIL:-0}" = 1 ] && [ "${1:-}" = -rf ] && [[ "${!#}" == */.archive-nearsite.* ]]; then
  echo "rm: mock failure" >&2; exit 1
fi
exec /bin/rm "$@"
FAKE
chmod 755 "$TMP/gnu/rm"
export MOCK_SHA_CALLS="$TMP/sha-calls" MOCK_REQUEST_FILE="$TMP/request.json"
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

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -z "${OUT:-}" ] || printf '  rc=%s output: %s\n' "${RC:-}" "${OUT:0:600}"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TOKEN=token-sentinel-4f9a
SNAP="$TMP/state/archive-nearsite.json"
OUTFILE="$TMP/out.txt"
H=0000000000000000000000000000000000000000000000000000000000000000
# The Heimdall producer credential reaches the verifier only through --delivery-env FILE
# (the unit starts it with env -i); the process environment of a manual run is ignored.
DENV="$TMP/delivery.env"
HUB=http://heimdall.invalid/api/panels
write_denv() { # lines...
  printf '%s\n' "$@" >"$DENV"; chmod 600 "$DENV"
}
# cmd [NOHUB=1] [NOTOKEN=1] [NODENV=1] [RAWDENV=1] [NAME=value]... -- script arguments...
# NOHUB/NOTOKEN leave that line out of the delivery env, NODENV passes no --delivery-env,
# RAWDENV uses the delivery env file as the test left it.
cmd() {
  local -a envs=(); local nohub=0 notoken=0 nodenv=0 rawdenv=0 kv
  while [ "$1" != -- ]; do
    case "$1" in NOHUB=1) nohub=1 ;; NOTOKEN=1) notoken=1 ;; NODENV=1) nodenv=1 ;; RAWDENV=1) rawdenv=1 ;; *) envs+=("$1") ;; esac
    shift
  done
  shift
  local -a dargs=(--delivery-env "$DENV")
  [ "$nodenv" = 0 ] || dargs=()
  if [ "$rawdenv" = 0 ]; then
    : >"$DENV"; chmod 600 "$DENV"
    [ "$nohub" = 1 ] || printf 'HEIMDALL_HUB_URL=%s\n' "$HUB" >>"$DENV"
    [ "$notoken" = 1 ] || printf 'HEIMDALL_FLEET_TOKEN=%s\n' "$TOKEN" >>"$DENV"
  fi
  OUT=$(
    export PATH="$TMP/gnu:$PATH" PYTHONPATH="$TMP/python"
    for kv in ${envs[@]+"${envs[@]}"}; do export "${kv?}"; done
    bash "$SCRIPT" "$@" ${dargs[@]+"${dargs[@]}"} 2>&1 </dev/null
  ) && RC=0 || RC=$?
  printf '%s' "$OUT" >"$OUTFILE"
}
run() { # mode [env assignments...]
  local mode=$1; shift
  rm -f "$MOCK_REQUEST_FILE" "$SNAP"; : >"$MOCK_SHA_CALLS"
  cmd ${@+"$@"} -- "$mode" --config "$CONF"
}
verify() { run --verify ${@+"$@"}; }
row() { python3 -I -c 'import json,sys; d={c["name"]: c for c in json.load(open(sys.argv[1]))["checks"]}; c=d.get(sys.argv[2]); print(c["status"] + " " + c["detail"] if c else "absent")' "$SNAP" "$1"; }
panel() { python3 -I -c 'import json,sys; b=json.load(open(sys.argv[1])); print(b["panel"], b["state"])' "$MOCK_REQUEST_FILE"; }
message() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"])' "$MOCK_REQUEST_FILE"; }
no_hash_run() { ! grep -q 'sha256sum --check' "$MOCK_SHA_CALLS"; }
# No fixture file name may appear in any captured output, snapshot, or delivered body.
no_names() { ! grep -qE 'private-person-name|x\.jpg|big\.nef|ärkiv|ünï' "$OUTFILE" "$MOCK_REQUEST_FILE" "$SNAP" 2>/dev/null; }
# Neither the token nor any run of 8 or more of its characters may appear anywhere.
no_token() {
  local i
  for ((i = 0; i + 8 <= ${#TOKEN}; i++)); do
    ! grep -rqF -- "${TOKEN:i:8}" "$OUTFILE" "$MOCK_REQUEST_FILE" "$SNAP" "$TMP/state" 2>/dev/null || return 1
  done
}

# --- healthy run -----------------------------------------------------------------------------
verify
check "healthy verify exits 0 and delivers a per-node panel" '[ "$RC" = 0 ] && [ "$(panel)" = "archive-nearsite-nas-host pass" ]'
check "manifest row passes" '[[ "$(row manifest)" == "pass "* ]]'
check "nearsite row: sha256sum -c matched every entry (UTF-8 and spaced names accepted)" '[[ "$(row nearsite)" == "pass sha256sum -c matched all 4 manifest entries"* ]]'
check "nearsite row says no extras were found" '[[ "$(row nearsite)" == *"0 extra files"* ]]'
check "hash run is sha256sum --check --quiet --strict" 'grep -q "sha256sum --check --quiet --strict " "$MOCK_SHA_CALLS"'
check "panel message leads with every row status" '[[ "$(message)" == "manifest=pass nearsite=pass"* ]]'
check "snapshot is written to the state directory as one JSON line" '[ -f "$SNAP" ] && [ "$(wc -l <"$SNAP" | tr -d " ")" = 1 ]'
check "no work directory is left behind" '[ -z "$(find "$TMP/state" "$TMPDIR" -name ".archive-nearsite.*")" ]'
check "token never reaches output, snapshot, or state" 'no_token'
check "no file name reaches the output, snapshot, or delivered body (pass)" 'no_names'
check "the delivered stamp carries the nearsite prefix" '[ -f "$TMP/state/archive-nearsite-last-push-success" ]'

# --- extra files are informational ------------------------------------------------------------
printf extra >"$NAS/new extra ü.txt"; mkdir -p "$NAS/deep dir"; printf extra2 >"$NAS/deep dir/more.txt"
verify
check "extra files are reported but the row still passes" '[ "$RC" = 0 ] && [[ "$(row nearsite)" == "pass sha256sum -c matched all 4 manifest entries; 2 extra files"* ]] && [ "$(panel)" = "archive-nearsite-nas-host pass" ]'
check "the extras note reaches the panel message without changing any status" '[[ "$(message)" == "manifest=pass nearsite=pass | "*"2 extra files"* ]]'
check "extra file names are not disclosed" 'no_names && ! grep -q "new extra\|more.txt" "$OUTFILE" "$MOCK_REQUEST_FILE" "$SNAP"'
rm -rf "$NAS/new extra ü.txt" "$NAS/deep dir"

# --- hashing failures: counts only --------------------------------------------------------------
cp "$NAS/big.nef" "$TMP/big.orig"
printf corrupt >"$NAS/big.nef"
verify
check "a changed file fails the nearsite row with a mismatch count" '[ "$RC" = 1 ] && [[ "$(row nearsite)" == "fail sha256sum -c exit 1: 1 mismatched, 0 missing of 4 manifest entries"* ]] && [[ "$(row manifest)" == pass* ]] && [ "$(panel)" = "archive-nearsite-nas-host fail" ]'
check "failure panel message leads with all row statuses then the alarm" '[[ "$(message)" == "manifest=pass nearsite=fail | nearsite: sha256sum -c exit 1"* ]]'
check "no file name reaches the output or panel on a mismatch" 'no_names'
cp "$TMP/big.orig" "$NAS/big.nef"
mv "$NAS/private-person-name.jpg" "$TMP/moved.jpg"; printf more >>"$NAS/a b/x.jpg"
verify
check "a missing file is counted separately from a mismatch" '[ "$RC" = 1 ] && [[ "$(row nearsite)" == "fail sha256sum -c exit 1: 1 mismatched, 1 missing of 4 manifest entries"* ]]'
check "no file name reaches the output or panel for a missing file" 'no_names'
mv "$TMP/moved.jpg" "$NAS/private-person-name.jpg"; printf one >"$NAS/a b/x.jpg"
verify
check "the restored tree passes again" '[ "$RC" = 0 ]'

# --- the pin is the trust anchor ---------------------------------------------------------------
printf '%s  forged.txt\n' "$H" >>"$MAN"
verify
check "a changed manifest never passes the pin" '[ "$RC" = 1 ] && [[ "$(row manifest)" == "fail manifest sha256 does not match the pinned value"* ]] && [ "$(panel)" = "archive-nearsite-nas-host fail" ]'
check "pin mismatch skips the hash run and says so" 'no_hash_run && [ "$(row nearsite)" = "fail not checked: manifest row failed" ]'
check "pin mismatch discloses neither full hash" '! grep -qE "[0-9a-f]{64}" "$OUTFILE" "$SNAP" "$MOCK_REQUEST_FILE"'
check "panel message leads with both failed statuses" '[[ "$(message)" == "manifest=fail nearsite=fail | "* ]]'
cp "$TMP/manifest.good" "$MAN"

# Each format violation fails the manifest row for its own stated reason. The manifest is
# re-pinned so only the format can be at fault.
format_case() { # description expected-detail-fragment raw-manifest-bytes (printf %b)
  printf '%b' "$3" >"$MAN"
  write_conf
  verify
  local want=$2   # expanded here: check evaluates its condition with its own positional parameters
  check "$1" '[ "$RC" = 1 ] && [[ "$(row manifest)" == "fail "*"'"$want"'"* ]] && [ "$(row nearsite)" = "fail not checked: manifest row failed" ]'
  check "$1: no hash run, delivered as fail" 'no_hash_run && [ "$(panel)" = "archive-nearsite-nas-host fail" ]'
}
format_case "absolute path in the manifest fails" "absolute path" "$H  /etc/passwd\n"
format_case "a .. component fails" ".. component" "$H  a/../b\n"
format_case "a leading ./ fails" "leading ./" "$H  ./a.txt\n"
format_case "a . component fails" ". component" "$H  a/./b\n"
format_case "an empty component (double slash) fails" "empty path component" "$H  a//b\n"
format_case "a backslash-escaped line fails" "backslash-escaped" "\\\\$H  a\\\\\\\\b\n"
format_case "a CR fails" "carriage return" "$H  a.txt\r\n"
format_case "a control character fails" "control character" "$H  a\tb.txt\n"
format_case "binary-mode lines fail" "text-mode" "$H *a.txt\n"
format_case "an uppercase digest fails" "text-mode" "$(printf '%s' "$H" | tr 0 A)  a.txt\n"
format_case "a short digest fails" "text-mode" "abc  a.txt\n"
format_case "a missing trailing newline fails" "does not end with a newline" "$H  a.txt"
format_case "an empty manifest fails" "empty" ""
format_case "a line with an empty path fails" "text-mode" "$H  \n"
# GNU sha256sum --check reads standard input for the path "-": with an empty-content digest
# a missing file would pass. Only the whole path "-" is special; "dir/-" and "a-b" are files.
EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
format_case "the path - (sha256sum reads stdin) fails even with the empty-content digest" "stdin" "$EMPTY  -\n"
printf '%b' "$H  dir/-\n$H  a-b\n$H  -a\n" >"$MAN"; write_conf; verify
check "paths that merely contain a dash are accepted by the manifest row" '[[ "$(row manifest)" == "pass "* ]]'
check "format failures never print the offending path" '! grep -q "passwd" "$OUTFILE"'
rm -f "$MAN"; ln -s "$TMP/manifest.good" "$MAN"; write_conf
verify
check "a symlinked manifest fails the manifest row" '[ "$RC" = 1 ] && [[ "$(row manifest)" == "fail manifest is not a readable regular non-symlink file"* ]] && no_hash_run'
rm -f "$MAN"
verify
check "a missing manifest fails the manifest row" '[ "$RC" = 1 ] && [[ "$(row manifest)" == fail* ]] && no_hash_run'
cp "$TMP/manifest.good" "$MAN"; write_conf
verify "ARCHIVE_NEARSITE_MANIFEST_SHA256=$H"
check "the pin comes only from the config file, never the environment" '[ "$RC" = 0 ]'
mv "$NAS" "$TMP/nas.away"
verify
check "a missing near-site directory fails the nearsite row" '[ "$RC" = 1 ] && [[ "$(row manifest)" == pass* ]] && [[ "$(row nearsite)" == "fail near-site directory missing"* ]]'
mv "$TMP/nas.away" "$NAS"

# The hash run reads the private copy of the pinned bytes, not the live file.
verify
check "sha256sum reads a private copy of the pinned bytes" '[ "$RC" = 0 ] && ! grep -qF " $MAN" "$MOCK_SHA_CALLS"'

# --- config refusal -------------------------------------------------------------------------------
chmod 640 "$CONF"
verify; check "group-readable config refused (exit 2, nothing delivered)" '[ "$RC" = 2 ] && [ ! -f "$MOCK_REQUEST_FILE" ]'
chmod 600 "$CONF"; ln -sf "$CONF" "$TMP/link.conf"
cmd -- --verify --config "$TMP/link.conf"
check "symlinked config refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"non-symlink"* ]]'
write_conf "PATH=/tmp"
verify; check "unknown config key refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"not allowed"* ]] && [ ! -f "$MOCK_REQUEST_FILE" ]'
write_conf "ARCHIVE_SRC=$NAS"
verify; check "an archive-offsite key is not accepted here" '[ "$RC" = 2 ] && [[ "$OUT" == *"not allowed"* ]]'
write_conf "ARCHIVE_NEARSITE_DIR=/other"
verify; check "duplicate config key refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"more than once"* ]]'
write_conf "ARCHIVE_NODE=\$(touch $TMP/pwned)"
verify; check "command substitution refused and never executed" '[ "$RC" = 2 ] && [ ! -e "$TMP/pwned" ]'
write_conf "export ARCHIVE_NODE=x"
verify; check "export prefix refused" '[ "$RC" = 2 ]'
raw_conf "ARCHIVE_NEARSITE_MANIFEST=$MAN" "ARCHIVE_NEARSITE_MANIFEST_SHA256=$(pin_of "$MAN")"
verify; check "missing ARCHIVE_NEARSITE_DIR refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"ARCHIVE_NEARSITE_DIR"* ]]'
raw_conf "ARCHIVE_NEARSITE_DIR=$NAS" "ARCHIVE_NEARSITE_MANIFEST_SHA256=$(pin_of "$MAN")"
verify; check "missing ARCHIVE_NEARSITE_MANIFEST refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"ARCHIVE_NEARSITE_MANIFEST"* ]]'
raw_conf "ARCHIVE_NEARSITE_DIR=$NAS" "ARCHIVE_NEARSITE_MANIFEST=$MAN"
verify; check "missing pin refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"ARCHIVE_NEARSITE_MANIFEST_SHA256"* ]] && no_hash_run'
raw_conf "ARCHIVE_NEARSITE_DIR=$NAS" "ARCHIVE_NEARSITE_MANIFEST=$MAN" "ARCHIVE_NEARSITE_MANIFEST_SHA256=ABCDEF"
verify; check "malformed pin refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"64 lowercase hex"* ]]'
raw_conf "ARCHIVE_NEARSITE_DIR=$NAS" "ARCHIVE_NEARSITE_MANIFEST=$MAN" "ARCHIVE_NEARSITE_MANIFEST_SHA256=$(pin_of "$MAN")a"
verify; check "overlong pin refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"64 lowercase hex"* ]]'
raw_conf "ARCHIVE_NEARSITE_DIR=$NAS" "ARCHIVE_NEARSITE_MANIFEST=$MAN" "ARCHIVE_NEARSITE_MANIFEST_SHA256=$(printf 'A%.0s' $(seq 1 64))"
verify; check "uppercase pin refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"64 lowercase hex"* ]]'
raw_conf "ARCHIVE_NEARSITE_DIR=nas" "ARCHIVE_NEARSITE_MANIFEST=$MAN" "ARCHIVE_NEARSITE_MANIFEST_SHA256=$(pin_of "$MAN")"
verify; check "relative near-site dir refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"absolute plain path"* ]]'
raw_conf "ARCHIVE_NEARSITE_DIR=$NAS" "ARCHIVE_NEARSITE_MANIFEST=man/../x" "ARCHIVE_NEARSITE_MANIFEST_SHA256=$(pin_of "$MAN")"
verify; check "relative manifest path refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"absolute plain path"* ]]'
raw_conf "ARCHIVE_NEARSITE_DIR=/a/../b" "ARCHIVE_NEARSITE_MANIFEST=$MAN" "ARCHIVE_NEARSITE_MANIFEST_SHA256=$(pin_of "$MAN")"
verify; check "dot-dot near-site dir refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"absolute plain path"* ]]'
rm -f "$CONF"
verify; check "missing config refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"config"* ]]'
write_conf
mkdir -p "$HOME/.config/brokkr"; cp "$CONF" "$HOME/.config/brokkr/archive-nearsite.conf"
rm -f "$MOCK_REQUEST_FILE"
cmd -- --verify
check "the default config path is ~/.config/brokkr/archive-nearsite.conf" '[ "$RC" = 0 ] && [ "$(panel)" = "archive-nearsite-nas-host pass" ]'
mkdir -p "$TMP/xdg/brokkr"; cp "$CONF" "$TMP/xdg/brokkr/archive-nearsite.conf"
rm -f "$HOME/.config/brokkr/archive-nearsite.conf"
cmd XDG_CONFIG_HOME="$TMP/xdg" -- --verify
check "XDG_CONFIG_HOME selects the default config" '[ "$RC" = 0 ]'
cp "$ROOT/scripts/lib/archive-nearsite.conf.example" "$CONF"; chmod 600 "$CONF"
run --validate
check "the shipped example config parses (stops only at its placeholder paths)" '[ "$RC" = 2 ] && [[ "$OUT" != *"not allowed"* && "$OUT" != *"not KEY=value"* && "$OUT" != *"plain or wholly quoted"* && "$OUT" != *"lowercase hex"* ]]'
write_conf

# --- node name and usage ----------------------------------------------------------------------------
verify ARCHIVE_NODE=NAS.Home.Example
check "the node name is lowercased and cut at the first dot" '[ "$RC" = 0 ] && [ "$(panel)" = "archive-nearsite-nas pass" ]'
verify ARCHIVE_NODE="$(printf 'n%.0s' $(seq 1 41))"
check "an over-long node name is refused" '[ "$RC" = 2 ] && [ ! -f "$MOCK_REQUEST_FILE" ]'
write_conf "ARCHIVE_NODE=cfg-node"
verify ARCHIVE_NODE=env-node
check "ARCHIVE_NODE from the config wins over the environment" '[ "$(panel)" = "archive-nearsite-cfg-node pass" ]'
write_conf
cmd -- --config "$CONF"
check "a missing mode is refused" '[ "$RC" = 2 ] && [[ "$OUT" == *usage* ]]'
cmd -- --config "$CONF" --nuke
check "an unknown mode is refused" '[ "$RC" = 2 ]'
cmd -- --verify --validate --config "$CONF"
check "two modes are refused" '[ "$RC" = 2 ]'

# --- Heimdall delivery -------------------------------------------------------------------------------------
rm -f "$MOCK_REQUEST_FILE" "$SNAP"
cmd NODENV=1 -- --config "$CONF" --verify
check "verify refuses without --delivery-env (exit 2, nothing written)" '[ "$RC" = 2 ] && [[ "$OUT" == *"not configured"* ]] && [ ! -f "$MOCK_REQUEST_FILE" ] && [ ! -f "$SNAP" ]'
cmd NODENV=1 HEIMDALL_HUB_URL="$HUB" HEIMDALL_FLEET_TOKEN="$TOKEN" -- --config "$CONF" --verify
check "the process environment is not a source of the credential (exit 2)" '[ "$RC" = 2 ] && [[ "$OUT" == *"not configured"* ]] && [ ! -f "$MOCK_REQUEST_FILE" ] && no_token'
cmd NOHUB=1 NOTOKEN=1 -- --config "$CONF" --verify
check "verify refuses an empty delivery env (exit 2)" '[ "$RC" = 2 ] && [[ "$OUT" == *"HEIMDALL_HUB_URL"* ]] && [ ! -f "$MOCK_REQUEST_FILE" ]'
cmd NOTOKEN=1 -- --config "$CONF" --verify
check "verify refuses with only a hub URL (exit 2)" '[ "$RC" = 2 ] && [[ "$OUT" == *"HEIMDALL_FLEET_TOKEN"* ]]'
cmd NOHUB=1 -- --config "$CONF" --verify
check "verify refuses with only a token (exit 2) and does not print it" '[ "$RC" = 2 ] && [[ "$OUT" == *"HEIMDALL_HUB_URL"* ]] && no_token'

# The delivery env is parsed in-process: private regular file, the two canonical lines once
# each and non-empty, every other key ignored. Refusals never print a value.
denv_refused() { # description line...
  local desc=$1; shift
  write_denv "$@"; run --verify RAWDENV=1
  check "delivery env: $desc" '[ "$RC" = 2 ] && [ ! -f "$MOCK_REQUEST_FILE" ] && [ ! -f "$SNAP" ] && no_token && no_hash_run && [[ "$OUT" != *heimdall.invalid* ]]'
}
GOODHUB="HEIMDALL_HUB_URL=$HUB"; GOODTOK="HEIMDALL_FLEET_TOKEN=$TOKEN"
denv_refused "a duplicate token is refused" "$GOODHUB" "$GOODTOK" "HEIMDALL_FLEET_TOKEN=${TOKEN}-other"
denv_refused "a duplicate hub URL is refused" "$GOODHUB" "$GOODTOK" "HEIMDALL_HUB_URL=http://other.invalid/p"
denv_refused "an empty token is refused" "$GOODHUB" "HEIMDALL_FLEET_TOKEN="
denv_refused "an empty hub URL is refused" "HEIMDALL_HUB_URL=" "$GOODTOK"
denv_refused "a double-quoted token is refused" "$GOODHUB" "HEIMDALL_FLEET_TOKEN=\"$TOKEN\""
denv_refused "a single-quoted token is refused" "$GOODHUB" "HEIMDALL_FLEET_TOKEN='$TOKEN'"
denv_refused "an export-prefixed token is refused" "$GOODHUB" "export HEIMDALL_FLEET_TOKEN=$TOKEN"
denv_refused "an export-prefixed hub URL is refused" "export $GOODHUB" "$GOODTOK"
denv_refused "whitespace around the token key is refused" "$GOODHUB" "HEIMDALL_FLEET_TOKEN = $TOKEN"
denv_refused "an indented token line is refused" "$GOODHUB" "  $GOODTOK"
denv_refused "trailing whitespace in the token is refused" "$GOODHUB" "$GOODTOK "
denv_refused "a CR in the token is refused" "$GOODHUB" "$GOODTOK"$'\r'
denv_refused "a token outside the b64token grammar is refused" "$GOODHUB" "HEIMDALL_FLEET_TOKEN=${TOKEN}\$x"
denv_refused "a token with an embedded space is refused" "$GOODHUB" "HEIMDALL_FLEET_TOKEN=${TOKEN} more"
denv_refused "a hub URL that is not http(s) is refused" "HEIMDALL_HUB_URL=ftp://heimdall.invalid/p" "$GOODTOK"
denv_refused "a hub URL with a quote is refused" "HEIMDALL_HUB_URL=\"$HUB\"" "$GOODTOK"
denv_refused "a hub URL with a space is refused" "HEIMDALL_HUB_URL=$HUB extra" "$GOODTOK"
write_denv "$GOODHUB" "$GOODTOK"; chmod 640 "$DENV"; run --verify RAWDENV=1
check "delivery env: a group-readable file is refused" '[ "$RC" = 2 ] && [ ! -f "$MOCK_REQUEST_FILE" ] && no_token'
write_denv "$GOODHUB" "$GOODTOK"; mv "$DENV" "$TMP/delivery.real"; ln -s "$TMP/delivery.real" "$DENV"; run --verify RAWDENV=1
check "delivery env: a symlink is refused" '[ "$RC" = 2 ] && [[ "$OUT" == *"non-symlink"* ]] && [ ! -f "$MOCK_REQUEST_FILE" ] && no_token'
rm -f "$DENV" "$TMP/delivery.real"; run --verify RAWDENV=1
check "delivery env: a missing file is refused" '[ "$RC" = 2 ] && [ ! -f "$MOCK_REQUEST_FILE" ]'
mkdir -p "$TMP/.config/brokkr"
printf '%s\n' "$GOODHUB" "$GOODTOK" >"$TMP/.config/brokkr/env"; chmod 600 "$TMP/.config/brokkr/env"
rm -f "$MOCK_REQUEST_FILE" "$SNAP"; : >"$MOCK_SHA_CALLS"
cmd RAWDENV=1 NODENV=1 -- --config "$CONF" --verify --delivery-env "$TMP/.config/brokkr/env"
check "delivery env: the usual ~/.config/brokkr/env location (a hidden directory) is accepted" '[ "$RC" = 0 ] && [ "$(panel)" = "archive-nearsite-nas-host pass" ]'
rm -rf "$TMP/.config"
write_denv "# comment" "" "UNRELATED=1" "$GOODHUB" "HEIMDALL_FLEET_TOKEN_EXTRA=ignored" "$GOODTOK" "export OTHER=2" "PATH=/evil"
run --verify RAWDENV=1
check "delivery env: comments, blank lines and every other key are ignored" '[ "$RC" = 0 ] && [ "$(panel)" = "archive-nearsite-nas-host pass" ]'
write_denv "$GOODHUB" "HEIMDALL_FLEET_TOKEN=Abc._~+/-xyz0123=="
run --validate RAWDENV=1
check "delivery env: the full b64token alphabet is accepted (validate checks the same parser)" '[ "$RC" = 0 ]'
write_denv "$GOODHUB" "HEIMDALL_FLEET_TOKEN=$TOKEN$TOKEN"; chmod 640 "$DENV"; run --validate RAWDENV=1
check "delivery env: validate refuses a group-readable file too, still delivering nothing" '[ "$RC" = 2 ] && [ ! -f "$MOCK_REQUEST_FILE" ]'
verify MOCK_HTTP_FAIL=1
check "failed Heimdall delivery exits 2 and keeps the snapshot" '[ "$RC" = 2 ] && [[ "$OUT" == *"Heimdall delivery failed"* ]] && [ -f "$SNAP" ] && no_token'
printf '%s  forged\n' "$H" >>"$MAN"
verify MOCK_HTTP_FAIL=1
check "a failing result plus failed delivery exits 2, not 1" '[ "$RC" = 2 ]'
cp "$TMP/manifest.good" "$MAN"

# --- --validate ------------------------------------------------------------------------------------------------
rm -rf "$TMP/state"
run --validate
check "validate passes and writes no state, delivery, or hash run" '[ "$RC" = 0 ] && [[ "$OUT" == *"4 manifest entries"* ]] && [ ! -e "$TMP/state" ] && [ ! -f "$MOCK_REQUEST_FILE" ] && no_hash_run'
cmd NODENV=1 -- --config "$CONF" --validate
check "validate needs no delivery env" '[ "$RC" = 0 ]'
printf 'x' >>"$MAN"
run --validate
check "validate fails on a manifest that does not match the pin (exit 2, no hashing)" '[ "$RC" = 2 ] && [[ "$OUT" == *"does not match the pinned value"* ]] && no_hash_run'
cp "$TMP/manifest.good" "$MAN"
mv "$NAS" "$TMP/nas.away"
run --validate
check "validate fails on a missing near-site directory" '[ "$RC" = 2 ]'
mv "$TMP/nas.away" "$NAS"
run --validate
check "validate output holds no file names or token" 'no_names && no_token'
check "validate leaves no scratch directory behind" '[ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]'

# --- hardening: tracing, startup files, stdin, the staged copy, exit codes -------------------------------
# The unit starts the verifier with `env -i` and hands it the delivery env as a file, so
# nothing the shared env file sets can reach it (an allowlist, not a list of bad names). The
# script still switches off tracing and BASH_ENV/ENV itself as cheap defence for manual runs.
cp "$TMP/manifest.good" "$MAN"; write_conf
write_denv "$GOODHUB" "$GOODTOK"
# An exported SHELLOPTS reaches every child bash with the script's own options (errexit,
# nounset), which breaks interpreter version-manager shims; use the real interpreter here.
mkdir -p "$TMP/realpy"
ln -s "$(python3 -I -c 'import sys; print(sys.executable)')" "$TMP/realpy/python3"
raw_run() { # extra env assignment for env(1); captures OUT and RC like cmd
  rm -f "$MOCK_REQUEST_FILE" "$SNAP"; : >"$MOCK_SHA_CALLS"
  OUT=$(env "$1" PATH="$TMP/realpy:$TMP/gnu:$PATH" PYTHONPATH="$TMP/python" \
    bash "$SCRIPT" --verify --config "$CONF" --delivery-env "$DENV" 2>&1 </dev/null) && RC=0 || RC=$?
  printf '%s' "$OUT" >"$OUTFILE"
}
raw_run SHELLOPTS=xtrace
check "SHELLOPTS=xtrace in the environment never traces the token (script and push.sh)" '[ "$RC" = 0 ] && no_token && [ "$(panel)" = "archive-nearsite-nas-host pass" ]'
printf 'echo ran >>"%s"\n' "$TMP/bashenv-count" >"$TMP/bashenv.sh"
rm -f "$TMP/bashenv-count"
raw_run BASH_ENV="$TMP/bashenv.sh"
check "BASH_ENV is not inherited by the child bash processes the script starts" '[ "$RC" = 0 ] && [ "$(wc -l <"$TMP/bashenv-count" | tr -d " ")" = 1 ]'
rm -f "$MOCK_REQUEST_FILE" "$SNAP"; : >"$MOCK_SHA_CALLS"
printf 'caller-stdin' | env PATH="$TMP/gnu:$PATH" PYTHONPATH="$TMP/python" \
  bash "$SCRIPT" --verify --config "$CONF" --delivery-env "$DENV" >"$OUTFILE" 2>&1
RC=$?
check "the hash run reads /dev/null, never the caller's stdin" '[ "$RC" = 0 ] && grep -qx "stdin_bytes=0" "$MOCK_SHA_CALLS"'
verify MOCK_SWAP_MANIFEST="$MAN"
check "a manifest changed after the pin check does not reach the hash run (staged copy consumed)" \
  '[ "$RC" = 0 ] && [[ "$(row manifest)" == "pass "* ]] && grep -Eq "^sha256sum --check --quiet --strict .*/\.archive-nearsite\.[^/]+/manifest$" "$MOCK_SHA_CALLS" && [ "$(wc -c <"$MAN" | tr -d " ")" -gt "$(wc -c <"$TMP/manifest.good" | tr -d " ")" ]'
cp "$TMP/manifest.good" "$MAN"
verify TMPDIR="$TMP/no-such-tmp"
check "an unusable TMPDIR does not matter: everything is written under the state directory" '[ "$RC" = 0 ] && [ ! -e "$TMP/no-such-tmp" ]'

# Exit 1 is reserved for "delivered, with a failing row": setup failures and interruption are 2.
: >"$TMP/afile"
verify BROKKR_STATE_DIR="$TMP/afile/state"
check "an unusable state directory exits 2, not 1" '[ "$RC" = 2 ] && [ ! -f "$MOCK_REQUEST_FILE" ]'
if command -v flock >/dev/null 2>&1; then
  mkdir -p "$TMP/lockstate/archive-nearsite.lock"
  verify BROKKR_STATE_DIR="$TMP/lockstate"
  check "an unusable lock file exits 2, not 1" '[ "$RC" = 2 ] && [ ! -f "$MOCK_REQUEST_FILE" ]'
else
  echo "skip - flock not installed; lock-file failure not exercised"
fi
rm -f "$MOCK_REQUEST_FILE" "$SNAP"; : >"$MOCK_SHA_CALLS"
(
  export PATH="$TMP/gnu:$PATH" PYTHONPATH="$TMP/python" MOCK_SHA_SLEEP=3
  exec bash "$SCRIPT" --verify --config "$CONF" --delivery-env "$DENV" >"$OUTFILE" 2>&1 </dev/null
) &
pid=$!
for _ in $(seq 1 100); do grep -q 'sha256sum --check' "$MOCK_SHA_CALLS" && break; sleep 0.1; done
kill -TERM "$pid"
wait "$pid"; RC=$?
OUT=$(cat "$OUTFILE")
check "a signal before delivery exits 2 and delivers nothing" '[ "$RC" = 2 ] && [ ! -f "$MOCK_REQUEST_FILE" ] && [ -z "$(find "$TMP/state" -name ".archive-nearsite.*")" ]'

# --- the unit's clean environment: only the two delivery values reach push.sh -----------------------------
# A release-shaped tree whose push.sh is a fake that records variable NAMES (never values) and
# whether the credential matches, so an injected variable would show up by name.
REL="$TMP/rel"; mkdir -p "$REL/scripts" "$REL/heimdall"
cp "$SCRIPT" "$REL/scripts/archive-nearsite.sh"
printf '%s' "$TOKEN" >"$TMP/expected-token"
cat >"$REL/heimdall/push.sh" <<FAKE
#!/usr/bin/env bash
compgen -e | LC_ALL=C sort >"$TMP/push-names"
printf 'path=%s\nhome=%s\nhub_ok=%s\ntoken_ok=%s\n' "\$PATH" "\$HOME" \\
  "\$([ "\${HEIMDALL_HUB_URL:-}" = "$HUB" ] && echo 1 || echo 0)" \\
  "\$([ "\${HEIMDALL_FLEET_TOKEN:-}" = "\$(cat "$TMP/expected-token")" ] && echo 1 || echo 0)" >"$TMP/push-info"
exit 0
FAKE
chmod 755 "$REL/heimdall/push.sh"
write_conf "ARCHIVE_NODE=nas-host"
write_denv "$GOODHUB" "$GOODTOK" "LD_AUDIT=/evil.so" "LD_PRELOAD=/evil.so" "LD_LIBRARY_PATH=/evil" "PYTHONUSERBASE=/evil" \
  "PYTHONPATH=/evil" "PYTHONSTARTUP=/evil.py" "BASH_ENV=/evil.sh" "ENV=/evil.sh" "SHELLOPTS=xtrace" "BASHOPTS=extdebug" \
  "PS4=evil" 'BASH_FUNC_x%%=() { echo evil; }' "PATH=/evil" "HOME=/evil" "TMPDIR=/evil" "BROKKR_STATE_DIR=/evil" "ARCHIVE_NODE=evil"
UNIT_PATH="$TMP/realpy:$TMP/gnu:/usr/local/bin:/usr/bin:/bin"
rm -f "$TMP/push-names" "$TMP/push-info"
OUT=$(env -i HOME="$HOME" PATH="$UNIT_PATH" LANG=C.UTF-8 \
  bash "$REL/scripts/archive-nearsite.sh" --config "$CONF" --delivery-env "$DENV" --verify 2>&1 </dev/null) && RC=0 || RC=$?
printf '%s' "$OUT" >"$OUTFILE"
check "env -i start: delivered despite a hostile delivery env" '[ "$RC" = 0 ] && [ -s "$TMP/push-names" ]'
check "env -i start: push.sh gets exactly the credential and the hub URL, intact" 'grep -qx "hub_ok=1" "$TMP/push-info" && grep -qx "token_ok=1" "$TMP/push-info" && grep -qx HEIMDALL_HUB_URL "$TMP/push-names" && grep -qx HEIMDALL_FLEET_TOKEN "$TMP/push-names"'
for var in LD_AUDIT LD_PRELOAD LD_LIBRARY_PATH PYTHONUSERBASE PYTHONPATH PYTHONSTARTUP BASH_ENV ENV SHELLOPTS BASHOPTS PS4 TMPDIR; do
  check "env -i start: $var from the delivery env never reaches push.sh" '! grep -qx "$var" "$TMP/push-names"'
done
check "env -i start: no exported bash function (BASH_FUNC_*) reaches push.sh" '! grep -q "^BASH_FUNC_" "$TMP/push-names"'
check "env -i start: PATH and HOME overrides in the delivery env are ignored" 'grep -qx "path=$UNIT_PATH" "$TMP/push-info" && grep -qx "home=$HOME" "$TMP/push-info" && ! grep -q "/evil" "$TMP/push-info"'
check "env -i start: BROKKR_STATE_DIR from the delivery env is ignored (snapshot under HOME)" '[ -f "$HOME/.local/state/brokkr/archive-nearsite.json" ] && [ ! -e /evil ]'
check "env -i start: no sentinel substring in the output" 'no_token'
write_conf; write_denv "$GOODHUB" "$GOODTOK"

# --- cleanup failures are explicit: exit 2, never a silently changed result ---------------------------------
drop_work() { find "$TMP/state" -name '.archive-nearsite.*' -type d -exec /bin/rm -rf {} + 2>/dev/null; return 0; }
verify MOCK_RM_FAIL=1
check "a cleanup failure after a delivered pass exits 2 (not 1), result still delivered" '[ "$RC" = 2 ] && [ "$(panel)" = "archive-nearsite-nas-host pass" ] && [[ "$OUT" == *"work directory"* ]]'
drop_work
printf '%s  forged\n' "$H" >>"$MAN"
verify MOCK_RM_FAIL=1
check "a cleanup failure after a delivered failing row exits 2 (not 1), result still delivered" '[ "$RC" = 2 ] && [ "$(panel)" = "archive-nearsite-nas-host fail" ] && [[ "$OUT" == *"work directory"* ]]'
drop_work
verify MOCK_RM_FAIL=1 MOCK_HTTP_FAIL=1
check "a cleanup failure after a delivery failure exits 2 (not 1)" '[ "$RC" = 2 ] && [[ "$OUT" == *"Heimdall delivery failed"* ]]'
drop_work
cp "$TMP/manifest.good" "$MAN"
verify
check "without a cleanup failure the same runs keep their codes (pass 0)" '[ "$RC" = 0 ]'

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
