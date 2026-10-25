#!/usr/bin/env bash
# Hermetic gates for scripts/deploy-agent-cli-update.sh. ssh, systemctl, loginctl, journalctl,
# and id are fakes on PATH; the "remote" is a temp HOME on this machine. No real host, network,
# or package manager is touched, and the updater itself is never run.
# shellcheck disable=SC2016,SC2034 # assertions are evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/test/lib/fixture-cleanup.sh
source "$HERE/lib/fixture-cleanup.sh"
TMP="$(fixture_cleanup_alloc)"
trap 'fixture_cleanup_on_exit "$TMP"' EXIT
# The deploy entry path must contain no symlinks (macOS /var is one).
TMP="$(cd "$TMP" && pwd -P)"

REPO="$TMP/repo"; HOME_DIR="$TMP/home"; BIN="$TMP/bin"; CALLS="$TMP/calls"
mkdir -p "$HOME_DIR" "$BIN" "$TMP/payload-tmp" "$TMP/nosbin"

make_repo() { # dir
  local r=$1
  mkdir -p "$r/scripts/lib" "$r/systemd/user"
  cp "$ROOT/scripts/deploy-agent-cli-update.sh" "$ROOT/scripts/agent-cli-update.sh" "$r/scripts/" 2>/dev/null
  cp "$ROOT/scripts/lib/deploy-source.sh" "$r/scripts/lib/"
  cp "$ROOT/systemd/user/"brokkr-agent-cli-update.* "$r/systemd/user/" 2>/dev/null
  echo "unrelated file that must never ship" >"$r/README.md"
  git init -q "$r"; git -C "$r" config user.name test; git -C "$r" config user.email test@example.invalid
}
commit_repo() { git -C "$1" add . ; git -C "$1" commit -qm fixture; git -C "$1" rev-parse HEAD; }
make_repo "$REPO"
SHA="$(commit_repo "$REPO")"
DEPLOY="$REPO/scripts/deploy-agent-cli-update.sh"

: >"$CALLS"
cat >"$BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
# usage: ssh [-o opt]... TARGET COMMAND
while [[ "${1:-}" == -o ]]; do shift 2; done
target=$1; shift
printf 'ssh %s\n' "$target" >>"$MOCK_CALLS"
[[ "$#" -eq 1 ]] || exit 64
exec env -u XDG_CONFIG_HOME HOME="$MOCK_REMOTE_HOME" PATH="$MOCK_REMOTE_PATH" \
  BROKKR_AGENT_CLI_TOOL_PATH="$MOCK_NOSBIN" bash -c "$1"
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
case " $* " in
  *" start "*)
    mkdir -p "$HOME/.local/state/brokkr"
    if [[ "${MOCK_NO_STATE:-0}" != 1 ]]; then
      printf '{\n  "timestamp": "2026-01-01T00:00:00Z",\n  "hostname": "node-a",\n  "result": "%s",\n  "tools": []\n}\n' "${MOCK_STATE_RESULT:-ok}" >"$HOME/.local/state/brokkr/agent-cli-update.json"
    fi
    exit "${MOCK_START_RC:-0}" ;;
  *" show "*) printf '%s\n' "${MOCK_RESULT:-success}" ;;
esac
exit 0
FAKE
cat >"$BIN/journalctl" <<'FAKE'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*" >>"$MOCK_CALLS"
echo "summary: result=ok tools=4 updated=0 current=2 external=0 absent=2 failed=0 rolled-back=0"
FAKE
# Fault injection: cp/mv fail when the destination matches; tar can fail, add a file, or add a
# symlink when it extracts the payload on stdin.
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
if [[ "${1:-}" == -xf && "${2:-}" == - ]]; then
  if [[ "${MOCK_TAR_FAIL:-0}" == 1 ]]; then echo "tar: injected extraction failure" >&2; exit 2; fi
  /usr/bin/tar "$@" || exit $?
  dest=$4
  if [[ "${MOCK_TAR_EXTRA:-0}" == 1 ]]; then echo surprise >"$dest/extra.txt"; fi
  if [[ "${MOCK_TAR_SYMLINK:-0}" == 1 ]]; then ln -s /etc/hosts "$dest/evil-link"; fi
  exit 0
fi
exec /usr/bin/tar "$@"
FAKE
chmod 755 "$BIN/"*

export MOCK_CALLS="$CALLS" MOCK_BIN="$BIN" MOCK_REMOTE_HOME="$HOME_DIR" MOCK_NOSBIN="$TMP/nosbin"
export MOCK_REMOTE_PATH="$BIN:/usr/bin:/bin"
export PATH="$BIN:$PATH" TMPDIR="$TMP/payload-tmp"
unset XDG_CONFIG_HOME
export BROKKR_EXPECTED_SOURCE="$REPO" BROKKR_EXPECTED_COMMIT="$SHA"
unset BROKKR_AGENT_CLI_BUSY_UNITS

TARGET=operator@node-a.example.invalid
UNIT_DIR="$HOME_DIR/.config/systemd/user"
RELEASE="$HOME_DIR/.local/lib/brokkr/agent-cli-update/releases/$SHA"
SERVICE="$UNIT_DIR/brokkr-agent-cli-update.service"
TIMER="$UNIT_DIR/brokkr-agent-cli-update.timer"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; printf '        rc=%s out=%s\n' "${RC:-}" "${OUT:-}" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() { OUT="$(cd "$REPO" && bash "$DEPLOY" "$@" 2>&1)"; RC=$?; }
line_of() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
tree_state() { { find "$HOME_DIR" | sort; find "$HOME_DIR" -type f -exec cksum {} + | sort; } | cksum; }
reset() {
  rm -rf "$HOME_DIR/.local" "$HOME_DIR/.config"
  : >"$CALLS"
  unset MOCK_ID_ROOT MOCK_LINGER MOCK_START_RC MOCK_RESULT MOCK_STATE_RESULT MOCK_NO_STATE
  unset MOCK_CP_FAIL MOCK_MV_FAIL MOCK_TAR_FAIL MOCK_TAR_EXTRA MOCK_TAR_SYMLINK
  export BROKKR_EXPECTED_SOURCE="$REPO" BROKKR_EXPECTED_COMMIT="$SHA"
  unset BROKKR_AGENT_CLI_BUSY_UNITS
}
# Staging under the release root is allowed to leave the (empty) directory skeleton.
no_release_or_units() { [[ ! -e "$RELEASE" && ! -e "$UNIT_DIR" && -z "$(find "$HOME_DIR/.local/lib" -name '.stage.*' 2>/dev/null)" ]]; }
# No remote state, units, or systemd mutation happened.
no_mutation() { [[ ! -e "$HOME_DIR/.local" && ! -e "$HOME_DIR/.config/systemd" ]] && ! grep -Eq '^systemctl' "$CALLS"; }
add_remote_tools() { mkdir -p "$HOME_DIR/.local/bin"; printf '#!/bin/sh\n' >"$HOME_DIR/.local/bin/npm"; cp "$HOME_DIR/.local/bin/npm" "$HOME_DIR/.local/bin/node"; chmod 755 "$HOME_DIR/.local/bin/npm" "$HOME_DIR/.local/bin/node"; }

echo "deploy-agent-cli-update.test.sh"
reset

# --- local gates: nothing reaches ssh ---------------------------------------------------
unset BROKKR_EXPECTED_COMMIT
run "$TARGET"
check "missing expected commit refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_EXPECTED_SOURCE and BROKKR_EXPECTED_COMMIT"* ]] && ! grep -q ssh "$CALLS"'
reset
export BROKKR_EXPECTED_COMMIT=0000000000000000000000000000000000000000
run "$TARGET"
check "wrong expected commit refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"revision does not match"* ]] && ! grep -q ssh "$CALLS"'
reset
ln -s "$DEPLOY" "$REPO/scripts/deploy-via-link.sh"
OUT="$(cd "$REPO" && bash "$REPO/scripts/deploy-via-link.sh" "$TARGET" 2>&1)"; RC=$?
check "symlinked entry script refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"must not contain symlinks"* ]] && ! grep -q ssh "$CALLS"'
rm -f "$REPO/scripts/deploy-via-link.sh"
for unit in 'bad' 'x;y.service' 'a.timer' '../x.service' '$(id).service' '*.service'; do
  BROKKR_AGENT_CLI_BUSY_UNITS="hugin.service $unit" run "$TARGET"
  check "invalid busy unit '$unit' refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"invalid BROKKR_AGENT_CLI_BUSY_UNITS"* ]] && ! grep -q ssh "$CALLS"'
done
BROKKR_AGENT_CLI_BUSY_UNITS=$'hugin.service\nother.service' run "$TARGET"
check "a newline inside the busy unit list refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"invalid BROKKR_AGENT_CLI_BUSY_UNITS"* ]] && ! grep -q ssh "$CALLS"'
run
check "missing ssh target refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *usage* ]] && ! grep -q ssh "$CALLS"'
run -oProxyCommand=evil
check "option-shaped ssh target refuses before ssh" '[[ "$RC" -ne 0 ]] && ! grep -q ssh "$CALLS"'
run "bad target"
check "ssh target with a space refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"invalid SSH target"* ]] && ! grep -q ssh "$CALLS"'
run "$TARGET" --bogus
check "unknown option refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *usage* ]] && ! grep -q ssh "$CALLS"'
run "$TARGET" other-target
check "a second target refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *usage* ]] && ! grep -q ssh "$CALLS"'

# --- dry-run: preflight only --------------------------------------------------------------
reset
before="$(tree_state)"
run "$TARGET"
check "dry-run succeeds with valid inputs" '[[ "$RC" -eq 0 && "$OUT" == *DRY-RUN* ]]'
check "dry-run mutates nothing on the remote" '[[ "$(tree_state)" == "$before" ]] && no_mutation'
check "dry-run reports the release target without creating it" '[[ "$OUT" == *"releases/$SHA"* && ! -e "$RELEASE" ]]'
check "dry-run validated through ssh" 'grep -q "^ssh $TARGET" "$CALLS" && grep -q "^loginctl" "$CALLS"'
check "dry-run payload parent is cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'
check "dry-run warns, without refusing, when npm and node are not on the unit PATH" '[[ "$OUT" == *"WARN"*npm* && "$OUT" == *"WARN"*node* ]]'

reset; add_remote_tools
before="$(tree_state)"
run "$TARGET"
check "dry-run reports npm and node when they resolve from the unit PATH" '[[ "$RC" -eq 0 && "$OUT" == *"preflight: npm at $HOME_DIR/.local/bin/npm"* && "$OUT" == *"preflight: node at $HOME_DIR/.local/bin/node"* && "$OUT" != *WARN* ]]'
check "dry-run with tools present still mutates nothing" '[[ "$(tree_state)" == "$before" ]]'

reset
BROKKR_AGENT_CLI_BUSY_UNITS="hugin.service  other.service" run "$TARGET"
check "dry-run reports the normalised busy unit list" '[[ "$RC" -eq 0 && "$OUT" == *"busy units: hugin.service other.service"* ]]'

# --- preflight refusals (both modes) --------------------------------------------------------
refuses() { # name expected-text [args...]
  local name=$1 text=$2; shift 2
  run "$@"
  check "$name (dry-run)" '[[ "$RC" -ne 0 && "$OUT" == *"$text"* ]] && $MUT'
  : >"$CALLS"
  run "$@" --apply
  check "$name (--apply)" '[[ "$RC" -ne 0 && "$OUT" == *"$text"* ]] && $MUT'
}
MUT=no_mutation
reset; export MOCK_ID_ROOT=1
refuses "root runtime user refuses" "must not be root" "$TARGET"
reset; export MOCK_LINGER=no
refuses "disabled user lingering refuses" "linger" "$TARGET"
reset
mkdir -p "$RELEASE"; echo precious >"$RELEASE/marker"
MUT='[[ ! -e "$UNIT_DIR" ]] && ! grep -q "^systemctl" "$CALLS"'
refuses "existing release directory refuses" "release already exists" "$TARGET"
MUT=no_mutation
check "existing release directory is left untouched" '[[ "$(cat "$RELEASE/marker")" == precious && "$(find "$RELEASE" -type f | wc -l | tr -d " ")" -eq 1 ]]'
reset
mkdir -p "$UNIT_DIR"; echo precious >"$SERVICE.previous-$SHA"
MUT='[[ ! -e "$RELEASE" ]] && ! grep -q "^systemctl" "$CALLS"'
refuses "an existing unit backup for this revision refuses" "unit backup brokkr-agent-cli-update.service.previous-$SHA already exists" "$TARGET"
MUT=no_mutation

# --- --apply: install ------------------------------------------------------------------------
reset
mkdir -p "$UNIT_DIR"; printf 'OLD SERVICE\n' >"$SERVICE"
BROKKR_AGENT_CLI_BUSY_UNITS="hugin.service other.service" run "$TARGET" --apply
if [[ -n "${TEST_VERBOSE:-}" ]]; then printf '%s\n' "$OUT"; cat "$SERVICE"; fi
check "--apply succeeds and reports the run result" '[[ "$RC" -eq 0 && "$OUT" == *"result: success"* && "$OUT" == *"OK:"* ]]'
check "release holds exactly the updater, templates, and rendered units" '[[ "$(cd "$RELEASE" && find . -type f | sort | tr "\n" " ")" == "./brokkr-agent-cli-update.service ./brokkr-agent-cli-update.timer ./scripts/agent-cli-update.sh ./systemd/user/brokkr-agent-cli-update.service.in ./systemd/user/brokkr-agent-cli-update.timer " ]]'
check "release files are executable where needed and private" '[[ -x "$RELEASE/scripts/agent-cli-update.sh" && "$(stat -c %a "$RELEASE" 2>/dev/null || stat -f %Lp "$RELEASE")" == 700 ]]'
check "no staging directory is left behind" '[[ -z "$(find "$HOME_DIR/.local/lib/brokkr/agent-cli-update" -maxdepth 1 -name ".stage.*")" ]]'
check "unit renders the exact SHA" 'grep -Fxq "ExecStart=%h/.local/lib/brokkr/agent-cli-update/releases/$SHA/scripts/agent-cli-update.sh" "$SERVICE" && grep -Fxq "WorkingDirectory=%h/.local/lib/brokkr/agent-cli-update/releases/$SHA" "$SERVICE"'
check "unit renders the busy units, quoted so the space survives systemd parsing" 'grep -Fxq "Environment=\"BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service other.service\"" "$SERVICE"'
check "rendered unit has no leftover placeholders, system-only directives, or old layout" '! grep -Eq "@[A-Z_]+@|^OnFailure|^User=|^SupplementaryGroups|/opt/brokkr|/home/brokkr|^ProtectHome|^ProtectSystem" "$SERVICE" && grep -Fxq NoNewPrivileges=yes "$SERVICE" && grep -Fxq PrivateTmp=yes "$SERVICE" && grep -Fxq Nice=10 "$SERVICE" && grep -Fxq IOSchedulingClass=idle "$SERVICE" && grep -Fxq TimeoutStartSec=30min "$SERVICE"'
check "timer is installed from the template" 'cmp -s "$TIMER" "$REPO/systemd/user/brokkr-agent-cli-update.timer"'
check "existing unit is backed up as .previous-<SHA>" '[[ "$(cat "$SERVICE.previous-$SHA")" == "OLD SERVICE" ]]'
check "systemd is reloaded, the timer enabled, then the service run once" '[[ "$(line_of "^systemctl --user daemon-reload")" -lt "$(line_of "^systemctl --user enable --now brokkr-agent-cli-update.timer")" && "$(line_of "^systemctl --user enable --now")" -lt "$(line_of "^systemctl --user start brokkr-agent-cli-update.service")" ]]'
check "the service is started exactly once" '[[ "$(grep -c "^systemctl --user start" "$CALLS")" -eq 1 ]]'
check "output shows the updater state, summary line, and last log line" '[[ "$OUT" == *"updater: result=ok"* && "$OUT" == *"summary: result=ok"* ]]'
check "output prints a concrete rollback recipe" '[[ "$OUT" == *"Rollback"* && "$OUT" == *"systemctl --user disable --now brokkr-agent-cli-update.timer"* && "$OUT" == *"$SERVICE.previous-$SHA"* && "$OUT" == *"releases/$SHA"* ]]'
check "the rollback recipe says agent CLI upgrades are not undone" '[[ "$OUT" == *"not undone"* ]]'
check "apply payload parent is cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'
: >"$CALLS"
run "$TARGET" --apply
check "re-applying the same revision refuses instead of overwriting" '[[ "$RC" -ne 0 && "$OUT" == *"release already exists"* ]] && ! grep -q "^systemctl" "$CALLS"'

reset
run "$TARGET" --apply
check "no busy units configured renders an empty list" '[[ "$RC" -eq 0 ]] && grep -Fxq "Environment=\"BROKKR_AGENT_CLI_BUSY_UNITS=\"" "$SERVICE"'

# --- --apply: failing first run -----------------------------------------------------------------
reset; export MOCK_START_RC=1 MOCK_RESULT=exit-code MOCK_STATE_RESULT=failed
run "$TARGET" --apply
check "a failing first run exits non-zero, says so, and prints the rollback recipe" '[[ "$RC" -ne 0 && "$OUT" == *"result: exit-code"* && "$OUT" == *FAILED* && "$OUT" == *Rollback* ]]'
check "a failing first run leaves the release, units, and timer installed" '[[ -d "$RELEASE" && -f "$SERVICE" && -f "$TIMER" ]] && grep -q "enable --now brokkr-agent-cli-update.timer" "$CALLS"'

reset; export MOCK_NO_STATE=1
run "$TARGET" --apply
check "a first run that writes no state file is a failure" '[[ "$RC" -ne 0 && "$OUT" == *"did not write a fresh state file"* && "$OUT" == *Rollback* ]]'
reset; export MOCK_NO_STATE=1
mkdir -p "$HOME_DIR/.local/state/brokkr"
printf '{"result": "STALE"}\n' >"$HOME_DIR/.local/state/brokkr/agent-cli-update.json"
touch -t 202001010000 "$HOME_DIR/.local/state/brokkr/agent-cli-update.json"
run "$TARGET" --apply
check "a stale state file is not accepted as the first run's output" '[[ "$RC" -ne 0 && "$OUT" == *"did not write a fresh state file"* && "$OUT" != *STALE* ]]'

# --- backup safety: originals stay intact until every backup exists ---------------------------
seed_units() { mkdir -p "$UNIT_DIR"; printf 'OLD SERVICE\n' >"$SERVICE"; printf 'OLD TIMER\n' >"$TIMER"; }
units_intact() { [[ "$(cat "$SERVICE")" == "OLD SERVICE" && "$(cat "$TIMER")" == "OLD TIMER" ]]; }
no_backup_debris() { [[ -z "$(find "$UNIT_DIR" -name '.*backup-tmp*' -print)" ]]; }
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

# --- payload is received and validated before anything changes --------------------------------
reset; export MOCK_TAR_FAIL=1
run "$TARGET" --apply
check "payload extraction failure changes nothing" '[[ "$RC" -ne 0 && "$OUT" == *"payload extraction failed"* ]] && ! grep -q "^systemctl" "$CALLS" && no_release_or_units && [[ "$OUT" == *"no release or installed unit was changed"* ]]'
reset; export MOCK_TAR_EXTRA=1
run "$TARGET" --apply
check "an unexpected extra payload file is refused" '[[ "$RC" -ne 0 && "$OUT" == *"unexpected files"* ]] && ! grep -q "^systemctl" "$CALLS" && no_release_or_units'
reset; export MOCK_TAR_SYMLINK=1
run "$TARGET" --apply
check "a symlink in the payload is refused" '[[ "$RC" -ne 0 && "$OUT" == *"unexpected entry types"* ]] && ! grep -q "^systemctl" "$CALLS" && no_release_or_units'

BAD_REPO="$TMP/bad-repo"
make_repo "$BAD_REPO"
printf 'if then fi\n' >>"$BAD_REPO/scripts/agent-cli-update.sh"
BAD_SHA="$(commit_repo "$BAD_REPO")"
reset
OUT="$(cd "$BAD_REPO" && BROKKR_EXPECTED_SOURCE="$BAD_REPO" BROKKR_EXPECTED_COMMIT="$BAD_SHA" bash "$BAD_REPO/scripts/deploy-agent-cli-update.sh" "$TARGET" --apply 2>&1)"; RC=$?
check "a staged updater that does not parse is refused before any change" '[[ "$RC" -ne 0 && "$OUT" == *"syntax"* ]] && ! grep -q "^systemctl" "$CALLS" && [[ ! -e "$HOME_DIR/.local/lib/brokkr/agent-cli-update/releases/$BAD_SHA" && ! -e "$UNIT_DIR" ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
