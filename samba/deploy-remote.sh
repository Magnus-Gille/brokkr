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
# [TimeMachine] share resolves in the requested state (retired by default).
# Active shares require explicit BROKKR_SAMBA_TIME_MACHINE_STATE=active.
# Validation is section-scoped and honours testparm's exit code. On failure it
# restores BOTH files. A failed reload also restores the files and reports failure.
# smb.conf/timemachine.conf are backed up next to themselves (`.bak-brokkr30-<ts>`); the
# backups are kept when a change was made and removed on a no-op run.
set -euo pipefail

ETC="${BROKKR_SAMBA_ETC:-/etc/samba}"
SMB="$ETC/smb.conf"
TMCONF="$ETC/timemachine.conf"
SUDO="${SUDO-sudo}"
: "${STAGE:?STAGE (staged timemachine.conf path) is required}"
VALIDATE_ONLY=0
case "${1-}" in
  --validate-stage) VALIDATE_ONLY=1 ;;
  "") ;;
  *) echo "ERROR: invalid deploy-remote argument" >&2; exit 2 ;;
esac
TIME_MACHINE_STATE="${BROKKR_SAMBA_TIME_MACHINE_STATE-retired}"
case "$TIME_MACHINE_STATE" in
  retired|active) ;;
  *) echo "ERROR: invalid BROKKR_SAMBA_TIME_MACHINE_STATE; expected retired or active" >&2; exit 2 ;;
esac

# ERE for an ACTIVE include of our file: case-insensitive, whitespace-tolerant around '=',
# anchored at line start so a commented "# include = ..." never matches. Dots are escaped.
TMCONF_RE="$(printf '%s' "$TMCONF" | sed 's/[.]/\\./g')"
INC_RE="^[[:space:]]*include[[:space:]]*=[[:space:]]*${TMCONF_RE}[[:space:]]*\$"

CHANGED=0 BK_SMB="" BK_TM="" had_tm=0
ts() { printf '%s-%s' "$(date +%Y%m%d-%H%M%S)" "$$"; }

# Require both retirement flags in this section. Flags in another share cannot
# satisfy the guard, and the last assignment wins as in Samba's config parser.
config_has_state() {
  awk -v state="$TIME_MACHINE_STATE" '
    function norm(l){ gsub(/[ \t\r]/,"",l); return tolower(l) }
    { line=norm($0) }
    line ~ /^\[.*\]$/ { intm=(line=="[timemachine]"); if(intm) count++; next }
    intm && line ~ /^available=/ { available=substr(line,index(line,"=")+1) }
    intm && line ~ /^fruit:timemachine=/ { fruit=substr(line,index(line,"=")+1) }
    END {
      if(count!=1) exit 1
      if(state=="retired") exit !(available=="no" && fruit=="no")
      exit !(fruit=="yes" && (available=="" || available=="yes"))
    }
  ' "${1:--}"
}

# Reject a stale enabled operator config before changing or backing up anything.
if ! config_has_state "$STAGE"; then
  echo "ERROR: staged [TimeMachine] config does not match requested $TIME_MACHINE_STATE state" >&2
  exit 2
fi
[ "$VALIDATE_ONLY" = 0 ] || exit 0

# True iff testparm succeeds and this section resolves in the requested state.
# Section and boolean matching is case-insensitive and whitespace-tolerant.
validate_share() {
  local eff
  if ! eff="$($SUDO testparm -s 2>/dev/null)"; then return 1; fi
  printf '%s\n' "$eff" | config_has_state
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
if ! validate_share; then
  if [ "$CHANGED" = "1" ]; then
    echo "   ABORT: [TimeMachine] does not resolve in $TIME_MACHINE_STATE state — rolling back (no reload)"
    rollback
  else
    [ -n "$BK_SMB" ] && $SUDO rm -f "$BK_SMB"
    [ -n "$BK_TM" ] && $SUDO rm -f "$BK_TM"
    echo "   ABORT: existing [TimeMachine] does not resolve in $TIME_MACHINE_STATE state (no reload)" >&2
  fi
  exit 2
fi
if [ "$CHANGED" = "1" ]; then
  if ! $SUDO systemctl reload smbd; then
    echo "   ABORT: smbd reload failed — restoring both config files; verify live service before retry" >&2
    rollback
    exit 2
  fi
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
