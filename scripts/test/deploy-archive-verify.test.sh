#!/usr/bin/env bash
# Hermetic gates for scripts/deploy-archive-verify.sh. ssh, rclone, systemctl, loginctl,
# journalctl, and id are fakes on PATH; the "remote" is a temp HOME on this machine. The
# real archive-offsite.sh --validate runs against a fake rclone and a tiny fixture
# archive. No real host, network, rclone remote, or credential is touched.
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
RCBIN="$TMP/rcbin"; PYBIN="$TMP/pybin"
mkdir -p "$REPO/scripts/lib" "$REPO/heimdall" "$REPO/systemd/user" \
  "$HOME_DIR/.config/brokkr" "$BIN" "$RCBIN" "$PYBIN" "$TMP/payload-tmp"
cp "$ROOT/scripts/deploy-archive-verify.sh" "$ROOT/scripts/archive-offsite.sh" "$REPO/scripts/" 2>/dev/null
cp "$ROOT/scripts/lib/deploy-source.sh" "$REPO/scripts/lib/"
cp "$ROOT/heimdall/push.sh" "$REPO/heimdall/"
cp "$ROOT/systemd/user/"brokkr-archive-verify.* "$REPO/systemd/user/"
echo "unrelated file that must never ship" > "$REPO/README.md"
git init -q "$REPO"; git -C "$REPO" config user.name test; git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add . ; git -C "$REPO" commit -qm fixture
SHA="$(git -C "$REPO" rev-parse HEAD)"
DEPLOY="$REPO/scripts/deploy-archive-verify.sh"

# The remote PATH sees python3 only through a wrapper, so a developer machine that has a
# real rclone next to its python3 cannot leak one into the "rclone missing" cases.
REAL_PYTHON="$(command -v python3)"
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
exec env -u XDG_CONFIG_HOME HOME="$MOCK_REMOTE_HOME" PATH="$MOCK_REMOTE_PATH" \
  BROKKR_ARCHIVE_RCLONE_SEARCH_PATH="$MOCK_RCBIN" bash -c "$1"
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
exit 0
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

# Fake rclone: only `config dump` is answered, as a crypt remote that archive-offsite.sh
# accepts. The passwords are dummy sentinels that must never appear in any output. The
# verifier refuses RCLONE_* variables, so a leak into the remote environment is recorded.
cat >"$TMP/rclone.src" <<'FAKE'
#!/usr/bin/env bash
printf 'rclone %s\n' "$*" >>"$MOCK_CALLS"
if compgen -e | grep -q '^RCLONE_'; then echo "rclone-env-leak" >>"$MOCK_CALLS"; fi
if [[ "${1:-}" == config && "${2:-}" == dump ]]; then
  cat <<JSON
{"example-crypt":{"type":"crypt","remote":"example-base:archive","filename_encryption":"standard","directory_name_encryption":"true","password":"dummy-password-sentinel","password2":"dummy-salt-sentinel","filename_encoding":"${MOCK_ENCODING:-base32768}"},"example-base":{"type":"onedrive","drive_type":"personal","drive_id":"EXAMPLE"}}
JSON
  exit 0
fi
echo "fake rclone: unexpected invocation" >&2; exit 99
FAKE

export MOCK_CALLS="$CALLS" MOCK_BIN="$BIN" MOCK_REMOTE_HOME="$HOME_DIR" MOCK_RCBIN="$RCBIN"
export MOCK_REMOTE_PATH="$BIN:$PYBIN:/usr/bin:/bin"
export PATH="$BIN:$PATH" TMPDIR="$TMP/payload-tmp"
# The fixture itself may live under /tmp (Linux CI); PrivateTmp roots are set per case.
export BROKKR_ARCHIVE_PRIVATE_TMP_ROOTS=/nonexistent-private-tmp
unset XDG_CONFIG_HOME
export BROKKR_EXPECTED_SOURCE="$REPO" BROKKR_EXPECTED_COMMIT="$SHA"

DELIVERY_ENV="$HOME_DIR/.config/brokkr/heimdall.env"
CONFIG="$HOME_DIR/.config/brokkr/archive-offsite.conf"
export BROKKR_ARCHIVE_DELIVERY_ENV="$DELIVERY_ENV"
unset BROKKR_ARCHIVE_CONFIG
TARGET=operator@node-a.example.invalid
UNIT_DIR="$HOME_DIR/.config/systemd/user"
RELEASE="$HOME_DIR/.local/lib/brokkr/archive-verify/releases/$SHA"
SERVICE="$UNIT_DIR/brokkr-archive-verify.service"
TIMER="$UNIT_DIR/brokkr-archive-verify.timer"
HEAD_ENV='HEIMDALL_HUB_URL=https://heimdall.example.invalid/api/panels\nHEIMDALL_FLEET_TOKEN=secret-sentinel\n'

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; printf '        rc=%s out=%s\n' "${RC:-}" "${OUT:-}" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() { OUT="$(cd "$REPO" && bash "$DEPLOY" "$@" 2>&1)"; RC=$?; }
line_of() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
tree_state() { { find "$HOME_DIR" | sort; find "$HOME_DIR" -type f -exec cksum {} + | sort; } | cksum; }
good_inputs() {
  printf '%b' "$HEAD_ENV" >"$DELIVERY_ENV"
  mkdir -p "$HOME_DIR/archive"
  printf 'one\n' >"$HOME_DIR/archive/a.txt"; printf 'two\n' >"$HOME_DIR/archive/b.txt"
  printf '0000000000000000000000000000000000000000000000000000000000000000  a.txt\n0000000000000000000000000000000000000000000000000000000000000000  b.txt\n' >"$HOME_DIR/archive.sha256"
  printf '# fixture\nARCHIVE_SRC=%s\nARCHIVE_MANIFEST=%s\nARCHIVE_REMOTE=example-crypt\n' "$HOME_DIR/archive" "$HOME_DIR/archive.sha256" >"$CONFIG"
  chmod 600 "$DELIVERY_ENV" "$CONFIG"
}
reset() {
  rm -rf "$HOME_DIR/.local" "$HOME_DIR/.config/systemd" "$HOME_DIR/.config/brokkr/other"
  rm -f "$DELIVERY_ENV" "$CONFIG" "$RCBIN/rclone"
  : >"$CALLS"
  unset MOCK_ID_ROOT MOCK_LINGER MOCK_ENCODING MOCK_CP_FAIL MOCK_MV_FAIL MOCK_TAR_FAIL
  export BROKKR_EXPECTED_COMMIT="$SHA" BROKKR_ARCHIVE_DELIVERY_ENV="$DELIVERY_ENV"
  unset BROKKR_ARCHIVE_CONFIG
  cp "$TMP/rclone.src" "$RCBIN/rclone"; chmod 755 "$RCBIN/rclone"
  good_inputs
}
# Staging under the release root is allowed to leave the (empty) directory skeleton.
no_release_or_units() { [[ ! -e "$RELEASE" && ! -e "$UNIT_DIR" && -z "$(find "$HOME_DIR/.local/lib" -name '.stage.*' 2>/dev/null)" ]]; }
# No remote state, units, or systemd mutation happened.
no_mutation() { [[ ! -e "$HOME_DIR/.local" && ! -e "$HOME_DIR/.config/systemd" ]] && ! grep -Eq '^systemctl' "$CALLS"; }
# The only rclone call ever made is the read-only config dump.
only_config_dump() { [[ -z "$(grep '^rclone ' "$CALLS" | grep -v '^rclone config dump$')" ]] && ! grep -q rclone-env-leak "$CALLS"; }

echo "deploy-archive-verify.test.sh"
reset
PATH_CHECK="$(PATH="$MOCK_REMOTE_PATH" command -v rclone || true)"
check "fixture precondition: no rclone on the simulated remote PATH" '[[ -z "$PATH_CHECK" ]]'

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
unset BROKKR_ARCHIVE_DELIVERY_ENV
run "$TARGET"
check "missing delivery env parameter refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_ARCHIVE_DELIVERY_ENV is required"* ]] && ! grep -q ssh "$CALLS"'
reset
BROKKR_ARCHIVE_DELIVERY_ENV="relative/heimdall.env" run "$TARGET"
check "relative delivery env path refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"invalid BROKKR_ARCHIVE_DELIVERY_ENV"* ]] && ! grep -q ssh "$CALLS"'
BROKKR_ARCHIVE_CONFIG="/unsafe path/x.conf" run "$TARGET"
check "unsafe config path refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"invalid BROKKR_ARCHIVE_CONFIG"* ]] && ! grep -q ssh "$CALLS"'
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
check "dry-run reports the rclone path and the validator verdict" '[[ "$OUT" == *"preflight: rclone present at $RCBIN/rclone"* && "$OUT" == *"preflight: underlying: example-base type="* ]]'
check "dry-run states what --apply would do and that nothing changed" '[[ "$OUT" == *"--apply would stage the payload"* && "$OUT" == *"Nothing was changed"* ]]'
check "dry-run only reads the rclone config dump" 'only_config_dump && grep -q "^rclone config dump$" "$CALLS"'
check "dry-run never prints secret values" '[[ "$OUT" != *secret-sentinel* && "$OUT" != *dummy-password-sentinel* && "$OUT" != *dummy-salt-sentinel* ]]'
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
refuses "missing archive config refuses" "archive config" "$TARGET"
reset; chmod 644 "$CONFIG"
refuses "world-readable archive config refuses" "archive config" "$TARGET"
reset; rm -f "$CONFIG"; printf 'x\n' >"$HOME_DIR/.config/brokkr/other"; ln -s "$HOME_DIR/.config/brokkr/other" "$CONFIG"
refuses "symlinked archive config refuses" "archive config" "$TARGET"
reset; printf 'ARCHIVE_LOG=%s/archive.log\n' "$HOME_DIR" >>"$CONFIG"
refuses "archive config with a log path the unit cannot write refuses" "must not set ARCHIVE_LOG" "$TARGET"
reset; printf 'ARCHIVE_SRC=/var/tmp/archive\n' >>"$CONFIG"
BROKKR_ARCHIVE_PRIVATE_TMP_ROOTS=/var/tmp refuses "archive under a PrivateTmp-hidden directory refuses" "ARCHIVE_SRC is under a temporary directory that PrivateTmp hides" "$TARGET"
reset
BROKKR_ARCHIVE_PRIVATE_TMP_ROOTS="$RCBIN" refuses "rclone under a PrivateTmp-hidden directory refuses" "rclone is under a temporary directory that PrivateTmp hides" "$TARGET"
reset; printf 'SURPRISE=1\n' >>"$CONFIG"
refuses "archive config rejected by the shipped parser refuses" "rejected by the shipped verifier" "$TARGET"
reset; printf '1 extra\n' >>"$HOME_DIR/archive.sha256"
refuses "archive and manifest count mismatch refuses" "manifest has 3 lines" "$TARGET"
reset; export MOCK_ID_ROOT=1
refuses "root runtime user refuses" "must not be root" "$TARGET"
reset; export MOCK_LINGER=no
refuses "disabled user lingering refuses" "linger" "$TARGET"
reset; rm -f "$RCBIN/rclone"
refuses "rclone missing refuses" "rclone is not installed" "$TARGET"
check "rclone is never installed or invoked when missing" '[[ ! -e "$RCBIN/rclone" ]] && ! grep -q "^rclone" "$CALLS"'
reset; export MOCK_ENCODING=base32
refuses "crypt validation failure (filename_encoding base32) refuses" "filename_encoding must be base32768" "$TARGET"
check "crypt validation failure leaves no scratch state" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'
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

# --- delivery env may not redirect the verifier; shared unrelated keys are fine -------------
for forbidden in ARCHIVE_RCLONE ARCHIVE_SRC RCLONE_CONFIG RCLONE_CONFIG_EXAMPLE_TYPE BROKKR_STATE_DIR PATH; do
  reset
  printf '%b%s=/tmp/redirect\n' "$HEAD_ENV" "$forbidden" >"$DELIVERY_ENV"
  refuses "delivery env setting $forbidden refuses" "verifier-controlling variable" "$TARGET"
done
reset
printf '%bexport RCLONE_CONFIG=/tmp/x\n' "$HEAD_ENV" >"$DELIVERY_ENV"
refuses "delivery env with an export-prefixed forbidden key refuses" "verifier-controlling variable" "$TARGET"
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
BROKKR_ARCHIVE_CONFIG="$HOME_DIR/.config/brokkr/custom.conf" run "$TARGET"
check "explicit BROKKR_ARCHIVE_CONFIG is validated instead of the default" '[[ "$RC" -eq 0 ]]'
rm -f "$HOME_DIR/.config/brokkr/custom.conf"
reset
mv "$DELIVERY_ENV" "$HOME_DIR/.config/brokkr/env"
BROKKR_ARCHIVE_DELIVERY_ENV="$HOME_DIR/.config/brokkr/env" run "$TARGET" --apply
check "the delivery env path is a parameter (env instead of heimdall.env)" '[[ "$RC" -eq 0 ]] && grep -Fxq "EnvironmentFile=$HOME_DIR/.config/brokkr/env" "$SERVICE"'
rm -f "$HOME_DIR/.config/brokkr/env"

# --- --apply: install --------------------------------------------------------------------------
reset
mkdir -p "$UNIT_DIR"; printf 'OLD SERVICE\n' >"$SERVICE"
run "$TARGET" --apply
if [[ -n "${TEST_VERBOSE:-}" ]]; then printf '%s\n' "$OUT"; cat "$SERVICE"; fi
check "--apply succeeds" '[[ "$RC" -eq 0 && "$OUT" == *"OK: archive verifier installed; timer enabled"* && "$OUT" == *"==> Done. No Heimdall credential values were printed."* ]]'
check "release holds exactly the verifier, push helper, templates, and rendered units" '[[ "$(cd "$RELEASE" && find . -type f | sort | tr "\n" " ")" == "./brokkr-archive-verify.service ./brokkr-archive-verify.timer ./heimdall/push.sh ./scripts/archive-offsite.sh ./systemd/user/brokkr-archive-verify.service.in ./systemd/user/brokkr-archive-verify.timer " ]]'
check "unrelated repository files never ship" '[[ ! -e "$RELEASE/README.md" ]]'
check "release files are executable where needed and private" '[[ -x "$RELEASE/scripts/archive-offsite.sh" && -x "$RELEASE/heimdall/push.sh" && "$(stat -c %a "$RELEASE" 2>/dev/null || stat -f %Lp "$RELEASE")" == 700 ]]'
check "no staging directory is left behind" '[[ -z "$(find "$HOME_DIR/.local/lib/brokkr/archive-verify" -maxdepth 1 -name ".stage.*")" ]]'
check "unit renders the exact SHA, delivery env, config, and rclone path" 'grep -Fxq "ExecStart=%h/.local/lib/brokkr/archive-verify/releases/$SHA/scripts/archive-offsite.sh --config $CONFIG --verify" "$SERVICE" && grep -Fxq "WorkingDirectory=%h/.local/lib/brokkr/archive-verify/releases/$SHA" "$SERVICE" && grep -Fxq "EnvironmentFile=$DELIVERY_ENV" "$SERVICE" && grep -Fxq "Environment=ARCHIVE_RCLONE=$RCBIN/rclone" "$SERVICE"'
check "rendered unit has no leftover placeholders, system-only directives, or old layout" '! grep -Eq "@[A-Z_]+@|^OnFailure|^User=|^SupplementaryGroups|/opt/brokkr|/home/brokkr" "$SERVICE" && grep -Fxq NoNewPrivileges=yes "$SERVICE" && grep -Fxq PrivateTmp=yes "$SERVICE"'
check "timer is installed from the template" 'cmp -s "$TIMER" "$REPO/systemd/user/brokkr-archive-verify.timer"'
check "existing unit is backed up as .previous-<SHA>" '[[ "$(cat "$SERVICE.previous-$SHA")" == "OLD SERVICE" ]]'
check "systemd is reloaded, then the timer enabled" '[[ "$(line_of "^systemctl --user daemon-reload")" -lt "$(line_of "^systemctl --user enable --now brokkr-archive-verify.timer")" ]]'
check "the service is NOT started during deploy" '! grep -Eq "^systemctl --user (start|restart|try-restart)" "$CALLS" && ! grep -q "^journalctl" "$CALLS"'
check "output prints how to start and check the first verification" '[[ "$OUT" == *"next: start the first verification with: systemctl --user start --no-block brokkr-archive-verify.service"* && "$OUT" == *"systemctl --user status brokkr-archive-verify.service"* && "$OUT" == *"cat ~/.local/state/brokkr/archive-verify.json"* ]]'
check "the staged verifier was validated before install and only dumped the rclone config" 'only_config_dump && [[ "$(grep -c "^rclone config dump$" "$CALLS")" -ge 2 ]]'
check "output prints a concrete rollback recipe" '[[ "$OUT" == *"Rollback"* && "$OUT" == *"systemctl --user disable --now brokkr-archive-verify.timer"* && "$OUT" == *"$SERVICE.previous-$SHA"* && "$OUT" == *"releases/$SHA"* ]]'
check "apply never prints secret values" '[[ "$OUT" != *secret-sentinel* && "$OUT" != *dummy-password-sentinel* && "$OUT" != *dummy-salt-sentinel* ]] && ! grep -Fq secret-sentinel "$CALLS"'
check "apply payload parent and validator scratch are cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'
check "the state directory exists for the sandboxed unit" '[[ -d "$HOME_DIR/.local/state/brokkr" && ! -e "$HOME_DIR/.local/state/brokkr/archive-offsite.log" ]]'
: >"$CALLS"
run "$TARGET" --apply
check "re-applying the same revision refuses instead of overwriting" '[[ "$RC" -ne 0 && "$OUT" == *"release already exists"* ]] && ! grep -q "^systemctl" "$CALLS"'

# --- backup safety: originals stay intact until every backup exists ---------------------------
seed_units() { mkdir -p "$UNIT_DIR"; printf 'OLD SERVICE\n' >"$SERVICE"; printf 'OLD TIMER\n' >"$TIMER"; }
units_intact() { [[ "$(cat "$SERVICE")" == "OLD SERVICE" && "$(cat "$TIMER")" == "OLD TIMER" ]]; }
no_backup_debris() { [[ -z "$(find "$UNIT_DIR" -name '.*backup-tmp*' -print)" ]]; }
reset; seed_units
run "$TARGET" --apply
check "both pre-existing units are backed up as .previous-<SHA>" '[[ "$RC" -eq 0 && "$(cat "$SERVICE.previous-$SHA")" == "OLD SERVICE" && "$(cat "$TIMER.previous-$SHA")" == "OLD TIMER" && "$OUT" == *"enable --now brokkr-archive-verify.timer   # restore the previous schedule"* ]]'
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
