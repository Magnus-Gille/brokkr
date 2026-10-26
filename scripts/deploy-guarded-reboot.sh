#!/usr/bin/env bash
# Brokkr · deploy the guarded reboot job (Grimnir ADR-009) to a fleet node as a revision-bound
# user-unit release. Run from the control node; the node is reached over ssh.
#
# Dry-run by default: the remote preflight (identity, lingering, Linux, passwordless sudo, notify
# configuration, the crypttab unlock assessment, the stock EEPROM service) runs and nothing is
# changed. Pass --apply to install. The job always starts in report mode unless
# BROKKR_GUARDED_REBOOT_MODE=reboot is given, and this script NEVER starts the reboot service
# or reboots anything: its only run of the job is `check --report-only` plus `status`.
# See docs/guarded-reboot.md.
#
#   BROKKR_EXPECTED_SOURCE=$PWD BROKKR_EXPECTED_COMMIT=<full-sha> \
#   BROKKR_GUARDED_REBOOT_WINDOW=03:30 BROKKR_GUARDED_REBOOT_BUSY_UNITS=hugin.service \
#     scripts/deploy-guarded-reboot.sh [--apply] operator@node-a.example
set -euo pipefail

ENTRY_SCRIPT="${BASH_SOURCE[0]}"
ENTRY_PATH="$ENTRY_SCRIPT"
[[ "$ENTRY_PATH" == /* ]] || ENTRY_PATH="$(pwd -P)/$ENTRY_PATH"
[[ "$ENTRY_PATH" != *$'\n'* && "$ENTRY_PATH" != *$'\r'* ]] || { echo "brokkr guarded-reboot deploy: deployment entry point path must not contain line breaks" >&2; exit 64; }
ENTRY_CURSOR=/
IFS=/ read -r -a ENTRY_COMPONENTS <<<"${ENTRY_PATH#/}"
for ENTRY_COMPONENT in "${ENTRY_COMPONENTS[@]}"; do
  case "$ENTRY_COMPONENT" in ''|.) continue ;; ..) ENTRY_CURSOR=$(dirname "$ENTRY_CURSOR"); continue ;; esac
  ENTRY_CURSOR="${ENTRY_CURSOR%/}/$ENTRY_COMPONENT"
  [[ ! -L "$ENTRY_CURSOR" ]] || { echo "brokkr guarded-reboot deploy: deployment entry point path must not contain symlinks" >&2; exit 64; }
done
# Resolve only after rejecting every lexical symlink component in the entry path.
SCRIPT_DIR="$(cd "$(dirname "$ENTRY_SCRIPT")" && pwd -P)"
HERE="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=scripts/lib/deploy-source.sh
source "$HERE/scripts/lib/deploy-source.sh"

die() { echo "brokkr guarded-reboot deploy: $*" >&2; exit 64; }
usage() {
  echo "usage: $0 [--apply] SSH_TARGET" >&2
  echo "  env: BROKKR_EXPECTED_SOURCE, BROKKR_EXPECTED_COMMIT (full SHA)," >&2
  echo "       optional BROKKR_GUARDED_REBOOT_MODE (report, the default, or reboot; reboot needs an explicit WINDOW and a PEER)," >&2
  echo "       BROKKR_GUARDED_REBOOT_WINDOW (HH:MM, default 03:30 in report mode), BROKKR_GUARDED_REBOOT_SPREAD (minutes, default 45)," >&2
  echo "       BROKKR_GUARDED_REBOOT_BUSY_UNITS (space-separated systemd user .service units)," >&2
  echo "       BROKKR_GUARDED_REBOOT_PEERS (space-separated host names that must answer on port 22)," >&2
  echo "       BROKKR_GUARDED_REBOOT_MAX_LOAD, BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN, BROKKR_GUARDED_REBOOT_ALERT_AFTER" >&2
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

# --- inputs: validated here (and again by the job at run time) because they are rendered into units
GR_MODE="${BROKKR_GUARDED_REBOOT_MODE:-report}"
case "$GR_MODE" in report|reboot) ;; *) die "invalid BROKKR_GUARDED_REBOOT_MODE (report or reboot)" ;; esac
WINDOW="${BROKKR_GUARDED_REBOOT_WINDOW:-03:30}"
[[ "$WINDOW" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "invalid BROKKR_GUARDED_REBOOT_WINDOW (HH:MM, 24-hour)"
SPREAD="${BROKKR_GUARDED_REBOOT_SPREAD:-45}"
[[ "$SPREAD" =~ ^[0-9]{1,3}$ ]] && [ "$((0 + 10#$SPREAD))" -le 240 ] || die "invalid BROKKR_GUARDED_REBOOT_SPREAD (minutes, 0 to 240)"
SPREAD="$((0 + 10#$SPREAD))"
MAX_LOAD="${BROKKR_GUARDED_REBOOT_MAX_LOAD:-}"
if [[ -n "$MAX_LOAD" ]]; then
  [[ "$MAX_LOAD" =~ ^[0-9]{1,4}(\.[0-9]{1,3})?$ ]] || die "invalid BROKKR_GUARDED_REBOOT_MAX_LOAD (a decimal such as 1.5; empty means 0.75 x CPUs)"
fi
TTY_IDLE_MIN="${BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN:-60}"
[[ "$TTY_IDLE_MIN" =~ ^[0-9]{1,4}$ ]] && [ "$((0 + 10#$TTY_IDLE_MIN))" -le 1440 ] || die "invalid BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN (minutes, 0 to 1440)"
TTY_IDLE_MIN="$((0 + 10#$TTY_IDLE_MIN))"
ALERT_AFTER="${BROKKR_GUARDED_REBOOT_ALERT_AFTER:-3}"
[[ "$ALERT_AFTER" =~ ^[0-9]{1,3}$ ]] && [ "$((0 + 10#$ALERT_AFTER))" -ge 1 ] && [ "$((0 + 10#$ALERT_AFTER))" -le 365 ] || die "invalid BROKKR_GUARDED_REBOOT_ALERT_AFTER (1 to 365)"
ALERT_AFTER="$((0 + 10#$ALERT_AFTER))"

# Busy units are plain .service names; a name must not start with '-' (it reaches systemctl).
BUSY_RAW="${BROKKR_GUARDED_REBOOT_BUSY_UNITS-}"
BUSY_UNIT_RE='^[A-Za-z0-9@_.][A-Za-z0-9@._-]*\.service$'
case "$BUSY_RAW" in
  *[!A-Za-z0-9@._\ -]*) die "invalid BROKKR_GUARDED_REBOOT_BUSY_UNITS (space-separated .service unit names)" ;;
esac
BUSY_UNITS=""
for BUSY_WORD in $BUSY_RAW; do
  [[ "$BUSY_WORD" =~ $BUSY_UNIT_RE ]] || die "invalid BROKKR_GUARDED_REBOOT_BUSY_UNITS entry (a .service unit name is required)"
  BUSY_UNITS="${BUSY_UNITS:+$BUSY_UNITS }$BUSY_WORD"
done
PEERS_RAW="${BROKKR_GUARDED_REBOOT_PEERS-}"
case "$PEERS_RAW" in
  *[!A-Za-z0-9.\ -]*) die "invalid BROKKR_GUARDED_REBOOT_PEERS (space-separated host names)" ;;
esac
PEERS=""
for PEER_WORD in $PEERS_RAW; do
  [[ "$PEER_WORD" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "invalid BROKKR_GUARDED_REBOOT_PEERS entry (a host name is required)"
  PEERS="${PEERS:+$PEERS }$PEER_WORD"
done
# Reboot mode is the owner's explicit switch and it needs both of these stated, not defaulted: a
# window chosen for this host (so it never reboots together with the host that monitors it), and at
# least one peer that must be reachable first (normally that monitoring host).
if [[ "$GR_MODE" == reboot ]]; then
  [[ -n "${BROKKR_GUARDED_REBOOT_WINDOW:-}" ]] || die "reboot mode needs an explicit BROKKR_GUARDED_REBOOT_WINDOW (there is no default window in reboot mode); stagger the windows, with spread, at least two hours apart"
  [[ -n "$PEERS" ]] || die "reboot mode needs BROKKR_GUARDED_REBOOT_PEERS (at least one host that must be reachable before this host reboots, normally the host that monitors it)"
fi

# Only what the job needs. The units are shipped as templates and rendered on the node, where the
# runtime home is known.
PAYLOAD_FILES=(
  scripts/guarded-reboot.sh
  scripts/lib/notify.sh
  systemd/user/brokkr-guarded-reboot.service.in
  systemd/user/brokkr-guarded-reboot.timer
  systemd/user/brokkr-post-boot-check.service.in
  systemd/user/brokkr-post-boot-check.timer
  systemd/user/brokkr-post-update-health.service.in
  systemd/user/brokkr-post-update-health.timer
)
for FILE in "${PAYLOAD_FILES[@]}"; do
  [[ -f "$DEPLOY_PAYLOAD_ROOT/$FILE" && ! -L "$DEPLOY_PAYLOAD_ROOT/$FILE" ]] || die "committed payload lacks regular file $FILE"
done

# Remote scripts run under sh (shipped base64-encoded, so the operator's login shell never parses
# them) and are POSIX-only. Inputs are validated above and below, so single-quoted assignment is safe.
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
[ "$(uname -s)" = Linux ] || refuse "the guarded reboot job is Linux only"
safe_path "${HOME:-}" || refuse "HOME is not an absolute plain path"
config_home=${XDG_CONFIG_HOME:-}
if [ -z "$config_home" ]; then config_home=$HOME/.config; fi
safe_path "$config_home" || refuse "config home is not an absolute plain path"
if ! linger=$(loginctl show-user "$user" --property=Linger 2>/dev/null); then linger=; fi
[ "$linger" = Linger=yes ] || refuse "user lingering is not enabled for $user (loginctl enable-linger); the user timers would not run unattended"
release_root=$HOME/.local/lib/brokkr/guarded-reboot
release=$release_root/releases/$REVISION
unit_dir=$config_home/systemd/user
state_dir=$HOME/.local/state/brokkr
UNITS="brokkr-guarded-reboot.service brokkr-guarded-reboot.timer brokkr-post-boot-check.service brokkr-post-boot-check.timer brokkr-post-update-health.service brokkr-post-update-health.timer"
TIMERS="brokkr-guarded-reboot.timer brokkr-post-boot-check.timer brokkr-post-update-health.timer"
if [ -e "$release" ] || [ -L "$release" ]; then refuse "release already exists for revision $REVISION"; fi
for unit in $UNITS; do
  if [ -e "$unit_dir/$unit.previous-$REVISION" ] || [ -L "$unit_dir/$unit.previous-$REVISION" ]; then
    refuse "unit backup $unit.previous-$REVISION already exists"
  fi
done
command -v bash >/dev/null 2>&1 || refuse "bash is required (the job runs under bash)"
sudo -n true </dev/null >/dev/null 2>&1 || refuse "passwordless sudo is required (sudo -n true failed): the job appends to the root-owned audit file and runs the reboot through sudo"
# The audit directories must be searchable by an unprivileged reader (the daily maintenance report
# reads the audit file as another user). An existing /var/lib/brokkr is never chmod-ed: it is
# verified, and a closed one is refused. The directories the privileged install creates are the
# constants /var/lib/brokkr and /var/lib/brokkr/guarded-reboot: no environment variable changes an
# argument of a sudo call. audit_parent below is only where the UNPRIVILEGED checks look (a test
# seam, the same path in production).
audit_parent=${BROKKR_AUDIT_PARENT_PROBE:-}
if [ -z "$audit_parent" ]; then audit_parent=/var/lib/brokkr; fi
safe_path "$audit_parent" || refuse "the audit parent directory is not an absolute plain path"
audit_dir=$audit_parent/guarded-reboot
if [ -L "$audit_parent" ]; then refuse "$audit_parent is a symlink; it must be a real directory"; fi
if [ -e "$audit_parent" ]; then
  [ -d "$audit_parent" ] || refuse "$audit_parent exists and is not a directory"
  if ! find "$audit_parent" -maxdepth 0 -type d -perm -001 | grep -q .; then
    refuse "$audit_parent is not world-searchable ($(ls -ld "$audit_parent" | cut -c1-10)); the report cannot read the audit file below it. Fix its mode (chmod o+x) and retry; this script does not change an existing directory"
  fi
fi
echo "preflight: runtime user $user (not root), Linux, user lingering enabled, passwordless sudo works"
echo "preflight: release target $release (absent)"
echo "preflight: user unit directory $unit_dir"
if [ -d "$audit_parent" ]; then
  echo "preflight: audit directory $audit_dir (parent $audit_parent exists and is world-searchable; it is left as it is)"
else
  echo "preflight: audit directory $audit_dir (the parent will be created, mode 0755)"
fi
echo "preflight: mode $GR_MODE, window $WINDOW (spread ${SPREAD} min), busy units: ${BUSY_UNITS:-(none)}, peers: ${PEERS:-(none)}"
REMOTE

# Read-only checks: the alert path, the unlock assessment and the stock EEPROM service.
IFS= read -r -d '' REMOTE_CHECKS <<'REMOTE' || true
# Notify configuration, found the way scripts/lib/notify.sh finds it: environment first, else the
# Ratatoskr .env, else the fleet notify.env. A chat id and a destination (Ratatoskr URL or bot
# token) are needed. Config files are read with grep, never sourced.
cfg_get() {
  [ -f "$1" ] || return 0
  grep -E "^$2=" "$1" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '"\r' || true
}
ratatoskr_env=${RATATOSKR_ENV:-}
if [ -z "$ratatoskr_env" ]; then ratatoskr_env=$HOME/repos/ratatoskr/.env; fi
notify_env=${NOTIFY_ENV:-}
if [ -z "$notify_env" ]; then notify_env=$HOME/.config/grimnir/notify.env; fi
cfg=
if [ -f "$ratatoskr_env" ]; then cfg=$ratatoskr_env; elif [ -f "$notify_env" ]; then cfg=$notify_env; fi
n_url=${RATATOSKR_URL:-}
if [ -z "$n_url" ]; then n_url=$(cfg_get "$cfg" RATATOSKR_URL); fi
n_chat=${TELEGRAM_ALLOWED_USERS:-}
if [ -z "$n_chat" ]; then n_chat=$(cfg_get "$cfg" TELEGRAM_ALLOWED_USERS); fi
n_chat=${n_chat%%,*}
n_token=${TELEGRAM_BOT_TOKEN:-}
if [ -z "$n_token" ]; then n_token=$(cfg_get "$cfg" TELEGRAM_BOT_TOKEN); fi
notify_ok=1
if ! printf '%s' "$n_chat" | grep -Eq '^-?[0-9]+$'; then notify_ok=0; fi
if [ -z "$n_url" ] && [ -z "$n_token" ]; then notify_ok=0; fi
if [ "$notify_ok" = 1 ]; then
  echo "preflight: notify configuration present (alerts reach the operator)"
elif [ "$GR_MODE" = reboot ]; then
  refuse "reboot mode needs a working alert path, and no notify configuration was found (a numeric TELEGRAM_ALLOWED_USERS plus RATATOSKR_URL or TELEGRAM_BOT_TOKEN, see scripts/lib/notify.env.example); without it every reboot would be refused by the notify guard"
else
  echo "preflight: WARN: no notify configuration found; report mode runs without alerts, but reboot mode would be refused until one exists (see scripts/lib/notify.env.example)"
fi
# Unlock assessment (the same rule as the job's unlock guard): a crypttab entry needed at boot (not
# noauto) is unattended only if its key field is a key-file path or its options hold tpm2-device=
# without tpm2-pin=yes. fido2-device=, pkcs11-uri=, keyscript=, any *-pin=yes, fido2-with-*,
# headless=false, or an empty/none key without tpm2 would stop an unattended reboot at a prompt;
# the job's unlock guard defers and alerts for it.
crypttab=${BROKKR_CRYPTTAB:-}
if [ -z "$crypttab" ]; then crypttab=/etc/crypttab; fi
if [ ! -e "$crypttab" ]; then
  echo "preflight: unlock assessment: no $crypttab, no encrypted volume to unlock"
elif [ ! -r "$crypttab" ]; then
  echo "preflight: WARN: unlock assessment: $crypttab is not readable; the job's unlock guard will defer every reboot (failing closed)"
else
  names=$(awk '
    /^[[:space:]]*#/ { next }
    NF == 0 { next }
    {
      key = (NF >= 3) ? $3 : "none"
      opts = (NF >= 4) ? $4 : ""
      n = split(opts, o, ",")
      noauto = 0; interactive = 0; tpm2 = 0
      for (k = 1; k <= n; k++) {
        if (o[k] == "noauto") noauto = 1
        if (o[k] ~ /^(fido2-device|pkcs11-uri|keyscript)=/) interactive = 1
        if (o[k] ~ /-pin=yes$/) interactive = 1
        if (o[k] ~ /^fido2-with-/) interactive = 1
        if (o[k] == "headless=false") interactive = 1
        if (o[k] ~ /^tpm2-device=/) tpm2 = 1
      }
      if (noauto) next
      unattended = 0
      if (key ~ /^\//) unattended = 1
      if (tpm2) unattended = 1
      if (interactive) unattended = 0
      if (!unattended) print $1
    }' "$crypttab" | head -n 8 | tr '\n' ' ')
  if [ -z "$names" ]; then
    echo "preflight: unlock assessment: every volume in $crypttab unlocks unattended or is noauto"
  else
    echo "preflight: WARN: unlock assessment: crypttab entries needing an interactive passphrase at boot: $names"
    echo "preflight: WARN: the job will defer every reboot on this host and alert once per episode (an unattended reboot would hang at the prompt)"
  fi
fi
# The stock EEPROM boot service stages a bootloader update at every boot, outside any guard.
if command -v rpi-eeprom-update >/dev/null 2>&1; then
  eeprom_state=$(systemctl is-enabled rpi-eeprom-update.service 2>/dev/null || true)
  echo "preflight: rpi-eeprom-update present; the stock rpi-eeprom-update.service is ${eeprom_state:-unknown}"
  if [ "$eeprom_state" = enabled ]; then
    echo "preflight: --apply disables it (sudo -n systemctl disable rpi-eeprom-update.service): bootloader updates are then staged only inside an admitted guarded reboot"
  fi
fi
if [ "$RUN_MODE" = dry-run ]; then
  echo "dry-run: --apply would stage the payload, move it to the release target, create the audit directory,"
  echo "dry-run: back up and replace the user units, enable the three timers, disable the stock EEPROM service"
  echo "dry-run: (when present), and run the job once with 'check --report-only' and 'status'."
  echo "dry-run: It never starts the reboot service or reboots anything. Nothing was changed."
fi
REMOTE

# Apply tail: the payload tar arrives on stdin.
IFS= read -r -d '' REMOTE_APPLY <<'REMOTE' || true
# Steps that actually completed; the exit trap prints a rollback matching exactly these.
release_moved=0
replaced_units=""
enabled_timers=""
eeprom_disabled=0
audit_dir_done=0
job_ran=0
prior_states=""
stage=
tmp_backups=
has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }
cleanup_tmp_backups() {
  for tmp in $tmp_backups; do rm -f "$tmp"; done
  tmp_backups=
}
print_state() {
  if [ "$release_moved" = 0 ] && [ -z "$replaced_units" ] && [ "$eeprom_disabled" = 0 ]; then
    echo "State: no release, installed unit or system service was changed on this node."
  else
    echo "Rollback (run on the target as $user; only steps this run started are listed):"
  fi
  if [ -n "$enabled_timers" ]; then echo "  systemctl --user disable --now$enabled_timers"; fi
  for unit in $UNITS; do
    backup=$unit_dir/$unit.previous-$REVISION
    if has_word "$replaced_units" "$unit"; then
      if [ -e "$backup" ]; then echo "  mv -f $backup $unit_dir/$unit"; else echo "  rm -f $unit_dir/$unit"; fi
    elif [ -e "$backup" ]; then
      echo "  # $unit was left untouched; optional: rm -f $backup"
    fi
  done
  if [ -n "$replaced_units" ]; then
    echo "  systemctl --user daemon-reload"
    # Each timer that had a previous unit gets back exactly the enabled and active state it was
    # captured in before this run: enable --now only if it was both, never for one that was off.
    for unit in $TIMERS; do
      if has_word "$replaced_units" "$unit" && [ -e "$unit_dir/$unit.previous-$REVISION" ]; then
        p_en=unknown; p_ac=unknown
        set -f
        for entry in $(printf '%s' "$prior_states" | tr ' ' ',' | tr '\n' ' '); do
          case $entry in "$unit",*) rest=${entry#*,}; p_en=${rest%%,*}; p_ac=${rest#*,} ;; esac
        done
        set +f
        if [ "$p_en" = enabled ] && [ "$p_ac" = active ]; then
          echo "  systemctl --user enable --now $unit   # it was enabled and active before this run"
        elif [ "$p_en" = enabled ]; then
          echo "  systemctl --user enable $unit   # it was enabled but not active before this run: leave it stopped"
        elif [ "$p_ac" = active ]; then
          echo "  systemctl --user start $unit   # it was active but not enabled before this run"
        else
          echo "  # $unit was $p_en and $p_ac before this run: it stays disabled and stopped"
        fi
      fi
    done
  fi
  if [ "$eeprom_disabled" = 1 ]; then
    echo "  sudo systemctl enable rpi-eeprom-update.service   # restore the stock boot-time bootloader staging (it was enabled before this run)"
  fi
  if [ "$release_moved" = 1 ]; then echo "  rm -rf $release   # optional once the units no longer point at it"; fi
  if [ "$audit_dir_done" = 1 ]; then
    echo "  # $audit_dir and its audit file are evidence and stay in place; so does $state_dir/guarded-reboot.json"
  fi
  if [ "$job_ran" = 1 ]; then
    echo "  # the first run was check --report-only: it rebooted nothing and staged nothing"
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
bash -n "$stage/scripts/guarded-reboot.sh" || refuse "staged job has a syntax error under this node's bash"
bash -n "$stage/scripts/lib/notify.sh" || refuse "staged notify helper has a syntax error under this node's bash"
# The payload is received and validated; only now change the node. Templates are rendered in the stage.
for unit in $UNITS; do
  case $unit in
    *.service) template=$stage/systemd/user/$unit.in ;;
    *) template=$stage/systemd/user/$unit ;;
  esac
  sed -e "s|@REVISION@|$REVISION|g" -e "s|@MODE@|$GR_MODE|g" -e "s|@BUSY_UNITS@|$BUSY_UNITS|g" \
    -e "s|@PEERS@|$PEERS|g" -e "s|@MAX_LOAD@|$MAX_LOAD|g" -e "s|@TTY_IDLE_MIN@|$TTY_IDLE_MIN|g" \
    -e "s|@ALERT_AFTER@|$ALERT_AFTER|g" -e "s|@WINDOW@|$WINDOW|g" -e "s|@SPREAD@|$SPREAD|g" \
    "$template" >"$stage/$unit"
done
if grep -Eq '@[A-Z_]+@' "$stage"/brokkr-*.service "$stage"/brokkr-*.timer; then refuse "unit template has an unrendered placeholder"; fi
if [ -e "$release" ] || [ -L "$release" ]; then refuse "release already exists for revision $REVISION"; fi
# The audit directory: root-owned, mode 0755, created under umask 022 so a new parent is searchable too.
# An existing parent was verified by the preflight and is not touched. The sudo arguments are the
# constant paths; nothing in the environment changes them.
if [ -d "$audit_parent" ]; then
  (umask 022; sudo -n install -d -m 0755 /var/lib/brokkr/guarded-reboot </dev/null) || refuse "could not create the audit directory $audit_dir"
else
  (umask 022; sudo -n install -d -m 0755 /var/lib/brokkr /var/lib/brokkr/guarded-reboot </dev/null) || refuse "could not create the audit directory $audit_dir"
fi
# The enabled and active state of every timer exactly as it is before this run replaces anything, so
# the rollback restores each one as it was (never starting or enabling what was off).
prior_states=""
for timer in $TIMERS; do
  p_en=$(systemctl --user is-enabled "$timer" 2>/dev/null | head -n 1 | tr -d '\n' | tr -c 'A-Za-z-' '?' || true)
  p_ac=$(systemctl --user is-active "$timer" 2>/dev/null | head -n 1 | tr -d '\n' | tr -c 'A-Za-z-' '?' || true)
  prior_states="$prior_states$timer ${p_en:-unknown} ${p_ac:-unknown}
"
done
audit_dir_done=1
echo "audit directory $audit_dir is in place"
mkdir -p "$unit_dir"
# Back up ALL existing units to temporary names first, then rename them into place. Until every
# backup exists nothing has been replaced, so a failure here leaves the original units intact.
for unit in $UNITS; do
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
for unit in $UNITS; do
  replaced_units="$replaced_units $unit"
  install -m 644 "$release/$unit" "$unit_dir/$unit"
done
systemctl --user daemon-reload
enabled_timers=" $TIMERS"
# shellcheck disable=SC2086 # the timer list is a fixed set of plain names
systemctl --user enable --now $TIMERS
# The stock EEPROM boot service stages a bootloader update at every boot, outside any guard. From
# now on staging happens only inside an admitted guarded reboot.
if command -v rpi-eeprom-update >/dev/null 2>&1; then
  eeprom_prior=$(systemctl is-enabled rpi-eeprom-update.service 2>/dev/null || true)
  if [ "$eeprom_prior" = enabled ]; then
    eeprom_disabled=1
    sudo -n systemctl disable rpi-eeprom-update.service </dev/null
    echo "disabled the stock rpi-eeprom-update.service (it was enabled): bootloader updates are now staged only inside an admitted guarded reboot"
  else
    echo "the stock rpi-eeprom-update.service is ${eeprom_prior:-unknown}: nothing to disable"
  fi
fi
# One run of the job in report mode. The reboot service is never started here, and report mode
# cannot reboot, stage or cancel anything.
job=$release/scripts/guarded-reboot.sh
job_path=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
# BROKKR_DEPLOY_PATH_PREFIX is a test seam: stub commands put in front of the unit's PATH.
if [ -n "${BROKKR_DEPLOY_PATH_PREFIX:-}" ]; then job_path=$BROKKR_DEPLOY_PATH_PREFIX:$job_path; fi
job_run() {
  env PATH="$job_path" BROKKR_GUARDED_REBOOT_BUSY_UNITS="$BUSY_UNITS" BROKKR_GUARDED_REBOOT_PEERS="$PEERS" \
    BROKKR_GUARDED_REBOOT_MAX_LOAD="$MAX_LOAD" BROKKR_GUARDED_REBOOT_TTY_IDLE_MIN="$TTY_IDLE_MIN" \
    BROKKR_GUARDED_REBOOT_ALERT_AFTER="$ALERT_AFTER" "$job" "$@" </dev/null
}
job_ran=1
echo "== first run: check --report-only"
if job_run check --report-only; then check_rc=0; else check_rc=$?; fi
echo "== status"
if job_run status; then status_rc=0; else status_rc=$?; fi
audit_file=$audit_dir/audit.jsonl
audit_ok=1
if [ -e "$audit_file" ]; then
  echo "audit file: $(ls -l "$audit_file")"
  if ! find "$audit_file" -maxdepth 0 -type f -perm -004 | grep -q .; then audit_ok=0; fi
else
  echo "audit file: $audit_file not created yet (the first audit line is written when there is something to record)"
fi
if [ "$check_rc" -ne 0 ] || [ "$status_rc" -ne 0 ]; then
  echo "FAILED: the first run of the job failed (check exit $check_rc, status exit $status_rc); the release, units and timers stay installed until rolled back" >&2
  exit 3
fi
if [ "$audit_ok" != 1 ]; then
  echo "FAILED: the audit file is not world-readable, so the daily report could not read it; the release stays installed until rolled back" >&2
  exit 3
fi
echo "OK: guarded reboot installed in $GR_MODE mode and the first run (check --report-only) succeeded"
if [ "$GR_MODE" = report ]; then
  echo "note: report mode only logs and alerts what it would do; after a week of review redeploy with BROKKR_GUARDED_REBOOT_MODE=reboot"
fi
REMOTE

run_remote() { # run-mode script-body; stdin is forwarded to the remote script
  local RUN_MODE=$1 prelude body encoded
  prelude="REVISION='$REVISION'
GR_MODE='$GR_MODE'
WINDOW='$WINDOW'
SPREAD='$SPREAD'
BUSY_UNITS='$BUSY_UNITS'
PEERS='$PEERS'
MAX_LOAD='$MAX_LOAD'
TTY_IDLE_MIN='$TTY_IDLE_MIN'
ALERT_AFTER='$ALERT_AFTER'
EXPECTED_FILES='${PAYLOAD_FILES[*]}'
EXPECTED_COUNT='${#PAYLOAD_FILES[@]}'
RUN_MODE='$RUN_MODE'
"
  body="$prelude$REMOTE_COMMON
$2
"
  encoded="$(printf '%s' "$body" | base64 | tr -d '\n')"
  ssh -o BatchMode=yes "$TARGET" "sh -c \"\$(printf %s '$encoded' | base64 -d)\""
}

if (( APPLY )); then
  echo "==> Preflight on $TARGET (revision ${REVISION}, mode ${GR_MODE})"
  run_remote apply "$REMOTE_CHECKS" </dev/null || {
    echo "brokkr guarded-reboot deploy: preflight failed; nothing was changed" >&2
    exit 1
  }
  echo "==> Installing guarded-reboot release ${REVISION} on $TARGET"
  if ! ( cd "$DEPLOY_PAYLOAD_ROOT" && COPYFILE_DISABLE=1 tar -cf - "${PAYLOAD_FILES[@]}" ) | run_remote apply "$REMOTE_APPLY"; then
    echo "brokkr guarded-reboot deploy: remote install failed (see output above; any rollback recipe applies)" >&2
    exit 1
  fi
  echo "==> Done."
else
  echo "==> DRY-RUN guarded-reboot preflight on $TARGET (revision ${REVISION}, mode ${GR_MODE})"
  run_remote dry-run "$REMOTE_CHECKS" </dev/null || {
    echo "brokkr guarded-reboot deploy: preflight failed; nothing was changed" >&2
    exit 1
  }
  echo "==> DRY-RUN complete. Re-run with --apply to install."
fi
