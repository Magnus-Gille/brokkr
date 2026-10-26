#!/usr/bin/env bash
# Brokkr · keep Energy Efficient Ethernet (EEE) off on one wired interface of a fleet
# node, as a revision-bound systemd system unit. Run from the control node; the node
# is reached over ssh as a non-root operator with passwordless sudo.
#
# Dry-run by default: the remote preflight (identity, sudo, interface, ethtool, ip, EEE
# support, the ad-hoc unit to adopt, duplicate units, backup targets) runs and nothing
# is changed. Pass --apply to install. The managed unit is started at every boot, on
# device appearance and, through its link watcher, after a link change. An existing
# ad-hoc <iface>-eee-off.service is backed up, and disabled and removed only after the
# managed units have turned EEE off. Redeploying over an earlier release migrates it.
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
WATCH_TEMPLATE_FILE="$DEPLOY_PAYLOAD_ROOT/network/brokkr-eee-off-watch@.service.example"
[[ -f "$WATCH_TEMPLATE_FILE" && ! -L "$WATCH_TEMPLATE_FILE" ]] || die "committed payload lacks regular file network/brokkr-eee-off-watch@.service.example"
WATCH_TEMPLATE_B64="$(base64 <"$WATCH_TEMPLATE_FILE" | tr -d '\n')"

# Remote scripts run under sh (shipped base64-encoded, so the operator's login shell
# never parses them) and are POSIX-only. The committed unit template arrives on stdin
# and the watcher template base64-encoded in the prelude, in both modes. Inputs are
# validated above and below (base64 has no quote), so single-quoted assignment is safe.
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
printf '%s' "$WATCH_TEMPLATE_B64" | base64 -d >"$work/watch-template" || refuse "could not decode the shipped watcher template"
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
# The link watcher listens with ip monitor; its path is rendered the same way.
find_ip() { ( PATH="$PATH:${BROKKR_IP_SEARCH_PATH:-/usr/sbin:/sbin}"; command -v ip 2>/dev/null ) || true; }
ip_path=$(find_ip)
case $ip_path in
  '') refuse "ip (iproute2) is required on the node for the link watcher (install it first; this deploy never installs packages)" ;;
  /*) safe_path "$ip_path" || refuse "ip path is not a plain absolute path" ;;
  *) refuse "ip resolved to a non-absolute command" ;;
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
# The interface as a whole token, so quoting ("eth0"), line continuations and odd
# spacing in another unit cannot hide it, while eth01 or eth0.device do not match.
tok_re="(^|[^A-Za-z0-9_.])$iface_re([^A-Za-z0-9_.]|\$)"
watch_name=brokkr-eee-off-watch@.service
watch_instance=brokkr-eee-off-watch@$IFACE.service
watch_managed=$unit_dir/$watch_name
# Each unit is wanted by the device (hotplug, driver reload) and by multi-user.target
# (every boot, even when the device's own .wants/ is not acted on).
dev_wants=$unit_dir/sys-subsystem-net-devices-$IFACE.device.wants
boot_wants=$unit_dir/multi-user.target.wants
instance_link=$dev_wants/$instance
# systemd reads unit files as root and some are root-only (mode 600), so the unit
# directory is enumerated and read through sudo -n, never as the operator. A read or
# listing that sudo -n refuses stops the deploy instead of counting as "no match".
root_cat() { sudo -n cat -- "$1" </dev/null 2>/dev/null; }
# One privileged find -L, which also descends into symlinked .d and .wants
# directories, prints each entry as "type<TAB>path[<TAB>link target]". The type is
# decided as root: f regular file, d directory, l live link, x dangling link, o other.
# A name containing a newline or tab cannot be represented, so it refuses.
tab=$(printf '\t')
nl='
'
enum_script='tab=$(printf "\t"); nl="
"
for f; do
  case $f in *"$nl"*|*"$tab"*) echo "unsupported file name" >&2; exit 3 ;; esac
  if [ -L "$f" ]; then
    if [ -e "$f" ]; then t=l; else t=x; fi
    target=$(readlink "$f") || exit 3
    printf "%s\t%s\t%s\n" "$t" "$f" "$target"
  elif [ -d "$f" ]; then printf "d\t%s\n" "$f"
  elif [ -f "$f" ]; then printf "f\t%s\n" "$f"
  else printf "o\t%s\n" "$f"
  fi
done'
entries=$(sudo -n find -L "$unit_dir" -mindepth 1 -maxdepth 2 -exec sh -c "$enum_script" sh {} + </dev/null 2>/dev/null) \
  || refuse "could not list $unit_dir with sudo -n (unreadable entry, symlink loop, or a file name with a newline or tab); inspect it as root"
entry_type() { # path -> f, d, l, x, o, or nothing when absent
  P=$1 awk -F "$tab" '$2 == ENVIRON["P"] { print $1; exit }' <<EOF
$entries
EOF
}
# Only regular files and live links can hold commands; a dangling link (a unit removed
# without being disabled) runs nothing.
scan_has() { # extended-regex file
  content=$(root_cat "$2") || refuse "could not read ${2#"$unit_dir"/} with sudo -n; inspect it as root"
  printf '%s\n' "$content" | grep -Eq -e "$1"
}
# A file owns EEE on this interface when it runs --set-eee anywhere and names the
# interface (or, for a template, %i/%I) anywhere. Deliberately broad: systemd
# quoting and continuations are not parsed, so an ambiguous file refuses.
owns_eee() { # file token-regex
  scan_has '--set-eee' "$1" && scan_has "$2" "$1"
}
absent() { [ -z "$(entry_type "$1")" ]; }

# The committed template must be the one this script expects, then it is rendered.
[ "$(grep -Fxc 'ExecStart=@ETHTOOL@ --set-eee %i eee off' "$work/template")" = 1 ] \
  || refuse "shipped template lacks the expected ExecStart line"
[ "$(grep -Fc '@IP@ -o monitor link' "$work/watch-template")" = 1 ] \
  && [ "$(grep -Ec '^ExecStart=/bin/sh -c ' "$work/watch-template")" = 1 ] \
  || refuse "shipped watcher template lacks the expected monitor command"
for f in template watch-template; do
  case $f in template) out=$template_name ;; *) out=$watch_name ;; esac
  sed -e "s|@ETHTOOL@|$ethtool_path|g" -e "s|@IP@|$ip_path|g" -e "s|@REVISION@|$REVISION|g" "$work/$f" >"$work/$out"
  if grep -Eq '@[A-Z_]+@' "$work/$out"; then refuse "unit template $out has an unrendered placeholder"; fi
done

legacy_present=0
legacy_enabled=
legacy_type=$(entry_type "$legacy")
if [ -n "$legacy_type" ]; then
  [ "$legacy_type" = f ] || refuse "$legacy_name is not a regular non-symlink file; inspect it manually"
  absent "$legacy.d" || refuse "$legacy_name has a drop-in directory; adopt it manually"
  legacy_content=$(root_cat "$legacy") || refuse "could not read $legacy_name with sudo -n; inspect it as root"
  legacy_grep() { printf '%s\n' "$legacy_content" | grep "$@"; }
  # Only the exact shape this deploy replaces is adopted, because the unit is then
  # deleted: one Exec directive, which runs ethtool by absolute path with exactly
  # these arguments.
  [ "$(legacy_grep -Ec '^[[:space:]]*Exec[A-Za-z]*[[:space:]]*=')" = 1 ] \
    && legacy_grep -Eq -e "^ExecStart=/([A-Za-z0-9._-]+/)*ethtool[[:space:]]+--set-eee[[:space:]]+$iface_re[[:space:]]+eee[[:space:]]+off[[:space:]]*\$" \
    || refuse "$legacy_name is not the ad-hoc EEE-off unit (exactly one Exec line, ExecStart=/.../ethtool --set-eee $IFACE eee off); inspect it manually"
  # Disabling a unit acts on everything its [Install] section names (Also=, Alias=),
  # so only directives without side effects on other units are accepted.
  allowed='Description|Documentation|After|Before|BindsTo|Requires|Wants|PartOf|Type|RemainAfterExit|ExecStart|WantedBy'
  if bad=$(legacy_grep -Ev '^[[:space:]]*($|[#;]|\[)' | grep -Ev "^($allowed)=" | head -n 1) && [ -n "$bad" ]; then
    refuse "$legacy_name is not the ad-hoc EEE-off unit (unsupported directive ${bad%%=*}); inspect it manually"
  fi
  [ "$(legacy_grep -Ec '^WantedBy=')" = 1 ] && legacy_grep -Fxq "WantedBy=sys-subsystem-net-devices-$IFACE.device" \
    || refuse "$legacy_name is not the ad-hoc EEE-off unit (it must have exactly WantedBy=sys-subsystem-net-devices-$IFACE.device); inspect it manually"
  legacy_present=1
  legacy_enabled=$(systemctl is-enabled "$legacy_name" 2>/dev/null || true)
  case $legacy_enabled in
    enabled|disabled) ;;
    *) refuse "$legacy_name is ${legacy_enabled:-in an unknown state}; only an enabled or disabled ad-hoc unit is adopted" ;;
  esac
fi
for u in "$instance" "$watch_instance"; do
  absent "$unit_dir/$u" \
    || refuse "$u exists as its own unit file and shadows the managed template; remove it first"
done
for d in "$unit_dir/$template_name.d" "$unit_dir/$instance.d" "$unit_dir/$watch_name.d" "$unit_dir/$watch_instance.d"; do
  absent "$d" || refuse "${d##*/} is a drop-in directory that overrides the managed unit; remove it first"
done
# systemd also applies drop-ins named after every dash-separated prefix of a unit
# name, and the top-level service.d. Any of them could reset ExecStart or add a
# condition, so the managed units and the adopted unit must have none.
for d in "$unit_dir/service.d" "$unit_dir/brokkr-.service.d" "$unit_dir/brokkr-eee-.service.d" "$unit_dir/brokkr-eee-off-.service.d"; do
  absent "$d" || refuse "${d##*/} is an inherited drop-in directory that applies to the managed unit; remove it first"
done
# The interface name has no dash, so these are all the prefixes of <iface>-eee-off.
for d in "$unit_dir/$IFACE-.service.d" "$unit_dir/$IFACE-eee-.service.d"; do
  absent "$d" || refuse "${d##*/} is an inherited drop-in directory that applies to $legacy_name; remove it first"
done
old_ifs=$IFS; IFS=$nl; set -f
if [ "$legacy_present" = 1 ]; then
  # Disabling removes every link to the unit, but the rollback can only recreate the
  # device dependency its [Install] section declares, so no other link may exist.
  wanted_link=$unit_dir/sys-subsystem-net-devices-$IFACE.device.wants/$legacy_name
  for line in $entries; do
    t=${line%%"$tab"*}; rest=${line#*"$tab"}; f=${rest%%"$tab"*}; target=${rest#*"$tab"}
    case $t in l|x) ;; *) continue ;; esac
    [ "${target##*/}" = "$legacy_name" ] || [ "${f##*/}" = "$legacy_name" ] || continue
    [ "$f" = "$wanted_link" ] \
      || refuse "${f#"$unit_dir"/} links to $legacy_name beyond its device dependency; remove it or adopt the unit manually"
  done
fi
# Any other unit or drop-in that already sets EEE on this interface, to any value,
# would make two owners of one setting.
for line in $entries; do
  t=${line%%"$tab"*}; rest=${line#*"$tab"}; f=${rest%%"$tab"*}
  case $t in f|l) ;; *) continue ;; esac
  name=${f#"$unit_dir"/}
  case $name in
    */*/*) continue ;;
    *.service.d/*.conf) ;;
    */*) continue ;;
    *.service) ;;
    *) continue ;;
  esac
  case $name in "$legacy_name"|"$template_name") continue ;; esac
  if owns_eee "$f" "$tok_re"; then
    refuse "$name also sets EEE on $IFACE; adopt or remove it manually so that only one unit owns this setting"
  fi
done
# An enabled instance of another template whose command sets EEE on its instance:
# the enabled link itself (its target is the template wherever it lives), plus the
# template, its drop-ins and the instance's drop-ins in this directory.
for line in $entries; do
  t=${line%%"$tab"*}; rest=${line#*"$tab"}; f=${rest%%"$tab"*}
  case $t in f|l) ;; *) continue ;; esac
  case ${f#"$unit_dir"/} in
    */*/*) continue ;;
    *.wants/*@"$IFACE".service|*.requires/*@"$IFACE".service) ;;
    *) continue ;;
  esac
  name=${f##*/}
  [ "$name" != "$instance" ] || continue
  if owns_eee "$f" "%[iI]|$tok_re"; then
    refuse "$name is enabled and also sets EEE on $IFACE; disable it manually so that only one unit owns this setting"
  fi
  for line2 in $entries; do
    t2=${line2%%"$tab"*}; rest2=${line2#*"$tab"}; g=${rest2%%"$tab"*}
    case $t2 in f|l) ;; *) continue ;; esac
    case ${g#"$unit_dir"/} in
      "${name%%@*}@.service"|"${name%%@*}@.service.d/"*.conf|"$name.d/"*.conf) ;;
      *) continue ;;
    esac
    if owns_eee "$g" "%[iI]|$tok_re"; then
      refuse "$name is enabled and also sets EEE on $IFACE; disable it manually so that only one unit owns this setting"
    fi
  done
done
IFS=$old_ifs; set +f
managed_present=0
managed_type=$(entry_type "$managed")
if [ -n "$managed_type" ]; then
  [ "$managed_type" = f ] || refuse "$template_name is not a regular non-symlink file; inspect it manually"
  managed_present=1
fi
watch_present=0
watch_type=$(entry_type "$watch_managed")
if [ -n "$watch_type" ]; then
  [ "$watch_type" = f ] || refuse "$watch_name is not a regular non-symlink file; inspect it manually"
  watch_present=1
fi
# systemd >= 250 reports a unit without a unit file as not-found; that is only
# expected while the managed template is absent.
enablement() { # instance template-present -> sets e to enabled, disabled, or empty
  e=$(systemctl is-enabled "$1" 2>/dev/null || true)
  case $e in
    enabled|disabled|'') ;;
    not-found) [ "$2" = 0 ] || refuse "$1 is not-found although its template exists; inspect it manually"; e= ;;
    *) refuse "$1 is $e; only an enabled, disabled, or absent instance is managed" ;;
  esac
}
enablement "$instance" "$managed_present"; instance_enabled=$e
enablement "$watch_instance" "$watch_present"; watch_enabled=$e
# is-enabled reports any wants link; only the device dependency re-applies the
# setting when the interface comes back. A missing boot link is what a redeploy
# over an earlier release adds, so it is not a refusal.
if [ "$instance_enabled" = enabled ] && [ "$(entry_type "$instance_link")" != l ]; then
  refuse "$instance is enabled without its device dependency (${instance_link#"$unit_dir"/}); disable it first"
fi
instance_active=$(systemctl is-active "$instance" 2>/dev/null || true)
watch_active=$(systemctl is-active "$watch_instance" 2>/dev/null || true)
links_in_place() { # instance -> success when both of its wants links are live
  [ "$(entry_type "$dev_wants/$1")" = l ] && [ "$(entry_type "$boot_wants/$1")" = l ]
}
entry_target() { # path -> the link target recorded by the enumeration
  P=$1 awk -F "$tab" '$2 == ENVIRON["P"] { print $3; exit }' <<EOF
$entries
EOF
}
# A wants link of a managed unit is either absent (enable creates it) or a live link
# to that unit's template; anything else would make enable fail or start other code.
for pair in "$instance:$template_name" "$watch_instance:$watch_name"; do
  for l in "$dev_wants/${pair%%:*}" "$boot_wants/${pair%%:*}"; do
    t=$(entry_type "$l")
    [ -n "$t" ] || continue
    [ "$t" = l ] && [ "$(entry_target "$l")" = "$unit_dir/${pair##*:}" ] \
      || refuse "${l#"$unit_dir"/} is not a link to $unit_dir/${pair##*:}; remove it first"
  done
done

echo "preflight: runtime user $user (not root); passwordless sudo available"
echo "preflight: interface $IFACE present; ethtool at $ethtool_path; ip at $ip_path"
echo "preflight: EEE status: $status"
echo "preflight: unit directory $unit_dir"

is_current() { # installed-path rendered-name -> success when byte-identical
  c=$(root_cat "$1") || refuse "could not read ${1##*/} with sudo -n; inspect it as root"
  [ "$c" = "$(cat "$work/$2")" ]
}
managed_current=0
if [ "$managed_present" = 1 ] && is_current "$managed" "$template_name"; then managed_current=1; fi
watch_current=0
if [ "$watch_present" = 1 ] && is_current "$watch_managed" "$watch_name"; then watch_current=1; fi
if [ "$managed_current" = 1 ] && [ "$watch_current" = 1 ] && [ "$legacy_present" = 0 ] \
  && [ "$instance_enabled" = enabled ] && [ "$instance_active" = active ] \
  && [ "$watch_enabled" = enabled ] && [ "$watch_active" = active ] \
  && links_in_place "$instance" && links_in_place "$watch_instance"; then
  case $status in
    disabled*)
      echo "already in place: $instance and $watch_instance are enabled (device and boot) and active at revision $REVISION and EEE is disabled; nothing to do"
      exit 0 ;;
  esac
fi

if [ "$legacy_present" = 1 ]; then
  absent "$legacy.previous-$REVISION" || refuse "backup $legacy_name.previous-$REVISION already exists"
  echo "preflight: ad-hoc unit $legacy_name ($legacy_enabled) will be backed up as $legacy_name.previous-$REVISION,"
  echo "preflight: then disabled and removed once $instance has turned EEE off"
else
  echo "preflight: no ad-hoc EEE-off unit for $IFACE to adopt"
fi
for f in "$managed:$managed_present" "$watch_managed:$watch_present"; do
  [ "${f##*:}" = 1 ] || continue
  f=${f%:*}
  absent "$f.previous-$REVISION" || refuse "backup ${f##*/}.previous-$REVISION already exists"
  echo "preflight: existing ${f##*/} will be backed up as ${f##*/}.previous-$REVISION"
done
echo "preflight: $instance is ${instance_enabled:-unknown} and ${instance_active:-unknown}"
echo "preflight: $watch_instance is ${watch_enabled:-unknown} and ${watch_active:-unknown}"
if [ "$MODE" = dry-run ]; then
  echo "dry-run: --apply would install $managed and $watch_managed, enable $instance and"
  echo "dry-run: $watch_instance for the device and for multi-user.target, restart both, verify that"
  echo "dry-run: EEE is disabled, and only then disable and remove the ad-hoc unit. Nothing was changed."
fi
REMOTE

# Apply tail. Steps that actually completed are tracked; the exit trap prints a
# rollback matching exactly these.
IFS= read -r -d '' REMOTE_APPLY <<'REMOTE' || true
legacy_backed_up=0
legacy_disabled=0
legacy_removed=0
managed_backed_up=0
managed_installed=0
watch_backed_up=0
watch_installed=0
instance_enable_ran=0
instance_restarted=0
watch_enable_ran=0
watch_restarted=0
tmp_backups=
# The wants links of each unit that did not exist before this run, so a rollback of
# an instance that was already enabled removes exactly what this run added.
new_links() { # instance
  for l in "$dev_wants/$1" "$boot_wants/$1"; do
    absent "$l" && printf ' %s' "$l"
  done
  return 0
}
instance_new_links=$(new_links "$instance")
watch_new_links=$(new_links "$watch_instance")
# Stops and un-enables one unit as far as this run started or enabled it.
rollback_unit() { # instance enable-ran restarted enabled-before active-before new-links
  if [ "$3" = 1 ] && [ "$5" != active ]; then echo "  sudo systemctl stop $1   # it was inactive before this run"; fi
  if [ "$2" = 1 ] && [ "$4" != enabled ]; then echo "  sudo systemctl disable $1"; fi
  if [ "$2" = 1 ] && [ "$4" = enabled ]; then
    for l in $6; do echo "  sudo rm -f $l   # added by this run; $1 was already enabled"; done
  fi
  return 0
}
print_state() {
  for tmp in $tmp_backups; do sudo -n rm -f "$tmp" || true; done
  if [ "$managed_installed" = 0 ] && [ "$watch_installed" = 0 ] && [ "$legacy_disabled" = 0 ] && [ "$legacy_removed" = 0 ]; then
    echo "State: no unit was changed on this node."
    return 0
  fi
  echo "Rollback (run on the target as $user; only steps this run completed are listed):"
  # The watcher first, so it cannot restart the managed unit during the rollback.
  rollback_unit "$watch_instance" "$watch_enable_ran" "$watch_restarted" "$watch_enabled" "$watch_active" "$watch_new_links"
  rollback_unit "$instance" "$instance_enable_ran" "$instance_restarted" "$instance_enabled" "$instance_active" "$instance_new_links"
  if [ "$watch_installed" = 1 ]; then
    if [ "$watch_backed_up" = 1 ]; then echo "  sudo mv -f $watch_managed.previous-$REVISION $watch_managed"; else echo "  sudo rm -f $watch_managed"; fi
  fi
  if [ "$managed_installed" = 1 ]; then
    if [ "$managed_backed_up" = 1 ]; then echo "  sudo mv -f $managed.previous-$REVISION $managed"; else echo "  sudo rm -f $managed"; fi
  fi
  if [ "$legacy_removed" = 1 ]; then echo "  sudo mv -f $legacy.previous-$REVISION $legacy"; fi
  echo "  sudo systemctl daemon-reload"
  if [ "$legacy_disabled" = 1 ] && [ "$legacy_enabled" = enabled ]; then echo "  sudo systemctl enable $legacy_name"; fi
  if [ "$instance_restarted" = 1 ] && [ "$instance_active" = active ] && [ "$managed_backed_up" = 1 ]; then
    echo "  sudo systemctl restart $instance   # it was active before this run; re-run the previous template"
  fi
  if [ "$watch_restarted" = 1 ] && [ "$watch_active" = active ] && [ "$watch_backed_up" = 1 ]; then
    echo "  sudo systemctl restart $watch_instance   # it was active before this run; run the previous template"
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
if [ "$watch_present" = 1 ]; then backup_pairs="$backup_pairs $watch_managed"; fi
for src in $backup_pairs; do
  tmp=$unit_dir/.${src##*/}.previous-$REVISION.tmp
  tmp_backups="$tmp_backups $tmp"
  sudo -n cp -p "$src" "$tmp" </dev/null || refuse "could not back up ${src##*/}; no unit was changed"
done
for src in $backup_pairs; do
  sudo -n mv "$unit_dir/.${src##*/}.previous-$REVISION.tmp" "$src.previous-$REVISION" </dev/null \
    || refuse "could not finalize the backup of ${src##*/}; no unit was changed"
  echo "backed up ${src##*/} as ${src##*/}.previous-$REVISION"
  case $src in "$legacy") legacy_backed_up=1 ;; "$managed") managed_backed_up=1 ;; *) watch_backed_up=1 ;; esac
done
tmp_backups=
managed_installed=1
sudo -n install -m 644 "$work/$template_name" "$managed" </dev/null
echo "installed $managed"
watch_installed=1
sudo -n install -m 644 "$work/$watch_name" "$watch_managed" </dev/null
echo "installed $watch_managed"
sudo -n systemctl daemon-reload </dev/null
# enable always runs: on an instance that an earlier release enabled for the device
# only, it adds the multi-user.target link from the new [Install] section.
enable_unit() { # instance
  sudo -n systemctl enable "$1" </dev/null
  for l in "$dev_wants/$1" "$boot_wants/$1"; do
    if ! sudo -n test -L "$l" </dev/null; then
      echo "FAILED: $1 has no ${l#"$unit_dir"/} link after enable (or sudo -n could not check it); the ad-hoc unit was left in charge" >&2
      exit 3
    fi
  done
}
instance_enable_ran=1
enable_unit "$instance"
# A start limit hit by earlier re-applies would refuse the restart.
sudo -n systemctl reset-failed "$instance" </dev/null
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
watch_enable_ran=1
enable_unit "$watch_instance"
sudo -n systemctl reset-failed "$watch_instance" </dev/null
watch_restarted=1
if ! sudo -n systemctl restart "$watch_instance" </dev/null; then
  echo "FAILED: $watch_instance did not start; the ad-hoc unit was left in charge" >&2
  exit 3
fi
active=$(systemctl is-active "$watch_instance" 2>/dev/null || true)
echo "verify: $watch_instance is ${active:-unknown}"
[ "$active" = active ] || { echo "FAILED: $watch_instance is not active; the ad-hoc unit was left in charge" >&2; exit 3; }
if [ "$legacy_present" = 1 ]; then
  legacy_disabled=1
  sudo -n systemctl disable "$legacy_name" </dev/null || {
    echo "FAILED: could not disable $legacy_name; both units are enabled until rolled back" >&2
    exit 3
  }
  legacy_removed=1
  sudo -n rm -f "$legacy" </dev/null
  sudo -n systemctl daemon-reload </dev/null
  [ ! -e "$legacy" ] || { echo "FAILED: $legacy is still present" >&2; exit 3; }
  echo "adopted: disabled and removed $legacy_name (backup $legacy_name.previous-$REVISION)"
fi
echo "OK: EEE is off on $IFACE and owned by $instance at revision $REVISION"
echo "OK: re-applied at every boot (multi-user.target), on device appearance, and after a link change ($watch_instance)"
REMOTE

run_remote() { # mode script-body; stdin is forwarded to the remote script
  local MODE=$1 prelude body encoded
  prelude="IFACE='$IFACE'
WATCH_TEMPLATE_B64='$WATCH_TEMPLATE_B64'
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

