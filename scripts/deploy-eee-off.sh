#!/usr/bin/env bash
# Brokkr · keep Energy Efficient Ethernet (EEE) off on one wired interface of a fleet
# node, as a revision-bound systemd system unit. Run from the control node; the node
# is reached over ssh as a non-root operator with passwordless sudo.
#
# Dry-run by default: the remote preflight (identity, sudo, interface, ethtool, EEE
# support, the ad-hoc unit to adopt, duplicate units, backup targets) runs and nothing
# is changed. Pass --apply to install. An existing ad-hoc <iface>-eee-off.service is
# backed up, and disabled and removed only after the managed unit has turned EEE off.
# See docs/eee-off.md.
#
#   BROKKR_EXPECTED_SOURCE=$PWD BROKKR_EXPECTED_COMMIT=<full-sha> \
#     scripts/deploy-eee-off.sh [--apply] operator@node-a.example eth0
set -euo pipefail

ENTRY_SCRIPT="${BASH_SOURCE[0]}"
ENTRY_PATH="$ENTRY_SCRIPT"
[[ "$ENTRY_PATH" == /* ]] || ENTRY_PATH="$(pwd -P)/$ENTRY_PATH"
[[ "$ENTRY_PATH" != *$'\n'* && "$ENTRY_PATH" != *$'\r'* ]] || { echo "brokkr eee-off deploy: deployment entry point path must not contain line breaks" >&2; exit 64; }
ENTRY_CURSOR=/
IFS=/ read -r -a ENTRY_COMPONENTS <<<"${ENTRY_PATH#/}"
for ENTRY_COMPONENT in "${ENTRY_COMPONENTS[@]}"; do
  case "$ENTRY_COMPONENT" in ''|.) continue ;; ..) ENTRY_CURSOR=$(dirname "$ENTRY_CURSOR"); continue ;; esac
  ENTRY_CURSOR="${ENTRY_CURSOR%/}/$ENTRY_COMPONENT"
  [[ ! -L "$ENTRY_CURSOR" ]] || { echo "brokkr eee-off deploy: deployment entry point path must not contain symlinks" >&2; exit 64; }
done
# Resolve only after rejecting every lexical symlink component in the entry path.
SCRIPT_DIR="$(cd "$(dirname "$ENTRY_SCRIPT")" && pwd -P)"
HERE="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=scripts/lib/deploy-source.sh
source "$HERE/scripts/lib/deploy-source.sh"

die() { echo "brokkr eee-off deploy: $*" >&2; exit 64; }
usage() {
  echo "usage: $0 [--apply] SSH_TARGET INTERFACE" >&2
  echo "  env: BROKKR_EXPECTED_SOURCE, BROKKR_EXPECTED_COMMIT (full SHA)" >&2
  exit 64
}

APPLY=0
TARGET=""
IFACE=""
for ARG in "$@"; do
  case "$ARG" in
    --apply) APPLY=1 ;;
    --*) usage ;;
    -*) [[ -n "$TARGET" && -z "$IFACE" ]] || usage; IFACE="$ARG" ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$ARG"
      elif [[ -z "$IFACE" ]]; then IFACE="$ARG"
      else usage
      fi ;;
  esac
done
[[ -n "$TARGET" && -n "$IFACE" ]] || usage
[[ "$TARGET" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(@[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]] || die "invalid SSH target"
[[ "$TARGET" != root@* ]] || die "the SSH target user must not be root (privileged steps use sudo -n)"
# Restricted so the raw instance name (%i) equals the escaped device-unit name: no
# dash, no leading dot, at most IFNAMSIZ-1 characters.
[[ "$IFACE" =~ ^[A-Za-z0-9_][A-Za-z0-9_.]{0,14}$ ]] \
  || die "unsupported interface name (letters, digits, '_' and '.', at most 15, not starting with '.')"
[[ "$(id -u)" != 0 ]] || die "must not run as root"

# This outermost local gate must run before even the remote target preflight.
require_brokkr_deploy_source_binding "$HERE"
REVISION="$BROKKR_EXPECTED_COMMIT"
DEPLOY_PAYLOAD_PARENT=""
DEPLOY_PAYLOAD_ROOT=""
cleanup_deploy_payload() { [[ -z "$DEPLOY_PAYLOAD_PARENT" ]] || rm -rf "$DEPLOY_PAYLOAD_PARENT"; }
trap cleanup_deploy_payload EXIT
trap 'cleanup_deploy_payload; exit 1' HUP INT TERM
materialize_brokkr_deploy_payload "$HERE" "$REVISION"

TEMPLATE_FILE="$DEPLOY_PAYLOAD_ROOT/network/brokkr-eee-off@.service.example"
[[ -f "$TEMPLATE_FILE" && ! -L "$TEMPLATE_FILE" ]] || die "committed payload lacks regular file network/brokkr-eee-off@.service.example"

# Remote scripts run under sh (shipped base64-encoded, so the operator's login shell
# never parses them) and are POSIX-only. The committed template arrives on stdin in
# both modes. Inputs are validated above and below, so single-quoted assignment is safe.
IFS= read -r -d '' REMOTE_COMMON <<'REMOTE' || true
set -eu
umask 077
refuse() { echo "REFUSED: $*" >&2; exit 2; }
safe_path() {
  printf '%s' "$1" | grep -Eq '^/[A-Za-z0-9._/@:+-]+$' || return 1
  if printf '%s' "$1" | grep -Eq '//|/[.][.]?(/|$)'; then return 1; fi
}
work=
on_exit() {
  rc=$?
  if [ -n "$work" ]; then rm -rf "$work"; fi
  if [ "$MODE" = apply ] && [ "${apply_started:-0}" = 1 ]; then print_state; fi
  exit "$rc"
}
trap on_exit EXIT
work=$(mktemp -d)
cat >"$work/template"
user=$(id -un)
uid=$(id -u)
if [ "$uid" = 0 ] || [ "$user" = root ]; then refuse "runtime user must not be root (privileged steps use sudo -n)"; fi
printf '%s' "$IFACE" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.]{0,14}$' || refuse "unsupported interface name"
unit_dir=${BROKKR_SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}
sysfs_net=${BROKKR_SYSFS_NET:-/sys/class/net}
safe_path "$unit_dir" || refuse "systemd unit directory is not an absolute plain path"
safe_path "$sysfs_net" || refuse "sysfs net directory is not an absolute plain path"
[ -d "$unit_dir" ] && [ ! -L "$unit_dir" ] || refuse "systemd unit directory $unit_dir is missing"
[ -e "$sysfs_net/$IFACE" ] || refuse "no network interface $IFACE on this node"
command -v systemctl >/dev/null 2>&1 || refuse "systemctl is required"
command -v sudo >/dev/null 2>&1 || refuse "sudo is required for the privileged steps"
sudo -n true </dev/null >/dev/null 2>&1 || refuse "privileged steps need passwordless sudo (sudo -n) for $user"
# Prints the absolute path of ethtool (a non-login PATH may lack /usr/sbin, so the
# verified path is rendered into the unit rather than trusted at run time).
find_ethtool() { ( PATH="$PATH:${BROKKR_ETHTOOL_SEARCH_PATH:-/usr/sbin:/sbin}"; command -v ethtool 2>/dev/null ) || true; }
ethtool_path=$(find_ethtool)
case $ethtool_path in
  '') refuse "ethtool is required on the node (install it first; this deploy never installs packages)" ;;
  /*) safe_path "$ethtool_path" || refuse "ethtool path is not a plain absolute path" ;;
  *) refuse "ethtool resolved to a non-absolute command" ;;
esac
# The status text after "EEE status:", read unprivileged first (the get request
# normally needs no capability) and through sudo -n otherwise.
eee_status() {
  for runner in '' 'sudo -n'; do
    if out=$($runner "$ethtool_path" --show-eee "$IFACE" 2>/dev/null </dev/null); then
      printf '%s\n' "$out" | sed -n 's/^[[:space:]]*EEE status:[[:space:]]*//p' | head -n 1
      return 0
    fi
  done
  return 1
}
status=$(eee_status) || status=
[ -n "$status" ] || refuse "could not read the EEE status of $IFACE with ethtool --show-eee"
case $status in
  'not supported'*) refuse "$IFACE does not support EEE; there is nothing to keep off" ;;
esac
template_name=brokkr-eee-off@.service
instance=brokkr-eee-off@$IFACE.service
managed=$unit_dir/$template_name
legacy_name=$IFACE-eee-off.service
legacy=$unit_dir/$legacy_name
iface_re=$(printf '%s' "$IFACE" | sed 's/[.]/[.]/g')
# Any EEE change on this interface, whatever value it sets.
any_set_re="--set-eee[[:space:]]+$iface_re([[:space:]]|\$)"
instance_link=$unit_dir/sys-subsystem-net-devices-$IFACE.device.wants/$instance
# grep for the scans below. systemd reads unit files as root, so a file the operator
# cannot read, or a read error, refuses instead of counting as "no match".
scan_has() { # extended-regex file
  [ -r "$2" ] || refuse "cannot read ${2#"$unit_dir"/} as $user; inspect it as root"
  if grep -Eq -e "$1" "$2"; then return 0; else rc=$?; fi
  [ "$rc" = 1 ] || refuse "could not scan ${2#"$unit_dir"/} (grep exit $rc)"
  return 1
}
# Every directory must be readable, or a glob below could silently skip it.
find "$unit_dir" >/dev/null 2>&1 \
  || refuse "could not read every directory under $unit_dir as $user; inspect it as root"

# The committed template must be the one this script expects, then it is rendered.
[ "$(grep -Fxc 'ExecStart=@ETHTOOL@ --set-eee %i eee off' "$work/template")" = 1 ] \
  || refuse "shipped template lacks the expected ExecStart line"
sed -e "s|@ETHTOOL@|$ethtool_path|g" -e "s|@REVISION@|$REVISION|g" "$work/template" >"$work/$template_name"
if grep -Eq '@[A-Z_]+@' "$work/$template_name"; then refuse "unit template has an unrendered placeholder"; fi

legacy_present=0
legacy_enabled=
if [ -e "$legacy" ] || [ -L "$legacy" ]; then
  [ -f "$legacy" ] && [ ! -L "$legacy" ] || refuse "$legacy_name is not a regular non-symlink file; inspect it manually"
  [ ! -e "$legacy.d" ] && [ ! -L "$legacy.d" ] || refuse "$legacy_name has a drop-in directory; adopt it manually"
  # Only the exact shape this deploy replaces is adopted, because the unit is then
  # deleted: one Exec directive, which runs ethtool by absolute path with exactly
  # these arguments.
  [ "$(grep -Ec '^[[:space:]]*Exec[A-Za-z]*[[:space:]]*=' "$legacy")" = 1 ] \
    && grep -Eq -e "^ExecStart=/([A-Za-z0-9._-]+/)*ethtool[[:space:]]+--set-eee[[:space:]]+$iface_re[[:space:]]+eee[[:space:]]+off[[:space:]]*\$" "$legacy" \
    || refuse "$legacy_name is not the ad-hoc EEE-off unit (exactly one Exec line, ExecStart=/.../ethtool --set-eee $IFACE eee off); inspect it manually"
  # Disabling a unit acts on everything its [Install] section names (Also=, Alias=),
  # so only directives without side effects on other units are accepted.
  allowed='Description|Documentation|After|Before|BindsTo|Requires|Wants|PartOf|Type|RemainAfterExit|ExecStart|WantedBy'
  if bad=$(grep -Ev '^[[:space:]]*($|[#;]|\[)' "$legacy" | grep -Ev "^($allowed)=" | head -n 1) && [ -n "$bad" ]; then
    refuse "$legacy_name is not the ad-hoc EEE-off unit (unsupported directive ${bad%%=*}); inspect it manually"
  fi
  [ "$(grep -Ec '^WantedBy=' "$legacy")" = 1 ] && grep -Fxq "WantedBy=sys-subsystem-net-devices-$IFACE.device" "$legacy" \
    || refuse "$legacy_name is not the ad-hoc EEE-off unit (it must have exactly WantedBy=sys-subsystem-net-devices-$IFACE.device); inspect it manually"
  legacy_present=1
  legacy_enabled=$(systemctl is-enabled "$legacy_name" 2>/dev/null || true)
  case $legacy_enabled in
    enabled|disabled) ;;
    *) refuse "$legacy_name is ${legacy_enabled:-in an unknown state}; only an enabled or disabled ad-hoc unit is adopted" ;;
  esac
fi
[ ! -e "$unit_dir/$instance" ] && [ ! -L "$unit_dir/$instance" ] \
  || refuse "$instance exists as its own unit file and shadows the managed template; remove it first"
for d in "$unit_dir/$template_name.d" "$unit_dir/$instance.d"; do
  [ ! -e "$d" ] && [ ! -L "$d" ] || refuse "${d##*/} is a drop-in directory that overrides the managed unit; remove it first"
done
# systemd also applies drop-ins named after every dash-separated prefix of a unit
# name, and the top-level service.d. Any of them could reset ExecStart or add a
# condition, so the managed and the adopted unit must have none.
for d in "$unit_dir/service.d" "$unit_dir/brokkr-.service.d" "$unit_dir/brokkr-eee-.service.d"; do
  [ ! -e "$d" ] && [ ! -L "$d" ] || refuse "${d##*/} is an inherited drop-in directory that applies to the managed unit; remove it first"
done
# The interface name has no dash, so these are all the prefixes of <iface>-eee-off.
for d in "$unit_dir/$IFACE-.service.d" "$unit_dir/$IFACE-eee-.service.d"; do
  [ ! -e "$d" ] && [ ! -L "$d" ] || refuse "${d##*/} is an inherited drop-in directory that applies to $legacy_name; remove it first"
done
if [ "$legacy_present" = 1 ]; then
  # Disabling removes every link to the unit, but the rollback can only recreate the
  # device dependency its [Install] section declares, so no other link may exist.
  wanted_link=$unit_dir/sys-subsystem-net-devices-$IFACE.device.wants/$legacy_name
  links=$(find "$unit_dir" -type l) || refuse "could not list the links under $unit_dir"
  for f in $links; do
    target=$(readlink "$f" 2>/dev/null) || continue
    [ "${target##*/}" = "$legacy_name" ] || [ "${f##*/}" = "$legacy_name" ] || continue
    [ "$f" = "$wanted_link" ] \
      || refuse "${f#"$unit_dir"/} links to $legacy_name beyond its device dependency; remove it or adopt the unit manually"
  done
fi
# Any other unit or drop-in that already sets EEE on this interface, to any value,
# would make two owners of one setting.
for f in "$unit_dir"/*.service "$unit_dir"/*.service.d/*.conf; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  name=${f#"$unit_dir"/}
  case $name in "$legacy_name"|"$template_name") continue ;; esac
  if scan_has "$any_set_re" "$f"; then
    refuse "$name also sets EEE on $IFACE; adopt or remove it manually so that only one unit owns this setting"
  fi
done
# An enabled instance of another template whose command sets EEE on its instance.
for f in "$unit_dir"/*.wants/*@"$IFACE".service "$unit_dir"/*.requires/*@"$IFACE".service; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  name=${f##*/}
  [ "$name" != "$instance" ] || continue
  for g in "$f" "$unit_dir/${name%%@*}@.service" "$unit_dir/${name%%@*}@.service.d"/*.conf "$unit_dir/$name.d"/*.conf; do
    [ -e "$g" ] || continue
    if scan_has "--set-eee[[:space:]]+(%[iI]|$iface_re)([[:space:]]|\$)" "$g"; then
      refuse "$name is enabled and also sets EEE on $IFACE; disable it manually so that only one unit owns this setting"
    fi
  done
done
managed_present=0
if [ -e "$managed" ] || [ -L "$managed" ]; then
  [ -f "$managed" ] && [ ! -L "$managed" ] || refuse "$template_name is not a regular non-symlink file; inspect it manually"
  managed_present=1
fi
instance_enabled=$(systemctl is-enabled "$instance" 2>/dev/null || true)
case $instance_enabled in
  enabled|disabled|'') ;;
  *) refuse "$instance is $instance_enabled; only an enabled, disabled, or absent instance is managed" ;;
esac
# is-enabled reports any wants link; only the device dependency re-applies the
# setting when the interface comes back.
if [ "$instance_enabled" = enabled ] && [ ! -L "$instance_link" ]; then
  refuse "$instance is enabled without its device dependency (${instance_link#"$unit_dir"/}); disable it first"
fi
instance_active=$(systemctl is-active "$instance" 2>/dev/null || true)

echo "preflight: runtime user $user (not root); passwordless sudo available"
echo "preflight: interface $IFACE present; ethtool at $ethtool_path"
echo "preflight: EEE status: $status"
echo "preflight: unit directory $unit_dir"

if [ "$managed_present" = 1 ] && cmp -s "$work/$template_name" "$managed" && [ "$legacy_present" = 0 ] \
  && [ "$instance_enabled" = enabled ] && [ "$instance_active" = active ]; then
  case $status in
    disabled*)
      echo "already in place: $instance is enabled and active at revision $REVISION and EEE is disabled; nothing to do"
      exit 0 ;;
  esac
fi

if [ "$legacy_present" = 1 ]; then
  if [ -e "$legacy.previous-$REVISION" ] || [ -L "$legacy.previous-$REVISION" ]; then
    refuse "backup $legacy_name.previous-$REVISION already exists"
  fi
  echo "preflight: ad-hoc unit $legacy_name ($legacy_enabled) will be backed up as $legacy_name.previous-$REVISION,"
  echo "preflight: then disabled and removed once $instance has turned EEE off"
else
  echo "preflight: no ad-hoc EEE-off unit for $IFACE to adopt"
fi
if [ "$managed_present" = 1 ]; then
  if [ -e "$managed.previous-$REVISION" ] || [ -L "$managed.previous-$REVISION" ]; then
    refuse "backup $template_name.previous-$REVISION already exists"
  fi
  echo "preflight: existing $template_name will be backed up as $template_name.previous-$REVISION"
fi
echo "preflight: $instance is ${instance_enabled:-unknown} and ${instance_active:-unknown}"
if [ "$MODE" = dry-run ]; then
  echo "dry-run: --apply would install $managed, enable and restart $instance, verify that EEE is"
  echo "dry-run: disabled, and only then disable and remove the ad-hoc unit. Nothing was changed."
fi
REMOTE

# Apply tail. Steps that actually completed are tracked; the exit trap prints a
# rollback matching exactly these.
IFS= read -r -d '' REMOTE_APPLY <<'REMOTE' || true
legacy_backed_up=0
managed_backed_up=0
managed_installed=0
instance_newly_enabled=0
instance_restarted=0
legacy_disabled=0
legacy_removed=0
tmp_backups=
print_state() {
  for tmp in $tmp_backups; do sudo -n rm -f "$tmp" || true; done
  if [ "$managed_installed" = 0 ] && [ "$legacy_disabled" = 0 ] && [ "$legacy_removed" = 0 ]; then
    echo "State: no unit was changed on this node."
    return 0
  fi
  echo "Rollback (run on the target as $user; only steps this run completed are listed):"
  if [ "$instance_restarted" = 1 ] && [ "$instance_active" != active ]; then
    echo "  sudo systemctl stop $instance   # it was inactive before this run"
  fi
  if [ "$instance_newly_enabled" = 1 ]; then echo "  sudo systemctl disable $instance"; fi
  if [ "$managed_installed" = 1 ]; then
    if [ "$managed_backed_up" = 1 ]; then echo "  sudo mv -f $managed.previous-$REVISION $managed"; else echo "  sudo rm -f $managed"; fi
  fi
  if [ "$legacy_removed" = 1 ]; then echo "  sudo mv -f $legacy.previous-$REVISION $legacy"; fi
  echo "  sudo systemctl daemon-reload"
  if [ "$legacy_disabled" = 1 ] && [ "$legacy_enabled" = enabled ]; then echo "  sudo systemctl enable $legacy_name"; fi
  if [ "$instance_restarted" = 1 ] && [ "$instance_active" = active ] && [ "$managed_backed_up" = 1 ]; then
    echo "  sudo systemctl restart $instance   # it was active before this run; re-run the previous template"
  fi
  if [ "$legacy_backed_up" = 1 ] && [ "$legacy_removed" = 0 ]; then
    echo "  # $legacy_name was left in place; optional: sudo rm -f $legacy.previous-$REVISION"
  fi
  echo "  # Disabling a unit does not change the live setting; EEE stays off until the next boot or driver reload."
  echo "  # Only if EEE should be on again (the tracked decision is off): sudo $ethtool_path --set-eee $IFACE eee on"
}
apply_started=1
# Back up every file this run will replace or remove to temporary names first, then
# rename them into place. Until every backup exists nothing has been changed.
backup_pairs=
if [ "$legacy_present" = 1 ]; then backup_pairs="$legacy"; fi
if [ "$managed_present" = 1 ]; then backup_pairs="$backup_pairs $managed"; fi
for src in $backup_pairs; do
  tmp=$unit_dir/.${src##*/}.previous-$REVISION.tmp
  tmp_backups="$tmp_backups $tmp"
  sudo -n cp -p "$src" "$tmp" </dev/null || refuse "could not back up ${src##*/}; no unit was changed"
done
for src in $backup_pairs; do
  sudo -n mv "$unit_dir/.${src##*/}.previous-$REVISION.tmp" "$src.previous-$REVISION" </dev/null \
    || refuse "could not finalize the backup of ${src##*/}; no unit was changed"
  echo "backed up ${src##*/} as ${src##*/}.previous-$REVISION"
  case $src in "$legacy") legacy_backed_up=1 ;; *) managed_backed_up=1 ;; esac
done
tmp_backups=
managed_installed=1
sudo -n install -m 644 "$work/$template_name" "$managed" </dev/null
echo "installed $managed"
sudo -n systemctl daemon-reload </dev/null
if [ "$instance_enabled" != enabled ]; then
  instance_newly_enabled=1
  sudo -n systemctl enable "$instance" </dev/null
fi
if [ ! -L "$instance_link" ]; then
  echo "FAILED: $instance has no device dependency link after enable; the ad-hoc unit was left in charge" >&2
  exit 3
fi
instance_restarted=1
if ! sudo -n systemctl restart "$instance" </dev/null; then
  echo "FAILED: the first run of $instance did not succeed; the ad-hoc unit was left in charge" >&2
  exit 3
fi
active=$(systemctl is-active "$instance" 2>/dev/null || true)
status=$(eee_status) || status=
echo "verify: $instance is ${active:-unknown}; EEE status: ${status:-unknown}"
case $status in
  disabled*) ;;
  *) echo "FAILED: EEE is still not disabled on $IFACE; the ad-hoc unit was left in charge" >&2; exit 3 ;;
esac
[ "$active" = active ] || { echo "FAILED: $instance is not active; the ad-hoc unit was left in charge" >&2; exit 3; }
if [ "$legacy_present" = 1 ]; then
  legacy_disabled=1
  sudo -n systemctl disable "$legacy_name" </dev/null
  legacy_removed=1
  sudo -n rm -f "$legacy" </dev/null
  sudo -n systemctl daemon-reload </dev/null
  [ ! -e "$legacy" ] || { echo "FAILED: $legacy is still present" >&2; exit 3; }
  echo "adopted: disabled and removed $legacy_name (backup $legacy_name.previous-$REVISION)"
fi
echo "OK: EEE is off on $IFACE and owned by $instance at revision $REVISION"
REMOTE

run_remote() { # mode script-body; stdin is forwarded to the remote script
  local MODE=$1 prelude body encoded
  prelude="IFACE='$IFACE'
REVISION='$REVISION'
MODE='$MODE'
"
  body="$prelude$REMOTE_COMMON
$2
"
  encoded="$(printf '%s' "$body" | base64 | tr -d '\n')"
  ssh -o BatchMode=yes "$TARGET" "sh -c \"\$(printf %s '$encoded' | base64 -d)\""
}

if (( APPLY )); then
  echo "==> Installing EEE-off unit for $IFACE on $TARGET (revision ${REVISION})"
  run_remote apply "$REMOTE_APPLY" <"$TEMPLATE_FILE" || {
    echo "brokkr eee-off deploy: remote install failed or was refused (see output above; any rollback recipe applies)" >&2
    exit 1
  }
  echo "==> Done."
else
  echo "==> DRY-RUN EEE-off preflight for $IFACE on $TARGET (revision ${REVISION})"
  run_remote dry-run "" <"$TEMPLATE_FILE" || {
    echo "brokkr eee-off deploy: preflight failed; nothing was changed" >&2
    exit 1
  }
  echo "==> DRY-RUN complete. Re-run with --apply to install."
fi
