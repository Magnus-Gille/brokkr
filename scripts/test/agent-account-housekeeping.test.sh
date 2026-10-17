#!/usr/bin/env bash
# Hermetic coverage for scripts/agent-account-housekeeping.sh. loginctl and id are PATH shims;
# the reaper reads a fake cgroup and /proc tree; the tmp sweep runs the real find against a
# private directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/.." && pwd)/agent-account-housekeeping.sh"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
STUBS="$TMP/bin"
STATE="$TMP/state"
CALLS="$TMP/calls"
mkdir -p "$STUBS" "$STATE"

stub() { cat >"$STUBS/$1"; chmod +x "$STUBS/$1"; }
# $STUB_STATE/sessions: one "id uid state" line per logind session of the account.
stub loginctl <<'EOF'
#!/usr/bin/env bash
printf 'loginctl %s\n' "$*" >>"$STUB_CALLS"
case $1 in
  show-user)
    case ${STUB_SHOW_USER:-ok} in
      notloggedin) echo "Failed to get user: User ID 1001 is not logged in or lingering" >&2; exit 1 ;;
      error) echo 'Failed to get user: Access denied' >&2; exit 1 ;;
      badid) echo '12 ../x'; exit 0 ;;
    esac
    awk '{print $1}' "$STUB_STATE/sessions" | tr '\n' ' '; echo ;;
  show-session)
    line=$(grep -m1 "^$2 " "$STUB_STATE/sessions") || { echo "Failed to get session: No session '$2' known" >&2; exit 1; }
    read -r _ uid state <<<"$line"
    printf 'User=%s\nState=%s\n' "$uid" "$state" ;;
  terminate-session) # STUB_TERMINATE_NOOP=1: the session ignores SIGTERM and stays closing
    [[ ${STUB_TERMINATE_FAIL:-} != "$2" ]] || { echo "Failed to terminate session: Access denied" >&2; exit 1; }
    [[ ${STUB_TERMINATE_NOOP:-} == 1 ]] && exit 0
    grep -v "^$2 " "$STUB_STATE/sessions" >"$STUB_STATE/sessions.new" || true
    mv "$STUB_STATE/sessions.new" "$STUB_STATE/sessions" ;;
  kill-session)
    [[ $3 == --signal=SIGKILL ]] || { echo "loginctl stub: unexpected: $*" >&2; exit 99; }
    [[ ${STUB_KILL_FAIL:-} != "$2" ]] || { echo "Failed to kill session: Access denied" >&2; exit 1; }
    grep -v "^$2 " "$STUB_STATE/sessions" >"$STUB_STATE/sessions.new" || true
    mv "$STUB_STATE/sessions.new" "$STUB_STATE/sessions" ;;
  *) exit 99 ;;
esac
EOF

PASS=0 FAIL=0 OUT='' RC=0
ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1" >&2; printf '%s\n' "$OUT" | head -12 | sed 's/^/    | /' >&2; }
check() { local desc=$1; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
rc_is() { [[ $RC -eq $1 ]]; }
out_has() { grep -qF -- "$1" <<<"$OUT"; }
has_call() { grep -qxF -- "$1" "$CALLS"; }
has_call_re() { grep -qE -- "$1" "$CALLS"; }
no_call() { ! grep -qF -- "$1" "$CALLS"; }
absent() { [[ ! -e $1 && ! -L $1 ]]; }
present() { [[ -e $1 || -L $1 ]]; }

CG="$TMP/cgroup"
PROCFS="$TMP/proc"
run() { # NOW=<epoch> run args...
  : >"$CALLS"
  OUT=$(PATH="$STUBS:$PATH" STUB_CALLS="$CALLS" STUB_STATE="$STATE" \
    BROKKR_HOUSEKEEPING_CGROUP_ROOT="$CG" BROKKR_HOUSEKEEPING_PROC="$PROCFS" \
    BROKKR_HOUSEKEEPING_NOW="${NOW:-1000000}" bash "$SCRIPT" "$@" 2>&1)
  RC=$?
}
mkscope() { # session-id pid...: the session's scope and the processes in it
  local dir="$CG/user.slice/user-1001.slice/session-$1.scope"
  mkdir -p "$dir"
  shift
  printf '%s\n' "$@" | grep . >"$dir/cgroup.procs" || : >"$dir/cgroup.procs"
}
# mkproc pid exe [socket-path inode]: a process; with a socket, a listening unix socket in
# its network namespace, as /proc/<pid>/net/unix lists it.
mkproc() {
  local d="$PROCFS/$1"
  mkdir -p "$d/fd" "$d/net"
  ln -sfn "$2" "$d/exe"
  printf 'Num       RefCount Protocol Flags    Type St Inode Path\n' >"$d/net/unix"
  if [[ -n ${3:-} ]]; then
    ln -sfn "socket:[$4]" "$d/fd/5"
    printf '0000000000000000: 00000002 00000000 00010000 0001 01 %s %s\n' "$4" "$3" >>"$d/net/unix"
  fi
}
mksocket() { python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
for id in 10 11 12 13 20 21 30 40 41; do mkscope "$id"; done

echo agent-account-housekeeping.test.sh

# 1. reap-closing --------------------------------------------------------------------------------
SD="$TMP/reap-state"
mkdir -p "$SD"
REAP=(reap-closing --user agent --uid 1001 --grace-seconds 3600 --state-dir "$SD")
printf '%s\n' '10 1001 active' '11 1001 closing' '12 1001 online' '13 1002 closing' >"$STATE/sessions"
NOW=1000000 run "${REAP[@]}"
check 'a first run succeeds' rc_is 0
check 'a first run records when a closing session was first seen' test "$(cat "$SD/11" 2>/dev/null)" = 1000000
check 'a first run terminates nothing' no_call 'terminate-session'
check 'a first run reports the kept session' out_has 'session 11 of agent closing for 0s (grace 3600s); kept'
check 'an active session gets no record' absent "$SD/10"
check 'an online session gets no record' absent "$SD/12"
check 'a session of another uid is skipped' out_has "session 13 belongs to uid '1002', not 1001; skipped"
check 'a session of another uid gets no record' absent "$SD/13"
NOW=1003599 run "${REAP[@]}"
check 'a session inside the grace period is kept' no_call 'terminate-session'
check 'the first-seen time is kept across runs' test "$(cat "$SD/11")" = 1000000
NOW=1003600 run "${REAP[@]}"
check 'a run at the end of the grace period succeeds' rc_is 0
check 'a session closing for the whole grace period is terminated' has_call 'loginctl terminate-session 11'
check 'only that session is terminated' test "$(grep -c terminate-session "$CALLS")" = 1
check 'the termination is reported' out_has 'terminated session 11 of agent, closing for at least 3600s'
check 'a terminated session records the terminate' grep -qx 'terminated 1003600' "$SD/11"
NOW=1003700 run "${REAP[@]}"
check 'the record of a terminated session that ended is removed' absent "$SD/11"
check 'an active session is never terminated' no_call 'terminate-session 10'
check 'a session of another uid is never terminated' no_call 'terminate-session 13'

# a session that becomes active again (or ends) loses its record
printf '%s\n' '20 1001 closing' '21 1001 closing' >"$STATE/sessions"
NOW=2000000 run "${REAP[@]}"
printf '%s\n' '20 1001 active' >"$STATE/sessions"
NOW=2000100 run "${REAP[@]}"
check 'a session that is active again loses its record' absent "$SD/20"
check 'a session that ended loses its record' absent "$SD/21"
echo 1 >"$SD/99"
NOW=2000200 run "${REAP[@]}"
check 'stale records of unknown sessions are removed' absent "$SD/99"

# a record from the future or garbage restarts the grace period, and is rewritten so the
# session is still ended one grace period later
printf '%s\n' '30 1001 closing' >"$STATE/sessions"
echo 9999999 >"$SD/30"
NOW=3000000 run "${REAP[@]}"
check 'a record from the future does not terminate' no_call 'terminate-session'
check 'a record from the future is rewritten with the current time' test "$(cat "$SD/30")" = 3000000
NOW=3003600 run "${REAP[@]}"
check 'a session with a future record is terminated one grace period later' has_call 'loginctl terminate-session 30'
printf '%s\n' '30 1001 closing' >"$STATE/sessions"
echo garbage >"$SD/30"
NOW=3100000 run "${REAP[@]}"
check 'a garbage record does not terminate' no_call 'terminate-session'
check 'a garbage record is rewritten with the current time' test "$(cat "$SD/30")" = 3100000
NOW=3103600 run "${REAP[@]}"
check 'a session with a garbage record is terminated one grace period later' has_call 'loginctl terminate-session 30'

# failures
printf '%s\n' '40 1001 closing' '41 1001 closing' >"$STATE/sessions"
echo 1 >"$SD/40"
echo 1 >"$SD/41"
STUB_TERMINATE_FAIL=40 NOW=4000000 run "${REAP[@]}"
check 'a failing terminate exits non-zero' rc_is 1
check 'a failing terminate is named' out_has 'could not terminate session 40: Failed to terminate session: Access denied'
check 'a failing terminate does not stop the next one' has_call 'loginctl terminate-session 41'
check 'a failing terminate keeps its record' present "$SD/40"
STUB_SHOW_USER=notloggedin run "${REAP[@]}"
check 'an account without sessions is not an error' rc_is 0
STUB_SHOW_USER=error run "${REAP[@]}"
check 'an unreadable session list exits non-zero' rc_is 1
check 'an unreadable session list is named' out_has 'cannot list the sessions of agent: Failed to get user: Access denied'
STUB_SHOW_USER=badid run "${REAP[@]}"
check 'an unexpected session id is refused' rc_is 1
check 'an unexpected session id is never terminated' no_call 'terminate-session'
check 'an unexpected session id never becomes a path' absent "$TMP/x"

# a session that ignores the terminate is killed on the next run instead of re-armed
rm -f "$SD"/*
printf '%s\n' '42 1001 closing' >"$STATE/sessions"
mkscope 42
echo 1 >"$SD/42"
STUB_TERMINATE_NOOP=1 NOW=4100000 run "${REAP[@]}"
check 'a stubborn session is first terminated' has_call 'loginctl terminate-session 42'
check 'a stubborn session is not killed on the same run' no_call 'kill-session'
check 'a terminated session keeps a record of the terminate' grep -qx 'terminated 4100000' "$SD/42"
STUB_TERMINATE_NOOP=1 NOW=4100600 run "${REAP[@]}"
check 'a session still closing after a terminate is killed with SIGKILL' has_call 'loginctl kill-session 42 --signal=SIGKILL'
check 'a session still closing after a terminate is not terminated again' no_call 'terminate-session 42'
check 'the kill is reported' out_has 'killed session 42 of agent with SIGKILL: still closing 600s after terminate-session'
check 'a killed session that ended loses its record' absent "$SD/42"
printf '%s\n' '43 1001 closing' >"$STATE/sessions"
mkscope 43
printf '1\nterminated 4200000\n' >"$SD/43"
STUB_KILL_FAIL=43 NOW=4200600 run "${REAP[@]}"
check 'a failing kill exits non-zero' rc_is 1
check 'a failing kill is named' out_has 'could not kill session 43: Failed to kill session: Access denied'
check 'a failing kill keeps its record for the next run' grep -qx 'terminated 4200000' "$SD/43"

# a tmux server with an attached client keeps its session; a detached one does not
rm -f "$SD"/*
SOCK="$TMP/tmux-sock"
mksocket "$SOCK"
mkproc 500 /usr/bin/tmux "$SOCK" 7700
mkproc 501 /usr/bin/bash
printf '%s\n' '50 1001 closing' >"$STATE/sessions"
mkscope 50 501 500
echo 1 >"$SD/50"
chmod u+x "$SOCK"
NOW=5000000 run "${REAP[@]}"
check 'an attached tmux server keeps a closing session past its grace' no_call 'terminate-session'
check 'the attached tmux server is reported' out_has "session 50 of agent holds tmux server 500 with an attached client ($SOCK); kept"
check 'an attached tmux server keeps the original first-seen time' test "$(head -1 "$SD/50")" = 1
chmod u-x "$SOCK"
NOW=5000600 run "${REAP[@]}"
check 'a detached tmux server past the grace is ended' has_call 'loginctl terminate-session 50'
rm -f "$SOCK"
printf 'not a socket\n' >"$SOCK"
chmod 700 "$SOCK"
printf '%s\n' '51 1001 closing' >"$STATE/sessions"
mkscope 51 500
echo 1 >"$SD/51"
NOW=5000600 run "${REAP[@]}"
check 'an executable non-socket at the tmux path does not count as attached' has_call 'loginctl terminate-session 51'
rm -f "$SOCK"
ln -s /usr/bin/env "$SOCK"
printf '%s\n' '52 1001 closing' >"$STATE/sessions"
mkscope 52 500
echo 1 >"$SD/52"
NOW=5000600 run "${REAP[@]}"
check 'a symlink at the tmux path does not count as attached' has_call 'loginctl terminate-session 52'
rm -f "$SOCK"
mkproc 502 /usr/bin/python3 "$TMP/py-sock" 7702
mksocket "$TMP/py-sock"
chmod u+x "$TMP/py-sock"
printf '%s\n' '53 1001 closing' >"$STATE/sessions"
mkscope 53 502
echo 1 >"$SD/53"
NOW=5000600 run "${REAP[@]}"
check 'an attached-looking socket of another program does not keep the session' has_call 'loginctl terminate-session 53'
# a session whose processes cannot be inspected is kept, never reaped blind
printf '%s\n' '54 1001 closing' >"$STATE/sessions"
echo 1 >"$SD/54"
NOW=5000600 run "${REAP[@]}"
check 'an uninspectable closing session is kept' no_call 'terminate-session'
check 'an uninspectable closing session is reported' out_has 'cannot read the processes of session 54'

# argument validation
run reap-closing --user agent --uid 1001 --grace-seconds 863913600 --state-dir "$SD"
check 'the longest grace the provisioner renders (9999d) is accepted' rc_is 0
run reap-closing --user agent --uid 1001 --grace-seconds 1000000000 --state-dir "$SD"
check 'a grace beyond the limit is refused' rc_is 64
run reap-closing --user agent --uid 1001 --grace-seconds 0 --state-dir "$SD"
check 'a zero grace period is refused' rc_is 64
run reap-closing --user agent --uid x --grace-seconds 60 --state-dir "$SD"
check 'a non-numeric uid is refused' rc_is 64
ln -s "$SD" "$TMP/reap-link"
run reap-closing --user agent --uid 1001 --grace-seconds 60 --state-dir "$TMP/reap-link"
check 'a symlinked state directory is refused' rc_is 64
run reap-closing --user 'Agent;x' --uid 1001 --grace-seconds 60 --state-dir "$SD"
check 'an invalid user name is refused' rc_is 64
run frobnicate --user agent
check 'an unknown mode is refused' rc_is 64

# 2. sweep-tmp -----------------------------------------------------------------------------------
ME=$(id -un)
if [[ $ME =~ ^[a-z][a-z0-9-]{1,30}$ && "$(id -u)" -ne 0 ]]; then
  D="$TMP/tmpfs"
  mkdir -p "$D/sub" "$D/emptydir" "$D/keepdir"
  echo x >"$D/old-file"
  echo x >"$D/sub/inner"
  ln -s /nonexistent "$D/old-link"
  mkfifo "$D/fifo"
  : >"$D/keepdir/.keep"
  sleep 1
  run sweep-tmp --user "$ME" --dir "$D" --max-age-minutes 0
  check 'a sweep succeeds' rc_is 0
  check 'an aged regular file is removed' absent "$D/old-file"
  check 'an aged nested file is removed' absent "$D/sub/inner"
  check 'an aged symlink is removed (not its target)' absent "$D/old-link"
  check 'a FIFO is kept' test -p "$D/fifo"
  check 'an aged empty directory is removed' absent "$D/emptydir"
  check 'the swept directory itself is kept' test -d "$D"
  check 'the sweep reports what it removed' out_has 'sweep-tmp: removed 4 files and'
  echo fresh >"$D/fresh"
  run sweep-tmp --user "$ME" --dir "$D" --max-age-minutes 60
  check 'a file younger than the age is kept' test -f "$D/fresh"
  mkdir -p "$D/locked"
  echo x >"$D/locked/file"
  chmod 000 "$D/locked"
  sleep 1
  run sweep-tmp --user "$ME" --dir "$D" --max-age-minutes 0
  check 'an aged unreadable directory of the account is opened and swept' rc_is 0
  check 'the files inside it are removed' absent "$D/locked/file"
  chmod 755 "$D/locked" 2>/dev/null || true
  ln -s "$D" "$TMP/tmp-link"
  run sweep-tmp --user "$ME" --dir "$TMP/tmp-link" --max-age-minutes 0
  check 'a symlinked sweep directory is refused' rc_is 64
  run sweep-tmp --user "$ME" --dir relative --max-age-minutes 0
  check 'a relative sweep directory is refused' rc_is 64
  run sweep-tmp --user "$ME" --dir "$D" --max-age-minutes 1d
  check 'a non-numeric age is refused' rc_is 64
else
  echo '  SKIP sweep-tmp against a real directory (needs a non-root user with a portable name)'
fi
run sweep-tmp --user someone-else --dir "$TMP" --max-age-minutes 0
check 'a sweep as a different user is refused' rc_is 64
check 'the user mismatch is named' out_has 'sweep-tmp must run as someone-else'

# root is refused before anything is searched
stub id <<'EOF'
#!/usr/bin/env bash
case $1 in -u) echo 0 ;; -un) echo root ;; esac
EOF
stub find <<'EOF'
#!/usr/bin/env bash
printf 'find %s\n' "$*" >>"$STUB_CALLS"
EOF
run sweep-tmp --user agent --dir "$TMP" --max-age-minutes 0
check 'a sweep as root is refused' rc_is 64
check 'a sweep as root names the reason' out_has 'refuses to run as root'
check 'a sweep as root searches nothing' no_call 'find '

# a failing pass is reported, but the other pass still runs
stub id <<'EOF'
#!/usr/bin/env bash
case $1 in -u) echo 1001 ;; -un) echo agent ;; esac
EOF
stub find <<'EOF'
#!/usr/bin/env bash
printf 'find %s\n' "$*" >>"$STUB_CALLS"
[[ " $* " != *' rm -f '* ]] || echo 'find: /tmp/x: Permission denied' >&2
exit 1
EOF
run sweep-tmp --user agent --dir "$TMP" --max-age-minutes 0
check 'a real error fails the sweep' rc_is 1
check 'the real error is named' out_has 'find: /tmp/x: Permission denied'
check 'the empty-directory pass runs after a failing file pass' has_call_re 'rmdir'
stub find <<'EOF'
#!/usr/bin/env bash
printf 'find %s\n' "$*" >>"$STUB_CALLS"
echo 'find: /tmp/gone: No such file or directory' >&2
echo 'rmdir: /tmp/busy: Directory not empty' >&2
exit 1
EOF
run sweep-tmp --user agent --dir "$TMP" --max-age-minutes 0
check 'races with the account processes are not errors' rc_is 0
stub find <<'EOF'
#!/usr/bin/env bash
printf 'find %s\n' "$*" >>"$STUB_CALLS"
exit 2
EOF
run sweep-tmp --user agent --dir "$TMP" --max-age-minutes 0
check 'a find that fails without a message fails the sweep' rc_is 1
check 'a silent find failure is named with its status' out_has 'find exited with status 2'

# the find expression: other users' directories are pruned and all three times must be old
stub find <<'EOF'
#!/usr/bin/env bash
printf 'find %s\n' "$*" >>"$STUB_CALLS"
EOF
stub id <<'EOF'
#!/usr/bin/env bash
case $1 in -u) echo 1001 ;; -un) echo agent ;; esac
EOF
run sweep-tmp --user agent --dir "$TMP" --max-age-minutes 1440
check 'a stubbed sweep succeeds' rc_is 0
run sweep-tmp --user agent --dir "$TMP" --max-age-minutes 14398560
check 'the longest age the provisioner renders (9999d) is accepted' rc_is 0
run sweep-tmp --user agent --dir "$TMP" --max-age-minutes 100000000
check 'an age beyond the limit is refused' rc_is 64
run sweep-tmp --user agent --dir "$TMP" --max-age-minutes 1440
check 'files are matched by owner, type and all three times, outside other users directories' \
  has_call "find $TMP -xdev -mindepth 1 ( -type d ! -user agent -prune ) -o ( -user agent -type d ! -perm -700 -mmin +1440 -cmin +1440 -exec chmod u+rwx -- {} ; -false ) -o ( -user agent ( -type f -o -type l ) -mmin +1440 -cmin +1440 -amin +1440 -print -exec rm -f -- {} + )"
check 'empty directories are matched by owner and age' \
  has_call "find $TMP -xdev -mindepth 1 ( -type d ! -user agent -prune ) -o ( -user agent -type d -empty -mmin +1440 -cmin +1440 -print -exec rmdir -- {} + )"
check 'the sweep never uses -delete (it would disable -prune)' no_call ' -delete'

if (( FAIL )); then
  printf '%s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf '%s passed\n' "$PASS"
