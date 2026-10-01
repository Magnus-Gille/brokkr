#!/usr/bin/env bash
# Brokkr · hermetic contract tests for samba/deploy-remote.sh (brokkr#131).
#
# The state argument is deliberately omitted from the new retired cases so the
# test proves the production default. The seven legacy cases pass active
# explicitly while that compatibility mode remains an opt-in.
set -uo pipefail
# shellcheck disable=SC2034 # run's RC and OUT are consumed through eval checks.
# shellcheck disable=SC2016 # Assertions are evaluated by chk, not at declaration.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="$HERE/../../samba/deploy-remote.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-samba-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"
mkdir -p "$MOCKBIN"
RELOAD_LOG="$WORK/reload.log"

# testparm emits an effective configuration assembled from active includes.
# The sentinel makes an unchanged fixture report an invalid current effective
# state for the final no-op validation case.
cat >"$MOCKBIN/testparm" <<'MOCK'
#!/usr/bin/env bash
smb="${MOCK_SMB:?MOCK_SMB is required}"
if grep -q '#FORCE_TESTPARM_FAIL' "$smb" 2>/dev/null; then
  echo "Error loading services" >&2
  exit 1
fi
if grep -q '#FORCE_EFFECTIVE_INVALID' "$smb" 2>/dev/null; then
  printf '[TimeMachine]\n   path = /srv/timemachine\n   available = yes\n   fruit:time machine = yes\n'
  exit 0
fi
awk '
  function norm(l){ t=l; gsub(/[ \t]/,"",t); return tolower(t) }
  {
    if (norm($0) ~ /^include=/) {
      p=$0
      sub(/^[ \t]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][ \t]*=[ \t]*/,"",p)
      gsub(/[ \t]+$/, "", p)
      while ((getline line < p) > 0) print line
      close(p)
    } else if ($0 !~ /^[ \t]*[#;]/) print
  }
' "$smb"
MOCK

cat >"$MOCKBIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >>"${MOCK_RELOAD_LOG:?MOCK_RELOAD_LOG is required}"
if [ "${MOCK_RELOAD_FAIL:-0}" = 1 ]; then
  echo 'mock reload failed' >&2
  exit 1
fi
MOCK
chmod +x "$MOCKBIN/testparm" "$MOCKBIN/systemctl"

PASS=0
FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS + 1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
chk(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

ACTIVE_TM=$'[TimeMachine]\n   path = /srv/backups/timemachine\n   valid users = backupuser\n   read only = no\n   vfs objects = catia fruit streams_xattr\n   fruit:time machine = yes\n   fruit:time machine max size = 1T\n'
RETIRED_TM=$'[TimeMachine]\n   path = /srv/backups/timemachine\n   valid users = backupuser\n   read only = no\n   available = no\n   fruit:time machine = no\n'
BAD_RETIRED_TM=$'[TimeMachine]\n   path = /srv/backups/timemachine\n   available = no\n   fruit:time machine = yes\n'
BAD_SCOPED_TM=$'[TimeMachine]\n   path = /srv/backups/timemachine\n[Other]\n   available = no\n   fruit:time machine = no\n'
printf '%s' "$ACTIVE_TM" >"$WORK/stage-active.conf"
printf '%s' "$RETIRED_TM" >"$WORK/stage-retired.conf"
printf '%s' "$BAD_RETIRED_TM" >"$WORK/stage-bad-retired.conf"
printf '%s' "$BAD_SCOPED_TM" >"$WORK/stage-bad-scoped.conf"

# $3 is optional by design: omitting it exercises the retired default.
run(){
  # shellcheck disable=SC2034 # RC and OUT are consumed by chk/eval below.
  local etc="$1" stage="$2" state="${3-}" reload_fail="${4-0}"
  : >"$RELOAD_LOG"
  if [ -n "$state" ]; then
    BROKKR_SAMBA_TIME_MACHINE_STATE="$state" \
      MOCK_SMB="$etc/smb.conf" MOCK_RELOAD_LOG="$RELOAD_LOG" MOCK_RELOAD_FAIL="$reload_fail" \
      PATH="$MOCKBIN:$PATH" SUDO='' BROKKR_SAMBA_ETC="$etc" STAGE="$stage" \
      bash "$REMOTE" >"$WORK/out.txt" 2>&1
  else
    env -u BROKKR_SAMBA_TIME_MACHINE_STATE \
      MOCK_SMB="$etc/smb.conf" MOCK_RELOAD_LOG="$RELOAD_LOG" MOCK_RELOAD_FAIL="$reload_fail" \
      PATH="$MOCKBIN:$PATH" SUDO='' BROKKR_SAMBA_ETC="$etc" STAGE="$stage" \
      bash "$REMOTE" >"$WORK/out.txt" 2>&1
  fi
  # shellcheck disable=SC2034
  RC=$?
  # shellcheck disable=SC2034
  OUT="$(cat "$WORK/out.txt")"
}
reloads(){ [ -f "$RELOAD_LOG" ] && wc -l <"$RELOAD_LOG" | tr -d ' ' || echo 0; }
inline_count(){ grep -ciE '^[[:space:]]*\[[[:space:]]*timemachine[[:space:]]*\][[:space:]]*$' "$1" || true; }
active_inc(){ grep -ciE "^[[:space:]]*include[[:space:]]*=[[:space:]]*$1/timemachine\.conf[[:space:]]*\$" "$1/smb.conf" || true; }
backup_count(){ find "$1" -maxdepth 1 -type f -name '*.bak-brokkr30-*' -print | wc -l | tr -d ' '; }

echo "== retired state =="
E="$WORK/retired-replace"
mkdir -p "$E"
printf '[global]\n   workgroup = WG\ninclude = %s/timemachine.conf\n' "$E" >"$E/smb.conf"
printf '%s' "$ACTIVE_TM" >"$E/timemachine.conf"
run "$E" "$WORK/stage-retired.conf"
chk "retired replaces active config" '[ "$RC" = 0 ] && grep -q "available = no" "$E/timemachine.conf" && grep -q "fruit:time machine = no" "$E/timemachine.conf"'
chk "retired replacement reloads once" '[ "$(reloads)" = 1 ]'
chk "retired replacement keeps include" '[ "$(active_inc "$E")" -ge 1 ]'

echo "== retired no-op =="
# shellcheck disable=SC2034 # Used by the deferred chk expression below.
prior_backups="$(backup_count "$E")"
run "$E" "$WORK/stage-retired.conf"
chk "retired no-op succeeds" '[ "$RC" = 0 ]'
chk "retired no-op does not reload" '[ "$(reloads)" = 0 ]'
chk "retired no-op preserves earlier rollback snapshots" '[ "$(backup_count "$E")" = "$prior_backups" ]'
chk "retired no-op validates desired state" '[[ "$OUT" == *"already in desired state"* ]]'

echo "== retired inline migration =="
E="$WORK/retired-inline"
mkdir -p "$E"
printf '[global]\n   workgroup = WG\n\n[homes]\n   read only = yes\n\n[Other]\n   fruit:time machine = yes\n\n[ TimeMachine ]\n   path = /old\n   available = no\n   fruit:time machine = no\n' >"$E/smb.conf"
run "$E" "$WORK/stage-retired.conf"
chk "retired inline migration succeeds" '[ "$RC" = 0 ] && [ "$(inline_count "$E/smb.conf")" = 0 ] && [ "$(active_inc "$E")" -ge 1 ]'
chk "retired inline migration preserves other sections" 'grep -q "^\[homes\]" "$E/smb.conf" && grep -q "read only = yes" "$E/smb.conf" && grep -q "^\[Other\]" "$E/smb.conf" && grep -q "fruit:time machine = yes" "$E/smb.conf"'
chk "retired inline migration reloads once" '[ "$(reloads)" = 1 ]'

echo "== invalid state and rejected staged state =="
E="$WORK/rejected"
mkdir -p "$E"
printf '[global]\n   workgroup = WG\ninclude = %s/timemachine.conf\n' "$E" >"$E/smb.conf"
printf '%s' "$ACTIVE_TM" >"$E/timemachine.conf"
cp -p "$E/smb.conf" "$WORK/rejected.smb.before"
cp -p "$E/timemachine.conf" "$WORK/rejected.tm.before"
run "$E" "$WORK/stage-retired.conf" invalid
chk "invalid state is rejected" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"invalid"* ]]'
chk "invalid state does not reload or snapshot" '[ "$(reloads)" = 0 ] && [ "$(backup_count "$E")" = 0 ] && cmp -s "$E/smb.conf" "$WORK/rejected.smb.before" && cmp -s "$E/timemachine.conf" "$WORK/rejected.tm.before"'
run "$E" "$WORK/stage-bad-retired.conf"
chk "retired stage must be structurally retired" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"retired"* ]]'
chk "rejected retired stage preserves both files" '[ "$(reloads)" = 0 ] && [ "$(backup_count "$E")" = 0 ] && cmp -s "$E/smb.conf" "$WORK/rejected.smb.before" && cmp -s "$E/timemachine.conf" "$WORK/rejected.tm.before"'

echo "== scoped retired flags =="
E="$WORK/scoped"
mkdir -p "$E"
printf '[global]\n   workgroup = WG\ninclude = %s/timemachine.conf\n' "$E" >"$E/smb.conf"
printf '%s' "$RETIRED_TM" >"$E/timemachine.conf"
cp -p "$E/smb.conf" "$WORK/scoped.smb.before"
cp -p "$E/timemachine.conf" "$WORK/scoped.tm.before"
run "$E" "$WORK/stage-bad-scoped.conf"
chk "flags in another share are rejected" '[ "$RC" -ne 0 ] && [ "$(reloads)" = 0 ]'
chk "scoped rejection preserves both files" '[ "$(backup_count "$E")" = 0 ] && cmp -s "$E/smb.conf" "$WORK/scoped.smb.before" && cmp -s "$E/timemachine.conf" "$WORK/scoped.tm.before"'

echo "== legacy active compatibility cases =="
E="$WORK/active-migrate"
mkdir -p "$E"
printf '[global]\n   workgroup = WG\n\n[ TimeMachine ]\n   path = /old\n   fruit:time machine = yes\n' >"$E/smb.conf"
run "$E" "$WORK/stage-active.conf" active
chk "active inline migration succeeds" '[ "$RC" = 0 ] && [ "$(inline_count "$E/smb.conf")" = 0 ] && grep -q "fruit:time machine = yes" "$E/timemachine.conf"'
chk "active migration reloads once" '[ "$(reloads)" = 1 ]'

E="$WORK/active-noop"
mkdir -p "$E"
printf '[global]\n   workgroup = WG\ninclude = %s/timemachine.conf\n' "$E" >"$E/smb.conf"
printf '%s' "$ACTIVE_TM" >"$E/timemachine.conf"
run "$E" "$WORK/stage-active.conf" active
chk "active no-op succeeds" '[ "$RC" = 0 ] && [ "$(reloads)" = 0 ]'

E="$WORK/active-variant"
mkdir -p "$E"
printf '[global]\n[ TimeMachine ]\n   path = /old\n   fruit:time machine = yes\ninclude = %s/timemachine.conf\n' "$E" >"$E/smb.conf"
printf '%s' "$ACTIVE_TM" >"$E/timemachine.conf"
run "$E" "$WORK/stage-active.conf" active
chk "active case-space variant is removed" '[ "$RC" = 0 ] && [ "$(inline_count "$E/smb.conf")" = 0 ]'

E="$WORK/active-comment"
mkdir -p "$E"
printf '[global]\n# include = %s/timemachine.conf\n' "$E" >"$E/smb.conf"
printf '%s' "$ACTIVE_TM" >"$E/timemachine.conf"
run "$E" "$WORK/stage-active.conf" active
chk "active commented include is not accepted" '[ "$RC" = 0 ] && grep -q "^# include" "$E/smb.conf" && [ "$(active_inc "$E")" -ge 1 ]'

E="$WORK/active-bad-fruit"
mkdir -p "$E"
printf '[global]\ninclude = %s/timemachine.conf\n' "$E" >"$E/smb.conf"
printf '%s' "$ACTIVE_TM" >"$E/timemachine.conf"
run "$E" "$WORK/stage-bad-scoped.conf" active
chk "active fruit guard remains scoped" '[ "$RC" -ne 0 ] && [ "$(reloads)" = 0 ] && grep -q "fruit:time machine = yes" "$E/timemachine.conf"'

E="$WORK/active-testparm-fail"
mkdir -p "$E"
printf '#FORCE_TESTPARM_FAIL\n[global]\n\n[TimeMachine]\n   fruit:time machine = yes\n' >"$E/smb.conf"
run "$E" "$WORK/stage-active.conf" active
chk "testparm failure rolls back" '[ "$RC" -ne 0 ] && [ "$(reloads)" = 0 ] && [ "$(inline_count "$E/smb.conf")" -ge 1 ] && [ ! -e "$E/timemachine.conf" ]'

E="$WORK/active-reload-fail"
mkdir -p "$E"
printf '[global]\n\n[TimeMachine]\n   path = /old\n   fruit:time machine = yes\n' >"$E/smb.conf"
printf '%s' "$ACTIVE_TM" >"$E/timemachine.conf"
cp -p "$E/smb.conf" "$WORK/reload-fail.smb.before"
cp -p "$E/timemachine.conf" "$WORK/reload-fail.tm.before"
run "$E" "$WORK/stage-active.conf" active 1
chk "reload failure is reported" '[ "$RC" -ne 0 ] && [ "$(reloads)" = 1 ]'
chk "reload failure restores both files" '[ "$(backup_count "$E")" -ge 1 ] && cmp -s "$E/smb.conf" "$WORK/reload-fail.smb.before" && cmp -s "$E/timemachine.conf" "$WORK/reload-fail.tm.before"'

echo "== final no-op validates effective config =="
E="$WORK/final-noop-invalid"
mkdir -p "$E"
printf '[global]\n#FORCE_EFFECTIVE_INVALID\ninclude = %s/timemachine.conf\n' "$E" >"$E/smb.conf"
printf '%s' "$RETIRED_TM" >"$E/timemachine.conf"
run "$E" "$WORK/stage-retired.conf"
chk "final no-op rejects invalid effective config" '[ "$RC" -ne 0 ] && [ "$(reloads)" = 0 ] && [ "$(backup_count "$E")" = 0 ]'

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
