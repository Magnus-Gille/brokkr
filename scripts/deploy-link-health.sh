#!/usr/bin/env bash
# Brokkr · deploy the wired-link health probe to a fleet node as a revision-bound
# user-unit release. Run from the control node; the node is reached over ssh.
#
# Dry-run by default: the remote preflight (identity, lingering, protected inputs,
# probe config parse, ethtool, release target) runs and nothing is changed. Pass
# --apply to install. See docs/link-health.md.
#
#   BROKKR_EXPECTED_SOURCE=$PWD BROKKR_EXPECTED_COMMIT=<full-sha> \
#   BROKKR_LINK_HEALTH_DELIVERY_ENV=/home/operator/.config/brokkr/env \
#     scripts/deploy-link-health.sh [--apply] operator@node-a.example
set -euo pipefail

ENTRY_SCRIPT="${BASH_SOURCE[0]}"
ENTRY_PATH="$ENTRY_SCRIPT"
[[ "$ENTRY_PATH" == /* ]] || ENTRY_PATH="$(pwd -P)/$ENTRY_PATH"
[[ "$ENTRY_PATH" != *$'\n'* && "$ENTRY_PATH" != *$'\r'* ]] || { echo "brokkr link-health deploy: deployment entry point path must not contain line breaks" >&2; exit 64; }
ENTRY_CURSOR=/
IFS=/ read -r -a ENTRY_COMPONENTS <<<"${ENTRY_PATH#/}"
for ENTRY_COMPONENT in "${ENTRY_COMPONENTS[@]}"; do
  case "$ENTRY_COMPONENT" in ''|.) continue ;; ..) ENTRY_CURSOR=$(dirname "$ENTRY_CURSOR"); continue ;; esac
  ENTRY_CURSOR="${ENTRY_CURSOR%/}/$ENTRY_COMPONENT"
  [[ ! -L "$ENTRY_CURSOR" ]] || { echo "brokkr link-health deploy: deployment entry point path must not contain symlinks" >&2; exit 64; }
done
# Resolve only after rejecting every lexical symlink component in the entry path.
SCRIPT_DIR="$(cd "$(dirname "$ENTRY_SCRIPT")" && pwd -P)"
HERE="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=scripts/lib/deploy-source.sh
source "$HERE/scripts/lib/deploy-source.sh"

die() { echo "brokkr link-health deploy: $*" >&2; exit 64; }
usage() {
  echo "usage: $0 [--apply] SSH_TARGET" >&2
  echo "  env: BROKKR_EXPECTED_SOURCE, BROKKR_EXPECTED_COMMIT (full SHA), BROKKR_LINK_HEALTH_DELIVERY_ENV (remote absolute path)," >&2
  echo "       optional BROKKR_LINK_HEALTH_CONFIG (remote absolute path; default \$XDG_CONFIG_HOME|~/.config/brokkr/link-health.conf)" >&2
  exit 64
}
valid_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/@:+-]+$ ]] \
    && [[ "$1" != *'//'* && "$1" != */./* && "$1" != */../* && "$1" != */. && "$1" != */.. ]]
}

APPLY=0
TARGET=""
for ARG in "$@"; do
  case "$ARG" in
    --apply) APPLY=1 ;;
    -*) usage ;;
    *) [[ -z "$TARGET" ]] || usage; TARGET="$ARG" ;;
  esac
done
[[ -n "$TARGET" ]] || usage
[[ "$TARGET" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(@[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]] || die "invalid SSH target"

# This outermost local gate must run before even the remote target preflight.
require_brokkr_deploy_source_binding "$HERE"
REVISION="$BROKKR_EXPECTED_COMMIT"
DEPLOY_PAYLOAD_PARENT=""
DEPLOY_PAYLOAD_ROOT=""
cleanup_deploy_payload() { [[ -z "$DEPLOY_PAYLOAD_PARENT" ]] || rm -rf "$DEPLOY_PAYLOAD_PARENT"; }
trap cleanup_deploy_payload EXIT
trap 'cleanup_deploy_payload; exit 1' HUP INT TERM
materialize_brokkr_deploy_payload "$HERE" "$REVISION"

DELIVERY_ENV="${BROKKR_LINK_HEALTH_DELIVERY_ENV:-}"
LINK_CONFIG="${BROKKR_LINK_HEALTH_CONFIG:-}"
[[ -n "$DELIVERY_ENV" ]] || die "BROKKR_LINK_HEALTH_DELIVERY_ENV is required (remote absolute path of the Heimdall delivery env file)"
valid_path "$DELIVERY_ENV" || die "invalid BROKKR_LINK_HEALTH_DELIVERY_ENV (absolute plain path required)"
if [[ -n "$LINK_CONFIG" ]]; then
  valid_path "$LINK_CONFIG" || die "invalid BROKKR_LINK_HEALTH_CONFIG (absolute plain path required)"
fi

# Only what the probe needs. The units are shipped as templates and rendered on
# the node, where the runtime home and protected-file paths are known.
PAYLOAD_FILES=(
  network/check-link-health.py
  scripts/link-health-snapshot.sh
  heimdall/push.sh
  systemd/user/brokkr-link-health.service.in
  systemd/user/brokkr-link-health.timer
)
for FILE in "${PAYLOAD_FILES[@]}"; do
  [[ -f "$DEPLOY_PAYLOAD_ROOT/$FILE" && ! -L "$DEPLOY_PAYLOAD_ROOT/$FILE" ]] || die "committed payload lacks regular file $FILE"
done

# Remote scripts run under sh (shipped base64-encoded, so the operator's login
# shell never parses them) and are POSIX-only. Inputs are validated above and
# below, so single-quoted assignment is safe.
IFS= read -r -d '' REMOTE_COMMON <<'REMOTE' || true
set -eu
umask 077
refuse() { echo "REFUSED: $*" >&2; exit 2; }
safe_path() {
  printf '%s' "$1" | grep -Eq '^/[A-Za-z0-9._/@:+-]+$' || return 1
  if printf '%s' "$1" | grep -Eq '//|/[.][.]?(/|$)'; then return 1; fi
}
user=$(id -un)
uid=$(id -u)
if [ "$uid" = 0 ] || [ "$user" = root ]; then refuse "runtime user must not be root"; fi
safe_path "${HOME:-}" || refuse "HOME is not an absolute plain path"
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
safe_path "$config_home" || refuse "config home is not an absolute plain path"
[ -n "$LINK_CONFIG" ] || LINK_CONFIG=$config_home/brokkr/link-health.conf
safe_path "$LINK_CONFIG" || refuse "link config path is not an absolute plain path"
safe_path "$DELIVERY_ENV" || refuse "delivery env path is not an absolute plain path"
if ! linger=$(loginctl show-user "$user" --property=Linger 2>/dev/null); then linger=; fi
[ "$linger" = Linger=yes ] || refuse "user lingering is not enabled for $user (loginctl enable-linger)"
private_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || refuse "$2 is not a regular non-symlink file"
  if ! meta=$(stat -c '%u %a' "$1" 2>/dev/null); then
    meta=$(stat -f '%u %Lp' "$1") || refuse "cannot stat $2"
  fi
  [ "$meta" = "$uid 600" ] || refuse "$2 must be owned by $user with mode 600"
}
private_file "$DELIVERY_ENV" "delivery env"
private_file "$LINK_CONFIG" "link config"
for key in HEIMDALL_HUB_URL HEIMDALL_FLEET_TOKEN; do
  grep -Eq "^${key}=.+$" "$DELIVERY_ENV" || refuse "delivery env lacks a non-empty $key"
  if grep -Eq "^${key}=(''|\"\")$" "$DELIVERY_ENV"; then refuse "delivery env lacks a non-empty $key"; fi
done
command -v python3 >/dev/null 2>&1 || refuse "python3 is required"
release_root=$HOME/.local/lib/brokkr/link-health
release=$release_root/releases/$REVISION
unit_dir=$config_home/systemd/user
state_dir=$HOME/.local/state/brokkr
if [ -e "$release" ] || [ -L "$release" ]; then refuse "release already exists for revision $REVISION"; fi
for unit in brokkr-link-health.service brokkr-link-health.timer; do
  if [ -e "$unit_dir/$unit.previous-$REVISION" ] || [ -L "$unit_dir/$unit.previous-$REVISION" ]; then
    refuse "unit backup $unit.previous-$REVISION already exists"
  fi
done
have_ethtool() ( PATH="$PATH:${BROKKR_ETHTOOL_SEARCH_PATH:-/usr/sbin:/sbin}"; command -v ethtool >/dev/null 2>&1 )
echo "preflight: runtime user $user (not root), user lingering enabled"
echo "preflight: delivery env and link config are private regular files owned by $user"
echo "preflight: delivery env has non-empty HEIMDALL_HUB_URL and HEIMDALL_FLEET_TOKEN"
echo "preflight: release target $release (absent)"
echo "preflight: user unit directory $unit_dir"
REMOTE

# Read-only checks: the probe arrives on stdin and validates the config with its own
# parser. Runs for the dry-run and as the gate before --apply mutates anything.
IFS= read -r -d '' REMOTE_CHECKS <<'REMOTE' || true
if out=$(BROKKR_LINK_HEALTH_CONFIG="$LINK_CONFIG" python3 - --check-config); then
  echo "preflight: $out"
else
  refuse "link config rejected by the shipped probe parser: $out"
fi
if have_ethtool; then
  echo "preflight: ethtool present"
elif [ "$MODE" = dry-run ]; then
  echo "preflight: ethtool missing; --apply would install it with: sudo -n apt-get install -y --no-install-recommends ethtool"
else
  echo "preflight: ethtool missing; it will be installed with: sudo -n apt-get install -y --no-install-recommends ethtool"
fi
if [ "$MODE" = dry-run ]; then
  echo "dry-run: --apply would stage the payload, move it to the release target, back up and replace the"
  echo "dry-run: user units, enable the timer, and run the service once. Nothing was changed."
fi
REMOTE

# Apply tail: the payload tar arrives on stdin.
IFS= read -r -d '' REMOTE_APPLY <<'REMOTE' || true
if ! have_ethtool; then
  command -v sudo >/dev/null 2>&1 || refuse "ethtool is missing and sudo is unavailable"
  command -v apt-get >/dev/null 2>&1 || refuse "ethtool is missing and apt-get is unavailable"
  echo "installing ethtool: sudo -n apt-get install -y --no-install-recommends ethtool"
  # stdin carries the payload tar; the installer must never read it.
  sudo -n apt-get install -y --no-install-recommends ethtool </dev/null || refuse "ethtool installation failed (sudo -n apt-get)"
  have_ethtool || refuse "ethtool is still missing after installation"
fi
service_unit=brokkr-link-health.service
timer_unit=brokkr-link-health.timer
installed=0
stage=
print_rollback() {
  echo "Rollback (run on the target as $user):"
  echo "  systemctl --user disable --now $timer_unit"
  echo "  systemctl --user stop $service_unit"
  for unit in $service_unit $timer_unit; do
    if [ -e "$unit_dir/$unit.previous-$REVISION" ]; then
      echo "  mv -f $unit_dir/$unit.previous-$REVISION $unit_dir/$unit"
    else
      echo "  rm -f $unit_dir/$unit"
    fi
  done
  echo "  systemctl --user daemon-reload"
  if [ -e "$unit_dir/$timer_unit.previous-$REVISION" ]; then
    echo "  systemctl --user enable --now $timer_unit   # restore the previous schedule"
  fi
  echo "  rm -rf $release   # optional; the probe never changes link settings"
}
on_exit() {
  rc=$?
  if [ -n "$stage" ]; then rm -rf "$stage"; fi
  if [ "$installed" = 1 ]; then print_rollback; fi
  exit "$rc"
}
trap on_exit EXIT
mkdir -p "$release_root/releases" "$unit_dir"
[ -d "$state_dir" ] || mkdir -p "$state_dir"
stage=$(mktemp -d "$release_root/.stage.XXXXXX")
tar -xf - -C "$stage" || refuse "payload extraction failed"
for file in $EXPECTED_FILES; do
  [ -f "$stage/$file" ] && [ ! -L "$stage/$file" ] || refuse "payload lacks $file"
done
if [ -n "$(find "$stage" ! -type d ! -type f -print)" ]; then refuse "payload contains unexpected entry types"; fi
[ "$(find "$stage" -type f | wc -l | tr -d ' ')" = "$EXPECTED_COUNT" ] || refuse "payload contains unexpected files"
BROKKR_LINK_HEALTH_CONFIG="$LINK_CONFIG" python3 "$stage/network/check-link-health.py" --check-config >/dev/null \
  || refuse "link config rejected by the staged probe parser"
render() {
  sed -e "s|@REVISION@|$REVISION|g" -e "s|@DELIVERY_ENV@|$DELIVERY_ENV|g" -e "s|@LINK_CONFIG@|$LINK_CONFIG|g" "$1" >"$2"
}
render "$stage/systemd/user/$service_unit.in" "$stage/$service_unit"
cp "$stage/systemd/user/$timer_unit" "$stage/$timer_unit"
if grep -Eq '@[A-Z_]+@' "$stage/$service_unit" "$stage/$timer_unit"; then refuse "unit template has an unrendered placeholder"; fi
if [ -e "$release" ] || [ -L "$release" ]; then refuse "release already exists for revision $REVISION"; fi
mv "$stage" "$release"
stage=
installed=1
echo "installed release $release"
for unit in $service_unit $timer_unit; do
  if [ -e "$unit_dir/$unit" ] || [ -L "$unit_dir/$unit" ]; then
    cp -p "$unit_dir/$unit" "$unit_dir/$unit.previous-$REVISION"
    echo "backed up existing $unit as $unit.previous-$REVISION"
  fi
  install -m 644 "$release/$unit" "$unit_dir/$unit"
done
systemctl --user daemon-reload
systemctl --user enable --now "$timer_unit"
# Drop the previous observation so any snapshot found below belongs to this run.
rm -f "$state_dir/link-health.json"
if systemctl --user start "$service_unit"; then start_rc=0; else start_rc=$?; fi
result=$(systemctl --user show "$service_unit" --property=Result --value 2>/dev/null || true)
[ -n "$result" ] || result=unknown
echo "service run: result: $result (start exit $start_rc)"
detail=
if [ -f "$state_dir/link-health.json" ]; then
  detail=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["checks"][0]["detail"])' "$state_dir/link-health.json" 2>/dev/null) || detail=
fi
echo "probe: ${detail:-(no snapshot written by this run)}"
last=$(journalctl --user _SYSTEMD_USER_UNIT="$service_unit" -n 1 -o cat --no-pager 2>/dev/null | tail -n 1 || true)
echo "last log line: ${last:-(user journal unavailable or empty)}"
if [ "$start_rc" -ne 0 ] || [ "$result" != success ]; then
  echo "FAILED: the first service run did not succeed; the timer stays enabled until rolled back" >&2
  exit 3
fi
echo "OK: link-health probe installed and first run succeeded"
REMOTE

run_remote() { # mode script-body; stdin is forwarded to the remote script
  local MODE=$1 prelude body encoded
  prelude="DELIVERY_ENV='$DELIVERY_ENV'
LINK_CONFIG='$LINK_CONFIG'
REVISION='$REVISION'
EXPECTED_FILES='${PAYLOAD_FILES[*]}'
EXPECTED_COUNT='${#PAYLOAD_FILES[@]}'
MODE='$MODE'
"
  body="$prelude$REMOTE_COMMON
$2
"
  encoded="$(printf '%s' "$body" | base64 | tr -d '\n')"
  ssh -o BatchMode=yes "$TARGET" "sh -c \"\$(printf %s '$encoded' | base64 -d)\""
}

PROBE_FILE="$DEPLOY_PAYLOAD_ROOT/network/check-link-health.py"
if (( APPLY )); then
  echo "==> Preflight on $TARGET (revision ${REVISION})"
  run_remote apply "$REMOTE_CHECKS" <"$PROBE_FILE" || {
    echo "brokkr link-health deploy: preflight failed; nothing was changed" >&2
    exit 1
  }
  echo "==> Installing link-health release ${REVISION} on $TARGET"
  if ! ( cd "$DEPLOY_PAYLOAD_ROOT" && COPYFILE_DISABLE=1 tar -cf - "${PAYLOAD_FILES[@]}" ) | run_remote apply "$REMOTE_APPLY"; then
    echo "brokkr link-health deploy: remote install failed (see output above; any rollback recipe applies)" >&2
    exit 1
  fi
  echo "==> Done. No Heimdall credential values were printed."
else
  echo "==> DRY-RUN link-health preflight on $TARGET (revision ${REVISION})"
  run_remote dry-run "$REMOTE_CHECKS" <"$PROBE_FILE" || {
    echo "brokkr link-health deploy: preflight failed; nothing was changed" >&2
    exit 1
  }
  echo "==> DRY-RUN complete. Re-run with --apply to install."
fi
