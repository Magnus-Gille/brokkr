#!/usr/bin/env bash
# Housekeeping for an agent account made by provision-agent-account.sh; installed on the host as
# /usr/local/libexec/brokkr-agent-housekeeping and run by its timers.
#
#   agent-account-housekeeping.sh sweep-tmp --user NAME --dir DIR --max-age-minutes N
#       Runs AS the agent account (never root). Deletes the account's regular files and symlinks
#       under DIR whose mtime, ctime and atime are all older than N minutes, then its empty
#       directories older than N minutes. Directories owned by anyone else are not entered.
#       This frees tmpfs (/tmp) pages that stay charged to the account's slice after the
#       process that wrote them has exited.
#
#   agent-account-housekeeping.sh reap-closing --user NAME --uid UID --grace-seconds N --state-dir DIR
#       Runs as root. Ends logind sessions of the account that have been in State=closing (the
#       login is gone but processes are left) for at least N seconds, as seen by consecutive
#       runs. DIR holds one file per closing session with the epoch it was first seen closing.
#
# Test seam: BROKKR_HOUSEKEEPING_NOW replaces the current epoch (seconds).
set -Eeuo pipefail

die() { echo "brokkr agent housekeeping: $*" >&2; exit 64; }
fatal() { echo "brokkr agent housekeeping: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die 'usage: agent-account-housekeeping.sh sweep-tmp|reap-closing [options]'
MODE=$1
shift
USER_NAME='' DIR='' MAX_AGE='' UID_NUM='' GRACE='' STATE_DIR=''
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || die "$1 requires a value"
  case $1 in
    --user) USER_NAME=$2 ;;
    --dir) DIR=$2 ;;
    --max-age-minutes) MAX_AGE=$2 ;;
    --uid) UID_NUM=$2 ;;
    --grace-seconds) GRACE=$2 ;;
    --state-dir) STATE_DIR=$2 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift 2
done
[[ $USER_NAME =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die '--user must match ^[a-z][a-z0-9-]{1,30}$'

now() { if [[ -n ${BROKKR_HOUSEKEEPING_NOW:-} ]]; then echo "$BROKKR_HOUSEKEEPING_NOW"; else date +%s; fi; }

# Races with the account's own processes (a file removed or a directory filled in between) are
# expected; every other find, rm or rmdir message is a real failure.
real_errors() { grep -vE ': (No such file or directory|Directory not empty)$' || true; }

# sweep_pass EXPRESSION...: runs find over DIR, outside other users' directories (-prune; -delete
# is avoided because it implies -depth, under which -prune has no effect). Prints the number of
# printed matches; reports any message that real_errors keeps on stderr and returns 1.
sweep_pass() {
  local errs
  exec 3>&1
  errs=$( { find "$DIR" -xdev -mindepth 1 \( -type d ! -user "$USER_NAME" -prune \) -o "$@" |
    wc -l | tr -d ' ' >&3; } 2>&1 | real_errors) || true
  [[ -n $errs ]] || return 0
  echo "brokkr agent housekeeping: sweep of $DIR: $errs" >&2
  return 1
}

sweep_tmp() {
  local files dirs a=$MAX_AGE u=$USER_NAME failed=0
  [[ "$(id -u)" -ne 0 ]] || die 'sweep-tmp refuses to run as root; run it as the agent account'
  [[ "$(id -un)" == "$u" ]] || die "sweep-tmp must run as $u, not $(id -un)"
  [[ $DIR == /* && -d $DIR && ! -L $DIR ]] || die '--dir must be an absolute, non-symlink directory'
  [[ $a =~ ^(0|[1-9][0-9]{0,5})$ ]] || die '--max-age-minutes must be an integer from 0 to 999999'
  # Aged directories of the account that it cannot enter or empty (read-only build or module
  # trees) get u+rwx first; "-exec ... ;" runs before find descends into them. Then regular files
  # and symlinks; sockets and FIFOs (tmux, ssh-agent) are kept.
  files=$(sweep_pass \( -user "$u" -type d ! -perm -700 -mmin +"$a" -cmin +"$a" -exec chmod u+rwx -- {} \; -false \) -o \
    \( -user "$u" \( -type f -o -type l \) -mmin +"$a" -cmin +"$a" -amin +"$a" -print -exec rm -f -- {} + \)) || failed=1
  # Parents are visited before their children, so a nested tree empties over several runs.
  dirs=$(sweep_pass \( -user "$u" -type d -empty -mmin +"$a" -cmin +"$a" -print -exec rmdir -- {} + \)) || failed=1
  echo "sweep-tmp: removed ${files:-0} files and ${dirs:-0} empty directories of $u under $DIR untouched for over $a minutes"
  [[ $failed -eq 0 ]] || exit 1
}

reap_closing() {
  local sessions id props state suid first t elapsed f out failures=()
  [[ $UID_NUM =~ ^[0-9]+$ ]] || die '--uid must be numeric'
  [[ $GRACE =~ ^[1-9][0-9]{0,7}$ ]] || die '--grace-seconds must be an integer from 1 to 99999999'
  [[ $STATE_DIR == /* && -d $STATE_DIR && ! -L $STATE_DIR ]] ||
    die '--state-dir must be an absolute, non-symlink directory'
  t=$(now)
  [[ $t =~ ^[0-9]+$ ]] || fatal "cannot read the current time ('$t')"
  if ! sessions=$(loginctl show-user "$USER_NAME" -p Sessions --value 2>&1); then
    case $sessions in
      *'not logged in'*) sessions= ;;
      *) fatal "cannot list the sessions of $USER_NAME: $sessions" ;;
    esac
  fi
  local seen=' '
  for id in $sessions; do
    [[ $id =~ ^[A-Za-z0-9]{1,32}$ ]] || fatal "logind returned an unexpected session id: $id"
    seen+="$id "
    props=$(loginctl show-session "$id" -p User -p State 2>/dev/null) || continue # ended meanwhile
    suid=$(sed -n 's/^User=//p' <<<"$props")
    state=$(sed -n 's/^State=//p' <<<"$props")
    f=$STATE_DIR/$id
    if [[ $suid != "$UID_NUM" ]]; then
      echo "reap-closing: session $id belongs to uid '$suid', not $UID_NUM; skipped"
      continue
    fi
    if [[ $state != closing ]]; then
      rm -f -- "$f"
      continue
    fi
    if [[ -f $f && ! -L $f ]]; then
      first=$(<"$f")
      [[ $first =~ ^[0-9]+$ && $first -le $t ]] || first=$t
    else
      first=$t
      echo "$first" >"$f"
    fi
    elapsed=$((t - first))
    if [[ $elapsed -lt $GRACE ]]; then
      echo "reap-closing: session $id of $USER_NAME closing for ${elapsed}s (grace ${GRACE}s); kept"
      continue
    fi
    if out=$(loginctl terminate-session "$id" 2>&1); then
      echo "reap-closing: terminated session $id of $USER_NAME, closing for at least ${elapsed}s"
      rm -f -- "$f"
    else
      failures+=("$id: $out")
    fi
  done
  for f in "$STATE_DIR"/*; do
    [[ -e $f || -L $f ]] || continue
    [[ $seen == *" ${f##*/} "* ]] || rm -f -- "$f"
  done
  if [[ ${#failures[@]} -gt 0 ]]; then
    printf 'brokkr agent housekeeping: could not terminate session %s\n' "${failures[@]}" >&2
    exit 1
  fi
}

case $MODE in
  sweep-tmp) [[ -n $DIR && -n $MAX_AGE ]] || die 'sweep-tmp needs --dir and --max-age-minutes'; sweep_tmp ;;
  reap-closing)
    [[ -n $UID_NUM && -n $GRACE && -n $STATE_DIR ]] ||
      die 'reap-closing needs --uid, --grace-seconds and --state-dir'
    reap_closing ;;
  *) die "unknown mode: $MODE" ;;
esac
