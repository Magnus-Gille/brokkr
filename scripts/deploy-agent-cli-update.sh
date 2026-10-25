#!/usr/bin/env bash
# Brokkr · deploy the agent CLI updater to a fleet node as a revision-bound user-unit
# release. Run from the control node; the node is reached over ssh.
#
# Dry-run by default: the remote preflight (identity, lingering, npm/node, release target)
# runs and nothing is changed. Pass --apply to install. See docs/agent-cli-update.md.
#
#   BROKKR_EXPECTED_SOURCE=$PWD BROKKR_EXPECTED_COMMIT=<full-sha> \
#   BROKKR_AGENT_CLI_BUSY_UNITS=hugin.service \
#     scripts/deploy-agent-cli-update.sh [--apply] operator@node-a.example
set -euo pipefail

ENTRY_SCRIPT="${BASH_SOURCE[0]}"
ENTRY_PATH="$ENTRY_SCRIPT"
[[ "$ENTRY_PATH" == /* ]] || ENTRY_PATH="$(pwd -P)/$ENTRY_PATH"
[[ "$ENTRY_PATH" != *$'\n'* && "$ENTRY_PATH" != *$'\r'* ]] || { echo "brokkr agent-cli-update deploy: deployment entry point path must not contain line breaks" >&2; exit 64; }
ENTRY_CURSOR=/
IFS=/ read -r -a ENTRY_COMPONENTS <<<"${ENTRY_PATH#/}"
for ENTRY_COMPONENT in "${ENTRY_COMPONENTS[@]}"; do
  case "$ENTRY_COMPONENT" in ''|.) continue ;; ..) ENTRY_CURSOR=$(dirname "$ENTRY_CURSOR"); continue ;; esac
  ENTRY_CURSOR="${ENTRY_CURSOR%/}/$ENTRY_COMPONENT"
  [[ ! -L "$ENTRY_CURSOR" ]] || { echo "brokkr agent-cli-update deploy: deployment entry point path must not contain symlinks" >&2; exit 64; }
done
# Resolve only after rejecting every lexical symlink component in the entry path.
SCRIPT_DIR="$(cd "$(dirname "$ENTRY_SCRIPT")" && pwd -P)"
HERE="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=scripts/lib/deploy-source.sh
source "$HERE/scripts/lib/deploy-source.sh"

die() { echo "brokkr agent-cli-update deploy: $*" >&2; exit 64; }
usage() {
  echo "usage: $0 [--apply] SSH_TARGET" >&2
  echo "  env: BROKKR_EXPECTED_SOURCE, BROKKR_EXPECTED_COMMIT (full SHA)," >&2
  echo "       optional BROKKR_AGENT_CLI_BUSY_UNITS (space-separated systemd user .service units; the updater defers while one has spawned work)" >&2
  exit 64
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

# The busy units are rendered into the unit file, so they are validated here (and again by
# the updater at run time) as plain .service names, never as free text. A name must not
# start with '-': the updater passes it to systemctl as an argument.
BUSY_RAW="${BROKKR_AGENT_CLI_BUSY_UNITS-}"
BUSY_UNIT_RE='^[A-Za-z0-9@_.][A-Za-z0-9@._-]*\.service$'
case "$BUSY_RAW" in
  *[!A-Za-z0-9@._\ -]*) die "invalid BROKKR_AGENT_CLI_BUSY_UNITS (space-separated .service unit names)" ;;
esac
BUSY_WORDS=()
IFS=' ' read -r -a BUSY_WORDS <<<"$BUSY_RAW"
BUSY_UNITS=""
for BUSY_WORD in ${BUSY_WORDS[@]+"${BUSY_WORDS[@]}"}; do
  [[ "$BUSY_WORD" =~ $BUSY_UNIT_RE ]] || die "invalid BROKKR_AGENT_CLI_BUSY_UNITS entry (a .service unit name is required)"
  BUSY_UNITS="${BUSY_UNITS:+$BUSY_UNITS }$BUSY_WORD"
done

# Only what the updater needs. The units are shipped as templates and rendered on the
# node, where the runtime home is known.
PAYLOAD_FILES=(
  scripts/agent-cli-update.sh
  systemd/user/brokkr-agent-cli-update.service.in
  systemd/user/brokkr-agent-cli-update.timer
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
if ! linger=$(loginctl show-user "$user" --property=Linger 2>/dev/null); then linger=; fi
[ "$linger" = Linger=yes ] || refuse "user lingering is not enabled for $user (loginctl enable-linger)"
release_root=$HOME/.local/lib/brokkr/agent-cli-update
release=$release_root/releases/$REVISION
unit_dir=$config_home/systemd/user
state_dir=$HOME/.local/state/brokkr
if [ -e "$release" ] || [ -L "$release" ]; then refuse "release already exists for revision $REVISION"; fi
for unit in brokkr-agent-cli-update.service brokkr-agent-cli-update.timer; do
  if [ -e "$unit_dir/$unit.previous-$REVISION" ] || [ -L "$unit_dir/$unit.previous-$REVISION" ]; then
    refuse "unit backup $unit.previous-$REVISION already exists"
  fi
done
command -v bash >/dev/null 2>&1 || refuse "bash is required (the updater runs under bash)"
echo "preflight: runtime user $user (not root), user lingering enabled"
echo "preflight: release target $release (absent)"
echo "preflight: user unit directory $unit_dir"
echo "preflight: busy units: ${BUSY_UNITS:-(none)}"
REMOTE

# Read-only checks. npm and node are what the npm-managed CLIs are updated with; the unit's
# PATH is fixed, so look for them where the unit will look. Absent is a warning, not a
# refusal: tools that are not npm-managed are updated without them.
IFS= read -r -d '' REMOTE_CHECKS <<'REMOTE' || true
search_path=${BROKKR_AGENT_CLI_TOOL_PATH:-/usr/local/bin:/usr/bin:/bin}:$HOME/.local/bin
for tool in npm node; do
  found=
  old_ifs=$IFS
  IFS=:
  for dir in $search_path; do
    if [ -x "$dir/$tool" ] && [ ! -d "$dir/$tool" ]; then found=$dir/$tool; break; fi
  done
  IFS=$old_ifs
  if [ -n "$found" ]; then
    echo "preflight: $tool at $found"
  else
    echo "preflight: WARN: $tool is not on the unit PATH ($search_path); npm-managed agent CLIs will be reported failed until it is"
  fi
done
if [ "$MODE" = dry-run ]; then
  echo "dry-run: --apply would stage the payload, move it to the release target, back up and replace the"
  echo "dry-run: user units, enable the timer, and run the updater once. Nothing was changed."
fi
REMOTE

# Apply tail: the payload tar arrives on stdin.
IFS= read -r -d '' REMOTE_APPLY <<'REMOTE' || true
service_unit=brokkr-agent-cli-update.service
timer_unit=brokkr-agent-cli-update.timer
# Steps that actually completed; the exit trap prints a rollback matching exactly these.
release_moved=0
service_replaced=0
timer_replaced=0
timer_enabled=0
service_started=0
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
  if [ "$service_started" = 1 ]; then echo "  systemctl --user stop $service_unit"; fi
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
    if [ "$timer_replaced" = 1 ] && [ -e "$unit_dir/$timer_unit.previous-$REVISION" ]; then
      echo "  systemctl --user enable --now $timer_unit   # restore the previous schedule"
    fi
  fi
  if [ "$release_moved" = 1 ]; then echo "  rm -rf $release   # optional once the units no longer point at it"; fi
  if [ "$service_started" = 1 ]; then
    echo "  # the first updater run may have upgraded agent CLIs in place; those upgrades are not undone by this rollback"
  fi
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
bash -n "$stage/scripts/agent-cli-update.sh" || refuse "staged updater has a syntax error under this node's bash"
# The payload is received and validated; only now change the node.
render() {
  sed -e "s|@REVISION@|$REVISION|g" -e "s|@BUSY_UNITS@|$BUSY_UNITS|g" "$1" >"$2"
}
render "$stage/systemd/user/$service_unit.in" "$stage/$service_unit"
cp "$stage/systemd/user/$timer_unit" "$stage/$timer_unit"
if grep -Eq '@[A-Z_]+@' "$stage/$service_unit" "$stage/$timer_unit"; then refuse "unit template has an unrendered placeholder"; fi
if [ -e "$release" ] || [ -L "$release" ]; then refuse "release already exists for revision $REVISION"; fi
mkdir -p "$unit_dir"
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
state=$state_dir/agent-cli-update.json
start_epoch=$(date +%s)
service_started=1
if systemctl --user start "$service_unit"; then start_rc=0; else start_rc=$?; fi
result=$(systemctl --user show "$service_unit" --property=Result --value 2>/dev/null || true)
[ -n "$result" ] || result=unknown
echo "service run: result: $result (start exit $start_rc)"
fresh=0
if [ -f "$state" ] && [ ! -L "$state" ]; then
  if ! state_mtime=$(stat -c %Y "$state" 2>/dev/null); then state_mtime=$(stat -f %m "$state" 2>/dev/null || echo 0); fi
  if [ "$state_mtime" -ge "$start_epoch" ]; then fresh=1; fi
fi
updater_result=
if [ "$fresh" = 1 ]; then
  updater_result=$(sed -n 's/^  "result": "\([a-z]*\)",$/\1/p' "$state" 2>/dev/null | head -n 1) || updater_result=
fi
echo "updater: result=${updater_result:-(no fresh state file written by this run)}"
last=$(journalctl --user _SYSTEMD_USER_UNIT="$service_unit" -n 1 -o cat --no-pager 2>/dev/null | tail -n 1 || true)
echo "last log line: ${last:-(user journal unavailable or empty)}"
if [ "$start_rc" -ne 0 ] || [ "$result" != success ]; then
  echo "FAILED: the first updater run did not succeed (a tool failed or was rolled back); the release, units and timer stay installed until rolled back" >&2
  exit 3
fi
if [ "$fresh" != 1 ]; then
  echo "FAILED: the first run did not write a fresh state file (is BROKKR_STATE_DIR redirected?); the timer stays enabled until rolled back" >&2
  exit 3
fi
echo "OK: agent CLI updater installed and first run succeeded (result: $updater_result)"
REMOTE

run_remote() { # mode script-body; stdin is forwarded to the remote script
  local MODE=$1 prelude body encoded
  prelude="REVISION='$REVISION'
BUSY_UNITS='$BUSY_UNITS'
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

if (( APPLY )); then
  echo "==> Preflight on $TARGET (revision ${REVISION})"
  run_remote apply "$REMOTE_CHECKS" </dev/null || {
    echo "brokkr agent-cli-update deploy: preflight failed; nothing was changed" >&2
    exit 1
  }
  echo "==> Installing agent-cli-update release ${REVISION} on $TARGET"
  if ! ( cd "$DEPLOY_PAYLOAD_ROOT" && COPYFILE_DISABLE=1 tar -cf - "${PAYLOAD_FILES[@]}" ) | run_remote apply "$REMOTE_APPLY"; then
    echo "brokkr agent-cli-update deploy: remote install failed (see output above; any rollback recipe applies)" >&2
    exit 1
  fi
  echo "==> Done."
else
  echo "==> DRY-RUN agent-cli-update preflight on $TARGET (revision ${REVISION})"
  run_remote dry-run "$REMOTE_CHECKS" </dev/null || {
    echo "brokkr agent-cli-update deploy: preflight failed; nothing was changed" >&2
    exit 1
  }
  echo "==> DRY-RUN complete. Re-run with --apply to install."
fi
