#!/usr/bin/env bash
# Brokkr · remote half of samba/deploy.sh — runs ON the NAS Pi (piped in via `ssh 'bash -s'`).
#
# Idempotent + self-migrating + guarded. Split out from deploy.sh so the safety logic is unit
# testable (see ../scripts/test/samba-deploy.test.sh). Parametrized via env so a test can point
# it at a fixture tree with no privilege:
#   BROKKR_SAMBA_ETC  dir holding smb.conf + timemachine.conf   (default /etc/samba)
#   SUDO              privilege prefix                          (default "sudo"; tests set "")
#   STAGE             path to the staged timemachine.conf to install (required)
#
# Contract: installs timemachine.conf, removes ANY inline [TimeMachine] stanza, ensures the
# include directive is present, and — after ANY change to EITHER file — validates that the
# [TimeMachine] share still resolves with `fruit:time machine = yes` (scoped to that section,
# honouring testparm's exit code). On failure it restores BOTH files and does NOT reload.
# smb.conf/timemachine.conf are backed up next to themselves (`.bak-brokkr30-<ts>`); the
# backups are kept when a change was made and removed on a no-op run.
set -euo pipefail

ETC="${BROKKR_SAMBA_ETC:-/etc/samba}"
SMB="$ETC/smb.conf"
TMCONF="$ETC/timemachine.conf"
SUDO="${SUDO-sudo}"
: "${STAGE:?STAGE (staged timemachine.conf path) is required}"

# ERE for an ACTIVE include of our file: case-insensitive, whitespace-tolerant around '=',
# anchored at line start so a commented "# include = ..." never matches. Dots are escaped.
TMCONF_RE="$(printf '%s' "$TMCONF" | sed 's/[.]/\\./g')"
INC_RE="^[[:space:]]*include[[:space:]]*=[[:space:]]*${TMCONF_RE}[[:space:]]*\$"

CHANGED=0 BK_SMB="" BK_TM="" had_tm=0
ts() { date +%Y%m%d-%H%M%S; }

# True iff the [TimeMachine] share resolves: testparm EXITS 0 AND that section (only) carries
# `fruit:time machine = yes`. Section names are matched case-insensitively / whitespace-agnostic.
validate_share() {
  local eff
  if ! eff="$($SUDO testparm -s 2>/dev/null)"; then return 1; fi
  printf '%s\n' "$eff" | awk '
    function norm(l){ gsub(/[ \t]/,"",l); return tolower(l) }
    function ishdr(l){ return norm(l) ~ /^\[.*\]$/ }
    norm($0)=="[timemachine]" { intm=1; next }
    intm && ishdr($0)         { intm=0 }
    intm && tolower($0) ~ /fruit:time machine[ \t]*=[ \t]*yes/ { found=1 }
    END { exit(found?0:1) }
  '
}
count_inline() {  # inline [TimeMachine] section headers in $1 (case/space-insensitive)
  $SUDO awk 'function norm(l){gsub(/[ \t]/,"",l);return tolower(l)}
             norm($0)=="[timemachine]"{c++} END{print c+0}' "$1"
}
rollback() {
  [ -n "$BK_SMB" ] && $SUDO cp -a "$BK_SMB" "$SMB"
  if [ "$had_tm" = 1 ]; then [ -n "$BK_TM" ] && $SUDO cp -a "$BK_TM" "$TMCONF"
  else $SUDO rm -f "$TMCONF"; fi
}

# Snapshot originals for rollback (both files are protected). Kept iff a change is made.
if $SUDO test -f "$TMCONF"; then had_tm=1; BK_TM="$TMCONF.bak-brokkr30-$(ts)"; $SUDO cp -a "$TMCONF" "$BK_TM"; fi
if $SUDO test -f "$SMB";    then BK_SMB="$SMB.bak-brokkr30-$(ts)"; $SUDO cp -a "$SMB" "$BK_SMB"; fi

# 1. Install/update the include file (the source of truth for the share).
if ! $SUDO cmp -s "$STAGE" "$TMCONF" 2>/dev/null; then
  $SUDO install -m 0644 "$STAGE" "$TMCONF"; echo "   installed $TMCONF"; CHANGED=1
fi

# 2. Migrate smb.conf if it still carries an inline [TimeMachine] stanza or lacks the include.
has_inline="$(count_inline "$SMB")"
if $SUDO grep -qiE "$INC_RE" "$SMB"; then has_include=1; else has_include=0; fi
if [ "$has_inline" != "0" ] || [ "$has_include" = "0" ]; then
  $SUDO awk '
    function norm(l){ gsub(/[ \t]/,"",l); return tolower(l) }
    function ishdr(l){ return norm(l) ~ /^\[.*\]$/ }
    norm($0)=="[timemachine]" { skip=1; next }
    skip && ishdr($0)         { skip=0 }
    !skip                     { print }
  ' "$SMB" | $SUDO tee "$SMB.brokkr-new" >/dev/null
  $SUDO grep -qiE "$INC_RE" "$SMB.brokkr-new" \
    || printf '\ninclude = %s\n' "$TMCONF" | $SUDO tee -a "$SMB.brokkr-new" >/dev/null
  $SUDO install -m 0644 "$SMB.brokkr-new" "$SMB"; $SUDO rm -f "$SMB.brokkr-new"
  echo "   migrated smb.conf (inline [TimeMachine] removed; include ensured)"; CHANGED=1
fi

# 3. After ANY change, validate the share; reload only on success, else restore both files.
if [ "$CHANGED" = "1" ]; then
  if ! validate_share; then
    echo "   ABORT: [TimeMachine] does not resolve with fruit:time machine=yes — rolling back (no reload)"
    rollback
    exit 2
  fi
  $SUDO systemctl reload smbd
  echo "   smbd reloaded"
  [ -n "$BK_SMB" ] && echo "   backup: $BK_SMB"
  [ -n "$BK_TM" ]  && echo "   backup: $BK_TM"
else
  # No-op run: drop the redundant snapshots so backups don't accumulate.
  [ -n "$BK_SMB" ] && $SUDO rm -f "$BK_SMB"
  [ -n "$BK_TM" ]  && $SUDO rm -f "$BK_TM"
  echo "   already in desired state — no changes, no reload"
fi

echo "-- verify --"
echo "   inline [TimeMachine] headers in smb.conf (want 0): $(count_inline "$SMB")"
echo "   active include line: $($SUDO grep -niE "$INC_RE" "$SMB" || echo MISSING)"
