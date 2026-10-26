#!/usr/bin/env bash
# Hermetic gates for scripts/deploy-eee-off.sh. ssh, sudo, systemctl, ethtool, and id
# are fakes on PATH; the "remote" unit directory, sysfs, and systemd state are temp
# directories on this machine. No real host, network interface, or systemd is touched.
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

REPO="$TMP/repo"; BIN="$TMP/bin"; CALLS="$TMP/calls"; STATE="$TMP/state"
UNIT_DIR="$TMP/etc/systemd/system"; SYSFS="$TMP/sys/class/net"; STORE="$TMP/store"
mkdir -p "$REPO/scripts/lib" "$REPO/network" "$BIN" "$TMP/payload-tmp" "$TMP/nosbin" "$STORE"
cp "$ROOT/scripts/deploy-eee-off.sh" "$REPO/scripts/" 2>/dev/null
cp "$ROOT/scripts/lib/deploy-source.sh" "$REPO/scripts/lib/"
cp "$ROOT/network/brokkr-eee-off@.service.example" "$REPO/network/" 2>/dev/null
cp "$ROOT/network/brokkr-eee-off-watch@.service.example" "$REPO/network/" 2>/dev/null
echo "unrelated file that must never ship" > "$REPO/README.md"
git init -q "$REPO"; git -C "$REPO" config user.name test; git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add . ; git -C "$REPO" commit -qm fixture
SHA="$(git -C "$REPO" rev-parse HEAD)"
DEPLOY="$REPO/scripts/deploy-eee-off.sh"
MANAGED="$UNIT_DIR/brokkr-eee-off@.service"
INSTANCE=brokkr-eee-off@eth0.service
WATCH=brokkr-eee-off-watch@eth0.service
WATCH_TEMPLATE="$UNIT_DIR/brokkr-eee-off-watch@.service"
DEV_WANTS="$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants"
BOOT_WANTS="$UNIT_DIR/multi-user.target.wants"
LEGACY="$UNIT_DIR/eth0-eee-off.service"

: >"$CALLS"
cat >"$BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
# usage: ssh [-o opt]... TARGET COMMAND
while [[ "${1:-}" == -o ]]; do shift 2; done
target=$1; shift
printf 'ssh %s\n' "$target" >>"$MOCK_CALLS"
[[ "$#" -eq 1 ]] || exit 64
exec env PATH="$MOCK_REMOTE_PATH" MOCK_ID_ROOT="${MOCK_REMOTE_ROOT:-0}" \
  BROKKR_ETHTOOL_SEARCH_PATH="$MOCK_NOSBIN" BROKKR_IP_SEARCH_PATH="$MOCK_NOSBIN" BROKKR_SYSTEMD_SYSTEM_DIR="$MOCK_UNIT_DIR" \
  BROKKR_SYSFS_NET="$MOCK_SYSFS" bash -c "$1"
FAKE
cat >"$BIN/id" <<'FAKE'
#!/usr/bin/env bash
if [[ "${MOCK_ID_ROOT:-0}" == 1 ]]; then
  case "${1:-}" in -u) echo 0; exit 0 ;; -un) echo root; exit 0 ;; esac
fi
exec /usr/bin/id "$@"
FAKE
cat >"$BIN/sudo" <<'FAKE'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$MOCK_CALLS"
if [[ "${MOCK_SUDO_DENY:-0}" == 1 ]]; then echo "sudo: a password is required" >&2; exit 1; fi
[[ "${1:-}" == -n ]] || { echo "fake sudo: -n required" >&2; exit 99; }
shift
if [[ -n "${MOCK_SUDO_DENY_CMD:-}" && "${1:-}" == "$MOCK_SUDO_DENY_CMD" ]]; then
  echo "sudo: a password is required" >&2; exit 1
fi
# Root can read root-only paths (mode 000 for the operator here): lift their mode
# for this one command, then restore it, innermost first.
read -r -a root_only <<<"${MOCK_ROOT_ONLY:-}"
for p in "${root_only[@]}"; do chmod u+rwx "$p"; done
"$@"; rc=$?
for (( i=${#root_only[@]}-1; i>=0; i-- )); do chmod 000 "${root_only[i]}"; done
exit "$rc"
FAKE
# The fake systemctl runs a started unit's ExecStart (with %i expanded), so the
# rendered unit is exercised end to end against the fake ethtool.
cat >"$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_CALLS"
if [[ -n "${MOCK_SYSTEMCTL_FAIL:-}" && "$*" == "$MOCK_SYSTEMCTL_FAIL" ]]; then echo "systemctl: injected failure" >&2; exit 1; fi
st=$MOCK_STATE
unit_template() { # unit -> sets inst and tpl
  case $1 in
    *@*.service) inst=${1#*@}; inst=${inst%.service}; tpl="$MOCK_UNIT_DIR/${1%%@*}@.service" ;;
    *) inst=; tpl="$MOCK_UNIT_DIR/$1" ;;
  esac
}
# A Type=simple unit (the link watcher) is only marked active, never executed;
# MOCK_WATCH_START_FAIL fails the start of a *-watch@* unit.
start_unit() {
  local u=$1 inst tpl line
  [[ "${MOCK_START_FAIL:-0}" != 1 ]] || return 1
  [[ "$u" != *-watch@* || "${MOCK_WATCH_START_FAIL:-0}" != 1 ]] || return 1
  unit_template "$u"
  [[ -f "$tpl" ]] || return 5
  if grep -q '^Type=simple' "$tpl"; then touch "$st/active.$u"; return 0; fi
  line=$(sed -n 's/^ExecStart=//p' "$tpl")
  line=${line//%i/$inst}
  # shellcheck disable=SC2086 # deliberate word splitting of the unit's command line
  $line || return 1
  touch "$st/active.$u"
}
enable_unit() { # one link per space-separated WantedBy unit
  local u=$1 inst tpl wb w
  touch "$st/enabled.$u"
  unit_template "$u"
  wb=$(sed -n 's/^WantedBy=//p' "$tpl"); wb=${wb//%i/$inst}
  for w in $wb; do mkdir -p "$MOCK_UNIT_DIR/$w.wants"; ln -sfn "$tpl" "$MOCK_UNIT_DIR/$w.wants/$u"; done
}
disable_unit() {
  rm -f "$st/enabled.$1"; find "$MOCK_UNIT_DIR" -path "*.wants/$1" -type l -exec rm -f {} +
}
case "${1:-}" in
  daemon-reload|reset-failed) exit 0 ;;
  enable) enable_unit "$2" ;;
  reenable) disable_unit "$2"; enable_unit "$2" ;;
  disable)
    u=$2; [[ "$u" == --now ]] && { u=$3; rm -f "$st/active.$u"; }
    disable_unit "$u" ;;
  stop) rm -f "$st/active.$2" ;;
  start) start_unit "$2" || exit 1 ;;
  restart) u=$2; [[ "$u" == --no-block ]] && u=$3; rm -f "$st/active.$u"; start_unit "$u" || exit 1 ;;
  is-failed) exit 1 ;;
  # An enabled.* file may hold a non-default state such as enabled-runtime.
  is-enabled)
    if [[ -e "$st/enabled.$2" ]]; then state=$(cat "$st/enabled.$2"); echo "${state:-enabled}"
    elif [[ -e "$MOCK_UNIT_DIR/$2" || ( "$2" == *@*.service && -e "$MOCK_UNIT_DIR/${2%%@*}@.service" ) ]]; then echo disabled; exit 1
    else echo not-found; exit 4; fi ;;
  is-active) if [[ -e "$st/active.$2" ]]; then echo active; else echo inactive; exit 3; fi ;;
  *) echo "fake systemctl: unexpected $*" >&2; exit 99 ;;
esac
exit 0
FAKE
cat >"$STORE/ethtool" <<'FAKE'
#!/usr/bin/env bash
printf 'ethtool %s\n' "$*" >>"$MOCK_CALLS"
f="$MOCK_STATE/eee.${2:-}"
[[ -e "$MOCK_SYSFS/${2:-}" ]] || { echo "netlink error: no device matches name" >&2; exit 75; }
case "${1:-}" in
  --show-eee)
    echo "EEE settings for $2:"
    if [[ "${MOCK_EEE_UNSUPPORTED:-0}" == 1 ]]; then printf '\tEEE status: not supported\n'; exit 0; fi
    printf '\tEEE status: %s\n' "$(cat "$f" 2>/dev/null || echo 'enabled - active')" ;;
  --set-eee)
    [[ "$#" -eq 4 && "$3 $4" == "eee off" ]] || exit 64
    [[ "${MOCK_ETHTOOL_NOOP:-0}" == 1 ]] || echo disabled >"$f" ;;
  *) exit 64 ;;
esac
FAKE
# The fake ip only plays back the lines of MOCK_IP_LINES for `ip -o monitor link`.
# It takes a moment to subscribe, like the real netlink listener, and then logs that it
# is listening, so a test can tell whether a status read came before or after.
cat >"$STORE/ip" <<'FAKE'
#!/usr/bin/env bash
sleep 0.3
printf 'ip %s (subscribed)\n' "$*" >>"$MOCK_CALLS"
if [[ -n "${MOCK_IP_LINES:-}" && -f "$MOCK_IP_LINES" ]]; then cat "$MOCK_IP_LINES"; fi
exit 0
FAKE
# Fault injection: cp/mv fail when the destination matches, install fails on request.
cat >"$BIN/mv" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${MOCK_MV_FAIL:-}" && "${!#}" == *"$MOCK_MV_FAIL"* ]]; then echo "mv: injected failure" >&2; exit 1; fi
exec /bin/mv "$@"
FAKE
cat >"$BIN/readlink" <<'FAKE'
#!/usr/bin/env bash
if [[ "${MOCK_READLINK_FAIL:-0}" == 1 ]]; then echo "readlink: injected failure" >&2; exit 1; fi
exec /usr/bin/readlink "$@"
FAKE
cat >"$BIN/install" <<'FAKE'
#!/usr/bin/env bash
if [[ "${MOCK_INSTALL_FAIL:-0}" == 1 ]]; then echo "install: injected failure" >&2; exit 1; fi
exec /usr/bin/install "$@"
FAKE
cat >"$BIN/cp" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${MOCK_CP_FAIL:-}" && "${!#}" == *"$MOCK_CP_FAIL"* ]]; then echo "cp: injected failure" >&2; exit 1; fi
exec /bin/cp "$@"
FAKE
chmod 755 "$BIN/"* "$STORE/ethtool" "$STORE/ip"

export MOCK_CALLS="$CALLS" MOCK_STATE="$STATE" MOCK_UNIT_DIR="$UNIT_DIR" MOCK_SYSFS="$SYSFS"
export MOCK_NOSBIN="$TMP/nosbin" MOCK_REMOTE_PATH="$BIN:/usr/bin:/bin"
export PATH="$BIN:$PATH" TMPDIR="$TMP/payload-tmp"
TARGET=operator@node-a.example.invalid

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; printf '        rc=%s out=%s\n' "${RC:-}" "${OUT:-}" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() { OUT="$(cd "$REPO" && bash "$DEPLOY" "$@" 2>&1)"; RC=$?; }
line_of() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
tree_state() { { find "$TMP/etc" "$STATE" | sort; find "$TMP/etc" "$STATE" -type f -exec cksum {} + | sort; } | cksum; }
no_mutation() {
  ! grep -Eq '^systemctl (enable|disable|start|restart|stop|daemon-reload)|^sudo -n (cp|mv|rm|install|systemctl)|^ethtool --set-eee' "$CALLS"
}
seed_legacy() {
  cat >"$LEGACY" <<'UNIT'
[Unit]
Description=Disable Energy Efficient Ethernet on eth0
BindsTo=sys-subsystem-net-devices-eth0.device
After=sys-subsystem-net-devices-eth0.device

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool --set-eee eth0 eee off

[Install]
WantedBy=sys-subsystem-net-devices-eth0.device
UNIT
  touch "$STATE/enabled.eth0-eee-off.service" "$STATE/active.eth0-eee-off.service"
  mkdir -p "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants"
  ln -s "$LEGACY" "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants/eth0-eee-off.service"
}
has_ethtool() { cp "$STORE/ethtool" "$BIN/ethtool"; }
has_ip() { cp "$STORE/ip" "$BIN/ip"; }
reset() {
  rm -rf "${TMP:?}/etc" "${TMP:?}/sys" "${STATE:?}"
  mkdir -p "$UNIT_DIR" "$SYSFS/eth0" "$STATE"
  rm -f "$BIN/ethtool" "$MOCK_NOSBIN/ethtool" "$BIN/ip" "$MOCK_NOSBIN/ip"
  : >"$CALLS"
  unset MOCK_ID_ROOT MOCK_REMOTE_ROOT MOCK_SUDO_DENY MOCK_START_FAIL MOCK_ETHTOOL_NOOP MOCK_EEE_UNSUPPORTED MOCK_CP_FAIL
  unset MOCK_MV_FAIL MOCK_INSTALL_FAIL MOCK_SYSTEMCTL_FAIL MOCK_READLINK_FAIL MOCK_WATCH_START_FAIL MOCK_UNIT_FAILED
  export BROKKR_EXPECTED_SOURCE="$REPO" BROKKR_EXPECTED_COMMIT="$SHA"
  has_ethtool
  has_ip
}
# Runs every "  sudo ..." line of the printed rollback recipe through the fakes.
run_rollback() {
  local line
  while IFS= read -r line; do
    case $line in
      "  sudo "*)
        line=${line#  sudo }; line=${line%%   #*}
        # shellcheck disable=SC2086,SC2024 # split the recipe line on purpose; the log is ours, not sudo's
        sudo -n $line >>"$CALLS" 2>&1 || return 1 ;;
    esac
  done < <(printf '%s\n' "$OUT" | sed -n '/^Rollback/,$p')
}
unit_state() { # files, contents, and enablement/activity, excluding this run's backups
  {
    find "$UNIT_DIR" -type f ! -name '*.previous-*' -exec cksum {} + | sort
    find "$UNIT_DIR" -type l | sort
    find "$STATE" -name 'active.*' | sort
    for f in "$STATE"/enabled.*; do [[ -e "$f" ]] && printf '%s=%s\n' "${f##*/}" "$(cat "$f")"; done
  } | cksum
}
refuses() { # name expected-substring args...
  local name=$1 want=$2; shift 2
  local before; before="$(tree_state)"
  run "$@"
  check "$name" '[[ "$RC" -ne 0 && "$OUT" == *"$want"* && "$(tree_state)" == "$before" ]] && no_mutation'
}

four_links() { [[ -L "$DEV_WANTS/$INSTANCE" && -L "$BOOT_WANTS/$INSTANCE" && -L "$DEV_WANTS/$WATCH" && -L "$BOOT_WANTS/$WATCH" ]]; }
both_live() { [[ -e "$STATE/enabled.$INSTANCE" && -e "$STATE/active.$INSTANCE" && -e "$STATE/enabled.$WATCH" && -e "$STATE/active.$WATCH" ]]; }
in_order() { # each fixed-start pattern first appears in $CALLS after the previous one
  local prev=0 n pat
  for pat in "$@"; do
    n="$(line_of "$pat")"
    [[ -n "$n" && "$n" -gt "$prev" ]] || return 1
    prev=$n
  done
}
# A PATH for the remote side in which no `ip` resolves, even on a host that has one.
make_noip_path() {
  local d f n
  rm -rf "${TMP:?}/noip"; mkdir -p "$TMP/noip"
  for d in "$BIN" /usr/bin /bin; do
    for f in "$d"/*; do
      n=${f##*/}
      [[ "$n" != ip && ! -e "$TMP/noip/$n" ]] || continue
      ln -s "$f" "$TMP/noip/$n"
    done
  done
}

echo "deploy-eee-off.test.sh"
reset
check "fixture precondition: the example units and deploy script are committed" '[[ -f "$REPO/network/brokkr-eee-off@.service.example" && -f "$REPO/network/brokkr-eee-off-watch@.service.example" && -f "$DEPLOY" ]] && git -C "$REPO" ls-files --error-unmatch network/brokkr-eee-off-watch@.service.example >/dev/null'

# --- local gates: nothing reaches ssh ---------------------------------------------------
unset BROKKR_EXPECTED_COMMIT
run "$TARGET" eth0
check "missing expected commit refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"BROKKR_EXPECTED_SOURCE and BROKKR_EXPECTED_COMMIT"* ]] && ! grep -q ssh "$CALLS"'
reset
export BROKKR_EXPECTED_COMMIT=0000000000000000000000000000000000000000
run "$TARGET" eth0
check "wrong expected commit refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"revision does not match"* ]] && ! grep -q ssh "$CALLS"'
reset
ln -s "$DEPLOY" "$REPO/scripts/deploy-via-link.sh"
OUT="$(cd "$REPO" && bash "$REPO/scripts/deploy-via-link.sh" "$TARGET" eth0 2>&1)"; RC=$?
check "symlinked entry script refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"must not contain symlinks"* ]] && ! grep -q ssh "$CALLS"'
rm -f "$REPO/scripts/deploy-via-link.sh"
run "$TARGET"
check "missing interface refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *usage* ]] && ! grep -q ssh "$CALLS"'
for iface in 'eth0;id' '-eth0' 'en-p1' '.eth0' 'abcdefghijklmnop' 'eth 0'; do
  run "$TARGET" "$iface"
  check "unsupported interface name '$iface' refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"unsupported interface name"* ]] && ! grep -q ssh "$CALLS"'
done
run root@node-a.example.invalid eth0
check "a root ssh target refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"must not be root"* ]] && ! grep -q ssh "$CALLS"'
MOCK_ID_ROOT=1 run "$TARGET" eth0
check "running the deploy as root refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *"must not run as root"* ]] && ! grep -q ssh "$CALLS"'
run -oProxyCommand=evil eth0
check "option-shaped ssh target refuses before ssh" '[[ "$RC" -ne 0 ]] && ! grep -q ssh "$CALLS"'
run "$TARGET" eth0 --bogus
check "unknown option refuses before ssh" '[[ "$RC" -ne 0 && "$OUT" == *usage* ]] && ! grep -q ssh "$CALLS"'

# --- dry-run: preflight only --------------------------------------------------------------
reset; seed_legacy
before="$(tree_state)"
run "$TARGET" eth0
check "dry-run succeeds with the ad-hoc unit present" '[[ "$RC" -eq 0 && "$OUT" == *DRY-RUN* ]]'
check "dry-run mutates nothing" '[[ "$(tree_state)" == "$before" ]] && no_mutation'
check "dry-run validated through ssh and sudo -n" 'grep -q "^ssh $TARGET" "$CALLS" && grep -q "^sudo -n true" "$CALLS"'
check "dry-run reports the ad-hoc unit it would adopt and its backup" '[[ "$OUT" == *"eth0-eee-off.service"* && "$OUT" == *"eth0-eee-off.service.previous-$SHA"* ]]'
check "dry-run reports the current EEE status" '[[ "$OUT" == *"EEE status: enabled"* ]]'
check "dry-run reports the pinned ip path" '[[ "$OUT" == *"ip at $BIN/ip"* ]]'
check "dry-run payload parent is cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'

# --- remote refusals: identical for dry-run and --apply, nothing changes ------------------
for mode in dry-run apply; do
  args=("$TARGET" eth0); [[ "$mode" == apply ]] && args+=(--apply)
  reset; seed_legacy; export MOCK_REMOTE_ROOT=1
  refuses "$mode: remote runtime user root refuses" "must not be root" "${args[@]}"
  reset; seed_legacy; rm -f "$BIN/ethtool"
  refuses "$mode: missing ethtool refuses (never installs)" "ethtool is required" "${args[@]}"
  reset; seed_legacy; make_noip_path
  MOCK_REMOTE_PATH="$TMP/noip" refuses "$mode: missing ip refuses (never installs)" "ip (iproute2) is required" "${args[@]}"
  reset; seed_legacy; rm -rf "$SYSFS/eth0"
  refuses "$mode: absent interface refuses" "no network interface eth0" "${args[@]}"
  reset; seed_legacy; export MOCK_SUDO_DENY=1
  refuses "$mode: sudo requiring a password refuses" "sudo -n" "${args[@]}"
  reset; seed_legacy; export MOCK_EEE_UNSUPPORTED=1
  refuses "$mode: an interface without EEE support refuses" "does not support EEE" "${args[@]}"
  reset; printf '[Service]\nExecStart=/bin/true\n' >"$LEGACY"
  refuses "$mode: a same-named unit that is not an EEE-off unit refuses" "not the ad-hoc EEE-off unit" "${args[@]}"
  reset; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee eth0 eee off\n' >"$TMP/elsewhere.service"
  ln -s "$TMP/elsewhere.service" "$LEGACY"
  refuses "$mode: a symlinked ad-hoc unit refuses" "regular non-symlink file" "${args[@]}"
  reset; seed_legacy; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee eth0 eee off\n' >"$UNIT_DIR/other-eee.service"
  refuses "$mode: a second unit already setting EEE on the interface refuses" "other-eee.service" "${args[@]}"
  reset; seed_legacy; echo old >"$LEGACY.previous-$SHA"
  refuses "$mode: an existing backup for this revision refuses" "backup" "${args[@]}"
  # Any other owner of the setting, whatever value it sets or wherever it lives.
  reset; seed_legacy; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee eth0 eee on\n' >"$UNIT_DIR/eee-on.service"
  refuses "$mode: another unit setting EEE on the interface to on refuses" "eee-on.service" "${args[@]}"
  reset; seed_legacy; mkdir -p "$UNIT_DIR/network-tweaks.service.d"
  printf '[Service]\nExecStartPost=/usr/sbin/ethtool --set-eee eth0 eee off\n' >"$UNIT_DIR/network-tweaks.service.d/eee.conf"
  refuses "$mode: a drop-in setting EEE on the interface refuses" "network-tweaks.service.d/eee.conf" "${args[@]}"
  reset; seed_legacy; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee %%i eee off\n' >"$UNIT_DIR/other-eee@.service"
  mkdir -p "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants"
  ln -s "$UNIT_DIR/other-eee@.service" "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants/other-eee@eth0.service"
  refuses "$mode: an enabled instance of another EEE template refuses" "other-eee@eth0.service" "${args[@]}"
  reset; seed_legacy; mkdir -p "$UNIT_DIR/brokkr-eee-off@eth0.service.d"; printf '[Service]\nExecStart=\n' >"$UNIT_DIR/brokkr-eee-off@eth0.service.d/x.conf"
  refuses "$mode: a drop-in overriding the managed unit refuses" "drop-in" "${args[@]}"
  # The link watcher is a second managed unit with the same ownership guards.
  reset; seed_legacy; printf '[Service]\nExecStart=/bin/true\n' >"$UNIT_DIR/$WATCH"
  refuses "$mode: a concrete watcher instance file shadowing the template refuses" "shadows the managed template" "${args[@]}"
  for wd in brokkr-eee-off-watch@.service.d brokkr-eee-off-watch@eth0.service.d; do
    reset; seed_legacy; mkdir -p "$UNIT_DIR/$wd"; printf '[Service]\nExecStart=\n' >"$UNIT_DIR/$wd/x.conf"
    refuses "$mode: a drop-in $wd overriding the watcher refuses" "drop-in" "${args[@]}"
  done
  reset; seed_legacy; mkdir -p "$UNIT_DIR/brokkr-eee-off-.service.d"; printf '[Unit]\nConditionPathExists=/nonexistent\n' >"$UNIT_DIR/brokkr-eee-off-.service.d/x.conf"
  refuses "$mode: an inherited drop-in brokkr-eee-off-.service.d refuses" "brokkr-eee-off-.service.d" "${args[@]}"
  reset; seed_legacy; printf '[Service]\nExecStart=/bin/true\n' >"$TMP/elsewhere-watch.service"; ln -s "$TMP/elsewhere-watch.service" "$WATCH_TEMPLATE"
  refuses "$mode: a symlinked watcher template refuses" "regular non-symlink file" "${args[@]}"
  # A wants link of a managed unit must be a live link to that unit's template.
  reset; seed_legacy; printf '[Service]\nExecStart=/bin/true\n' >"$UNIT_DIR/elsewhere.service"
  mkdir -p "$BOOT_WANTS"; ln -s "$UNIT_DIR/elsewhere.service" "$BOOT_WANTS/$INSTANCE"
  refuses "$mode: a boot wants link of the instance to another unit refuses" "is not a link to" "${args[@]}"
  reset; seed_legacy; printf '[Service]\nExecStart=/bin/true\n' >"$UNIT_DIR/elsewhere.service"
  mkdir -p "$BOOT_WANTS"; ln -s "$UNIT_DIR/elsewhere.service" "$BOOT_WANTS/$WATCH"
  refuses "$mode: a boot wants link of the watcher to another unit refuses" "is not a link to" "${args[@]}"
  reset; seed_legacy; printf '[Service]\nExecStart=/bin/true\n' >"$WATCH_TEMPLATE"; echo enabled-runtime >"$STATE/enabled.$WATCH"
  refuses "$mode: a watcher instance in an unsupported enablement state refuses" "enabled-runtime" "${args[@]}"
  # The ad-hoc unit must have exactly the supported shape before it is deleted.
  reset; seed_legacy; sed -i.bak 's|^ExecStart=.*|ExecStart=/bin/echo --set-eee eth0 eee off|' "$LEGACY"; rm -f "$LEGACY.bak"
  refuses "$mode: an ad-hoc unit that only echoes the ethtool arguments refuses" "not the ad-hoc EEE-off unit" "${args[@]}"
  reset; seed_legacy; printf 'ExecStartPost=/usr/bin/logger eee\n' >>"$LEGACY"
  refuses "$mode: an ad-hoc unit with an extra command refuses" "not the ad-hoc EEE-off unit" "${args[@]}"
  reset; seed_legacy; printf 'ExecStart=/usr/sbin/ethtool --set-eee eth0 eee off\n' >>"$LEGACY"
  refuses "$mode: an ad-hoc unit with two ExecStart lines refuses" "not the ad-hoc EEE-off unit" "${args[@]}"
  reset; seed_legacy; mkdir -p "$LEGACY.d"; printf '[Service]\nExecStartPost=/bin/true\n' >"$LEGACY.d/x.conf"
  refuses "$mode: an ad-hoc unit with drop-ins refuses" "drop-in" "${args[@]}"
  reset; seed_legacy; printf '[Service]\nExecStart=/usr/bin/true\n' >"$UNIT_DIR/other-eee@.service"
  mkdir -p "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants" "$UNIT_DIR/other-eee@.service.d"
  printf '[Service]\nExecStartPost=/usr/sbin/ethtool --set-eee %%i eee on\n' >"$UNIT_DIR/other-eee@.service.d/eee.conf"
  ln -s "$UNIT_DIR/other-eee@.service" "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants/other-eee@eth0.service"
  refuses "$mode: an enabled instance whose template drop-in sets EEE refuses" "other-eee@eth0.service" "${args[@]}"
  reset; seed_legacy; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee %%i eee off\nExecStartPost=/usr/bin/logger x\n' >"$UNIT_DIR/$INSTANCE"
  refuses "$mode: a concrete managed instance file shadowing the template refuses" "shadows the managed template" "${args[@]}"
  reset; seed_legacy; printf 'Also=ssh.service\n' >>"$LEGACY"
  refuses "$mode: an ad-hoc unit with Also= refuses" "unsupported directive Also" "${args[@]}"
  reset; seed_legacy; sed -i.bak 's|^WantedBy=.*|WantedBy=multi-user.target|' "$LEGACY"; rm -f "$LEGACY.bak"
  refuses "$mode: an ad-hoc unit not wanted by the interface device refuses" "WantedBy" "${args[@]}"
  for inherited in brokkr-.service.d brokkr-eee-.service.d service.d eth0-.service.d eth0-eee-.service.d; do
    reset; seed_legacy; mkdir -p "$UNIT_DIR/$inherited"; printf '[Unit]\nConditionPathExists=/nonexistent\n' >"$UNIT_DIR/$inherited/x.conf"
    refuses "$mode: an inherited drop-in $inherited refuses" "$inherited" "${args[@]}"
  done
  reset; seed_legacy; mkdir -p "$UNIT_DIR/critical.target.requires"
  ln -s "$LEGACY" "$UNIT_DIR/critical.target.requires/eth0-eee-off.service"
  refuses "$mode: an ad-hoc unit with an extra dependency link refuses" "critical.target.requires" "${args[@]}"
  reset; seed_legacy; ln -s "$LEGACY" "$UNIT_DIR/eee-alias.service"
  refuses "$mode: an alias of the ad-hoc unit refuses" "eee-alias.service" "${args[@]}"
  reset; seed_legacy; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee "eth0" eee on\n' >"$UNIT_DIR/quoted.service"
  refuses "$mode: a unit setting EEE on a quoted interface refuses" "quoted.service" "${args[@]}"
  reset; seed_legacy; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee \\\n  eth0 eee on\n' >"$UNIT_DIR/continued.service"
  refuses "$mode: a unit setting EEE across a line continuation refuses" "continued.service" "${args[@]}"
  reset; seed_legacy; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee "%%i" eee on\n' >"$UNIT_DIR/quoted-eee@.service"
  mkdir -p "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants"
  ln -s "$UNIT_DIR/quoted-eee@.service" "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants/quoted-eee@eth0.service"
  refuses "$mode: an enabled instance of a template with a quoted %i refuses" "quoted-eee@eth0.service" "${args[@]}"
  reset; seed_legacy; touch "$STATE/enabled.$INSTANCE"
  refuses "$mode: an instance enabled without its device dependency refuses" "without its device dependency" "${args[@]}"
  reset; seed_legacy; echo not-found >"$STATE/enabled.$INSTANCE"
  printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee %%i eee off\n' >"$MANAGED"
  refuses "$mode: an instance reported not-found while its template exists refuses" "not-found" "${args[@]}"
  # systemd reads unit files as root and some are root-only (mode 600), so every scan
  # reads through sudo -n. What even sudo -n cannot read or list refuses.
  if [[ "$(/usr/bin/id -u)" != 0 ]]; then
    reset; seed_legacy; printf '[Service]\nExecStart=/usr/local/bin/build-cleanup\n' >"$UNIT_DIR/build-cleanup.service"; chmod 000 "$UNIT_DIR/build-cleanup.service"
    MOCK_ROOT_ONLY="$UNIT_DIR/build-cleanup.service" run "${args[@]}"
    check "$mode: a root-only unit without an EEE command is read through sudo -n and accepted" '[[ "$RC" -eq 0 ]] && grep -Fq "sudo -n cat -- $UNIT_DIR/build-cleanup.service" "$CALLS"'
    chmod 644 "$UNIT_DIR/build-cleanup.service"
    reset; seed_legacy; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee eth0 eee on\n' >"$UNIT_DIR/root-eee.service"; chmod 000 "$UNIT_DIR/root-eee.service"
    MOCK_ROOT_ONLY="$UNIT_DIR/root-eee.service" refuses "$mode: a root-only unit that sets EEE refuses" "root-eee.service also sets EEE" "${args[@]}"
    chmod 644 "$UNIT_DIR/root-eee.service"
    reset; seed_legacy; mkdir -p "$UNIT_DIR/locked.service.d"
    printf '[Service]\nExecStartPost=/usr/sbin/ethtool --set-eee eth0 eee on\n' >"$UNIT_DIR/locked.service.d/eee.conf"
    chmod 000 "$UNIT_DIR/locked.service.d/eee.conf" "$UNIT_DIR/locked.service.d"
    MOCK_ROOT_ONLY="$UNIT_DIR/locked.service.d $UNIT_DIR/locked.service.d/eee.conf" \
      refuses "$mode: a drop-in in a root-only directory that sets EEE refuses" "locked.service.d/eee.conf also sets EEE" "${args[@]}"
    chmod 755 "$UNIT_DIR/locked.service.d"; chmod 644 "$UNIT_DIR/locked.service.d/eee.conf"
    reset; seed_legacy; mkdir -p "$UNIT_DIR/locked.target.wants"; chmod 000 "$UNIT_DIR/locked.target.wants"
    MOCK_ROOT_ONLY="$UNIT_DIR/locked.target.wants" run "${args[@]}"
    check "$mode: a root-only directory without an EEE command is listed through sudo -n and accepted" '[[ "$RC" -eq 0 ]]'
    chmod 755 "$UNIT_DIR/locked.target.wants"
    reset; seed_legacy; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee eth0 eee on\n' >"$UNIT_DIR/secret.service"; chmod 000 "$UNIT_DIR/secret.service"
    refuses "$mode: a unit file even sudo -n cannot read refuses" "could not read secret.service with sudo -n" "${args[@]}"
    chmod 644 "$UNIT_DIR/secret.service"
    reset; seed_legacy; mkdir -p "$UNIT_DIR/locked.target.wants"; chmod 000 "$UNIT_DIR/locked.target.wants"
    refuses "$mode: a directory even sudo -n cannot list refuses" "with sudo -n" "${args[@]}"
    chmod 755 "$UNIT_DIR/locked.target.wants"
  fi
  # Fail closed when sudo -n itself refuses a read or a listing.
  reset; seed_legacy
  MOCK_SUDO_DENY_CMD="cat" refuses "$mode: sudo -n refusing to read a unit refuses" "with sudo -n" "${args[@]}"
  reset; seed_legacy
  MOCK_SUDO_DENY_CMD="find" refuses "$mode: sudo -n refusing to list the unit directory refuses" "could not list" "${args[@]}"
  # Without an ad-hoc unit, so the denied read is the duplicate-owner scan itself.
  reset; printf '[Service]\nExecStart=/usr/local/bin/other\n' >"$UNIT_DIR/other.service"
  MOCK_SUDO_DENY_CMD="cat" refuses "$mode: sudo -n refusing to read a candidate owner refuses" "could not read other.service with sudo -n" "${args[@]}"
  # Symlinked drop-in and dependency directories are followed.
  reset; seed_legacy; mkdir -p "$TMP/etc/overrides"; ln -s "$TMP/etc/overrides" "$UNIT_DIR/other.service.d"
  printf '[Service]\nExecStartPost=/usr/sbin/ethtool --set-eee eth0 eee on\n' >"$TMP/etc/overrides/eee.conf"
  refuses "$mode: a symlinked drop-in directory that sets EEE refuses" "other.service.d/eee.conf also sets EEE" "${args[@]}"
  reset; seed_legacy; mkdir -p "$TMP/etc/wants"; ln -s "$TMP/etc/wants" "$UNIT_DIR/multi-user.target.wants"
  printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee %%i eee on\n' >"$UNIT_DIR/other-eee@.service"
  ln -s "$UNIT_DIR/other-eee@.service" "$TMP/etc/wants/other-eee@eth0.service"
  refuses "$mode: an instance enabled through a symlinked wants directory refuses" "other-eee@eth0.service is enabled" "${args[@]}"
  # A file name the enumeration cannot represent refuses.
  reset; seed_legacy; mkdir -p "$UNIT_DIR/x.service.d"; printf '[Service]\n' >"$UNIT_DIR/x.service.d/10-a
20-b.conf"
  refuses "$mode: a drop-in name containing a newline refuses" "could not list" "${args[@]}"
  if [[ "$(/usr/bin/id -u)" != 0 ]]; then
    # A link whose target only root can reach is live, not dangling: it is read as
    # root, and a denied read refuses rather than being skipped.
    reset; mkdir -p "$TMP/etc/private"; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee eth0 eee on\n' >"$TMP/etc/private/hidden.service"
    ln -s "$TMP/etc/private/hidden.service" "$UNIT_DIR/hidden.service"; chmod 000 "$TMP/etc/private"
    MOCK_ROOT_ONLY="$TMP/etc/private" refuses "$mode: a link into a root-only directory that sets EEE refuses" "hidden.service also sets EEE" "${args[@]}"
    MOCK_ROOT_ONLY="$TMP/etc/private" MOCK_SUDO_DENY_CMD="cat" \
      refuses "$mode: a link into a root-only directory whose read sudo -n denies refuses" "could not read hidden.service with sudo -n" "${args[@]}"
    chmod 755 "$TMP/etc/private"
  fi
  # A link target that cannot be read inside the privileged enumeration refuses, so
  # an extra link to the ad-hoc unit cannot be missed.
  reset; seed_legacy; mkdir -p "$UNIT_DIR/other.target.wants"; ln -s ../eth0-eee-off.service "$UNIT_DIR/other.target.wants/alias.service"
  MOCK_READLINK_FAIL=1 refuses "$mode: a link target that cannot be read refuses" "could not list" "${args[@]}"
  reset; seed_legacy; ln -s "$TMP/etc/nonexistent.service" "$UNIT_DIR/ghost.service"
  run "${args[@]}"
  check "$mode: a genuinely dangling link is skipped" '[[ "$RC" -eq 0 ]]'

  reset; seed_legacy; echo enabled-runtime >"$STATE/enabled.eth0-eee-off.service"
  refuses "$mode: an ad-hoc unit in an unsupported enablement state refuses" "enabled-runtime" "${args[@]}"
done

# --- apply: adopt the ad-hoc unit ---------------------------------------------------------
reset; seed_legacy
LEGACY_BEFORE="$(cat "$LEGACY")"
run "$TARGET" eth0 --apply
check "apply with the ad-hoc unit present succeeds" '[[ "$RC" -eq 0 && "$OUT" == *"OK: EEE is off on eth0"* ]]'
check "the managed template is installed with the pinned ethtool and revision" 'grep -Fxq "ExecStart=$BIN/ethtool --set-eee %i eee off" "$MANAGED" && grep -q "$SHA" "$MANAGED" && ! grep -Eq "@[A-Z_]+@" "$MANAGED"'
check "the managed template is wanted by the interface device and by multi-user.target" 'grep -Fxq "WantedBy=sys-subsystem-net-devices-%i.device multi-user.target" "$MANAGED"'
check "the managed template carries a start limit" 'grep -Fxq "StartLimitBurst=5" "$MANAGED"'
# A unit-wide job timeout would also count the wait behind basic.target, so a slow
# boot (a long fsck) would cancel both jobs and leave EEE on. The device job's own
# timeout (DefaultDeviceTimeoutSec=) bounds the wait for a missing interface.
check "neither template sets a job timeout that a slow boot could expire" '! grep -Eq "^Job(Running)?TimeoutSec=" "$MANAGED" && ! grep -Eq "^Job(Running)?TimeoutSec=" "$WATCH_TEMPLATE"'
check "the managed instance is enabled and active" '[[ -e "$STATE/enabled.$INSTANCE" && -e "$STATE/active.$INSTANCE" ]]'
check "the managed instance is wanted by the interface device" '[[ -L "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants/$INSTANCE" ]]'
check "the watcher template is installed rendered with the revision and pinned paths" '[[ -f "$WATCH_TEMPLATE" ]] && ! grep -Eq "@[A-Z_]+@" "$WATCH_TEMPLATE" && grep -Fq "$SHA" "$WATCH_TEMPLATE" && grep -Fq "$BIN/ip -o monitor link" "$WATCH_TEMPLATE" && grep -Fq "$BIN/ethtool" "$WATCH_TEMPLATE"'
check "both units are enabled and active with all four device and boot links" 'four_links && both_live'
check "the verification reports the watcher active and the boot re-apply" '[[ "$OUT" == *"verify: $WATCH is active"* && "$OUT" == *"OK: re-applied at every boot"* ]]'
check "the instance is enabled, reset, and restarted, then the watcher enabled and restarted, before the ad-hoc unit is disabled" 'in_order "^sudo -n systemctl enable $INSTANCE\$" "^sudo -n systemctl reset-failed $INSTANCE\$" "^sudo -n systemctl restart $INSTANCE\$" "^sudo -n systemctl enable $WATCH\$" "^sudo -n systemctl reset-failed $WATCH\$" "^sudo -n systemctl restart $WATCH\$" "^sudo -n systemctl disable eth0-eee-off.service\$"'
check "the ad-hoc unit's device link is gone" '[[ ! -e "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants/eth0-eee-off.service" && ! -L "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants/eth0-eee-off.service" ]]'
check "the unit itself turned EEE off through ethtool" '[[ "$(cat "$STATE/eee.eth0")" == disabled ]] && [[ "$OUT" == *"EEE status: disabled"* ]]'
check "the ad-hoc unit is disabled and removed" '[[ ! -e "$LEGACY" && ! -e "$STATE/enabled.eth0-eee-off.service" ]]'
check "the ad-hoc unit is backed up verbatim" '[[ "$(cat "$LEGACY.previous-$SHA")" == "$LEGACY_BEFORE" ]]'
check "exactly one loadable unit sets EEE on eth0 afterwards" '[[ "$(grep -l -- "--set-eee" "$UNIT_DIR"/*.service | wc -l | tr -d " ")" == 1 ]]'
check "the managed instance is enabled and verified before the ad-hoc unit is disabled" '[[ "$(line_of "systemctl restart $INSTANCE")" -lt "$(line_of "systemctl disable eth0-eee-off.service")" ]]'
check "the rollback recipe restores the ad-hoc unit and removes the managed one" '[[ "$OUT" == *"mv -f $LEGACY.previous-$SHA $LEGACY"* && "$OUT" == *"systemctl enable eth0-eee-off.service"* && "$OUT" == *"systemctl stop $INSTANCE"* && "$OUT" == *"systemctl disable $INSTANCE"* && "$OUT" == *"rm -f $MANAGED"* ]]'
check "the rollback recipe says stopping does not turn EEE back on" '[[ "$OUT" == *"--set-eee eth0 eee on"* ]]'
ADOPT_OUT="$OUT"
check "apply payload parent is cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'

# Executing the printed recipe restores the pre-deploy files, enablement, and activity.
reset; seed_legacy; PRE_STATE="$(unit_state)"
run "$TARGET" eth0 --apply
DEPLOY_RC=$RC; run_rollback; RB=$?
check "the adoption rollback recipe restores the exact pre-deploy unit state" '[[ "$DEPLOY_RC" -eq 0 && "$OUT" == *"OK: EEE is off"* && "$OUT" == *Rollback* && "$RB" -eq 0 && "$(unit_state)" == "$PRE_STATE" && "$(cat "$LEGACY")" == "$LEGACY_BEFORE" ]]'
reset; seed_legacy
run "$TARGET" eth0 --apply
OUT="$ADOPT_OUT"
# A second run of the same revision changes nothing.
: >"$CALLS"; before="$(tree_state)"
run "$TARGET" eth0 --apply
check "re-applying the same revision is a verified no-op" '[[ "$RC" -eq 0 && "$OUT" == *"already in place"* && "$(tree_state)" == "$before" ]] && no_mutation'

if [[ "$(/usr/bin/id -u)" != 0 ]]; then
  # A root-only managed template and device dependency directory are inspected as
  # root, so an installation that is already in place is still a no-op.
  chmod 000 "$MANAGED" "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants"
  : >"$CALLS"; before="$(tree_state)"
  MOCK_ROOT_ONLY="$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants $MANAGED" run "$TARGET" eth0 --apply
  check "a root-only managed template and device dependency are read as root (still a no-op)" '[[ "$RC" -eq 0 && "$OUT" == *"already in place"* && "$(tree_state)" == "$before" ]] && no_mutation'
  chmod 755 "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants"; chmod 644 "$MANAGED"
fi

# A later revision backs up the managed template and keeps the instance enabled.
echo "second revision" >>"$REPO/README.md"; git -C "$REPO" commit -qam second
SHA2="$(git -C "$REPO" rev-parse HEAD)"
MANAGED_BEFORE="$(cat "$MANAGED")"
: >"$CALLS"
BROKKR_EXPECTED_COMMIT="$SHA2" run "$TARGET" eth0 --apply
check "a later revision enables the already enabled instance again" 'grep -Fxq "sudo -n systemctl enable $INSTANCE" "$CALLS"'
check "a later revision replaces the managed template" '[[ "$RC" -eq 0 ]] && grep -q "$SHA2" "$MANAGED" && [[ "$(cat "$MANAGED.previous-$SHA2")" == "$MANAGED_BEFORE" ]]'
check "a later revision's rollback restores the previous template without disabling" '[[ "$OUT" == *"mv -f $MANAGED.previous-$SHA2 $MANAGED"* && "$OUT" != *"systemctl disable"*"$INSTANCE"* ]]'
run_rollback; RB=$?
check "a later revision's rollback recipe restores the previous template, still enabled and active" '[[ "$RB" -eq 0 && "$(cat "$MANAGED")" == "$MANAGED_BEFORE" && -e "$STATE/enabled.$INSTANCE" && -e "$STATE/active.$INSTANCE" ]]'
# A watcher that was running is stopped before its template is restored, so it cannot
# restart the managed unit mid-rollback, and is started again at the end.
recipe_line() { printf '%s\n' "$OUT" | sed -n '/^Rollback/,$p' | grep -nF -- "$1" | head -1 | cut -d: -f1; }
check "a later revision's rollback stops the running watcher first and restarts it last" '[[ -n "$(recipe_line "systemctl stop $WATCH")" && "$(recipe_line "systemctl stop $WATCH")" -lt "$(recipe_line "mv -f $WATCH_TEMPLATE.previous-$SHA2")" && "$(recipe_line "systemctl daemon-reload")" -lt "$(recipe_line "systemctl restart $WATCH")" ]]'
check "a later revision's rollback leaves the watcher enabled and active on its previous template" '[[ -e "$STATE/enabled.$WATCH" && -e "$STATE/active.$WATCH" && -f "$WATCH_TEMPLATE" && ! -e "$WATCH_TEMPLATE.previous-$SHA2" ]]'
git -C "$REPO" reset -q --hard "$SHA"

# A previously enabled but inactive instance is not left active by the rollback.
reset; run "$TARGET" eth0 --apply; rm -f "$STATE/active.$INSTANCE"
echo "third revision" >>"$REPO/README.md"; git -C "$REPO" commit -qam third
SHA3="$(git -C "$REPO" rev-parse HEAD)"
PRE_STATE="$(unit_state)"; MANAGED_BEFORE="$(cat "$MANAGED")"
BROKKR_EXPECTED_COMMIT="$SHA3" run "$TARGET" eth0 --apply
DEPLOY_RC=$RC; run_rollback; RB=$?
check "rollback of an upgrade over an inactive instance restores it inactive" '[[ "$DEPLOY_RC" -eq 0 && "$OUT" == *"systemctl stop $INSTANCE"* && "$RB" -eq 0 && "$(unit_state)" == "$PRE_STATE" && "$(cat "$MANAGED")" == "$MANAGED_BEFORE" ]]'
git -C "$REPO" reset -q --hard "$SHA"

# A previously active but disabled instance whose restart fails is restarted on the
# previous template by the rollback, not left stopped.
reset; run "$TARGET" eth0 --apply; systemctl disable "$INSTANCE" >/dev/null
echo "fourth revision" >>"$REPO/README.md"; git -C "$REPO" commit -qam fourth
SHA4="$(git -C "$REPO" rev-parse HEAD)"
PRE_STATE="$(unit_state)"; MANAGED_BEFORE="$(cat "$MANAGED")"
MOCK_START_FAIL=1 BROKKR_EXPECTED_COMMIT="$SHA4" run "$TARGET" eth0 --apply
DEPLOY_RC=$RC; run_rollback; RB=$?
check "rollback after a failed restart of an active, disabled instance restores it active and disabled" '[[ "$DEPLOY_RC" -ne 0 && "$OUT" == *"did not succeed"* && "$RB" -eq 0 && "$(unit_state)" == "$PRE_STATE" && "$(cat "$MANAGED")" == "$MANAGED_BEFORE" ]]'
git -C "$REPO" reset -q --hard "$SHA"

# --- apply: fresh host, no ad-hoc unit -----------------------------------------------------
reset
run "$TARGET" eth0 --apply
check "apply without an ad-hoc unit succeeds" '[[ "$RC" -eq 0 && "$OUT" == *"OK: EEE is off on eth0"* && -e "$STATE/enabled.$INSTANCE" ]]'
check "apply without an ad-hoc unit neither backs up nor mentions one" '[[ -z "$(find "$UNIT_DIR" -name "*.previous-*" -print)" && "$OUT" != *"eth0-eee-off.service"* ]]'
check "apply without an ad-hoc unit installs and starts the watcher with all four links" '[[ -f "$WATCH_TEMPLATE" ]] && four_links && both_live && [[ "$OUT" == *"verify: $WATCH is active"* ]]'
check "a fresh host enables the instance, resets its failed state, restarts it, then enables and restarts the watcher" 'in_order "^sudo -n systemctl enable $INSTANCE\$" "^sudo -n systemctl reset-failed $INSTANCE\$" "^sudo -n systemctl restart $INSTANCE\$" "^sudo -n systemctl enable $WATCH\$" "^sudo -n systemctl reset-failed $WATCH\$" "^sudo -n systemctl restart $WATCH\$"'

# --- apply failures keep the ad-hoc unit in charge -------------------------------------------
reset; seed_legacy; export MOCK_START_FAIL=1
run "$TARGET" eth0 --apply
check "a failed first run keeps the ad-hoc unit enabled and in place" '[[ "$RC" -ne 0 && -f "$LEGACY" && -e "$STATE/enabled.eth0-eee-off.service" ]]'
check "a failed first run prints a rollback for the managed unit only" '[[ "$OUT" == *Rollback* && "$OUT" == *"rm -f $MANAGED"* && "$OUT" != *"mv -f $LEGACY.previous"* ]]'
reset; seed_legacy; export MOCK_ETHTOOL_NOOP=1; PRE_STATE="$(unit_state)"
run "$TARGET" eth0 --apply
DEPLOY_RC=$RC; run_rollback; RB=$?
check "a failed verification's rollback recipe restores the exact pre-deploy unit state" '[[ "$DEPLOY_RC" -ne 0 && "$OUT" == *"EEE is still not disabled"* && "$OUT" == *Rollback* && "$RB" -eq 0 && "$(unit_state)" == "$PRE_STATE" ]]'
reset; seed_legacy; export MOCK_ETHTOOL_NOOP=1
run "$TARGET" eth0 --apply
check "EEE still on after the run fails verification and keeps the ad-hoc unit" '[[ "$RC" -ne 0 && "$OUT" == *"EEE is still not disabled"* && -f "$LEGACY" && -e "$STATE/enabled.eth0-eee-off.service" && "$OUT" == *Rollback* ]]'
reset; seed_legacy; export MOCK_CP_FAIL="eth0-eee-off.service.previous"
run "$TARGET" eth0 --apply
check "a failed backup changes nothing" '[[ "$RC" -ne 0 && "$OUT" == *"could not back up"* && -f "$LEGACY" && ! -e "$MANAGED" ]] && ! grep -Eq "^systemctl (enable|restart|disable)" "$CALLS"'
check "a failed backup reports that nothing was changed" '[[ "$OUT" == *"no unit was changed"* ]]'
reset; seed_legacy; export MOCK_MV_FAIL="eth0-eee-off.service.previous"
run "$TARGET" eth0 --apply
check "a failed backup finalisation changes nothing and leaves no temporary backup" '[[ "$RC" -ne 0 && "$OUT" == *"could not finalize"* && "$OUT" == *"no unit was changed"* && -f "$LEGACY" && ! -e "$MANAGED" && -z "$(find "$UNIT_DIR" -name ".*.tmp" -print)" ]] && ! grep -Eq "^systemctl (enable|restart|disable)" "$CALLS"'

# A watcher that cannot start keeps the ad-hoc unit in charge and rolls back exactly.
reset; seed_legacy; PRE_STATE="$(unit_state)"
MOCK_WATCH_START_FAIL=1 run "$TARGET" eth0 --apply
check "a watcher start failure fails the deploy and keeps the ad-hoc unit enabled and in place" '[[ "$RC" -ne 0 && "$OUT" == *"$WATCH"* && "$OUT" == *Rollback* && -f "$LEGACY" && -e "$STATE/enabled.eth0-eee-off.service" ]]'
run_rollback; RB=$?
check "a watcher start failure's rollback recipe restores the exact pre-deploy unit state" '[[ "$RB" -eq 0 && "$(unit_state)" == "$PRE_STATE" && -f "$LEGACY" ]]'

# Each partial apply prints a rollback that restores the exact pre-deploy state.
partial() { # name expected-output env-assignment...
  local name=$1 want=$2; shift 2
  reset; seed_legacy; PRE_STATE="$(unit_state)"
  OUT="$(cd "$REPO" && env "$@" bash "$DEPLOY" "$TARGET" eth0 --apply 2>&1)"; RC=$?
  run_rollback; RB=$?
  check "$name" '[[ "$RC" -ne 0 && "$OUT" == *"$want"* && "$OUT" == *Rollback* && "$RB" -eq 0 && "$(unit_state)" == "$PRE_STATE" && -f "$LEGACY" ]]'
}
partial "a failed template install rolls back to the pre-deploy state" "install: injected failure" MOCK_INSTALL_FAIL=1
partial "a failed daemon-reload rolls back to the pre-deploy state" "systemctl: injected failure" MOCK_SYSTEMCTL_FAIL=daemon-reload
partial "a failed enable rolls back to the pre-deploy state" "systemctl: injected failure" "MOCK_SYSTEMCTL_FAIL=enable $INSTANCE"
partial "a failed ad-hoc disable says both units are enabled and rolls back" "both units are enabled" "MOCK_SYSTEMCTL_FAIL=disable eth0-eee-off.service"

# A unit that sets EEE on another interface is not a second owner of this one.
reset; seed_legacy; printf '[Unit]\nAfter=sys-subsystem-net-devices-eth1.device\n[Service]\nExecStart=/usr/sbin/ethtool --set-eee eth1 eee off\n' >"$UNIT_DIR/eth1-eee.service"
run "$TARGET" eth0 --apply
check "a unit setting EEE on a different interface does not block the deploy" '[[ "$RC" -eq 0 && "$OUT" == *"OK: EEE is off on eth0"* ]]'

# Re-applying the installed revision recovers a degraded instance.
for recover in inactive disabled eee-on; do
  reset; run "$TARGET" eth0 --apply
  case $recover in
    inactive) systemctl stop "$INSTANCE" >/dev/null ;;
    disabled) systemctl disable "$INSTANCE" >/dev/null ;;
    eee-on) echo 'enabled - active' >"$STATE/eee.eth0" ;;
  esac
  run "$TARGET" eth0 --apply
  check "re-applying the same revision recovers a $recover instance" '[[ "$RC" -eq 0 && "$OUT" == *"OK: EEE is off"* && "$OUT" != *"already in place"* && -e "$STATE/enabled.$INSTANCE" && -e "$STATE/active.$INSTANCE" && -L "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants/$INSTANCE" && "$(cat "$STATE/eee.eth0")" == disabled ]]'
done

# "Already in place" also needs the boot links, the watcher enabled and active, so a
# host that lost any of them is repaired by re-applying the same revision.
for lost in boot-instance-link stop-watcher boot-watcher-link; do
  reset; run "$TARGET" eth0 --apply
  case $lost in
    boot-instance-link) rm -f "$BOOT_WANTS/$INSTANCE" ;;
    stop-watcher) systemctl stop "$WATCH" >/dev/null ;;
    boot-watcher-link) rm -f "$BOOT_WANTS/$WATCH" ;;
  esac
  run "$TARGET" eth0 --apply
  check "re-applying the same revision repairs a host that lost $lost" '[[ "$RC" -eq 0 && "$OUT" != *"already in place"* ]] && four_links && both_live'
done

# Migration from the previous release: the template had only the device WantedBy, no
# watcher, and the instance was enabled through the device dependency alone.
OLD_SHA=1111111111111111111111111111111111111111
reset
cat >"$MANAGED" <<UNIT
[Unit]
Description=Brokkr: keep Energy Efficient Ethernet off on %i (revision $OLD_SHA)
Documentation=https://github.com/Magnus-Gille/brokkr/blob/main/docs/eee-off.md
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN/ethtool --set-eee %i eee off

[Install]
WantedBy=sys-subsystem-net-devices-%i.device
UNIT
mkdir -p "$DEV_WANTS"; ln -s "$MANAGED" "$DEV_WANTS/$INSTANCE"
touch "$STATE/enabled.$INSTANCE" "$STATE/active.$INSTANCE"; echo disabled >"$STATE/eee.eth0"
PRE_STATE="$(unit_state)"; OLD_MANAGED="$(cat "$MANAGED")"
run "$TARGET" eth0 --apply
check "migrating from the previous release succeeds and is not a no-op" '[[ "$RC" -eq 0 && "$OUT" != *"already in place"* && "$OUT" == *"OK: EEE is off"* ]]'
check "migration backs up the previous template" '[[ "$(cat "$MANAGED.previous-$SHA" 2>/dev/null)" == "$OLD_MANAGED" ]]'
check "migration adds the boot link and installs and starts the watcher" '[[ -L "$BOOT_WANTS/$INSTANCE" && -f "$WATCH_TEMPLATE" ]] && four_links && both_live'
check "the migration rollback recipe removes the added boot link and the watcher" '[[ "$OUT" == *"rm -f $UNIT_DIR/multi-user.target.wants/$INSTANCE"* && "$OUT" == *"systemctl disable $WATCH"* && "$OUT" == *"rm -f $WATCH_TEMPLATE"* ]]'
run_rollback; RB=$?
check "the migration rollback recipe restores the exact pre-deploy unit state" '[[ "$RB" -eq 0 && "$(unit_state)" == "$PRE_STATE" && "$(cat "$MANAGED")" == "$OLD_MANAGED" && ! -e "$BOOT_WANTS/$INSTANCE" && ! -L "$BOOT_WANTS/$INSTANCE" && ! -e "$WATCH_TEMPLATE" && ! -e "$STATE/enabled.$WATCH" && ! -e "$STATE/active.$WATCH" ]]'

# --- the rendered watcher script itself -----------------------------------------------------
# Extract it as systemd would: join continued lines, take the ExecStart= value, keep the
# text between the first and the last quote, and turn "$$" back into "$".
extract_watch_script() { # unit-file -> the sh -c script on stdout
  local line cur='' value='' dd='$$' d='$' bs=$'\\'
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *"$bs" ]]; then cur+="${line%"$bs"} "; continue; fi
    cur+="$line"
    if [[ "$cur" == ExecStart=* ]]; then value=${cur#ExecStart=}; break; fi
    cur=
  done <"$1"
  [[ "$value" == *"'"* ]] || return 0
  value=${value#*"'"}; value=${value%"'"*}
  printf '%s' "${value//"$dd"/$d}"
}
WBIN="$TMP/wbin"; WLOG="$TMP/watch.log"; IPLINES="$TMP/ip.lines"; mkdir -p "$WBIN"
cat >"$WBIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_WLOG"
if [[ "${1:-}" == is-failed ]]; then [[ "${MOCK_UNIT_FAILED:-0}" == 1 ]]; exit; fi
exit 0
FAKE
chmod 755 "$WBIN/systemctl"
# run_watch IP-LINE... : runs the extracted script against the fake ip lines.
run_watch() {
  : >"$WLOG"; : >"$IPLINES"
  local l; for l in "$@"; do printf '%s\n' "$l" >>"$IPLINES"; done
  W_ERR="$(env PATH="$WBIN:/usr/bin:/bin" MOCK_WLOG="$WLOG" MOCK_IP_LINES="$IPLINES" \
    sh -c "$WATCH_SCRIPT" brokkr-eee-off-watch eth0 2>&1 >/dev/null </dev/null)"
  W_RESTARTS="$(grep -cx "restart --no-block $INSTANCE" "$WLOG" || true)"
}
reset; run "$TARGET" eth0 --apply
WATCH_SCRIPT="$(extract_watch_script "$WATCH_TEMPLATE")"
check "the rendered watcher script is extracted without placeholders or doubled dollars" '[[ -n "$WATCH_SCRIPT" ]] && ! grep -Eq "@[A-Z_]+@" <<<"$WATCH_SCRIPT" && [[ "$WATCH_SCRIPT" != *"\$\$"* ]]'
UP='2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default'
DOWN='2: eth0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc fq_codel state DOWN mode DEFAULT group default'
echo disabled >"$STATE/eee.eth0"; run_watch
check "watcher: EEE already disabled and no link event restarts nothing" '[[ -n "$WATCH_SCRIPT" && "$W_RESTARTS" == 0 ]]'
echo 'enabled - active' >"$STATE/eee.eth0"; run_watch
check "watcher: EEE enabled at start restarts the unit once" '[[ "$W_RESTARTS" == 1 ]]'
: >"$CALLS"; echo disabled >"$STATE/eee.eth0"; run_watch
check "watcher: the start check reads EEE only after ip monitor is listening" '[[ -n "$(line_of "^ip -o monitor link (subscribed)")" && -n "$(line_of "^ethtool --show-eee eth0")" && "$(line_of "^ip -o monitor link (subscribed)")" -lt "$(line_of "^ethtool --show-eee eth0")" ]]'
echo 'enabled - active' >"$STATE/eee.eth0"
run_watch "$UP"
check "watcher: a LOWER_UP event of the interface with EEE enabled restarts the unit again" '[[ "$W_RESTARTS" == 2 ]]'
run_watch "$DOWN"
check "watcher: a NO-CARRIER event does not restart the unit" '[[ "$W_RESTARTS" == 1 ]]'
run_watch "Deleted $UP"
check "watcher: a deleted-link event does not restart the unit" '[[ "$W_RESTARTS" == 1 ]]'
run_watch '3: eth01: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500' '4: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500'
check "watcher: events of other interfaces (eth01, eth1) do not restart the unit" '[[ "$W_RESTARTS" == 1 ]]'
MOCK_EEE_UNSUPPORTED=1 run_watch "$UP"
check "watcher: an interface without EEE support restarts nothing" '[[ -n "$WATCH_SCRIPT" && "$W_RESTARTS" == 0 ]]'
MOCK_UNIT_FAILED=1 run_watch "$UP"
check "watcher: a failed unit is not restarted and the reason is reported" '[[ -n "$WATCH_SCRIPT" && "$W_RESTARTS" == 0 && "$W_ERR" == *"has failed"* ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
