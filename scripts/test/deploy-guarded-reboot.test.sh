#!/usr/bin/env bash
# Hermetic gates for scripts/deploy-guarded-reboot.sh. ssh, sudo, systemctl, loginctl, id and uname
# are fakes on PATH; the "remote" is a temp HOME on this machine. The released job really runs once
# (check --report-only and status) against fixture seams; the reboot service is never started and
# nothing is rebooted, staged or sent. No real host or network is touched.
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

REPO="$TMP/repo"; HOME_DIR="$TMP/home"; BIN="$TMP/bin"; CALLS="$TMP/calls"; MOCK="$TMP/mock"
AUDIT_PARENT="$TMP/varlib/brokkr"; AUDIT_DIR="$AUDIT_PARENT/guarded-reboot"; AUDIT_FILE="$AUDIT_DIR/audit.jsonl"
BOOT="$TMP/boot"; BOOTID="$TMP/boot-id"; PENDING="$TMP/eeprom-pending"; CRYPTTAB="$TMP/crypttab"
mkdir -p "$HOME_DIR" "$BIN" "$TMP/payload-tmp" "$BOOT" "$MOCK"

make_repo() { # dir
  local r=$1
  mkdir -p "$r/scripts/lib" "$r/systemd/user"
  cp "$ROOT/scripts/deploy-guarded-reboot.sh" "$ROOT/scripts/guarded-reboot.sh" "$r/scripts/" 2>/dev/null
  cp "$ROOT/scripts/lib/deploy-source.sh" "$ROOT/scripts/lib/notify.sh" "$r/scripts/lib/"
  cp "$ROOT/systemd/user/"brokkr-guarded-reboot.* "$ROOT/systemd/user/"brokkr-post-boot-check.* \
    "$ROOT/systemd/user/"brokkr-post-update-health.* "$r/systemd/user/" 2>/dev/null
  echo "unrelated file that must never ship" >"$r/README.md"
  fgit init -q "$r"; fgit -C "$r" config user.name test; fgit -C "$r" config user.email test@example.invalid
}
# Fixture git never reads the user's global or system config, so no hook, template or signing
# program of theirs runs while the test builds its repositories.
fgit() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TEMPLATE_DIR="$TMP/empty-git-template" \
    git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c tag.gpgsign=false "$@"
}
mkdir -p "$TMP/empty-git-template"
commit_repo() { fgit -C "$1" add . ; fgit -C "$1" commit -qm fixture; fgit -C "$1" rev-parse HEAD; }
make_repo "$REPO"
SHA="$(commit_repo "$REPO")"
DEPLOY="$REPO/scripts/deploy-guarded-reboot.sh"
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
cat >"$BIN/uname" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "${MOCK_UNAME_S:-Linux}"; exit 0 ;;
  -r) echo 7.0.0-38-generic; exit 0 ;;
esac
exec /usr/bin/uname "$@"
FAKE
# sudo: the fixed argument lists only. install -d really creates the directories (under the caller's
# umask, like the real thing); tee -a really appends; the reboot is recorded and must never happen.
cat >"$BIN/sudo" <<'FAKE'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$MOCK_CALLS"
[[ "${1:-}" == -n ]] || { echo "sudo: stub requires -n" >&2; exit 2; }
shift
case "$*" in
  true) [[ "${MOCK_SUDO_FAIL:-0}" != 1 ]] || exit 1; exit 0 ;;
  "install -d -m 0755 "*)
    shift 3
    [[ "${MOCK_INSTALL_FAIL:-0}" != 1 ]] || exit 1
    exec /usr/bin/install -d -m 0755 "$@" ;;
  "tee -a "*)
    tee -a "$3" || exit 1
    if [[ "${MOCK_AUDIT_PRIVATE:-0}" == 1 ]]; then chmod 600 "$3"; fi
    exit 0 ;;
  "systemctl disable rpi-eeprom-update.service") echo disabled >>"$MOCK_DIR/eeprom-service"; exit 0 ;;
  "rpi-eeprom-update -j -m "*)
    printf '{"EXITCODE": "EXIT_SUCCESS", "BOOTLOADER_CURRENT": 1700000000, "BOOTLOADER_LATEST": 1700000000}\n' >"$5"
    exit 0 ;;
  "systemctl reboot") echo REBOOT >>"$MOCK_DIR/reboot-calls"; exit 0 ;;
  *) echo "sudo $*" >>"$MOCK_DIR/unexpected"; exit 99 ;;
esac
FAKE
cat >"$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_CALLS"
scope=system
if [[ "${1:-}" == --user ]]; then scope=user; shift; fi
case "${1:-}" in
  is-enabled) echo "${MOCK_EEPROM_SERVICE:-enabled}"; [[ "${MOCK_EEPROM_SERVICE:-enabled}" == enabled ]]; exit $? ;;
  is-active) echo inactive; exit 3 ;;
  list-units) printf 'alpha.service loaded active running Fixture\n'; exit 0 ;;
  --failed) exit 0 ;;
  show) echo inactive; exit 0 ;;
  daemon-reload|enable) exit 0 ;;
  start|stop) echo "systemctl $scope $*" >>"$MOCK_DIR/unexpected"; exit 99 ;;
esac
echo "systemctl $*" >>"$MOCK_DIR/unexpected"
exit 99
FAKE
# Fault injection: cp/mv fail when the destination matches; tar can fail, add a file, or add a
# symlink when it extracts the payload on stdin.
cat >"$BIN/cp" <<'FAKE'
#!/usr/bin/env bash
last=${*: -1}
if [[ -n "${MOCK_CP_FAIL:-}" && "$last" == *"$MOCK_CP_FAIL"* ]]; then echo "cp: injected failure" >&2; exit 1; fi
exec /bin/cp "$@"
FAKE
cat >"$BIN/mv" <<'FAKE'
#!/usr/bin/env bash
last=${*: -1}
if [[ -n "${MOCK_MV_FAIL:-}" && "$last" == *"$MOCK_MV_FAIL"* ]]; then echo "mv: injected failure" >&2; exit 1; fi
exec /bin/mv "$@"
FAKE
cat >"$BIN/tar" <<'FAKE'
#!/usr/bin/env bash
a1=${1:-}
a2=${2:-}
if [[ "$a1" == -xf && "$a2" == - ]]; then
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

# --- harness -------------------------------------------------------------------------------------
mkdir -p "$TMP/eeprom-bin"
printf '#!/usr/bin/env bash\necho "rpi-eeprom-update runs only through the sudo stub here" >&2\nexit 99\n' >"$TMP/eeprom-bin/rpi-eeprom-update"
chmod 755 "$TMP/eeprom-bin/rpi-eeprom-update"
export MOCK_CALLS="$CALLS" MOCK_DIR="$MOCK" MOCK_REMOTE_HOME="$HOME_DIR" MOCK_REMOTE_PATH="$BIN:/usr/bin:/bin"
export PATH="$BIN:$PATH" TMPDIR="$TMP/payload-tmp" BROKKR_DEPLOY_PATH_PREFIX="$BIN"
unset XDG_CONFIG_HOME

TARGET=operator@node-a.example.invalid
UNIT_DIR="$HOME_DIR/.config/systemd/user"
RELEASE="$HOME_DIR/.local/lib/brokkr/guarded-reboot/releases/$SHA"
STATE_FILE="$HOME_DIR/.local/state/brokkr/guarded-reboot.json"
SVC="$UNIT_DIR/brokkr-guarded-reboot.service"; TMR="$UNIT_DIR/brokkr-guarded-reboot.timer"
PB_SVC="$UNIT_DIR/brokkr-post-boot-check.service"; PB_TMR="$UNIT_DIR/brokkr-post-boot-check.timer"
H_SVC="$UNIT_DIR/brokkr-post-update-health.service"; H_TMR="$UNIT_DIR/brokkr-post-update-health.timer"
ALL_UNITS="brokkr-guarded-reboot.service brokkr-guarded-reboot.timer brokkr-post-boot-check.service brokkr-post-boot-check.timer brokkr-post-update-health.service brokkr-post-update-health.timer"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; printf '        rc=%s out=%s\n' "${RC:-}" "${OUT:-}" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
skip() { printf '  SKIP  %s\n' "$1"; }
run() { OUT="$(cd "$REPO" && bash "$DEPLOY" "$@" 2>&1)"; RC=$?; }
line_of() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
tree_state() { { find "$HOME_DIR" "$TMP/varlib" | sort; find "$HOME_DIR" "$TMP/varlib" -type f -exec cksum {} + | sort; } | cksum; }
reset() {
  local v
  rm -rf "$HOME_DIR/.local" "$HOME_DIR/.config" "$HOME_DIR/repos" "$TMP/varlib" "$MOCK" "$BOOT" "$PENDING" "$CRYPTTAB" "$TMP/notify.env"
  mkdir -p "$MOCK" "$BOOT" "$TMP/varlib" "$HOME_DIR"
  : >"$CALLS"
  for v in $(compgen -e | grep -E '^(MOCK_[A-Z_]+|BROKKR_GUARDED_REBOOT_[A-Z_]+)$' || true); do
    case "$v" in MOCK_CALLS|MOCK_DIR|MOCK_REMOTE_HOME|MOCK_REMOTE_PATH) ;; *) unset "$v" ;; esac
  done
  unset RATATOSKR_URL RATATOSKR_SEND_API_KEY TELEGRAM_ALLOWED_USERS TELEGRAM_BOT_TOKEN
  rm -f "$BIN/rpi-eeprom-update"
  export RATATOSKR_ENV="$TMP/no-ratatoskr.env" NOTIFY_ENV="$TMP/no-notify.env"
  export BROKKR_AUDIT_PARENT="$AUDIT_PARENT" BROKKR_GUARDED_REBOOT_AUDIT="$AUDIT_FILE" BROKKR_BOOT_DIR="$BOOT"
  export BROKKR_BOOT_ID_FILE="$BOOTID" BROKKR_EEPROM_PENDING_FLAG="$PENDING" BROKKR_CRYPTTAB="$CRYPTTAB"
  export BROKKR_KILL_SWITCH="$TMP/kill-switch" BROKKR_REBOOT_REQUIRED_FILE="$TMP/reboot-required"
  : >"$BOOT/vmlinuz-7.0.0-38-generic"
  printf 'aaaaaaaa-0000-4000-8000-000000000001\n' >"$BOOTID"
  export BROKKR_EXPECTED_SOURCE="$REPO" BROKKR_EXPECTED_COMMIT="$SHA"
}
with_notify() { printf 'TELEGRAM_ALLOWED_USERS=123456789\nTELEGRAM_BOT_TOKEN=fake-bot-token\n' >"$TMP/notify.env"; export NOTIFY_ENV="$TMP/notify.env"; }
with_eeprom() { ln -sf "$TMP/eeprom-bin/rpi-eeprom-update" "$BIN/rpi-eeprom-update"; }
real_eeprom() { PATH=/usr/bin:/bin command -v rpi-eeprom-update >/dev/null 2>&1; }
# Nothing on the node was installed, enabled, created or started; read-only probes are fine.
no_mutation() {
  [[ ! -e "$HOME_DIR/.local" && ! -e "$HOME_DIR/.config/systemd" && ! -e "$AUDIT_PARENT" ]] \
    && ! grep -Eq '^systemctl --user (daemon-reload|enable|start|stop|disable)|^sudo -n (install|tee|systemctl|rpi-eeprom)' "$CALLS" \
    && [[ ! -s "$MOCK/eeprom-service" ]]
}
no_unexpected() { [[ ! -s "$MOCK/unexpected" ]]; }
never_rebooted() { [[ ! -s "$MOCK/reboot-calls" ]] && ! grep -Eq '^sudo -n systemctl reboot|^systemctl --user (start|restart)' "$CALLS"; }

echo "deploy-guarded-reboot.test.sh"
reset

# --- local gates: nothing reaches ssh -------------------------------------------------------------
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
refuses_before_ssh() { # name text env-assignment...
  local name=$1 text=$2
  shift 2
  env "$@" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$REPO" "$DEPLOY" "$TARGET" >"$TMP/out.txt" 2>&1
  RC=$?; OUT="$(cat "$TMP/out.txt")"
  check "$name" '[[ "$RC" -ne 0 && "$OUT" == *"$text"* ]] && ! grep -q ssh "$CALLS"'
}
for v in reboot-now Report; do refuses_before_ssh "invalid mode '$v' refuses before ssh" "BROKKR_GUARDED_REBOOT_MODE" "BROKKR_GUARDED_REBOOT_MODE=$v"; done
for v in 25:00 3:30 03:60 noon 0330 "03:30 "; do refuses_before_ssh "invalid window '$v' refuses before ssh" "BROKKR_GUARDED_REBOOT_WINDOW" "BROKKR_GUARDED_REBOOT_WINDOW=$v"; done
for v in abc 241 -1 1.5; do refuses_before_ssh "invalid spread '$v' refuses before ssh" "BROKKR_GUARDED_REBOOT_SPREAD" "BROKKR_GUARDED_REBOOT_SPREAD=$v"; done
for v in 'bad' 'x;y.service' 'a.timer' '-x.service' '../x.service' '$(id).service' '*.service'; do
  refuses_before_ssh "invalid busy unit '$v' refuses before ssh" "BROKKR_GUARDED_REBOOT_BUSY_UNITS" "BROKKR_GUARDED_REBOOT_BUSY_UNITS=hugin.service $v"
done
for v in '-bad' 'x;y' '$(id)' 'a/b' '.x' 'a b!'; do
  refuses_before_ssh "invalid peer '$v' refuses before ssh" "BROKKR_GUARDED_REBOOT_PEERS" "BROKKR_GUARDED_REBOOT_PEERS=node-b.example $v"
done
for v in abc -1 1.2.3 99999; do refuses_before_ssh "invalid max load '$v' refuses before ssh" "BROKKR_GUARDED_REBOOT_MAX_LOAD" "BROKKR_GUARDED_REBOOT_MAX_LOAD=$v"; done
for v in abc 1441 -5; do refuses_before_ssh "invalid terminal idle '$v' refuses before ssh" "BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN" "BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN=$v"; done
for v in abc 0 366; do refuses_before_ssh "invalid alert-after '$v' refuses before ssh" "BROKKR_GUARDED_REBOOT_ALERT_AFTER" "BROKKR_GUARDED_REBOOT_ALERT_AFTER=$v"; done
BROKKR_GUARDED_REBOOT_BUSY_UNITS=$'hugin.service\nother.service' run "$TARGET"
check "a newline inside the busy unit list refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"invalid BROKKR_GUARDED_REBOOT_BUSY_UNITS"* ]] && ! grep -q ssh "$CALLS"'
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

# --- dry-run: preflight only -------------------------------------------------------------------------
reset
before="$(tree_state)"
run "$TARGET"
check "dry-run succeeds with valid inputs" '[[ "$RC" -eq 0 && "$OUT" == *DRY-RUN* ]]'
check "dry-run mutates nothing on the remote" '[[ "$(tree_state)" == "$before" ]] && no_mutation && never_rebooted'
check "dry-run reports the release target without creating it" '[[ "$OUT" == *"releases/$SHA"* && ! -e "$RELEASE" ]]'
check "dry-run validated through ssh, including lingering and passwordless sudo" 'grep -q "^ssh $TARGET" "$CALLS" && grep -q "^loginctl" "$CALLS" && grep -q "^sudo -n true$" "$CALLS"'
check "dry-run payload parent is cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'
check "dry-run defaults to report mode, window 03:30, spread 45" '[[ "$OUT" == *"mode report, window 03:30 (spread 45 min)"* ]]'
check "dry-run warns, without refusing, that no notify configuration exists in report mode" '[[ "$OUT" == *"WARN: no notify configuration"* ]]'
check "dry-run says the audit parent will be created" '[[ "$OUT" == *"the parent will be created, mode 0755"* ]]'
check "dry-run reports a host without crypttab" '[[ "$OUT" == *"unlock assessment: no "* ]]'
check "dry-run on a host without rpi-eeprom-update prints nothing about it" '[[ "$OUT" != *"rpi-eeprom-update present"* ]]'

reset; with_notify; BROKKR_GUARDED_REBOOT_WINDOW=04:10 BROKKR_GUARDED_REBOOT_SPREAD=20 BROKKR_GUARDED_REBOOT_BUSY_UNITS="hugin.service  other.service" BROKKR_GUARDED_REBOOT_PEERS="node-b.example" run "$TARGET"
check "dry-run reports the notify configuration, the normalised busy units, the peers, window and spread" '[[ "$RC" -eq 0 && "$OUT" == *"notify configuration present"* && "$OUT" == *"busy units: hugin.service other.service"* && "$OUT" == *"peers: node-b.example"* && "$OUT" == *"window 04:10 (spread 20 min)"* ]]'
reset; printf 'TELEGRAM_ALLOWED_USERS=123,456\nRATATOSKR_URL=http://ratatoskr.example/api/send\n' >"$TMP/notify.env"; export NOTIFY_ENV="$TMP/notify.env"; run "$TARGET"
check "notify discovery: a Ratatoskr URL with a chat id counts, the first chat id is used" '[[ "$OUT" == *"notify configuration present"* ]]'
reset; printf 'TELEGRAM_ALLOWED_USERS=abc\nTELEGRAM_BOT_TOKEN=x\n' >"$TMP/notify.env"; export NOTIFY_ENV="$TMP/notify.env"; run "$TARGET"
check "notify discovery: a non-numeric chat id does not count" '[[ "$OUT" == *"WARN: no notify configuration"* ]]'
reset; printf 'TELEGRAM_ALLOWED_USERS=123\n' >"$TMP/notify.env"; export NOTIFY_ENV="$TMP/notify.env"; run "$TARGET"
check "notify discovery: a chat id without a destination does not count" '[[ "$OUT" == *"WARN: no notify configuration"* ]]'
reset; TELEGRAM_ALLOWED_USERS=123 TELEGRAM_BOT_TOKEN=tok run "$TARGET"
check "notify discovery: the environment counts too" '[[ "$OUT" == *"notify configuration present"* ]]'
reset; mkdir -p "$HOME_DIR/repos/ratatoskr"; printf 'TELEGRAM_ALLOWED_USERS=123\nTELEGRAM_BOT_TOKEN=tok\n' >"$HOME_DIR/repos/ratatoskr/.env"; unset RATATOSKR_ENV NOTIFY_ENV; run "$TARGET"
check "notify discovery: the Ratatoskr .env under HOME counts" '[[ "$OUT" == *"notify configuration present"* ]]'

reset; printf 'root UUID=1 none luks\ndata UUID=2 none luks,tpm2-device=auto\n' >"$CRYPTTAB"; run "$TARGET"
check "unlock assessment: a passphrase-only volume is reported with the consequence" '[[ "$RC" -eq 0 && "$OUT" == *"WARN: unlock assessment: crypttab entries needing an interactive passphrase at boot: root"* && "$OUT" == *"defer every reboot"* ]]'
reset; printf 'root UUID=1 none luks,tpm2-device=auto\nswap /dev/sda3 /dev/urandom swap\nx UUID=3 none luks,noauto\n' >"$CRYPTTAB"; run "$TARGET"
check "unlock assessment: unattended and noauto volumes are fine" '[[ "$OUT" == *"every volume in "*"unlocks unattended or is noauto"* ]]'

if real_eeprom; then
  skip "stock EEPROM service tests (a real rpi-eeprom-update is on this machine PATH)"
else
  reset; with_eeprom; run "$TARGET"
  check "dry-run reports the stock EEPROM service and that apply disables it, without touching it" '[[ "$RC" -eq 0 && "$OUT" == *"rpi-eeprom-update present; the stock rpi-eeprom-update.service is enabled"* && "$OUT" == *"--apply disables it"* ]] && no_mutation'
  reset; with_eeprom; MOCK_EEPROM_SERVICE=disabled run "$TARGET"
  check "dry-run reports an already disabled stock EEPROM service" '[[ "$OUT" == *"stock rpi-eeprom-update.service is disabled"* && "$OUT" != *"--apply disables it"* ]]'
fi

# --- reboot mode needs a working alert path ------------------------------------------------------------
reset; BROKKR_GUARDED_REBOOT_MODE=reboot run "$TARGET"
check "reboot mode refuses without notify configuration (dry-run)" '[[ "$RC" -ne 0 && "$OUT" == *"reboot mode needs a working alert path"* ]] && no_mutation'
: >"$CALLS"; BROKKR_GUARDED_REBOOT_MODE=reboot run "$TARGET" --apply
check "reboot mode refuses without notify configuration (--apply) and changes nothing" '[[ "$RC" -ne 0 && "$OUT" == *"reboot mode needs a working alert path"* ]] && no_mutation && [[ ! -e "$RELEASE" ]]'
reset; with_notify; BROKKR_GUARDED_REBOOT_MODE=reboot run "$TARGET"
check "reboot mode passes the preflight with notify configuration" '[[ "$RC" -eq 0 && "$OUT" == *"mode reboot"* ]]'

# --- preflight refusals (both modes) -----------------------------------------------------------------------
refuses() { # name expected-text [args...]
  local name=$1 text=$2; shift 2
  run "$@"
  check "$name (dry-run)" '[[ "$RC" -ne 0 && "$OUT" == *"$text"* ]] && $MUT'
  : >"$CALLS"
  run "$@" --apply
  check "$name (--apply)" '[[ "$RC" -ne 0 && "$OUT" == *"$text"* ]] && $MUT'
}
MUT=no_mutation
no_installs() { [[ ! -e "$UNIT_DIR" ]] && ! grep -Eq "^systemctl --user (daemon-reload|enable)" "$CALLS"; }
no_unit_changes() { [[ ! -e "$RELEASE" ]] && ! grep -Eq "^systemctl --user (daemon-reload|enable)" "$CALLS"; }
reset; export MOCK_ID_ROOT=1
refuses "root runtime user refuses" "must not be root" "$TARGET"
reset; export MOCK_LINGER=no
refuses "disabled user lingering refuses" "linger" "$TARGET"
reset; export MOCK_UNAME_S=Darwin
refuses "a non-Linux node refuses" "Linux only" "$TARGET"
reset; export MOCK_SUDO_FAIL=1
refuses "missing passwordless sudo refuses" "passwordless sudo is required" "$TARGET"
reset
mkdir -p "$RELEASE"; echo precious >"$RELEASE/marker"
MUT=no_installs
refuses "existing release directory refuses" "release already exists" "$TARGET"
MUT=no_mutation
check "existing release directory is left untouched" '[[ "$(cat "$RELEASE/marker")" == precious && "$(find "$RELEASE" -type f | wc -l | tr -d " ")" -eq 1 ]]'
reset
mkdir -p "$UNIT_DIR"; echo precious >"$SVC.previous-$SHA"
MUT=no_unit_changes
refuses "an existing unit backup for this revision refuses" "unit backup brokkr-guarded-reboot.service.previous-$SHA already exists" "$TARGET"
MUT=no_mutation

# The audit directories must be searchable by an unprivileged reader.
reset; mkdir -p "$AUDIT_PARENT"; chmod 700 "$AUDIT_PARENT"
MUT=no_installs
refuses "an existing audit parent that is not world-searchable refuses" "is not world-searchable" "$TARGET"
check "the closed audit parent is not chmod-ed" '[[ "$(mode_of "$AUDIT_PARENT")" == 700 ]] && ! grep -q "^sudo -n install" "$CALLS"'
MUT=no_mutation
reset; mkdir -p "$TMP/real-parent"; ln -s "$TMP/real-parent" "$AUDIT_PARENT"
MUT=no_installs
refuses "an audit parent that is a symlink refuses" "is a symlink" "$TARGET"
MUT=no_mutation
rm -rf "$TMP/real-parent"

# --- --apply: install --------------------------------------------------------------------------------------
reset
mkdir -p "$UNIT_DIR"; printf 'OLD SERVICE\n' >"$SVC"
BROKKR_GUARDED_REBOOT_WINDOW=04:10 BROKKR_GUARDED_REBOOT_SPREAD=20 BROKKR_GUARDED_REBOOT_BUSY_UNITS="hugin.service other.service" \
  BROKKR_GUARDED_REBOOT_PEERS="node-b.example" BROKKR_GUARDED_REBOOT_MAX_LOAD=1.5 BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN=30 \
  BROKKR_GUARDED_REBOOT_ALERT_AFTER=2 run "$TARGET" --apply
if [[ -n "${TEST_VERBOSE:-}" ]]; then printf '%s\n' "$OUT"; cat "$SVC" "$TMR"; fi
check "--apply succeeds and reports the first run" '[[ "$RC" -eq 0 && "$OUT" == *"OK: guarded reboot installed in report mode"* && "$OUT" == *"first run: check --report-only"* ]]'
check "release holds exactly the job, the notify helper, the templates and the rendered units" '[[ "$(cd "$RELEASE" && find . -type f | sort | tr "\n" " ")" == "./brokkr-guarded-reboot.service ./brokkr-guarded-reboot.timer ./brokkr-post-boot-check.service ./brokkr-post-boot-check.timer ./brokkr-post-update-health.service ./brokkr-post-update-health.timer ./scripts/guarded-reboot.sh ./scripts/lib/notify.sh ./systemd/user/brokkr-guarded-reboot.service.in ./systemd/user/brokkr-guarded-reboot.timer ./systemd/user/brokkr-post-boot-check.service.in ./systemd/user/brokkr-post-boot-check.timer ./systemd/user/brokkr-post-update-health.service.in ./systemd/user/brokkr-post-update-health.timer " ]]'
check "release files are executable where needed and private" '[[ -x "$RELEASE/scripts/guarded-reboot.sh" && "$(mode_of "$RELEASE")" == 700 ]]'
check "no staging directory is left behind" '[[ -z "$(find "$HOME_DIR/.local/lib/brokkr/guarded-reboot" -maxdepth 1 -name ".stage.*")" ]]'
check "the nightly unit renders the exact SHA, mode, busy units (quoted), peers, load, idle and alert-after" 'grep -Fxq "ExecStart=%h/.local/lib/brokkr/guarded-reboot/releases/$SHA/scripts/guarded-reboot.sh check" "$SVC" && grep -Fxq "WorkingDirectory=%h/.local/lib/brokkr/guarded-reboot/releases/$SHA" "$SVC" && grep -Fxq "Environment=BROKKR_GUARDED_REBOOT_MODE=report" "$SVC" && grep -Fxq "Environment=\"BROKKR_GUARDED_REBOOT_BUSY_UNITS=hugin.service other.service\"" "$SVC" && grep -Fxq "Environment=\"BROKKR_GUARDED_REBOOT_PEERS=node-b.example\"" "$SVC" && grep -Fxq "Environment=BROKKR_GUARDED_REBOOT_MAX_LOAD=1.5" "$SVC" && grep -Fxq "Environment=BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN=30" "$SVC" && grep -Fxq "Environment=BROKKR_GUARDED_REBOOT_ALERT_AFTER=2" "$SVC"'
check "the nightly timer renders the window and the spread, and never fires after a missed window" 'grep -Fxq "OnCalendar=*-*-* 04:10:00" "$TMR" && grep -Fxq "RandomizedDelaySec=20min" "$TMR" && grep -Fxq "Persistent=false" "$TMR" && grep -Fxq "AccuracySec=1min" "$TMR"'
check "the post-boot check runs ten minutes after boot and the health check at 08:00" 'grep -Fxq "OnBootSec=10min" "$PB_TMR" && grep -Fxq "ExecStart=%h/.local/lib/brokkr/guarded-reboot/releases/$SHA/scripts/guarded-reboot.sh post-boot" "$PB_SVC" && grep -Fxq "OnCalendar=*-*-* 08:00" "$H_TMR" && grep -Fxq "Persistent=true" "$H_TMR" && grep -Fxq "ExecStart=%h/.local/lib/brokkr/guarded-reboot/releases/$SHA/scripts/guarded-reboot.sh health" "$H_SVC"'
check "the units that run the job carry the mode" 'grep -Fxq "Environment=BROKKR_GUARDED_REBOOT_MODE=report" "$PB_SVC" && grep -Fxq "Environment=BROKKR_GUARDED_REBOOT_MODE=report" "$H_SVC"'
check "rendered units have no placeholders and no sandboxing or system-only directives (sudo must work)" '! grep -Eq "@[A-Z_]+@|^OnFailure|^User=|^NoNewPrivileges|^PrivateTmp|^Protect|^Restrict|/opt/brokkr" "$SVC" "$TMR" "$PB_SVC" "$PB_TMR" "$H_SVC" "$H_TMR" && grep -Fxq "TimeoutStartSec=5min" "$SVC"'
check "the unit PATH reaches sudo, systemctl and the sbin tools" 'grep -Fxq "Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$SVC"'
check "existing unit is backed up as .previous-<SHA>" '[[ "$(cat "$SVC.previous-$SHA")" == "OLD SERVICE" ]]'
check "systemd is reloaded and all three timers enabled in one call" '[[ "$(line_of "^systemctl --user daemon-reload")" -lt "$(line_of "^systemctl --user enable --now brokkr-guarded-reboot.timer brokkr-post-boot-check.timer brokkr-post-update-health.timer$")" ]]'
check "the reboot service is never started and nothing reboots" 'never_rebooted && ! grep -q "systemctl --user start" "$CALLS" && no_unexpected'
check "the audit directories are created by the one fixed privileged command, parent and directory, mode 0755" 'grep -Fxq "sudo -n install -d -m 0755 $AUDIT_PARENT $AUDIT_DIR" "$CALLS" && [[ "$(mode_of "$AUDIT_PARENT")" == 755 && "$(mode_of "$AUDIT_DIR")" == 755 ]]'
check "the audit directory exists before the release is installed" '[[ "$(line_of "^sudo -n install -d")" -lt "$(line_of "^systemctl --user daemon-reload")" ]]'
check "the first run is check --report-only and its decision and the status are printed" '[[ "$OUT" == *"== first run: check --report-only"* && "$OUT" == *"decision: none"* && "$OUT" == *"== status"* && "$OUT" == *"configured mode: report"* && "$OUT" == *"busy units: hugin.service other.service; peers: node-b.example"* ]]'
check "the first run wrote the private state file and one audit line" '[[ "$(mode_of "$STATE_FILE")" == 600 ]] && [[ "$(wc -l <"$AUDIT_FILE" | tr -d " ")" -eq 1 ]]'
check "the audit file is world-readable (0644), created through sudo tee under umask 022" '[[ "$(mode_of "$AUDIT_FILE")" == 644 ]] && [[ "$OUT" == *"audit file: "* ]]'
check "output prints a concrete rollback recipe" '[[ "$OUT" == *"Rollback"* && "$OUT" == *"systemctl --user disable --now brokkr-guarded-reboot.timer brokkr-post-boot-check.timer brokkr-post-update-health.timer"* && "$OUT" == *"mv -f $SVC.previous-$SHA $SVC"* && "$OUT" == *"rm -f $TMR"* && "$OUT" == *"releases/$SHA"* ]]'
check "the rollback leaves the evidence in place and says the first run changed nothing else" '[[ "$OUT" == *"are evidence and stay in place"* && "$OUT" == *"rebooted nothing and staged nothing"* ]]'
check "a host without rpi-eeprom-update gets no EEPROM service change" '[[ ! -s "$MOCK/eeprom-service" && "$OUT" != *"rpi-eeprom-update.service"* ]]'
check "apply payload parent is cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'
: >"$CALLS"
run "$TARGET" --apply
check "re-applying the same revision refuses instead of overwriting" '[[ "$RC" -ne 0 && "$OUT" == *"release already exists"* ]] && ! grep -Eq "^systemctl --user (daemon-reload|enable)" "$CALLS"'

reset
run "$TARGET" --apply
check "defaults render the empty busy and peer lists, an empty (auto) load limit, 03:30 and 45 min" 'grep -Fxq "Environment=\"BROKKR_GUARDED_REBOOT_BUSY_UNITS=\"" "$SVC" && grep -Fxq "Environment=\"BROKKR_GUARDED_REBOOT_PEERS=\"" "$SVC" && grep -Fxq "Environment=BROKKR_GUARDED_REBOOT_MAX_LOAD=" "$SVC" && grep -Fxq "OnCalendar=*-*-* 03:30:00" "$TMR" && grep -Fxq "RandomizedDelaySec=45min" "$TMR" && grep -Fxq "Environment=BROKKR_GUARDED_REBOOT_ALERT_AFTER=3" "$SVC"'
reset; with_notify
BROKKR_GUARDED_REBOOT_MODE=reboot run "$TARGET" --apply
check "reboot mode is rendered into all three service units, and the first run is still report-only" '[[ "$RC" -eq 0 && "$OUT" == *"installed in reboot mode"* ]] && grep -Fxq "Environment=BROKKR_GUARDED_REBOOT_MODE=reboot" "$SVC" && grep -Fxq "Environment=BROKKR_GUARDED_REBOOT_MODE=reboot" "$PB_SVC" && grep -Fxq "Environment=BROKKR_GUARDED_REBOOT_MODE=reboot" "$H_SVC" && never_rebooted && grep -q "\"mode\":\"report\"" "$AUDIT_FILE"'

# An existing /var/lib/brokkr is never chmod-ed; only the guarded-reboot directory is created.
reset; mkdir -p "$AUDIT_PARENT"; chmod 711 "$AUDIT_PARENT"
run "$TARGET" --apply
check "an existing world-searchable audit parent is left exactly as it is" '[[ "$RC" -eq 0 && "$(mode_of "$AUDIT_PARENT")" == 711 && "$(mode_of "$AUDIT_DIR")" == 755 ]] && grep -Fxq "sudo -n install -d -m 0755 $AUDIT_DIR" "$CALLS"'
reset; MOCK_INSTALL_FAIL=1 run "$TARGET" --apply
check "an audit directory that cannot be created refuses before anything is installed" '[[ "$RC" -ne 0 && "$OUT" == *"could not create the audit directory"* ]] && [[ ! -e "$RELEASE" && ! -e "$UNIT_DIR" ]] && ! grep -q "^systemctl --user" "$CALLS"'
reset; MOCK_AUDIT_PRIVATE=1 run "$TARGET" --apply
check "an audit file that is not world-readable fails the deploy, with the rollback" '[[ "$RC" -ne 0 && "$OUT" == *"audit file is not world-readable"* && "$OUT" == *Rollback* ]]'

# --- the stock EEPROM boot service ---------------------------------------------------------------------------
if real_eeprom; then
  skip "stock EEPROM service apply tests (a real rpi-eeprom-update is on this machine PATH)"
else
  reset; with_eeprom; run "$TARGET" --apply
  check "apply disables the enabled stock rpi-eeprom-update.service through the one fixed command" '[[ "$RC" -eq 0 && "$(cat "$MOCK/eeprom-service")" == disabled ]] && grep -Fxq "sudo -n systemctl disable rpi-eeprom-update.service" "$CALLS" && [[ "$OUT" == *"disabled the stock rpi-eeprom-update.service"* ]]'
  check "the rollback prints the exact re-enable command" '[[ "$OUT" == *"sudo systemctl enable rpi-eeprom-update.service"* ]]'
  check "the first run on a Pi host stages and cancels nothing" '! grep -Eq "^sudo -n rpi-eeprom-update -(a|r)" "$CALLS" && grep -q "^sudo -n rpi-eeprom-update -j -m " "$CALLS"'
  reset; with_eeprom; MOCK_EEPROM_SERVICE=disabled run "$TARGET" --apply
  check "an already disabled stock service is left alone and the rollback has nothing to re-enable" '[[ "$RC" -eq 0 && ! -s "$MOCK/eeprom-service" && "$OUT" != *"sudo systemctl enable rpi-eeprom-update.service"* ]]'
  reset; with_eeprom; echo "recovery 1790000000" >"$PENDING"; run "$TARGET" --apply
  check "the deploy summary states that a staged EEPROM update applies at the next boot and that the kill switch does not cancel it" '[[ "$RC" -eq 0 && "$OUT" == *"bootloader update is STAGED"* && "$OUT" == *"next boot of any kind"* && "$OUT" == *"does not cancel it"* && "$OUT" == *"apt-mark hold rpi-eeprom"* ]]'
  check "the report-only first run does not cancel the staged update itself" '[[ -e "$PENDING" ]] && ! grep -q "rpi-eeprom-update -r" "$CALLS"'
fi

# --- --apply: failing first run ------------------------------------------------------------------------------------------
reset; BROKKR_BOOT_ID_FILE="$TMP/no-such-boot-id" run "$TARGET" --apply
check "a failing first run exits non-zero, says so, and prints the rollback recipe" '[[ "$RC" -ne 0 && "$OUT" == *FAILED* && "$OUT" == *Rollback* ]]'
check "a failing first run leaves the release, units and timers installed" '[[ -d "$RELEASE" && -f "$SVC" && -f "$TMR" ]] && grep -q "enable --now brokkr-guarded-reboot.timer" "$CALLS" && never_rebooted'

# --- backup safety: originals stay intact until every backup exists ---------------------------------------------------------
seed_units() { mkdir -p "$UNIT_DIR"; printf 'OLD SERVICE\n' >"$SVC"; printf 'OLD TIMER\n' >"$TMR"; }
units_intact() {
  local s t
  s=$(cat "$SVC"); t=$(cat "$TMR")
  [[ "$s" == "OLD SERVICE" ]] && [[ "$t" == "OLD TIMER" ]]
}
no_backup_debris() { [[ -z "$(find "$UNIT_DIR" -name '.*backup-tmp*' -print)" ]]; }
reset; seed_units; export MOCK_CP_FAIL="service.backup-tmp"
run "$TARGET" --apply
check "a failed first backup leaves both original units untouched and installs nothing" '[[ "$RC" -ne 0 && "$OUT" == *"could not back up"* ]] && units_intact && no_backup_debris && [[ ! -e "$RELEASE" ]] && ! grep -Eq "^systemctl --user (daemon-reload|enable)" "$CALLS"'
check "a failed first backup prints no unit rollback steps" '[[ "$OUT" == *"no release, installed unit or system service was changed"* && "$OUT" != *"mv -f"* ]]'
reset; seed_units; export MOCK_CP_FAIL="timer.backup-tmp"
run "$TARGET" --apply
check "a partial backup (a later unit fails) leaves originals untouched and no temp files" '[[ "$RC" -ne 0 && "$OUT" == *"could not back up"* ]] && units_intact && no_backup_debris && [[ ! -e "$RELEASE" && ! -e "$SVC.previous-$SHA" ]]'
reset; seed_units; export MOCK_MV_FAIL="guarded-reboot.timer.previous"
run "$TARGET" --apply
check "a failed backup finalize leaves originals untouched and the recipe only offers cleanup" '[[ "$RC" -ne 0 && "$OUT" == *"could not finalize"* ]] && units_intact && no_backup_debris && [[ ! -e "$RELEASE" ]] && [[ "$OUT" != *"mv -f $UNIT_DIR"* ]]'

# --- payload is received and validated before anything changes ---------------------------------------------------------------
reset; export MOCK_TAR_FAIL=1
run "$TARGET" --apply
check "payload extraction failure changes nothing" '[[ "$RC" -ne 0 && "$OUT" == *"payload extraction failed"* ]] && ! grep -Eq "^(systemctl --user|sudo -n install)" "$CALLS" && [[ ! -e "$RELEASE" && ! -e "$UNIT_DIR" && ! -e "$AUDIT_PARENT" ]]'
reset; export MOCK_TAR_EXTRA=1
run "$TARGET" --apply
check "an unexpected extra payload file is refused" '[[ "$RC" -ne 0 && "$OUT" == *"unexpected files"* ]] && ! grep -Eq "^(systemctl --user|sudo -n install)" "$CALLS" && [[ ! -e "$RELEASE" && ! -e "$AUDIT_PARENT" ]]'
reset; export MOCK_TAR_SYMLINK=1
run "$TARGET" --apply
check "a symlink in the payload is refused" '[[ "$RC" -ne 0 && "$OUT" == *"unexpected entry types"* ]] && ! grep -Eq "^(systemctl --user|sudo -n install)" "$CALLS" && [[ ! -e "$RELEASE" ]]'

BAD_REPO="$TMP/bad-repo"
make_repo "$BAD_REPO"
printf 'if then fi\n' >>"$BAD_REPO/scripts/guarded-reboot.sh"
BAD_SHA="$(commit_repo "$BAD_REPO")"
reset
OUT="$(cd "$BAD_REPO" && BROKKR_EXPECTED_SOURCE="$BAD_REPO" BROKKR_EXPECTED_COMMIT="$BAD_SHA" bash "$BAD_REPO/scripts/deploy-guarded-reboot.sh" "$TARGET" --apply 2>&1)"; RC=$?
check "a staged job that does not parse is refused before any change" '[[ "$RC" -ne 0 && "$OUT" == *"syntax"* ]] && ! grep -Eq "^(systemctl --user|sudo -n install)" "$CALLS" && [[ ! -e "$HOME_DIR/.local/lib/brokkr/guarded-reboot/releases/$BAD_SHA" && ! -e "$UNIT_DIR" && ! -e "$AUDIT_PARENT" ]]'

check "across every run no stub saw a command outside the fixed lists" 'no_unexpected'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
