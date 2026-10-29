#!/usr/bin/env bash
# Brokkr · deploy the monthly archive near-site self-check to the host that holds the
# near-site copy, as a revision-bound user-unit release. Run from the control node; the
# host is reached over ssh.
#
# Dry-run by default: the remote preflight (identity, lingering, protected inputs, GNU
# sha256sum, near-site config and manifest-pin validation, release target) runs and
# nothing is changed. Pass --apply to install. Applying enables the timer but never
# starts the service: a check re-hashes the whole copy and takes hours. The Heimdall
# delivery env must already exist: this script never creates or changes it or any
# credential, and never prints its values. See docs/archive-nearsite.md.
#
#   BROKKR_EXPECTED_SOURCE=$PWD BROKKR_EXPECTED_COMMIT=<full-sha> \
#   BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV=/home/operator/.config/brokkr/env \
#     scripts/deploy-archive-nearsite.sh [--apply] operator@node-a.example
set -euo pipefail

ENTRY_SCRIPT="${BASH_SOURCE[0]}"
ENTRY_PATH="$ENTRY_SCRIPT"
[[ "$ENTRY_PATH" == /* ]] || ENTRY_PATH="$(pwd -P)/$ENTRY_PATH"
[[ "$ENTRY_PATH" != *$'\n'* && "$ENTRY_PATH" != *$'\r'* ]] || { echo "brokkr archive-nearsite deploy: deployment entry point path must not contain line breaks" >&2; exit 64; }
ENTRY_CURSOR=/
IFS=/ read -r -a ENTRY_COMPONENTS <<<"${ENTRY_PATH#/}"
for ENTRY_COMPONENT in "${ENTRY_COMPONENTS[@]}"; do
  case "$ENTRY_COMPONENT" in ''|.) continue ;; ..) ENTRY_CURSOR=$(dirname "$ENTRY_CURSOR"); continue ;; esac
  ENTRY_CURSOR="${ENTRY_CURSOR%/}/$ENTRY_COMPONENT"
  [[ ! -L "$ENTRY_CURSOR" ]] || { echo "brokkr archive-nearsite deploy: deployment entry point path must not contain symlinks" >&2; exit 64; }
done
# Resolve only after rejecting every lexical symlink component in the entry path.
SCRIPT_DIR="$(cd "$(dirname "$ENTRY_SCRIPT")" && pwd -P)"
HERE="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=scripts/lib/deploy-source.sh
source "$HERE/scripts/lib/deploy-source.sh"

die() { echo "brokkr archive-nearsite deploy: $*" >&2; exit 64; }
usage() {
  echo "usage: $0 [--apply] SSH_TARGET" >&2
  echo "  env: BROKKR_EXPECTED_SOURCE, BROKKR_EXPECTED_COMMIT (full SHA), BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV (remote absolute path)," >&2
  echo "       optional BROKKR_ARCHIVE_NEARSITE_CONFIG (remote absolute path; default \$XDG_CONFIG_HOME|~/.config/brokkr/archive-nearsite.conf)" >&2
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

DELIVERY_ENV="${BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV:-}"
ARCHIVE_CONFIG="${BROKKR_ARCHIVE_NEARSITE_CONFIG:-}"
[[ -n "$DELIVERY_ENV" ]] || die "BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV is required (remote absolute path of the Heimdall delivery env file)"
valid_path "$DELIVERY_ENV" || die "invalid BROKKR_ARCHIVE_NEARSITE_DELIVERY_ENV (absolute plain path required)"
if [[ -n "$ARCHIVE_CONFIG" ]]; then
  valid_path "$ARCHIVE_CONFIG" || die "invalid BROKKR_ARCHIVE_NEARSITE_CONFIG (absolute plain path required)"
fi

# Only what the self-check needs. The service unit is shipped as a template and rendered
# on the node, where the runtime home and protected-file paths are known.
PAYLOAD_FILES=(
  scripts/archive-nearsite.sh
  heimdall/push.sh
  systemd/user/brokkr-archive-nearsite.service.in
  systemd/user/brokkr-archive-nearsite.timer
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
[ -n "$ARCHIVE_CONFIG" ] || ARCHIVE_CONFIG=$config_home/brokkr/archive-nearsite.conf
safe_path "$ARCHIVE_CONFIG" || refuse "archive config path is not an absolute plain path"
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
private_file "$ARCHIVE_CONFIG" "near-site config"
# PrivateTmp=yes gives the unit its own /tmp and /var/tmp, so inputs there would pass
# this preflight and vanish at run time. (The override exists only for the hermetic test,
# whose fixtures may live under /tmp; ssh does not forward it.)
tmp_roots=${BROKKR_ARCHIVE_NEARSITE_PRIVATE_TMP_ROOTS:-/tmp /var/tmp}
hidden_by_private_tmp() {
  for root in $tmp_roots; do case $1 in "$root"|"$root"/*) return 0 ;; esac; done
  return 1
}
if hidden_by_private_tmp "$ARCHIVE_CONFIG"; then refuse "near-site config is under a temporary directory that PrivateTmp hides from the unit"; fi
for key in ARCHIVE_NEARSITE_DIR ARCHIVE_NEARSITE_MANIFEST; do
  value=$(sed -n "s/^$key=//p" "$ARCHIVE_CONFIG" | tail -n 1 | tr -d "\"'")
  if [ -n "$value" ] && hidden_by_private_tmp "$value"; then
    refuse "$key is under a temporary directory that PrivateTmp hides from the unit"
  fi
done
# The existing producer credential is only tested for presence (grep -q, exit status
# only): no value is captured, printed, or written anywhere, and the file is never changed.
for key in HEIMDALL_HUB_URL HEIMDALL_FLEET_TOKEN; do
  grep -Eq "^${key}=.+$" "$DELIVERY_ENV" || refuse "delivery env lacks a non-empty $key"
  if grep -Eq "^${key}=(''|\"\")$" "$DELIVERY_ENV"; then refuse "delivery env lacks a non-empty $key"; fi
  [ "$(grep -Ec "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$DELIVERY_ENV")" = 1 ] \
    || refuse "delivery env must define $key exactly once"
done
# systemd applies EnvironmentFile after Environment=, so this file (shared with other
# brokkr units) must not be able to redirect what this unit runs or reads, for example
# the state directory or an ARCHIVE_* variable. Unrelated keys are allowed.
forbidden='PATH|HOME|TMPDIR|BROKKR_STATE_DIR|PYTHONPATH|PYTHONHOME|LD_PRELOAD|LD_LIBRARY_PATH|ARCHIVE_[A-Z0-9_]*'
if bad_key=$(grep -Eo "^[[:space:]]*(export[[:space:]]+)?($forbidden)[[:space:]]*=" "$DELIVERY_ENV" | head -n 1) && [ -n "$bad_key" ]; then
  refuse "delivery env must not set the verifier-controlling variable ${bad_key%%=*}"
fi
command -v python3 >/dev/null 2>&1 || refuse "python3 is required"
command -v bash >/dev/null 2>&1 || refuse "bash is required"
# Captured first: a closing `grep -q` must not fail the check through SIGPIPE.
sha_banner=$(sha256sum --version 2>/dev/null || true)
case $sha_banner in *GNU*) ;; *) refuse "GNU sha256sum is required on this node" ;; esac
release_root=$HOME/.local/lib/brokkr/archive-nearsite
release=$release_root/releases/$REVISION
unit_dir=$config_home/systemd/user
state_dir=$HOME/.local/state/brokkr
if [ -e "$release" ] || [ -L "$release" ]; then refuse "release already exists for revision $REVISION"; fi
for unit in brokkr-archive-nearsite.service brokkr-archive-nearsite.timer; do
  if [ -e "$unit_dir/$unit.previous-$REVISION" ] || [ -L "$unit_dir/$unit.previous-$REVISION" ]; then
    refuse "unit backup $unit.previous-$REVISION already exists"
  fi
done
# Runs an archive-nearsite.sh in --validate mode against the near-site config. The mode
# parses the config, checks that the manifest matches the pinned sha256 and is well
# formed, and checks that the directory exists; it hashes nothing and prints counts
# only. A scratch state dir keeps it away from the node's real state directory so a
# dry-run leaves nothing behind.
validate_nearsite() { # script path, or - to read the script from stdin
  vstate=$(mktemp -d) || refuse "cannot create a scratch directory"
  vscript=$1
  # A script piped to `bash -s` has no BASH_SOURCE, so give stdin input a real file.
  if [ "$vscript" = - ]; then vscript=$vstate/archive-nearsite.sh; cat >"$vscript"; fi
  if vout=$(BROKKR_STATE_DIR="$vstate" TMPDIR="$vstate" bash "$vscript" --config "$ARCHIVE_CONFIG" --validate 2>&1 </dev/null); then vrc=0; else vrc=$?; fi
  rm -rf "$vstate"
  if [ -n "$vout" ]; then printf '%s\n' "$vout" | sed 's/^/preflight: /'; fi
  [ "$vrc" = 0 ] || refuse "near-site config or manifest rejected by the shipped verifier (--validate exit $vrc)"
}
echo "preflight: runtime user $user (not root), user lingering enabled"
echo "preflight: delivery env and near-site config are private regular files owned by $user"
echo "preflight: delivery env has non-empty HEIMDALL_HUB_URL and HEIMDALL_FLEET_TOKEN (values not read)"
echo "preflight: GNU sha256sum and python3 present"
echo "preflight: release target $release (absent)"
echo "preflight: user unit directory $unit_dir"
REMOTE

# Read-only checks: the verifier arrives on stdin and validates the config with its own
# parser and --validate. Runs for the dry-run and as the gate before --apply mutates
# anything.
IFS= read -r -d '' REMOTE_CHECKS <<'REMOTE' || true
validate_nearsite -
if [ "$MODE" = dry-run ]; then
  echo "dry-run: --apply would stage the payload, move it to the release target, back up and replace the"
  echo "dry-run: user units, and enable the timer. It would not start a check. Nothing was changed."
fi
REMOTE

# Apply tail: the payload tar arrives on stdin.
IFS= read -r -d '' REMOTE_APPLY <<'REMOTE' || true
service_unit=brokkr-archive-nearsite.service
timer_unit=brokkr-archive-nearsite.timer
# Steps that actually completed; the exit trap prints a rollback matching exactly these.
release_moved=0
service_replaced=0
timer_replaced=0
timer_enabled=0
# The timer's state before this run, recorded before any unit changes, so the rollback
# restores exactly that state and never starts a schedule that was off.
prev_timer_enabled=unknown
prev_timer_active=unknown
stage=
tmp_backups=
cleanup_tmp_backups() {
  for tmp in $tmp_backups; do rm -f "$tmp"; done
  tmp_backups=
}
print_state() {
  if [ "$release_moved" = 0 ] && [ "$service_replaced" = 0 ] && [ "$timer_replaced" = 0 ]; then
    echo "State: no release or installed unit was changed on this node."
  else
    echo "Rollback (run on the target as $user; only steps this run started are listed):"
  fi
  if [ "$timer_enabled" = 1 ]; then echo "  systemctl --user disable --now $timer_unit"; fi
  for unit in $service_unit $timer_unit; do
    case $unit in "$service_unit") replaced=$service_replaced ;; *) replaced=$timer_replaced ;; esac
    backup=$unit_dir/$unit.previous-$REVISION
    if [ "$replaced" = 1 ]; then
      if [ -e "$backup" ]; then echo "  mv -f $backup $unit_dir/$unit"; else echo "  rm -f $unit_dir/$unit"; fi
    elif [ -e "$backup" ]; then
      echo "  # $unit was left untouched; optional: rm -f $backup"
    fi
  done
  if [ "$service_replaced" = 1 ] || [ "$timer_replaced" = 1 ]; then
    echo "  systemctl --user daemon-reload"
  fi
  if [ "$timer_enabled" = 1 ]; then
    echo "  # timer before this run: $prev_timer_enabled, $prev_timer_active"
    if [ "$prev_timer_enabled" = enabled ]; then echo "  systemctl --user enable $timer_unit"; fi
    if [ "$prev_timer_active" = active ]; then echo "  systemctl --user start $timer_unit"; fi
  fi
  if [ "$release_moved" = 1 ]; then echo "  rm -rf $release   # optional; the check never changes the near-site copy"; fi
}
on_exit() {
  rc=$?
  cleanup_tmp_backups
  if [ -n "$stage" ]; then rm -rf "$stage"; fi
  print_state
  exit "$rc"
}
trap on_exit EXIT
mkdir -p "$release_root/releases"
stage=$(mktemp -d "$release_root/.stage.XXXXXX")
tar -xf - -C "$stage" || refuse "payload extraction failed"
for file in $EXPECTED_FILES; do
  [ -f "$stage/$file" ] && [ ! -L "$stage/$file" ] || refuse "payload lacks $file"
done
if [ -n "$(find "$stage" ! -type d ! -type f -print)" ]; then refuse "payload contains unexpected entry types"; fi
[ "$(find "$stage" -type f | wc -l | tr -d ' ')" = "$EXPECTED_COUNT" ] || refuse "payload contains unexpected files"
[ -x "$stage/scripts/archive-nearsite.sh" ] && [ -x "$stage/heimdall/push.sh" ] || refuse "payload scripts are not executable"
validate_nearsite "$stage/scripts/archive-nearsite.sh"
# The payload is received and validated; only now change the node.
render() {
  sed -e "s|@REVISION@|$REVISION|g" -e "s|@DELIVERY_ENV@|$DELIVERY_ENV|g" -e "s|@ARCHIVE_CONFIG@|$ARCHIVE_CONFIG|g" "$1" >"$2"
}
render "$stage/systemd/user/$service_unit.in" "$stage/$service_unit"
cp "$stage/systemd/user/$timer_unit" "$stage/$timer_unit"
if grep -Eq '@[A-Z_]+@' "$stage/$service_unit" "$stage/$timer_unit"; then refuse "unit template has an unrendered placeholder"; fi
if [ -e "$release" ] || [ -L "$release" ]; then refuse "release already exists for revision $REVISION"; fi
mkdir -p "$unit_dir"
[ -d "$state_dir" ] || mkdir -p "$state_dir"
# Back up BOTH existing units to temporary names first, then rename them into place.
# Until every backup exists nothing has been replaced, so a failure here leaves the
# original units intact.
for unit in $service_unit $timer_unit; do
  if [ -e "$unit_dir/$unit" ] || [ -L "$unit_dir/$unit" ]; then
    tmp=$unit_dir/.$unit.backup-tmp.$$
    tmp_backups="$tmp_backups $tmp"
    cp -p "$unit_dir/$unit" "$tmp" || refuse "could not back up existing $unit; no unit was changed"
  fi
done
for tmp in $tmp_backups; do
  name=${tmp##*/.}
  name=${name%.backup-tmp.*}
  mv "$tmp" "$unit_dir/$name.previous-$REVISION" || refuse "could not finalize the backup of $name; no unit was changed"
  echo "backed up existing $name as $name.previous-$REVISION"
done
tmp_backups=
# Queries only; an absent unit reports not-found / inactive and a non-zero status.
prev_timer_enabled=$(systemctl --user is-enabled "$timer_unit" 2>/dev/null || true)
prev_timer_active=$(systemctl --user is-active "$timer_unit" 2>/dev/null || true)
prev_timer_enabled=${prev_timer_enabled:-not-found}
prev_timer_active=${prev_timer_active:-inactive}
echo "timer before this run: $prev_timer_enabled, $prev_timer_active"
mv "$stage" "$release"
stage=
release_moved=1
echo "installed release $release"
service_replaced=1
install -m 644 "$release/$service_unit" "$unit_dir/$service_unit"
timer_replaced=1
install -m 644 "$release/$timer_unit" "$unit_dir/$timer_unit"
systemctl --user daemon-reload
timer_enabled=1
systemctl --user enable --now "$timer_unit"
# A check re-hashes the whole near-site copy and takes hours, so it is not started here.
echo "next: start the first check with: systemctl --user start --no-block $service_unit"
echo "next: check progress with: systemctl --user status $service_unit"
echo "next: read the result with: cat ~/.local/state/brokkr/archive-nearsite.json"
echo "OK: archive near-site self-check installed; timer enabled"
REMOTE

run_remote() { # mode script-body; stdin is forwarded to the remote script
  local MODE=$1 prelude body encoded
  prelude="DELIVERY_ENV='$DELIVERY_ENV'
ARCHIVE_CONFIG='$ARCHIVE_CONFIG'
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

VERIFIER_FILE="$DEPLOY_PAYLOAD_ROOT/scripts/archive-nearsite.sh"
if (( APPLY )); then
  echo "==> Preflight on $TARGET (revision ${REVISION})"
  run_remote apply "$REMOTE_CHECKS" <"$VERIFIER_FILE" || {
    echo "brokkr archive-nearsite deploy: preflight failed; nothing was changed" >&2
    exit 1
  }
  echo "==> Installing archive-nearsite release ${REVISION} on $TARGET"
  if ! ( cd "$DEPLOY_PAYLOAD_ROOT" && COPYFILE_DISABLE=1 tar -cf - "${PAYLOAD_FILES[@]}" ) | run_remote apply "$REMOTE_APPLY"; then
    echo "brokkr archive-nearsite deploy: remote install failed (see output above; any rollback recipe applies)" >&2
    exit 1
  fi
  echo "==> Done. No Heimdall credential values were printed."
else
  echo "==> DRY-RUN archive-nearsite preflight on $TARGET (revision ${REVISION})"
  run_remote dry-run "$REMOTE_CHECKS" <"$VERIFIER_FILE" || {
    echo "brokkr archive-nearsite deploy: preflight failed; nothing was changed" >&2
    exit 1
  }
  echo "==> DRY-RUN complete. Re-run with --apply to install."
fi
