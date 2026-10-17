#!/usr/bin/env bash
# Hermetic coverage for scripts/agent-account-housekeeping.sh. loginctl and id are PATH shims;
# the tmp sweep runs the real find against a private directory.
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
  terminate-session)
    [[ ${STUB_TERMINATE_FAIL:-} != "$2" ]] || { echo "Failed to terminate session: Access denied" >&2; exit 1; }
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

run() { # NOW=<epoch> run args...
  : >"$CALLS"
  OUT=$(PATH="$STUBS:$PATH" STUB_CALLS="$CALLS" STUB_STATE="$STATE" \
    BROKKR_HOUSEKEEPING_NOW="${NOW:-1000000}" bash "$SCRIPT" "$@" 2>&1)
  RC=$?
}

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
check 'a terminated session loses its record' absent "$SD/11"
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

# a record from the future or garbage restarts the grace period instead of terminating
printf '%s\n' '30 1001 closing' >"$STATE/sessions"
echo 9999999 >"$SD/30"
NOW=3000000 run "${REAP[@]}"
check 'a record from the future does not terminate' no_call 'terminate-session'
echo garbage >"$SD/30"
NOW=3000000 run "${REAP[@]}"
check 'a garbage record does not terminate' no_call 'terminate-session'

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

# argument validation
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
