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
echo "unrelated file that must never ship" > "$REPO/README.md"
git init -q "$REPO"; git -C "$REPO" config user.name test; git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add . ; git -C "$REPO" commit -qm fixture
SHA="$(git -C "$REPO" rev-parse HEAD)"
DEPLOY="$REPO/scripts/deploy-eee-off.sh"
MANAGED="$UNIT_DIR/brokkr-eee-off@.service"
INSTANCE=brokkr-eee-off@eth0.service
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
  BROKKR_ETHTOOL_SEARCH_PATH="$MOCK_NOSBIN" BROKKR_SYSTEMD_SYSTEM_DIR="$MOCK_UNIT_DIR" \
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
exec "$@"
FAKE
# The fake systemctl runs a started unit's ExecStart (with %i expanded), so the
# rendered unit is exercised end to end against the fake ethtool.
cat >"$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_CALLS"
st=$MOCK_STATE
start_unit() {
  local u=$1 inst= tpl line
  [[ "${MOCK_START_FAIL:-0}" != 1 ]] || return 1
  case $u in
    *@*.service) inst=${u#*@}; inst=${inst%.service}; tpl="$MOCK_UNIT_DIR/${u%%@*}@.service" ;;
    *) tpl="$MOCK_UNIT_DIR/$u" ;;
  esac
  [[ -f "$tpl" ]] || return 5
  line=$(sed -n 's/^ExecStart=//p' "$tpl")
  line=${line//%i/$inst}
  # shellcheck disable=SC2086 # deliberate word splitting of the unit's command line
  $line || return 1
  touch "$st/active.$u"
}
case "${1:-}" in
  daemon-reload) exit 0 ;;
  enable)
    touch "$st/enabled.$2"
    case $2 in *@*.service) inst=${2#*@}; inst=${inst%.service}; tpl="$MOCK_UNIT_DIR/${2%%@*}@.service" ;; *) inst=; tpl="$MOCK_UNIT_DIR/$2" ;; esac
    wb=$(sed -n 's/^WantedBy=//p' "$tpl"); wb=${wb//%i/$inst}
    if [[ -n "$wb" ]]; then mkdir -p "$MOCK_UNIT_DIR/$wb.wants"; ln -sfn "$tpl" "$MOCK_UNIT_DIR/$wb.wants/$2"; fi ;;
  disable)
    u=$2; [[ "$u" == --now ]] && { u=$3; rm -f "$st/active.$u"; }
    rm -f "$st/enabled.$u"; find "$MOCK_UNIT_DIR" -path "*.wants/$u" -type l -exec rm -f {} + ;;
  stop) rm -f "$st/active.$2" ;;
  start) start_unit "$2" || exit 1 ;;
  restart) rm -f "$st/active.$2"; start_unit "$2" || exit 1 ;;
  # An enabled.* file may hold a non-default state such as enabled-runtime.
  is-enabled)
    if [[ -e "$st/enabled.$2" ]]; then state=$(cat "$st/enabled.$2"); echo "${state:-enabled}"
    else echo disabled; exit 1; fi ;;
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
# Fault injection: cp fails when its destination matches.
cat >"$BIN/cp" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${MOCK_CP_FAIL:-}" && "${!#}" == *"$MOCK_CP_FAIL"* ]]; then echo "cp: injected failure" >&2; exit 1; fi
exec /bin/cp "$@"
FAKE
chmod 755 "$BIN/"* "$STORE/ethtool"

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
reset() {
  rm -rf "${TMP:?}/etc" "${TMP:?}/sys" "${STATE:?}"
  mkdir -p "$UNIT_DIR" "$SYSFS/eth0" "$STATE"
  rm -f "$BIN/ethtool" "$MOCK_NOSBIN/ethtool"
  : >"$CALLS"
  unset MOCK_ID_ROOT MOCK_REMOTE_ROOT MOCK_SUDO_DENY MOCK_START_FAIL MOCK_ETHTOOL_NOOP MOCK_EEE_UNSUPPORTED MOCK_CP_FAIL
  export BROKKR_EXPECTED_SOURCE="$REPO" BROKKR_EXPECTED_COMMIT="$SHA"
  has_ethtool
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

echo "deploy-eee-off.test.sh"
reset
check "fixture precondition: the example unit and deploy script are committed" '[[ -f "$REPO/network/brokkr-eee-off@.service.example" && -f "$DEPLOY" ]]'

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
check "dry-run payload parent is cleaned" '[[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]]'

# --- remote refusals: identical for dry-run and --apply, nothing changes ------------------
for mode in dry-run apply; do
  args=("$TARGET" eth0); [[ "$mode" == apply ]] && args+=(--apply)
  reset; seed_legacy; export MOCK_REMOTE_ROOT=1
  refuses "$mode: remote runtime user root refuses" "must not be root" "${args[@]}"
  reset; seed_legacy; rm -f "$BIN/ethtool"
  refuses "$mode: missing ethtool refuses (never installs)" "ethtool is required" "${args[@]}"
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
  reset; seed_legacy; touch "$STATE/enabled.$INSTANCE"
  refuses "$mode: an instance enabled without its device dependency refuses" "without its device dependency" "${args[@]}"
  # Inspection must be complete: systemd reads these as root, the operator may not.
  if [[ "$(/usr/bin/id -u)" != 0 ]]; then
    reset; seed_legacy; printf '[Service]\nExecStart=/usr/sbin/ethtool --set-eee eth0 eee on\n' >"$UNIT_DIR/secret.service"; chmod 000 "$UNIT_DIR/secret.service"
    refuses "$mode: an unreadable unit file refuses" "cannot read secret.service" "${args[@]}"
    chmod 644 "$UNIT_DIR/secret.service"
    reset; seed_legacy; mkdir -p "$UNIT_DIR/locked.target.wants"; chmod 000 "$UNIT_DIR/locked.target.wants"
    refuses "$mode: an unreadable unit directory refuses" "could not read every directory" "${args[@]}"
    chmod 755 "$UNIT_DIR/locked.target.wants"
  fi
  reset; seed_legacy; echo enabled-runtime >"$STATE/enabled.eth0-eee-off.service"
  refuses "$mode: an ad-hoc unit in an unsupported enablement state refuses" "enabled-runtime" "${args[@]}"
done

# --- apply: adopt the ad-hoc unit ---------------------------------------------------------
reset; seed_legacy
LEGACY_BEFORE="$(cat "$LEGACY")"
run "$TARGET" eth0 --apply
check "apply with the ad-hoc unit present succeeds" '[[ "$RC" -eq 0 && "$OUT" == *"OK: EEE is off on eth0"* ]]'
check "the managed template is installed with the pinned ethtool and revision" 'grep -Fxq "ExecStart=$BIN/ethtool --set-eee %i eee off" "$MANAGED" && grep -q "$SHA" "$MANAGED" && ! grep -Eq "@[A-Z_]+@" "$MANAGED"'
check "the managed template is wanted by the interface device" 'grep -Fxq "WantedBy=sys-subsystem-net-devices-%i.device" "$MANAGED"'
check "the managed instance is enabled and active" '[[ -e "$STATE/enabled.$INSTANCE" && -e "$STATE/active.$INSTANCE" ]]'
check "the managed instance is wanted by the interface device" '[[ -L "$UNIT_DIR/sys-subsystem-net-devices-eth0.device.wants/$INSTANCE" ]]'
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

# A later revision backs up the managed template and keeps the instance enabled.
echo "second revision" >>"$REPO/README.md"; git -C "$REPO" commit -qam second
SHA2="$(git -C "$REPO" rev-parse HEAD)"
MANAGED_BEFORE="$(cat "$MANAGED")"
: >"$CALLS"
BROKKR_EXPECTED_COMMIT="$SHA2" run "$TARGET" eth0 --apply
check "a later revision replaces the managed template" '[[ "$RC" -eq 0 ]] && grep -q "$SHA2" "$MANAGED" && [[ "$(cat "$MANAGED.previous-$SHA2")" == "$MANAGED_BEFORE" ]]'
check "a later revision's rollback restores the previous template without disabling" '[[ "$OUT" == *"mv -f $MANAGED.previous-$SHA2 $MANAGED"* && "$OUT" != *"systemctl disable"*"$INSTANCE"* ]]'
run_rollback; RB=$?
check "a later revision's rollback recipe restores the previous template, still enabled and active" '[[ "$RB" -eq 0 && "$(cat "$MANAGED")" == "$MANAGED_BEFORE" && -e "$STATE/enabled.$INSTANCE" && -e "$STATE/active.$INSTANCE" ]]'
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

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
