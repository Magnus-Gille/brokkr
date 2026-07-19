#!/usr/bin/env bash
# Brokkr · unit test for samba/deploy-remote.sh (brokkr#30).
#
# Runs the remote deploy logic against a fixture tree with mock `testparm`/`systemctl` and no
# privilege (SUDO=""), so the safety guard + migration are exercised with zero risk to any host.
# Covers the Codex-review findings on PR #35: unified guard on the install path, section-scoped
# fruit check, testparm exit-code honouring, case/space-variant stanza removal, and the
# commented-include false-positive.
#
#   ./scripts/test/samba-deploy.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="$HERE/../../samba/deploy-remote.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-samba-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
RELOAD_LOG="$WORK/reload.log"

# --- mock testparm: -s prints effective config = smb.conf with ACTIVE includes spliced in ----
cat > "$MOCKBIN/testparm" <<'MOCK'
#!/usr/bin/env bash
smb="$MOCK_SMB"
grep -q '#FORCE_TESTPARM_FAIL' "$smb" 2>/dev/null && { echo "Error loading services"; exit 1; }
awk '
  function norm(l){ t=l; gsub(/[ \t]/,"",t); return tolower(t) }
  {
    if (norm($0) ~ /^include=/) {
      p=$0; sub(/^[ \t]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][ \t]*=[ \t]*/,"",p); gsub(/[ \t]+$/,"",p)
      while ((getline line < p) > 0) print line
      close(p)
    } else if ($0 !~ /^[ \t]*[#;]/) print
  }
' "$smb"
exit 0
MOCK
# --- mock systemctl: record every call so the test can assert reload count -------------------
cat > "$MOCKBIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_RELOAD_LOG"
exit 0
MOCK
chmod +x "$MOCKBIN/testparm" "$MOCKBIN/systemctl"

PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
chk(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

GOOD_TM=$'[TimeMachine]\n   path = /srv/backups/timemachine\n   valid users = backupuser\n   read only = no\n   vfs objects = catia fruit streams_xattr\n   fruit:time machine = yes\n   fruit:time machine max size = 1T\n'
BAD_TM_NOFRUIT=$'[TimeMachine]\n   path = /mnt/timemachine\n   valid users = backupuser\n'
BAD_TM_SCOPED=$'[TimeMachine]\n   path = /mnt/timemachine\n[Other]\n   fruit:time machine = yes\n'
printf '%s' "$GOOD_TM"        > "$WORK/stage-good.conf"
printf '%s' "$BAD_TM_NOFRUIT" > "$WORK/stage-bad.conf"
printf '%s' "$BAD_TM_SCOPED"  > "$WORK/stage-scoped.conf"

run(){ # $1=etc dir  $2=stage file ; echoes exit code, writes output to $WORK/out.txt
  MOCK_SMB="$1/smb.conf" MOCK_RELOAD_LOG="$RELOAD_LOG" PATH="$MOCKBIN:$PATH" \
    SUDO='' BROKKR_SAMBA_ETC="$1" STAGE="$2" bash "$REMOTE" > "$WORK/out.txt" 2>&1
  echo $?
}
reloads(){ [ -f "$RELOAD_LOG" ] && wc -l < "$RELOAD_LOG" | tr -d ' ' || echo 0; }
inline_count(){ grep -ciE '^[[:space:]]*\[[[:space:]]*timemachine[[:space:]]*\][[:space:]]*$' "$1"; }
active_inc(){ grep -ciE "^[[:space:]]*include[[:space:]]*=[[:space:]]*$1/timemachine\.conf[[:space:]]*\$" "$1/smb.conf"; }

echo "== case 1: migrate inline [TimeMachine] -> include =="
: > "$RELOAD_LOG"; E="$WORK/etc1"; mkdir -p "$E"
printf '[global]\n   workgroup = WG\n\n[homes]\n   read only = yes\n\n%s' "$GOOD_TM" > "$E/smb.conf"
rc=$(run "$E" "$WORK/stage-good.conf")
chk "exit 0"                    "[ '$rc' = 0 ]"
chk "timemachine.conf installed" "[ -f '$E/timemachine.conf' ]"
chk "no inline stanza left"      "[ \"\$(inline_count '$E/smb.conf')\" = 0 ]"
chk "active include present"     "[ \"\$(active_inc '$E')\" -ge 1 ]"
chk "reloaded once"              "[ \"\$(reloads)\" = 1 ]"

echo "== case 2: idempotent second run is a no-op =="
: > "$RELOAD_LOG"
rc=$(run "$E" "$WORK/stage-good.conf")
chk "exit 0"                     "[ '$rc' = 0 ]"
chk "no reload on no-op"         "[ \"\$(reloads)\" = 0 ]"
chk "still no inline stanza"     "[ \"\$(inline_count '$E/smb.conf')\" = 0 ]"
chk "reports desired state"      "grep -q 'already in desired state' '$WORK/out.txt'"

echo "== case 3: case/space-variant inline stanza is removed (#4) =="
: > "$RELOAD_LOG"; E3="$WORK/etc3"; mkdir -p "$E3"
printf '[global]\n   workgroup = WG\n[ TimeMachine ]\n   path = /mnt/x\n   fruit:time machine = yes\ninclude = %s/timemachine.conf\n' "$E3" "$E3" > "$E3/smb.conf"
printf '%s' "$GOOD_TM" > "$E3/timemachine.conf"
rc=$(run "$E3" "$WORK/stage-good.conf")
chk "exit 0"                     "[ '$rc' = 0 ]"
chk "variant stanza removed"     "[ \"\$(inline_count '$E3/smb.conf')\" = 0 ]"
chk "include still present"      "[ \"\$(active_inc '$E3')\" -ge 1 ]"
chk "reloaded (smb.conf changed)" "[ \"\$(reloads)\" = 1 ]"

echo "== case 4: commented include is not treated as active (#5) =="
: > "$RELOAD_LOG"; E4="$WORK/etc4"; mkdir -p "$E4"
printf '[global]\n   workgroup = WG\n# include = %s/timemachine.conf\n' "$E4" > "$E4/smb.conf"
printf '%s' "$GOOD_TM" > "$E4/timemachine.conf"
rc=$(run "$E4" "$WORK/stage-good.conf")
chk "exit 0"                     "[ '$rc' = 0 ]"
chk "active include added"       "[ \"\$(active_inc '$E4')\" -ge 1 ]"
chk "commented line preserved"   "grep -q '^# include' '$E4/smb.conf'"
chk "reloaded once"              "[ \"\$(reloads)\" = 1 ]"

echo "== case 5: bad timemachine.conf on migrated host -> rollback, no reload (#1) =="
: > "$RELOAD_LOG"; E5="$WORK/etc5"; mkdir -p "$E5"
printf '[global]\n   workgroup = WG\ninclude = %s/timemachine.conf\n' "$E5" > "$E5/smb.conf"
printf '%s' "$GOOD_TM" > "$E5/timemachine.conf"
rc=$(run "$E5" "$WORK/stage-bad.conf")
chk "exit 2 (guard tripped)"     "[ '$rc' = 2 ]"
chk "NO reload"                  "[ \"\$(reloads)\" = 0 ]"
chk "timemachine.conf restored"  "grep -q 'fruit:time machine = yes' '$E5/timemachine.conf'"
chk "reports rolling back"       "grep -q 'rolling back' '$WORK/out.txt'"

echo "== case 6: fruit in another section does NOT satisfy the guard (#3 scoping) =="
: > "$RELOAD_LOG"; E6="$WORK/etc6"; mkdir -p "$E6"
printf '[global]\n   workgroup = WG\ninclude = %s/timemachine.conf\n' "$E6" > "$E6/smb.conf"
printf '%s' "$GOOD_TM" > "$E6/timemachine.conf"
rc=$(run "$E6" "$WORK/stage-scoped.conf")
chk "exit 2 (scoped guard tripped)" "[ '$rc' = 2 ]"
chk "NO reload"                  "[ \"\$(reloads)\" = 0 ]"
chk "good config restored"       "grep -q 'fruit:time machine max size' '$E6/timemachine.conf'"

echo "== case 7: testparm non-zero exit triggers rollback (#2 exit-code) =="
: > "$RELOAD_LOG"; E7="$WORK/etc7"; mkdir -p "$E7"
# Sentinel above [global] so it survives the stanza-removal awk and makes mock testparm exit 1.
printf '#FORCE_TESTPARM_FAIL\n[global]\n   workgroup = WG\n\n%s' "$GOOD_TM" > "$E7/smb.conf"
rc=$(run "$E7" "$WORK/stage-good.conf")
chk "exit 2 (testparm-fail rollback)" "[ '$rc' = 2 ]"
chk "NO reload"                  "[ \"\$(reloads)\" = 0 ]"
chk "inline stanza restored"     "[ \"\$(inline_count '$E7/smb.conf')\" -ge 1 ]"

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
