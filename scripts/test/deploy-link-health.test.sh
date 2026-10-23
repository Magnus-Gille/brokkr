#!/usr/bin/env bash
# Hermetic gates for scripts/deploy-link-health.sh. ssh, sudo, apt-get, systemctl,
# loginctl, journalctl, and id are fakes on PATH; the "remote" is a temp HOME on
# this machine. No real host, network, or package manager is touched.
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
mkdir -p "$REPO/scripts/lib" "$REPO/network" "$REPO/heimdall" "$REPO/systemd/user" \
  "$HOME_DIR/.config/brokkr" "$BIN" "$TMP/payload-tmp" "$TMP/nosbin"
cp "$ROOT/scripts/deploy-link-health.sh" "$ROOT/scripts/link-health-snapshot.sh" "$REPO/scripts/" 2>/dev/null
cp "$ROOT/scripts/lib/deploy-source.sh" "$REPO/scripts/lib/"
cp "$ROOT/network/check-link-health.py" "$REPO/network/"
cp "$ROOT/heimdall/push.sh" "$REPO/heimdall/"
cp "$ROOT/systemd/user/"brokkr-link-health.* "$REPO/systemd/user/"
echo "unrelated file that must never ship" > "$REPO/README.md"
git init -q "$REPO"; git -C "$REPO" config user.name test; git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add . ; git -C "$REPO" commit -qm fixture
SHA="$(git -C "$REPO" rev-parse HEAD)"
DEPLOY="$REPO/scripts/deploy-link-health.sh"

: >"$CALLS"
cat >"$BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
# usage: ssh [-o opt]... TARGET COMMAND
while [[ "${1:-}" == -o ]]; do shift 2; done
target=$1; shift
printf 'ssh %s\n' "$target" >>"$MOCK_CALLS"
[[ "$#" -eq 1 ]] || exit 64
exec env -u XDG_CONFIG_HOME HOME="$MOCK_REMOTE_HOME" PATH="$MOCK_REMOTE_PATH" \
  BROKKR_ETHTOOL_SEARCH_PATH="$MOCK_NOSBIN" bash -c "$1"
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
cat >"$BIN/sudo" <<'FAKE'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$MOCK_CALLS"
if [[ "${MOCK_sudo_DENY:-0}" == 1 ]]; then echo "sudo: a password is required" >&2; exit 1; fi
if [[ "${1:-}" == -n && "${2:-}" == apt-get ]]; then shift 2; exec "$MOCK_BIN/apt-get" "$@"; fi
echo "fake sudo: unexpected invocation" >&2; exit 99
FAKE
cat >"$BIN/apt-get" <<'FAKE'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >>"$MOCK_CALLS"
[[ "${MOCK_APT_FAIL:-0}" != 1 ]] || exit 100
exec "$MOCK_BIN/mk-ethtool"
FAKE
cat >"$BIN/mk-ethtool" <<'FAKE'
#!/usr/bin/env bash
printf '#!/bin/sh\nexit 0\n' >"$MOCK_BIN/ethtool"
chmod 755 "$MOCK_BIN/ethtool"
FAKE
cat >"$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_CALLS"
case " $* " in
  *" start "*)
    mkdir -p "$HOME/.local/state/brokkr"
    printf '{"checks":[{"name":"link-health","status":"pass","detail":"OK: eth0 1000Mb/s, no drops"}]}\n' >"$HOME/.local/state/brokkr/link-health.json"
    exit "${MOCK_START_RC:-0}" ;;
  *" show "*) printf '%s\n' "${MOCK_RESULT:-success}" ;;
esac
exit 0
FAKE
cat >"$BIN/journalctl" <<'FAKE'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*" >>"$MOCK_CALLS"
echo "brokkr push: 200 (state=pass)"
FAKE
chmod 755 "$BIN/"*

export MOCK_CALLS="$CALLS" MOCK_BIN="$BIN" MOCK_REMOTE_HOME="$HOME_DIR" MOCK_NOSBIN="$TMP/nosbin"
PYDIR="$(dirname "$(command -v python3)")"
export MOCK_REMOTE_PATH="$BIN:$PYDIR:/usr/bin:/bin"
export PATH="$BIN:$PATH" TMPDIR="$TMP/payload-tmp"
unset XDG_CONFIG_HOME
export BROKKR_EXPECTED_SOURCE="$REPO" BROKKR_EXPECTED_COMMIT="$SHA"

DELIVERY_ENV="$HOME_DIR/.config/brokkr/heimdall.env"
CONFIG="$HOME_DIR/.config/brokkr/link-health.conf"
export BROKKR_LINK_HEALTH_DELIVERY_ENV="$DELIVERY_ENV"
unset BROKKR_LINK_HEALTH_CONFIG
TARGET=operator@node-a.example.invalid
UNIT_DIR="$HOME_DIR/.config/systemd/user"
RELEASE="$HOME_DIR/.local/lib/brokkr/link-health/releases/$SHA"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; printf '        rc=%s out=%s\n' "${RC:-}" "${OUT:-}" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() { OUT="$(cd "$REPO" && bash "$DEPLOY" "$@" 2>&1)"; RC=$?; }
line_of() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
tree_state() { { find "$HOME_DIR" | sort; find "$HOME_DIR" -type f -exec cksum {} + | sort; } | cksum; }
good_inputs() {
  printf 'HEIMDALL_HUB_URL=https://heimdall.example.invalid/api/panels\nHEIMDALL_FLEET_TOKEN=secret-sentinel\n' >"$DELIVERY_ENV"
  printf '# fixture\nLINK=eth0,1000\n' >"$CONFIG"
  chmod 600 "$DELIVERY_ENV" "$CONFIG"
}
reset() {
  rm -rf "$HOME_DIR/.local" "$HOME_DIR/.config/systemd" "$HOME_DIR/.config/brokkr/other"
  rm -f "$BIN/ethtool" "$DELIVERY_ENV" "$CONFIG"
  : >"$CALLS"
  unset MOCK_ID_ROOT MOCK_LINGER MOCK_sudo_DENY MOCK_APT_FAIL MOCK_START_RC MOCK_RESULT
  export BROKKR_EXPECTED_COMMIT="$SHA" BROKKR_LINK_HEALTH_DELIVERY_ENV="$DELIVERY_ENV"
  unset BROKKR_LINK_HEALTH_CONFIG
  good_inputs
}
has_ethtool() { "$BIN/mk-ethtool"; }
# No remote state, units, privileged calls, or systemd mutation happened.
no_mutation() { [[ ! -e "$HOME_DIR/.local" && ! -e "$HOME_DIR/.config/systemd" ]] && ! grep -Eq '^(sudo|apt-get|systemctl)' "$CALLS"; }

echo "deploy-link-health.test.sh"
reset
PATH_CHECK="$(PATH="$MOCK_REMOTE_PATH" command -v ethtool || true)"
check "fixture precondition: no ethtool on the simulated remote PATH" '[[ -z "$PATH_CHECK" ]]'

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
unset BROKKR_LINK_HEALTH_DELIVERY_ENV
run "$TARGET"
check "missing delivery env parameter refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_LINK_HEALTH_DELIVERY_ENV is required"* ]] && ! grep -q ssh "$CALLS"'
reset
BROKKR_LINK_HEALTH_DELIVERY_ENV="relative/heimdall.env" run "$TARGET"
check "relative delivery env path refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"invalid BROKKR_LINK_HEALTH_DELIVERY_ENV"* ]] && ! grep -q ssh "$CALLS"'
BROKKR_LINK_HEALTH_CONFIG="/unsafe path/x.conf" run "$TARGET"
check "unsafe config path refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"invalid BROKKR_LINK_HEALTH_CONFIG"* ]] && ! grep -q ssh "$CALLS"'
run
check "missing ssh target refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *usage* ]] && ! grep -q ssh "$CALLS"'
run -oProxyCommand=evil
check "option-shaped ssh target refuses before ssh" '[[ "$RC" -ne 0 ]] && ! grep -q ssh "$CALLS"'
run "$TARGET" --bogus
check "unknown option refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *usage* ]] && ! grep -q ssh "$CALLS"'

# --- dry-run: preflight only --------------------------------------------------------------
reset; has_ethtool
before="$(tree_state)"
run "$TARGET"
check "dry-run succeeds with valid inputs" '[[ "$RC" -eq 0 && "$OUT" == *DRY-RUN* ]]'
check "dry-run mutates nothing on the remote" '[[ "$(tree_state)" == "$before" ]] && no_mutation'
check "dry-run reports the release target without creating it" '[[ "$OUT" == *"releases/$SHA"* && ! -e "$RELEASE" ]]'
check "dry-run validated through ssh" 'grep -q "^ssh $TARGET" "$CALLS" && grep -q "^loginctl" "$CALLS"'
check "dry-run never prints secret values" '[[ "$OUT" != *secret-sentinel* ]]'
check "dry-run payload parent is cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'

reset
run "$TARGET"
check "dry-run reports missing ethtool without installing" '[[ "$RC" -eq 0 && "$OUT" == *"ethtool"*"missing"* && "$OUT" == *"sudo -n apt-get install -y --no-install-recommends ethtool"* ]] && no_mutation'

# --- preflight refusals (both modes) --------------------------------------------------------
MUT=no_mutation
no_installs() { [[ ! -e "$UNIT_DIR" ]] && ! grep -Eq '^(sudo|apt-get|systemctl)' "$CALLS"; }
refuses() { # name expected-text [args...]
  local name=$1 text=$2; shift 2
  run "$@"
  check "$name (dry-run)" '[[ "$RC" -ne 0 && "$OUT" == *"$text"* ]] && $MUT && [[ "$OUT" != *secret-sentinel* ]]'
  : >"$CALLS"
  run "$@" --apply
  check "$name (--apply)" '[[ "$RC" -ne 0 && "$OUT" == *"$text"* ]] && $MUT && [[ "$OUT" != *secret-sentinel* ]]'
}
reset; has_ethtool; rm -f "$DELIVERY_ENV"
refuses "missing delivery env refuses" "delivery env" "$TARGET"
reset; has_ethtool; rm -f "$DELIVERY_ENV"; printf 'x\n' >"$HOME_DIR/.config/brokkr/other"; ln -s "$HOME_DIR/.config/brokkr/other" "$DELIVERY_ENV"
refuses "symlinked delivery env refuses" "delivery env" "$TARGET"
reset; has_ethtool; chmod 644 "$DELIVERY_ENV"
refuses "world-readable delivery env refuses" "delivery env" "$TARGET"
reset; has_ethtool; chmod 400 "$DELIVERY_ENV"
refuses "mode-400 delivery env refuses (exactly 600 required)" "delivery env" "$TARGET"
reset; has_ethtool; printf 'HEIMDALL_HUB_URL=https://heimdall.example.invalid/api/panels\n' >"$DELIVERY_ENV"
refuses "delivery env without a token refuses" "HEIMDALL_FLEET_TOKEN" "$TARGET"
reset; has_ethtool; printf 'HEIMDALL_HUB_URL=\nHEIMDALL_FLEET_TOKEN=secret-sentinel\n' >"$DELIVERY_ENV"
refuses "delivery env with an empty URL refuses" "HEIMDALL_HUB_URL" "$TARGET"
reset; has_ethtool; printf 'HEIMDALL_HUB_URL=https://heimdall.example.invalid/api/panels\nHEIMDALL_FLEET_TOKEN=""\n' >"$DELIVERY_ENV"
refuses "delivery env with a quoted-empty token refuses" "HEIMDALL_FLEET_TOKEN" "$TARGET"
reset; has_ethtool; rm -f "$CONFIG"
refuses "missing link config refuses" "link config" "$TARGET"
reset; has_ethtool; printf 'LINK=eth0,1000\nSURPRISE=1\n' >"$CONFIG"
refuses "link config rejected by the probe parser refuses" "link config" "$TARGET"
reset; has_ethtool; chmod 644 "$CONFIG"
refuses "world-readable link config refuses" "link config" "$TARGET"
reset; has_ethtool; rm -f "$CONFIG"; printf 'x\n' >"$HOME_DIR/.config/brokkr/other"; ln -s "$HOME_DIR/.config/brokkr/other" "$CONFIG"
refuses "symlinked link config refuses" "link config" "$TARGET"
reset; has_ethtool; export MOCK_ID_ROOT=1
refuses "root runtime user refuses" "must not be root" "$TARGET"
reset; has_ethtool; export MOCK_LINGER=no
refuses "disabled user lingering refuses" "linger" "$TARGET"
reset; has_ethtool
mkdir -p "$RELEASE"; echo precious >"$RELEASE/marker"
MUT=no_installs
refuses "existing release directory refuses" "release already exists" "$TARGET"
MUT=no_mutation
check "existing release directory is left untouched" '[[ "$(cat "$RELEASE/marker")" == precious && "$(find "$RELEASE" -type f | wc -l | tr -d " ")" -eq 1 ]]'

# --- explicit link config path ---------------------------------------------------------------
reset; has_ethtool
mv "$CONFIG" "$HOME_DIR/.config/brokkr/custom.conf"
BROKKR_LINK_HEALTH_CONFIG="$HOME_DIR/.config/brokkr/custom.conf" run "$TARGET"
check "explicit BROKKR_LINK_HEALTH_CONFIG is validated instead of the default" '[[ "$RC" -eq 0 ]]'
rm -f "$HOME_DIR/.config/brokkr/custom.conf"

# --- --apply: ethtool ------------------------------------------------------------------------
reset
run "$TARGET" --apply
check "--apply installs missing ethtool via sudo -n apt-get" '[[ "$RC" -eq 0 ]] && grep -Fxq "sudo -n apt-get install -y --no-install-recommends ethtool" "$CALLS"'
check "ethtool install happens before any systemd mutation" '[[ "$(line_of "^apt-get")" -lt "$(line_of "^systemctl --user daemon-reload")" ]]'

reset; export MOCK_sudo_DENY=1
run "$TARGET" --apply
check "--apply fails closed when sudo -n is denied" '[[ "$RC" -ne 0 && "$OUT" == *ethtool* ]] && [[ ! -e "$HOME_DIR/.local" && ! -e "$UNIT_DIR" ]] && ! grep -Eq "^(apt-get|systemctl)" "$CALLS"'
reset; export MOCK_APT_FAIL=1
run "$TARGET" --apply
check "--apply fails closed when the apt install fails" '[[ "$RC" -ne 0 && "$OUT" == *ethtool* ]] && [[ ! -e "$HOME_DIR/.local" && ! -e "$UNIT_DIR" ]] && ! grep -q "^systemctl" "$CALLS"'
reset; has_ethtool
run "$TARGET" --apply
check "--apply does not touch sudo when ethtool is present" '[[ "$RC" -eq 0 ]] && ! grep -Eq "^(sudo|apt-get)" "$CALLS"'

# --- --apply: install ------------------------------------------------------------------------
reset; has_ethtool
mkdir -p "$UNIT_DIR"; printf 'OLD SERVICE\n' >"$UNIT_DIR/brokkr-link-health.service"
run "$TARGET" --apply
SERVICE="$UNIT_DIR/brokkr-link-health.service"
if [[ -n "${TEST_VERBOSE:-}" ]]; then printf '%s\n' "$OUT"; cat "$SERVICE"; fi
check "--apply succeeds and reports the run result" '[[ "$RC" -eq 0 && "$OUT" == *"result: success"* ]]'
check "release holds exactly the probe, runner, push helper, templates, and rendered units" '[[ "$(cd "$RELEASE" && find . -type f | sort | tr "\n" " ")" == "./brokkr-link-health.service ./brokkr-link-health.timer ./heimdall/push.sh ./network/check-link-health.py ./scripts/link-health-snapshot.sh ./systemd/user/brokkr-link-health.service.in ./systemd/user/brokkr-link-health.timer " ]]'
check "release files are executable where needed and private" '[[ -x "$RELEASE/scripts/link-health-snapshot.sh" && -x "$RELEASE/heimdall/push.sh" && "$(stat -c %a "$RELEASE" 2>/dev/null || stat -f %Lp "$RELEASE")" == 700 ]]'
check "no staging directory is left behind" '[[ -z "$(find "$HOME_DIR/.local/lib/brokkr/link-health" -maxdepth 1 -name ".stage.*")" ]]'
check "unit renders the exact SHA, delivery env, and config" 'grep -Fxq "ExecStart=%h/.local/lib/brokkr/link-health/releases/$SHA/scripts/link-health-snapshot.sh" "$SERVICE" && grep -Fxq "WorkingDirectory=%h/.local/lib/brokkr/link-health/releases/$SHA" "$SERVICE" && grep -Fxq "EnvironmentFile=$DELIVERY_ENV" "$SERVICE" && grep -Fxq "Environment=BROKKR_LINK_HEALTH_CONFIG=$CONFIG" "$SERVICE"'
check "rendered unit has no leftover placeholders, system-only directives, or old layout" '! grep -Eq "@[A-Z_]+@|^OnFailure|^User=|^SupplementaryGroups|/opt/brokkr|/home/brokkr" "$SERVICE" && grep -Fxq NoNewPrivileges=yes "$SERVICE" && grep -Fxq PrivateTmp=yes "$SERVICE"'
check "timer is installed from the template" 'cmp -s "$UNIT_DIR/brokkr-link-health.timer" "$REPO/systemd/user/brokkr-link-health.timer"'
check "existing unit is backed up as .previous-<SHA>" '[[ "$(cat "$SERVICE.previous-$SHA")" == "OLD SERVICE" ]]'
check "systemd is reloaded, the timer enabled, then the service run once" '[[ "$(line_of "^systemctl --user daemon-reload")" -lt "$(line_of "^systemctl --user enable --now brokkr-link-health.timer")" && "$(line_of "^systemctl --user enable --now")" -lt "$(line_of "^systemctl --user start brokkr-link-health.service")" ]]'
check "output shows the probe line and last log line" '[[ "$OUT" == *"probe: OK: eth0 1000Mb/s, no drops"* && "$OUT" == *"brokkr push: 200 (state=pass)"* ]]'
check "output prints a concrete rollback recipe" '[[ "$OUT" == *"Rollback"* && "$OUT" == *"systemctl --user disable --now brokkr-link-health.timer"* && "$OUT" == *"$SERVICE.previous-$SHA"* && "$OUT" == *"releases/$SHA"* ]]'
check "apply never prints secret values" '[[ "$OUT" != *secret-sentinel* ]] && ! grep -Fq secret-sentinel "$CALLS"'
check "apply payload parent is cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'
check "the state directory exists for the sandboxed unit" '[[ -d "$HOME_DIR/.local/state/brokkr" ]]'
: >"$CALLS"
run "$TARGET" --apply
check "re-applying the same revision refuses instead of overwriting" '[[ "$RC" -ne 0 && "$OUT" == *"release already exists"* ]] && ! grep -q "^systemctl" "$CALLS"'

# --- --apply: other delivery env name and failing service -------------------------------------------
reset; has_ethtool
mv "$DELIVERY_ENV" "$HOME_DIR/.config/brokkr/env"
BROKKR_LINK_HEALTH_DELIVERY_ENV="$HOME_DIR/.config/brokkr/env" run "$TARGET" --apply
check "the delivery env path is a parameter (env instead of heimdall.env)" '[[ "$RC" -eq 0 ]] && grep -Fxq "EnvironmentFile=$HOME_DIR/.config/brokkr/env" "$UNIT_DIR/brokkr-link-health.service"'
rm -f "$HOME_DIR/.config/brokkr/env"

reset; has_ethtool; export MOCK_START_RC=1 MOCK_RESULT=exit-code
run "$TARGET" --apply
check "a failing first run exits non-zero but still prints the rollback recipe" '[[ "$RC" -ne 0 && "$OUT" == *"result: exit-code"* && "$OUT" == *Rollback* ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

