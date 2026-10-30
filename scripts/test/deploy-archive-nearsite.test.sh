#!/usr/bin/env bash
# Hermetic gates for scripts/deploy-archive-nearsite.sh. ssh, sha256sum, systemctl,
# loginctl, journalctl, and id are fakes on PATH; the "remote" is a temp HOME on this
# machine. The real archive-nearsite.sh --validate runs against a tiny fixture copy and a
# pinned manifest. No real host, network, or credential is touched.
# shellcheck disable=SC2016,SC2034 # assertions are evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/test/lib/fixture-cleanup.sh
source "$HERE/lib/fixture-cleanup.sh"
TMP="$(fixture_cleanup_alloc)" || { echo "not ok - cannot allocate a test fixture" >&2; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "not ok - fixture allocation returned no directory" >&2; exit 1; }
trap 'fixture_cleanup_on_exit "$TMP"' EXIT
# The deploy entry path must contain no symlinks (macOS /var is one).
TMP="$(cd "$TMP" && pwd -P)" && [ -n "$TMP" ] || { echo "not ok - cannot resolve the fixture path" >&2; exit 1; }

REPO="$TMP/repo"; HOME_DIR="$TMP/home"; BIN="$TMP/bin"; CALLS="$TMP/calls"
PYBIN="$TMP/pybin"
mkdir -p "$REPO/scripts/lib" "$REPO/heimdall" "$REPO/systemd/user" \
  "$HOME_DIR/.config/brokkr" "$BIN" "$PYBIN" "$TMP/payload-tmp"
cp "$ROOT/scripts/deploy-archive-nearsite.sh" "$ROOT/scripts/archive-nearsite.sh" "$REPO/scripts/" 2>/dev/null
cp "$ROOT/scripts/lib/deploy-source.sh" "$REPO/scripts/lib/"
cp "$ROOT/heimdall/push.sh" "$REPO/heimdall/"
cp "$ROOT/systemd/user/"brokkr-archive-nearsite.* "$REPO/systemd/user/"
echo "unrelated file that must never ship" > "$REPO/README.md"
git init -q "$REPO"; git -C "$REPO" config user.name test; git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add . ; git -C "$REPO" commit -qm fixture
SHA="$(git -C "$REPO" rev-parse HEAD)"
DEPLOY="$REPO/scripts/deploy-archive-nearsite.sh"

# The remote PATH sees python3 only through a wrapper.
# The preflight runs python3 under `env -i` like the unit does, so the wrapper must point at
# the real interpreter, not at a version-manager shim that needs the caller's environment.
REAL_PYTHON="$(python3 -I -c 'import sys; print(sys.executable)')"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PYTHON" >"$PYBIN/python3"
chmod 755 "$PYBIN/python3"

: >"$CALLS"
cat >"$BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
# usage: ssh [-o opt]... TARGET COMMAND
while [[ "${1:-}" == -o ]]; do shift 2; done
target=$1; shift
printf 'ssh %s\n' "$target" >>"$MOCK_CALLS"
[[ "$#" -eq 1 ]] || exit 64
exec env -u XDG_CONFIG_HOME HOME="$MOCK_REMOTE_HOME" PATH="$MOCK_REMOTE_PATH" bash -c "$1"
FAKE
cat >"$BIN/id" <<'FAKE'
#!/usr/bin/env bash
if [[ "${MOCK_ID_ROOT:-0}" == 1 ]]; then
  case "${1:-}" in -u) echo 0; exit 0 ;; -un) echo root; exit 0 ;; esac
fi
exec /usr/bin/id "$@"
FAKE
cat >"$BIN/loginctl" <<'FAKE'
#!/usr/bin/env bash
printf 'loginctl %s\n' "$*" >>"$MOCK_CALLS"
printf 'Linger=%s\n' "${MOCK_LINGER:-yes}"
FAKE
cat >"$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_CALLS"
# State queries answer like systemd for a previously installed timer (default: absent).
case "$2" in
  is-enabled) echo "${MOCK_TIMER_ENABLED:-not-found}"; [ "${MOCK_TIMER_ENABLED:-}" = enabled ] ;;
  is-active) echo "${MOCK_TIMER_ACTIVE:-inactive}"; [ "${MOCK_TIMER_ACTIVE:-}" = active ] ;;
  *) exit 0 ;;
esac
FAKE
cat >"$BIN/journalctl" <<'FAKE'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*" >>"$MOCK_CALLS"
FAKE
# Fault injection: cp/mv fail when the destination matches, tar fails to extract on stdin.
cat >"$BIN/cp" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${MOCK_CP_FAIL:-}" && "${!#}" == *"$MOCK_CP_FAIL"* ]]; then echo "cp: injected failure" >&2; exit 1; fi
exec /bin/cp "$@"
FAKE
cat >"$BIN/mv" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${MOCK_MV_FAIL:-}" && "${!#}" == *"$MOCK_MV_FAIL"* ]]; then echo "mv: injected failure" >&2; exit 1; fi
exec /bin/mv "$@"
FAKE
cat >"$BIN/tar" <<'FAKE'
#!/usr/bin/env bash
if [[ "${MOCK_TAR_FAIL:-0}" == 1 && "${1:-}" == -xf && "${2:-}" == - ]]; then echo "tar: injected extraction failure" >&2; exit 2; fi
exec /usr/bin/tar "$@"
FAKE
chmod 755 "$BIN/"*

# Fake sha256sum: only the version banner is answered (the deploy preflight needs GNU,
# --validate hashes with python). Any other call is recorded so a hash run is provable.
# It runs under `env -i` like the unit, so the log and banner file paths are baked in
# rather than read from the environment.
cat >"$BIN/sha256sum" <<FAKE
#!/usr/bin/env bash
printf 'sha256sum %s\n' "\$*" >>"$CALLS"
if [[ "\${1:-}" == --version ]]; then
  if [[ -f "$TMP/sha-banner" ]]; then cat "$TMP/sha-banner"; else echo "sha256sum (GNU coreutils) 9.4"; fi
  exit 0
fi
echo "fake sha256sum: unexpected invocation" >&2; exit 99
FAKE
chmod 755 "$BIN/sha256sum"

export MOCK_CALLS="$CALLS" MOCK_BIN="$BIN" MOCK_REMOTE_HOME="$HOME_DIR"
mkdir -p "$TMP/sysbin"
for tool in /bin/* /usr/bin/*; do
  name=${tool##*/}
  [[ "$name" != sha256sum && -x "$tool" && ! -e "$TMP/sysbin/$name" ]] || continue
  ln -s "$tool" "$TMP/sysbin/$name"
done
# Same tools without any python or sha256sum: stands in for a node whose unit PATH lacks them.
mkdir -p "$TMP/nopy"
for tool in "$TMP"/sysbin/*; do
  name=${tool##*/}
  case "$name" in python*|sha256sum) continue ;; esac
  ln -s "$tool" "$TMP/nopy/$name"
done
export MOCK_REMOTE_PATH="$BIN:$PYBIN:$TMP/sysbin"
# The unit's own PATH (env -i PATH=...) is the production default; the hermetic fixture's
# fakes live elsewhere, so the test points the unit PATH at the same fake directories.
export BROKKR_ARCHIVE_NEARSITE_UNIT_PATH="$MOCK_REMOTE_PATH"
export PATH="$BIN:$PATH" TMPDIR="$TMP/payload-tmp"
# The fixture itself may live under /tmp (Linux CI); PrivateTmp roots are set per case.
export BROKKR_ARCHIVE_NEARSITE_PRIVATE_TMP_ROOTS=/nonexistent-private-tmp
unset XDG_CONFIG_HOME
export BROKKR_EXPECTED_SOURCE="$REPO" BROKKR_EXPECTED_COMMIT="$SHA"

DELIVERY_ENV="$HOME_DIR/.config/brokkr/heimdall.env"
CONFIG="$HOME_DIR/.config/brokkr/archive-nearsite.conf"
export BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV="$DELIVERY_ENV"
unset BROKKR_ARCHIVE_NEARSITE_CONFIG
TARGET=operator@node-a.example.invalid
UNIT_DIR="$HOME_DIR/.config/systemd/user"
RELEASE="$HOME_DIR/.local/lib/brokkr/archive-nearsite/releases/$SHA"
SERVICE="$UNIT_DIR/brokkr-archive-nearsite.service"
TIMER="$UNIT_DIR/brokkr-archive-nearsite.timer"
HEAD_ENV='HEIMDALL_HUB_URL=https://heimdall.example.invalid/api/panels\nHEIMDALL_FLEET_TOKEN=secret-sentinel\n'

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; printf '        rc=%s out=%s\n' "${RC:-}" "${OUT:-}" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() { OUT="$(cd "$REPO" && bash "$DEPLOY" "$@" 2>&1)"; RC=$?; }
line_of() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
tree_state() { { find "$HOME_DIR" | sort; find "$HOME_DIR" -type f -exec cksum {} + | sort; } | cksum; }
pin_of() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
write_manifest() { # real digests of the two fixture files, then the pin of that manifest
  python3 -I - "$HOME_DIR/archive" "$HOME_DIR/archive.sha256" <<'PY'
import hashlib, os, sys
src, out = sys.argv[1:]
lines = sorted(hashlib.sha256(open(os.path.join(src, n), "rb").read()).hexdigest() + "  " + n + "\n" for n in os.listdir(src))
open(out, "w").write("".join(lines))
PY
}
write_config() { # extra lines
  printf '# fixture\nARCHIVE_NEARSITE_DIR=%s\nARCHIVE_NEARSITE_MANIFEST=%s\nARCHIVE_NEARSITE_MANIFEST_SHA256=%s\n' \
    "$HOME_DIR/archive" "$HOME_DIR/archive.sha256" "$(pin_of "$HOME_DIR/archive.sha256")" >"$CONFIG"
  printf '%s\n' "$@" >>"$CONFIG"
  chmod 600 "$CONFIG"
}
good_inputs() {
  printf '%b' "$HEAD_ENV" >"$DELIVERY_ENV"
  mkdir -p "$HOME_DIR/archive"
  printf 'one\n' >"$HOME_DIR/archive/a.txt"; printf 'two\n' >"$HOME_DIR/archive/b.txt"
  write_manifest
  write_config
  chmod 600 "$DELIVERY_ENV"
}
reset() {
  rm -rf "$HOME_DIR/.local" "$HOME_DIR/.config/systemd" "$HOME_DIR/.config/brokkr/other"
  rm -f "$DELIVERY_ENV" "$CONFIG"
  : >"$CALLS"
  rm -f "$TMP/sha-banner"; unset MOCK_ID_ROOT MOCK_LINGER MOCK_CP_FAIL MOCK_MV_FAIL MOCK_TAR_FAIL
  export BROKKR_EXPECTED_COMMIT="$SHA" BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV="$DELIVERY_ENV"
  unset BROKKR_ARCHIVE_NEARSITE_CONFIG
  good_inputs
}
# Staging under the release root is allowed to leave the (empty) directory skeleton.
no_release_or_units() { [[ ! -e "$RELEASE" && ! -e "$UNIT_DIR" && -z "$(find "$HOME_DIR/.local/lib" -name '.stage.*' 2>/dev/null)" ]]; }
# No remote state, units, or systemd mutation happened.
no_mutation() { [[ ! -e "$HOME_DIR/.local" && ! -e "$HOME_DIR/.config/systemd" ]] && ! grep -Eq '^systemctl' "$CALLS"; }
# The only sha256sum call ever made is the version banner: nothing is hashed by the deploy.
only_version_probe() { [[ -z "$(grep '^sha256sum ' "$CALLS" | grep -v '^sha256sum --version$')" ]]; }

echo "deploy-archive-nearsite.test.sh"
reset

# --- local gates: nothing reaches ssh ---------------------------------------------------
unset BROKKR_EXPECTED_COMMIT
run "$TARGET"
check "missing expected commit refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_EXPECTED_SOURCE and BROKKR_EXPECTED_COMMIT"* ]] && ! grep -q ssh "$CALLS"'
reset
export BROKKR_EXPECTED_COMMIT=0000000000000000000000000000000000000000
run "$TARGET"
check "wrong expected commit refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"revision does not match"* ]] && ! grep -q ssh "$CALLS"'
export BROKKR_EXPECTED_COMMIT="${SHA:0:12}"
run "$TARGET"
check "short expected commit refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"full commit SHA"* ]] && ! grep -q ssh "$CALLS"'
reset
ln -s "$DEPLOY" "$REPO/scripts/deploy-via-link.sh"
OUT="$(cd "$REPO" && bash "$REPO/scripts/deploy-via-link.sh" "$TARGET" 2>&1)"; RC=$?
check "symlinked entry script refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"must not contain symlinks"* ]] && ! grep -q ssh "$CALLS"'
rm -f "$REPO/scripts/deploy-via-link.sh"
unset BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV
run "$TARGET"
check "missing delivery env parameter refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV is required"* ]] && ! grep -q ssh "$CALLS"'
reset
BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV="relative/heimdall.env" run "$TARGET"
check "relative delivery env path refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"invalid BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV"* ]] && ! grep -q ssh "$CALLS"'
BROKKR_ARCHIVE_NEARSITE_CONFIG="/unsafe path/x.conf" run "$TARGET"
check "unsafe config path refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"invalid BROKKR_ARCHIVE_NEARSITE_CONFIG"* ]] && ! grep -q ssh "$CALLS"'
run
check "missing ssh target refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *usage* ]] && ! grep -q ssh "$CALLS"'
run 'bad;target'
check "invalid ssh target refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"invalid SSH target"* ]] && ! grep -q ssh "$CALLS"'
run -oProxyCommand=evil
check "option-shaped ssh target refuses before ssh" '[[ "$RC" -ne 0 ]] && ! grep -q ssh "$CALLS"'
run "$TARGET" --bogus
check "unknown option refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *usage* ]] && ! grep -q ssh "$CALLS"'

# --- dry-run: preflight only --------------------------------------------------------------
reset
before="$(tree_state)"
run "$TARGET"
check "dry-run succeeds with valid inputs" '[[ "$RC" -eq 0 && "$OUT" == *DRY-RUN* ]]'
check "dry-run mutates nothing on the remote" '[[ "$(tree_state)" == "$before" ]] && no_mutation'
check "dry-run reports the release target without creating it" '[[ "$OUT" == *"releases/$SHA"* && ! -e "$RELEASE" ]]'
check "dry-run validated through ssh" 'grep -q "^ssh $TARGET" "$CALLS" && grep -q "^loginctl" "$CALLS"'
check "dry-run reports the shipped verifier's verdict on the pinned manifest" '[[ "$OUT" == *"preflight: validated: 2 manifest entries"* ]]'
check "dry-run states what --apply would do and that nothing changed" '[[ "$OUT" == *"--apply would stage the payload"* && "$OUT" == *"Nothing was changed"* ]]'
check "dry-run hashes nothing (only the sha256sum version probe)" 'only_version_probe && grep -q "^sha256sum --version$" "$CALLS"'
check "dry-run never prints delivery env values" '[[ "$OUT" != *secret-sentinel* && "$OUT" != *heimdall.example.invalid* ]]'
check "dry-run never writes the delivery env or the config" '[[ "$(cat "$DELIVERY_ENV")" == "$(printf "%b" "$HEAD_ENV")" ]]'
check "dry-run payload parent and validator scratch are cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'

# --- preflight refusals (both modes) --------------------------------------------------------
refuses() { # name expected-text [args...]
  local name=$1 text=$2; shift 2
  run "$@"
  check "$name (dry-run)" '[[ "$RC" -ne 0 && "$OUT" == *"$text"* ]] && no_mutation && [[ "$OUT" != *secret-sentinel* ]]'
  : >"$CALLS"
  run "$@" --apply
  check "$name (--apply)" '[[ "$RC" -ne 0 && "$OUT" == *"$text"* ]] && no_mutation && [[ "$OUT" != *secret-sentinel* ]]'
}
reset; rm -f "$DELIVERY_ENV"
refuses "missing delivery env refuses" "delivery env" "$TARGET"
reset; rm -f "$DELIVERY_ENV"; printf 'x\n' >"$HOME_DIR/.config/brokkr/other"; ln -s "$HOME_DIR/.config/brokkr/other" "$DELIVERY_ENV"
refuses "symlinked delivery env refuses" "delivery env" "$TARGET"
reset; chmod 644 "$DELIVERY_ENV"
refuses "delivery env with mode 644 refuses" "delivery env" "$TARGET"
reset; chmod 400 "$DELIVERY_ENV"
refuses "mode-400 delivery env refuses (exactly 600 required)" "delivery env" "$TARGET"
reset; printf 'HEIMDALL_HUB_URL=https://heimdall.example.invalid/api/panels\n' >"$DELIVERY_ENV"
refuses "delivery env without a token refuses" "HEIMDALL_FLEET_TOKEN" "$TARGET"
reset; printf 'HEIMDALL_FLEET_TOKEN=secret-sentinel\n' >"$DELIVERY_ENV"
refuses "delivery env without a hub URL refuses" "HEIMDALL_HUB_URL" "$TARGET"
reset; printf 'HEIMDALL_HUB_URL=\nHEIMDALL_FLEET_TOKEN=secret-sentinel\n' >"$DELIVERY_ENV"
refuses "delivery env with an empty URL refuses" "HEIMDALL_HUB_URL" "$TARGET"
reset; printf 'HEIMDALL_HUB_URL=https://heimdall.example.invalid/api/panels\nHEIMDALL_FLEET_TOKEN=""\n' >"$DELIVERY_ENV"
refuses "delivery env with a quoted-empty token refuses" "HEIMDALL_FLEET_TOKEN" "$TARGET"
reset; rm -f "$CONFIG"
refuses "missing near-site config refuses" "near-site config" "$TARGET"
reset; chmod 644 "$CONFIG"
refuses "world-readable near-site config refuses" "near-site config" "$TARGET"
reset; chmod 400 "$CONFIG"
refuses "mode-400 near-site config refuses (exactly 600 required)" "near-site config" "$TARGET"
reset; rm -f "$CONFIG"; printf 'x\n' >"$HOME_DIR/.config/brokkr/other"; ln -s "$HOME_DIR/.config/brokkr/other" "$CONFIG"
refuses "symlinked near-site config refuses" "near-site config" "$TARGET"
reset; write_config "ARCHIVE_NEARSITE=off"
refuses "near-site config with an unknown key refuses (shipped parser)" "rejected by the shipped verifier" "$TARGET"
reset; write_config "SURPRISE=1"
refuses "near-site config rejected by the shipped parser refuses" "rejected by the shipped verifier" "$TARGET"
reset; printf 'ARCHIVE_NEARSITE_DIR=/var/tmp/copy\nARCHIVE_NEARSITE_MANIFEST=%s\nARCHIVE_NEARSITE_MANIFEST_SHA256=%s\n' "$HOME_DIR/archive.sha256" "$(pin_of "$HOME_DIR/archive.sha256")" >"$CONFIG"
BROKKR_ARCHIVE_NEARSITE_PRIVATE_TMP_ROOTS=/var/tmp refuses "a near-site directory under a PrivateTmp-hidden directory refuses" "ARCHIVE_NEARSITE_DIR is under a temporary directory that PrivateTmp hides" "$TARGET"
reset
reset; mkdir -p "$HOME_DIR/tmpish"; mv "$DELIVERY_ENV" "$HOME_DIR/tmpish/env"
BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV="$HOME_DIR/tmpish/env" BROKKR_ARCHIVE_NEARSITE_PRIVATE_TMP_ROOTS="$HOME_DIR/tmpish" refuses "a delivery env under a PrivateTmp-hidden directory refuses" "delivery env is under a temporary directory that PrivateTmp hides" "$TARGET"
BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV="$HOME_DIR/tmpish/env" BROKKR_ARCHIVE_NEARSITE_PRIVATE_TMP_ROOTS="/nonexistent-a $HOME_DIR/tmpish" refuses "a delivery env under any of several PrivateTmp roots refuses" "delivery env is under a temporary directory that PrivateTmp hides" "$TARGET"
BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV="$HOME_DIR/tmpish/env" run "$TARGET"
check "the same delivery env outside every PrivateTmp root is accepted" '[[ "$RC" -eq 0 ]]'
rm -rf "$HOME_DIR/tmpish"
reset
BROKKR_ARCHIVE_NEARSITE_PRIVATE_TMP_ROOTS="$HOME_DIR/.config" refuses "a config under a PrivateTmp-hidden directory refuses" "near-site config is under a temporary directory that PrivateTmp hides" "$TARGET"
# A parent directory that is a symlink into a PrivateTmp root hides the file from the unit
# although its lexical path does not: compare the resolved physical path too.
HIDDEN="$HOME_DIR/hiddenroot"
symlinked_inputs() { # moves the inputs under a hidden root, reachable only through $HOME_DIR/linkd
  rm -rf "$HIDDEN" "$HOME_DIR/linkd"; mkdir -p "$HIDDEN/d"; ln -s "$HIDDEN/d" "$HOME_DIR/linkd"
}
drop_symlinked_inputs() { rm -rf "$HIDDEN" "$HOME_DIR/linkd"; }
reset; symlinked_inputs; mv "$DELIVERY_ENV" "$HIDDEN/d/env"
BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV="$HOME_DIR/linkd/env" BROKKR_ARCHIVE_NEARSITE_PRIVATE_TMP_ROOTS="$HIDDEN" refuses "a delivery env reached through a symlinked parent into a PrivateTmp root refuses" "delivery env is under a temporary directory that PrivateTmp hides" "$TARGET"
BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV="$HOME_DIR/linkd/env" run "$TARGET"
check "the same symlinked parent is fine when it does not lead into a PrivateTmp root" '[[ "$RC" -eq 0 ]]'
drop_symlinked_inputs
reset; symlinked_inputs; mv "$CONFIG" "$HIDDEN/d/near.conf"
BROKKR_ARCHIVE_NEARSITE_CONFIG="$HOME_DIR/linkd/near.conf" BROKKR_ARCHIVE_NEARSITE_PRIVATE_TMP_ROOTS="$HIDDEN" refuses "a config reached through a symlinked parent into a PrivateTmp root refuses" "near-site config is under a temporary directory that PrivateTmp hides" "$TARGET"
drop_symlinked_inputs
reset; symlinked_inputs; mv "$HOME_DIR/archive.sha256" "$HIDDEN/d/archive.sha256"
printf 'ARCHIVE_NEARSITE_DIR=%s\nARCHIVE_NEARSITE_MANIFEST=%s\nARCHIVE_NEARSITE_MANIFEST_SHA256=%s\n' "$HOME_DIR/archive" "$HOME_DIR/linkd/archive.sha256" "$(pin_of "$HIDDEN/d/archive.sha256")" >"$CONFIG"
BROKKR_ARCHIVE_NEARSITE_PRIVATE_TMP_ROOTS="$HIDDEN" refuses "a manifest reached through a symlinked parent into a PrivateTmp root refuses" "ARCHIVE_NEARSITE_MANIFEST is under a temporary directory that PrivateTmp hides" "$TARGET"
drop_symlinked_inputs
reset; symlinked_inputs; mv "$HOME_DIR/archive" "$HIDDEN/d/archive"
printf 'ARCHIVE_NEARSITE_DIR=%s\nARCHIVE_NEARSITE_MANIFEST=%s\nARCHIVE_NEARSITE_MANIFEST_SHA256=%s\n' "$HOME_DIR/linkd/archive" "$HOME_DIR/archive.sha256" "$(pin_of "$HOME_DIR/archive.sha256")" >"$CONFIG"
BROKKR_ARCHIVE_NEARSITE_PRIVATE_TMP_ROOTS="$HIDDEN" refuses "a near-site directory that is a symlink into a PrivateTmp root refuses" "ARCHIVE_NEARSITE_DIR is under a temporary directory that PrivateTmp hides" "$TARGET"
drop_symlinked_inputs

# The unit runs under `env -i PATH=...`, so the dependencies must exist on THAT path, not
# only on the ssh session's. The same prefix serves the probes, --validate and the unit.
reset
BROKKR_ARCHIVE_NEARSITE_UNIT_PATH="$PYBIN:$TMP/sysbin" refuses "a sha256sum present only on the ssh PATH (not the unit's) refuses" "sha256sum" "$TARGET"
reset
BROKKR_ARCHIVE_NEARSITE_UNIT_PATH="$BIN:$TMP/nopy" refuses "a python3 present only on the ssh PATH (not the unit's) refuses" "python3" "$TARGET"
reset
run "$TARGET" --apply
check "the unit's PATH and LANG come from the one definition the preflight probes with" 'grep -Fq "PATH=$MOCK_REMOTE_PATH LANG=C.UTF-8" "$SERVICE"'
check "the production default unit PATH is /usr/local/bin:/usr/bin:/bin (one definition, template placeholder)" 'grep -Fq ":-/usr/local/bin:/usr/bin:/bin}" "$DEPLOY" && grep -Fq "PATH=@UNIT_PATH@ LANG=@UNIT_LANG@" "$REPO/systemd/user/brokkr-archive-nearsite.service.in"'

reset; printf 'tampered\n' >>"$HOME_DIR/archive.sha256"
refuses "a manifest that does not match the pin refuses" "rejected by the shipped verifier" "$TARGET"
check "the pin mismatch is reported without the full hashes" '[[ "$OUT" == *"does not match the pinned value"* ]] && ! grep -qE "[0-9a-f]{64}" <<<"$OUT"'
reset; write_manifest; printf '%s\n' "$(pin_of "$HOME_DIR/archive.sha256")" >/dev/null; rm -rf "$HOME_DIR/archive"
refuses "a missing near-site directory refuses" "rejected by the shipped verifier" "$TARGET"
reset; export MOCK_ID_ROOT=1
refuses "root runtime user refuses" "must not be root" "$TARGET"
reset; export MOCK_LINGER=no
refuses "disabled user lingering refuses" "linger" "$TARGET"
reset; echo "sha256sum (Darwin) 1.0" >"$TMP/sha-banner"
refuses "a non-GNU sha256sum refuses" "GNU sha256sum is required" "$TARGET"
check "validate leaves no scratch state" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'
reset
mkdir -p "$RELEASE"; echo precious >"$RELEASE/marker"
refuses_release() { # an existing release must be refused without touching systemd or units
  run "$TARGET"
  check "existing release directory refuses (dry-run)" '[[ "$RC" -ne 0 && "$OUT" == *"release already exists"* && ! -e "$UNIT_DIR" ]] && ! grep -q "^systemctl" "$CALLS"'
  run "$TARGET" --apply
  check "existing release directory refuses (--apply)" '[[ "$RC" -ne 0 && "$OUT" == *"release already exists"* && ! -e "$UNIT_DIR" ]] && ! grep -q "^systemctl" "$CALLS"'
}
refuses_release
check "existing release directory is left untouched" '[[ "$(cat "$RELEASE/marker")" == precious && "$(find "$RELEASE" -type f | wc -l | tr -d " ")" -eq 1 ]]'

# --- the delivery env is an allowlist input: only its two Heimdall lines are used ------------
# The unit starts the verifier under env -i and reads the two lines itself, so there is no
# list of forbidden variables: extra keys are ignored, whatever they are, and the preflight
# runs the shipped parser (--validate --delivery-env) to prove the file's shape.
for extra in LD_AUDIT LD_PRELOAD PYTHONUSERBASE PYTHONPATH BASH_ENV SHELLOPTS PATH HOME ARCHIVE_NODE; do
  reset
  printf '%b%s=/tmp/redirect\n' "$HEAD_ENV" "$extra" >"$DELIVERY_ENV"
  run "$TARGET"
  check "a hostile $extra line in a shared delivery env is ignored, not an error (dry-run)" '[[ "$RC" -eq 0 && "$OUT" == *DRY-RUN* ]] && no_mutation'
done
reset
printf '%bBASH_FUNC_evil%%%%=() { :; }\n' "$HEAD_ENV" >"$DELIVERY_ENV"
run "$TARGET"
check "an exported-function line in a shared delivery env is ignored (dry-run)" '[[ "$RC" -eq 0 ]]'
reset
printf 'HEIMDALL_HUB_URL=https://heimdall.example.invalid/api/panels\nHEIMDALL_FLEET_TOKEN="secret-sentinel"\n' >"$DELIVERY_ENV"
refuses "a quoted token is rejected by the shipped parser" "rejected by the shipped verifier" "$TARGET"
reset
printf 'HEIMDALL_HUB_URL=https://heimdall.example.invalid/api/panels\nHEIMDALL_FLEET_TOKEN=secret-sentinel$x\n' >"$DELIVERY_ENV"
refuses "a token outside the b64token grammar is rejected by the shipped parser" "rejected by the shipped verifier" "$TARGET"
reset
printf 'HEIMDALL_HUB_URL="https://heimdall.example.invalid/api/panels"\nHEIMDALL_FLEET_TOKEN=secret-sentinel\n' >"$DELIVERY_ENV"
refuses "a quoted hub URL is rejected by the shipped parser" "rejected by the shipped verifier" "$TARGET"
reset
printf 'export HEIMDALL_HUB_URL=https://heimdall.example.invalid/api/panels\nHEIMDALL_FLEET_TOKEN=secret-sentinel\n' >"$DELIVERY_ENV"
refuses "an export-prefixed hub URL refuses" "HEIMDALL_HUB_URL" "$TARGET"
reset
printf '%bHEIMDALL_FLEET_TOKEN=other-secret\n' "$HEAD_ENV" >"$DELIVERY_ENV"
refuses "duplicate HEIMDALL_FLEET_TOKEN refuses" "exactly once" "$TARGET"
reset
printf '%bHEIMDALL_HUB_URL=https://other.example.invalid\n' "$HEAD_ENV" >"$DELIVERY_ENV"
refuses "duplicate HEIMDALL_HUB_URL refuses" "exactly once" "$TARGET"
reset
printf '%bBROKKR_TAILSCALE_KEY_EXPIRY_POLICY=monitored\nSOMETHING_ELSE=1\n' "$HEAD_ENV" >"$DELIVERY_ENV"
run "$TARGET" --apply
check "unrelated keys in a shared delivery env are accepted" '[[ "$RC" -eq 0 ]]'

# --- explicit archive config path and delivery env name ----------------------------------------
reset
mv "$CONFIG" "$HOME_DIR/.config/brokkr/custom.conf"
BROKKR_ARCHIVE_NEARSITE_CONFIG="$HOME_DIR/.config/brokkr/custom.conf" run "$TARGET"
check "explicit BROKKR_ARCHIVE_NEARSITE_CONFIG is validated instead of the default" '[[ "$RC" -eq 0 ]]'
rm -f "$HOME_DIR/.config/brokkr/custom.conf"
reset
mv "$DELIVERY_ENV" "$HOME_DIR/.config/brokkr/env"
BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV="$HOME_DIR/.config/brokkr/env" run "$TARGET" --apply
check "the delivery env path is a parameter (env instead of heimdall.env)" '[[ "$RC" -eq 0 ]] && grep -Fq -- "--delivery-env $HOME_DIR/.config/brokkr/env --verify" "$SERVICE"'
rm -f "$HOME_DIR/.config/brokkr/env"

# --- --apply: install --------------------------------------------------------------------------
reset
mkdir -p "$UNIT_DIR"; printf 'OLD SERVICE\n' >"$SERVICE"
# The archive node's verifier lives beside this one on a shared host in this fixture: it
# must come out of the deploy byte-identical.
VERIFY_UNIT="$UNIT_DIR/brokkr-archive-verify.service"; VERIFY_TIMER="$UNIT_DIR/brokkr-archive-verify.timer"
VERIFY_RELEASE="$HOME_DIR/.local/lib/brokkr/archive-verify/releases/previous"
printf 'VERIFY SERVICE\n' >"$VERIFY_UNIT"; printf 'VERIFY TIMER\n' >"$VERIFY_TIMER"
mkdir -p "$VERIFY_RELEASE"; printf 'verify release\n' >"$VERIFY_RELEASE/marker"
env_before="$(cksum <"$DELIVERY_ENV")"; config_before="$(cksum <"$CONFIG")"
run "$TARGET" --apply
if [[ -n "${TEST_VERBOSE:-}" ]]; then printf '%s\n' "$OUT"; cat "$SERVICE"; fi
check "--apply succeeds" '[[ "$RC" -eq 0 && "$OUT" == *"OK: archive near-site self-check installed; timer enabled"* && "$OUT" == *"==> Done. No Heimdall credential values were printed."* ]]'
check "the archive-verify units and release are untouched" '[[ "$(cat "$VERIFY_UNIT")" == "VERIFY SERVICE" && "$(cat "$VERIFY_TIMER")" == "VERIFY TIMER" && "$(cat "$VERIFY_RELEASE/marker")" == "verify release" ]] && ! grep -q "archive-verify" "$CALLS" && [[ "$OUT" != *archive-verify* ]]'
check "the delivery env and config are byte-identical after the deploy" '[[ "$(cksum <"$DELIVERY_ENV")" == "$env_before" && "$(cksum <"$CONFIG")" == "$config_before" ]] && [[ "$(stat -c %a "$DELIVERY_ENV" 2>/dev/null || stat -f %Lp "$DELIVERY_ENV")" == 600 ]]'
check "no other file in the config directory was created" '[[ "$(ls -A "$HOME_DIR/.config/brokkr" | tr "\n" " ")" == "archive-nearsite.conf heimdall.env " ]]'
check "release holds exactly the verifier, push helper, templates, and rendered units" '[[ "$(cd "$RELEASE" && find . -type f | sort | tr "\n" " ")" == "./brokkr-archive-nearsite.service ./brokkr-archive-nearsite.timer ./heimdall/push.sh ./scripts/archive-nearsite.sh ./systemd/user/brokkr-archive-nearsite.service.in ./systemd/user/brokkr-archive-nearsite.timer " ]]'
check "unrelated repository files never ship" '[[ ! -e "$RELEASE/README.md" ]]'
check "release files are executable where needed and private" '[[ -x "$RELEASE/scripts/archive-nearsite.sh" && -x "$RELEASE/heimdall/push.sh" && "$(stat -c %a "$RELEASE" 2>/dev/null || stat -f %Lp "$RELEASE")" == 700 ]]'
check "no staging directory is left behind" '[[ -z "$(find "$HOME_DIR/.local/lib/brokkr/archive-nearsite" -maxdepth 1 -name ".stage.*")" ]]'
check "unit renders the exact SHA, delivery env, and config path under a clean environment" 'grep -Fxq "ExecStart=/usr/bin/env -i HOME=%h PATH=$MOCK_REMOTE_PATH LANG=C.UTF-8 %h/.local/lib/brokkr/archive-nearsite/releases/$SHA/scripts/archive-nearsite.sh --config $CONFIG --delivery-env $DELIVERY_ENV --verify" "$SERVICE" && grep -Fxq "WorkingDirectory=%h/.local/lib/brokkr/archive-nearsite/releases/$SHA" "$SERVICE"'
check "rendered unit loads no EnvironmentFile and has no blacklist (allowlist model)" '! grep -Eq "^(EnvironmentFile|UnsetEnvironment|PassEnvironment|Environment)=" "$SERVICE"'
check "no secret is on the rendered command line (only file paths follow --delivery-env and --config)" '! grep -q "secret-sentinel" "$SERVICE" && ! grep -Eq "^ExecStart=.*(HEIMDALL_|TOKEN)" "$SERVICE"'
check "rendered unit has no leftover placeholders, system-only directives, or old layout" '! grep -Eq "@[A-Z_]+@|^OnFailure|^User=|^SupplementaryGroups|/opt/brokkr|/home/brokkr|rclone" "$SERVICE" && grep -Fxq NoNewPrivileges=yes "$SERVICE" && grep -Fxq PrivateTmp=yes "$SERVICE"'
check "rendered unit is sandboxed: read-only home, only the state dir writable, 12h timeout" 'grep -Fxq ProtectSystem=strict "$SERVICE" && grep -Fxq ProtectHome=read-only "$SERVICE" && grep -Fxq "ReadWritePaths=%h/.local/state/brokkr" "$SERVICE" && grep -Fxq TimeoutStartSec=12h "$SERVICE" && grep -Fxq Nice=10 "$SERVICE" && grep -Fxq IOSchedulingClass=idle "$SERVICE"'
check "apply says a catch-up run can start after an upgrade and not on a first install" '[[ "$OUT" == *"catch-up"* && "$OUT" == *"first install"* ]]'
check "timer runs on the 2nd, after the archive node's run on the 1st" 'grep -Fxq "OnCalendar=*-*-02 03:30:00" "$TIMER" && grep -Fxq Persistent=true "$TIMER" && grep -Fxq RandomizedDelaySec=2h "$TIMER"'
check "timer is installed from the template" 'cmp -s "$TIMER" "$REPO/systemd/user/brokkr-archive-nearsite.timer"'
check "existing unit is backed up as .previous-<SHA>" '[[ "$(cat "$SERVICE.previous-$SHA")" == "OLD SERVICE" ]]'
check "systemd is reloaded, then the timer enabled" '[[ "$(line_of "^systemctl --user daemon-reload")" -lt "$(line_of "^systemctl --user enable --now brokkr-archive-nearsite.timer")" ]]'
check "the service is NOT started during deploy" '! grep -Eq "^systemctl --user (start|restart|try-restart)" "$CALLS" && ! grep -q "^journalctl" "$CALLS"'
check "output prints how to start and check the first check" '[[ "$OUT" == *"next: start the first check with: systemctl --user start --no-block brokkr-archive-nearsite.service"* && "$OUT" == *"systemctl --user status brokkr-archive-nearsite.service"* && "$OUT" == *"cat ~/.local/state/brokkr/archive-nearsite.json"* ]]'
check "the staged verifier was validated before install, twice, and nothing was hashed" 'only_version_probe && [[ "$(grep -c "^sha256sum --version$" "$CALLS")" -ge 2 ]] && [[ "$(printf "%s" "$OUT" | grep -c "preflight: validated: 2 manifest entries")" -ge 2 ]]'
check "output prints a concrete rollback recipe" '[[ "$OUT" == *"Rollback"* && "$OUT" == *"systemctl --user disable --now brokkr-archive-nearsite.timer"* && "$OUT" == *"$SERVICE.previous-$SHA"* && "$OUT" == *"releases/$SHA"* ]]'
check "apply never prints delivery env values" '[[ "$OUT" != *secret-sentinel* && "$OUT" != *heimdall.example.invalid* ]] && ! grep -Fq secret-sentinel "$CALLS"'
check "apply payload parent and validator scratch are cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'
check "the state directory exists for the sandboxed unit and holds no log" '[[ -d "$HOME_DIR/.local/state/brokkr" && -z "$(ls -A "$HOME_DIR/.local/state/brokkr")" ]]'
check "no archive-verify file was created by the deploy" '[[ ! -e "$HOME_DIR/.local/lib/brokkr/archive-nearsite/releases/previous" && -z "$(find "$HOME_DIR/.local/lib/brokkr/archive-nearsite" -name "*verify*")" ]]'
: >"$CALLS"
run "$TARGET" --apply
check "re-applying the same revision refuses instead of overwriting" '[[ "$RC" -ne 0 && "$OUT" == *"release already exists"* ]] && ! grep -q "^systemctl" "$CALLS"'

# --- backup safety: originals stay intact until every backup exists ---------------------------
seed_units() { mkdir -p "$UNIT_DIR"; printf 'OLD SERVICE\n' >"$SERVICE"; printf 'OLD TIMER\n' >"$TIMER"; }
units_intact() { [[ "$(cat "$SERVICE")" == "OLD SERVICE" && "$(cat "$TIMER")" == "OLD TIMER" ]]; }
no_backup_debris() { [[ -z "$(find "$UNIT_DIR" -name '.*backup-tmp*' -print)" ]]; }
reset; seed_units
run "$TARGET" --apply
check "both pre-existing units are backed up as .previous-<SHA>" '[[ "$RC" -eq 0 && "$(cat "$SERVICE.previous-$SHA")" == "OLD SERVICE" && "$(cat "$TIMER.previous-$SHA")" == "OLD TIMER" ]]'
# The rollback restores the timer's recorded state, never a schedule that was off.
rollback_tail() { printf '%s\n' "$OUT" | sed -n '/^Rollback/,$p'; }
reset; seed_units
MOCK_TIMER_ENABLED=disabled MOCK_TIMER_ACTIVE=inactive run "$TARGET" --apply
check "rollback over a disabled, inactive timer records that state" '[[ "$RC" -eq 0 && "$(rollback_tail)" == *"timer before this run: disabled, inactive"* ]]'
check "rollback over a disabled, inactive timer never re-enables or starts it" '! rollback_tail | grep -Eq "systemctl --user (enable|start)"'
reset; seed_units
MOCK_TIMER_ENABLED=enabled MOCK_TIMER_ACTIVE=active run "$TARGET" --apply
check "rollback over an enabled, active timer re-enables and restarts it" '[[ "$RC" -eq 0 && "$(rollback_tail)" == *"systemctl --user enable $(basename "$TIMER")"* && "$(rollback_tail)" == *"systemctl --user start $(basename "$TIMER")"* ]]'
check "rollback restores the timer files before its state" '[[ "$(rollback_tail | grep -n "mv -f $TIMER.previous" | cut -d: -f1)" -lt "$(rollback_tail | grep -n "systemctl --user enable" | cut -d: -f1)" ]]'
reset; seed_units
MOCK_TIMER_ENABLED=enabled MOCK_TIMER_ACTIVE=inactive run "$TARGET" --apply
check "rollback over an enabled, inactive timer re-enables without starting" '[[ "$(rollback_tail)" == *"systemctl --user enable $(basename "$TIMER")"* ]] && ! rollback_tail | grep -q "systemctl --user start"'
reset; seed_units; export MOCK_CP_FAIL="service.backup-tmp"
run "$TARGET" --apply
check "a failed first backup leaves both original units untouched and installs nothing" '[[ "$RC" -ne 0 && "$OUT" == *"could not back up"* ]] && units_intact && no_backup_debris && [[ ! -e "$RELEASE" ]] && ! grep -q "^systemctl" "$CALLS"'
check "a failed first backup prints no unit rollback steps" '[[ "$OUT" == *"no release or installed unit was changed"* && "$OUT" != *"rm -f $UNIT_DIR"* && "$OUT" != *"mv -f"* ]]'
reset; seed_units; export MOCK_CP_FAIL="timer.backup-tmp"
run "$TARGET" --apply
check "a partial backup (second unit fails) leaves originals untouched and no temp files" '[[ "$RC" -ne 0 && "$OUT" == *"could not back up"* ]] && units_intact && no_backup_debris && [[ ! -e "$RELEASE" && ! -e "$SERVICE.previous-$SHA" ]] && ! grep -q "^systemctl" "$CALLS"'
reset; seed_units; export MOCK_MV_FAIL="timer.previous"
run "$TARGET" --apply
check "a failed backup finalize leaves originals untouched and the recipe only offers cleanup" '[[ "$RC" -ne 0 && "$OUT" == *"could not finalize"* ]] && units_intact && no_backup_debris && [[ ! -e "$RELEASE" ]] && ! grep -q "^systemctl" "$CALLS" && [[ "$OUT" != *"mv -f $UNIT_DIR"* ]]'

# --- payload is received and validated before the node is changed -----------------------------
reset; export MOCK_TAR_FAIL=1
run "$TARGET" --apply
check "payload extraction failure changes nothing" '[[ "$RC" -ne 0 && "$OUT" == *"payload extraction failed"* ]] && ! grep -q "^systemctl" "$CALLS" && no_release_or_units && [[ "$OUT" == *"no release or installed unit was changed"* ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
