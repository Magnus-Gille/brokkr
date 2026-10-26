#!/usr/bin/env bash
# Hermetic tests for the remote OS probe embedded in scripts/maintenance-report.sh: the
# flavour-aware reboot detection and the guarded-reboot audit projection (Grimnir ADR-009).
# The probe text is extracted from the script and run under /bin/sh against a fixture tree
# (BROKKR_PROBE_ROOT) with a curated PATH, so no real kernel, package manager or firmware
# tool is consulted.
# shellcheck disable=SC2016,SC2034 # assertions are evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/test/lib/fixture-cleanup.sh
source "$HERE/lib/fixture-cleanup.sh"
TMP="$(fixture_cleanup_alloc)"
trap 'fixture_cleanup_on_exit "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

PBIN="$TMP/pbin"; mkdir -p "$PBIN"
for tool in awk sed grep sort tail head tr wc cut date cat df dirname; do
  src="$(command -v "$tool")" || { echo "missing host tool: $tool" >&2; exit 2; }
  ln -s "$src" "$PBIN/$tool"
done
cat >"$PBIN/uname" <<'FAKE'
#!/bin/sh
[ "$1" = "-r" ] && { echo "$MOCK_UNAME_R"; exit 0; }
exec /usr/bin/uname "$@"
FAKE
# needrestart claims a kernel mismatch (the Raspberry Pi 5 flavour false positive). The probe
# must not consult it.
cat >"$PBIN/needrestart" <<'FAKE'
#!/bin/sh
echo "NEEDRESTART-KSTA: 3"
FAKE
chmod +x "$PBIN/uname" "$PBIN/needrestart"

# Extract the probe heredoc from the script under test.
PROBE="$TMP/probe.sh"
sed -n "/^cat <<'PROBE'\$/,/^PROBE\$/p" "$ROOT/scripts/maintenance-report.sh" | sed '1d;$d' >"$PROBE"
[[ "$(wc -l <"$PROBE")" -gt 50 ]] || { echo "probe extraction failed" >&2; exit 2; }

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${BLOB:-}" ]] && printf '%s\n' "$BLOB" | sed 's/^/        | /'; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

BLOB=""
# probe KERNEL ROOT -> BLOB
probe() {
  BLOB="$(env -i PATH="$PBIN" MOCK_UNAME_R="$1" BROKKR_PROBE_ROOT="$2" /bin/sh -c "$(cat "$PROBE")" 2>/dev/null)"
}
val() { grep -m1 "^$1=" <<<"$BLOB" | cut -d= -f2-; }

NOW="$(date +%s)"
mkroot() { # name kernel... : fixture root with /boot/vmlinuz-<kernel> files
  local r="$TMP/root-$1"; shift
  rm -rf "$r"; mkdir -p "$r/boot" "$r/var/run" "$r/var/lib/brokkr/guarded-reboot"
  for k in "$@"; do : >"$r/boot/vmlinuz-$k"; done
  printf '%s' "$r"
}

echo "maintenance-report-probe.test.sh"

# ── Reboot detection ─────────────────────────────────────────────────────────
r="$(mkroot pi 6.18.50+rpt-rpi-2712 6.18.50+rpt-rpi-v8)"
probe 6.18.50+rpt-rpi-2712 "$r"
check "Pi 5: running 2712 is newest, v8 present, needrestart says KSTA 3: no reboot" '[[ "$(val REBOOT)" == no ]]'

r="$(mkroot pi-old 6.18.40+rpt-rpi-2712 6.18.50+rpt-rpi-2712 6.18.50+rpt-rpi-v8)"
probe 6.18.40+rpt-rpi-2712 "$r"
check "Pi 5: a newer 2712 kernel is installed: reboot" '[[ "$(val REBOOT)" == yes ]]'

r="$(mkroot pi-v8-newer 6.18.50+rpt-rpi-2712 6.18.99+rpt-rpi-v8)"
probe 6.18.50+rpt-rpi-2712 "$r"
check "Pi 5: a newer kernel of ANOTHER flavour (v8) does not trigger a reboot" '[[ "$(val REBOOT)" == no ]]'

r="$(mkroot deb 6.12.48+deb13-amd64 6.12.57+deb13-amd64)"
probe 6.12.48+deb13-amd64 "$r"
check "Debian amd64: a newer same-flavour kernel is installed: reboot" '[[ "$(val REBOOT)" == yes ]]'

r="$(mkroot deb-numeric 6.12.9+deb13-amd64 6.12.48+deb13-amd64)"
probe 6.12.48+deb13-amd64 "$r"
check "version order is numeric (6.12.9 is older than 6.12.48): no reboot" '[[ "$(val REBOOT)" == no ]]'

r="$(mkroot ubu 7.0.0-4-generic 7.0.0-38-generic 7.0.0-40-generic)"
probe 7.0.0-38-generic "$r"
check "Ubuntu generic: a newer generic kernel is installed: reboot" '[[ "$(val REBOOT)" == yes ]]'

r="$(mkroot ubu-cur 7.0.0-4-generic 7.0.0-38-generic)"
probe 7.0.0-38-generic "$r"
check "Ubuntu generic: running kernel is the newest (7.0.0-4 is older): no reboot" '[[ "$(val REBOOT)" == no ]]'

r="$(mkroot rrfile 6.12.48+deb13-amd64)"; : >"$r/var/run/reboot-required"; printf 'linux-image\nlibc6\n' >"$r/var/run/reboot-required.pkgs"
probe 6.12.48+deb13-amd64 "$r"
check "reboot-required file: reboot, with the package count" '[[ "$(val REBOOT)" == yes && "$(val REBOOT_PKGS)" == 2 ]]'

r="$(mkroot nokern)"
probe 6.12.48+deb13-amd64 "$r"
check "no candidate kernel under /boot: no signal, no reboot" '[[ "$(val REBOOT)" == no ]]'

r="$(mkroot noflav 6.12.57)"
probe 6.12 "$r"
check "a kernel release without a flavour: no signal, no reboot" '[[ "$(val REBOOT)" == no ]]'

# Flavour rule (shared with the guarded-reboot job): the version part is the longest prefix
# matching ^[0-9]+(\.[0-9]+)*(\+[a-z0-9]+)?(-[0-9]+)?, the flavour is what follows the next "-".
# 7.0.0-38-generic -> generic; 6.12.48+deb13-amd64 -> amd64; 6.12.48+deb13-rt-amd64 -> rt-amd64;
# 6.18.50+rpt-rpi-2712 -> rpi-2712 (vs rpi-v8). Candidates must match the running flavour EXACTLY.
r="$(mkroot rt-beside 6.12.48+deb13-amd64 6.12.57+deb13-rt-amd64)"
probe 6.12.48+deb13-amd64 "$r"
check "flavour: a newer rt-amd64 kernel beside the running amd64 does not trigger a reboot" '[[ "$(val REBOOT)" == no ]]'

r="$(mkroot rt-same 6.12.48+deb13-rt-amd64 6.12.57+deb13-rt-amd64 6.12.99+deb13-amd64)"
probe 6.12.48+deb13-rt-amd64 "$r"
check "flavour: a newer rt-amd64 kernel for the running rt-amd64 triggers a reboot" '[[ "$(val REBOOT)" == yes ]]'

r="$(mkroot rt-cur 6.12.48+deb13-rt-amd64 6.12.99+deb13-amd64)"
probe 6.12.48+deb13-rt-amd64 "$r"
check "flavour: running rt-amd64 is the newest rt-amd64 (plain amd64 is newer): no reboot" '[[ "$(val REBOOT)" == no ]]'

r="$(mkroot pi4-v8 6.18.50+rpt-rpi-v8 6.18.99+rpt-rpi-2712)"
probe 6.18.50+rpt-rpi-v8 "$r"
check "flavour: running rpi-v8 ignores a newer rpi-2712" '[[ "$(val REBOOT)" == no ]]'

r="$(mkroot ubu-64k 7.0.0-38-generic 7.0.0-40-generic-64k)"
probe 7.0.0-38-generic "$r"
check "flavour: a newer generic-64k kernel does not count for running generic" '[[ "$(val REBOOT)" == no ]]'

r="$(mkroot ubu-64k-run 7.0.0-38-generic-64k 7.0.0-40-generic-64k 7.0.0-41-generic)"
probe 7.0.0-38-generic-64k "$r"
check "flavour: a newer generic-64k kernel counts for running generic-64k" '[[ "$(val REBOOT)" == yes ]]'

r="$(mkroot deb-odd 6.12.48+deb13-amd64 6.12.99+deb13-amd64.old)"
probe 6.12.48+deb13-amd64 "$r"
check "flavour: a vmlinuz file with a suffix after the flavour is not a candidate" '[[ "$(val REBOOT)" == no ]]'

# The newest installed same-flavour kernel must be NEWER than the running one, not merely
# different: a running kernel that is newer than everything left in /boot (for example after the
# newest package was removed or a kernel was booted by hand) is not a reboot trigger.
r="$(mkroot newer-running 7.0.0-39-generic)"
probe 7.0.0-40-generic "$r"
check "running 7.0.0-40-generic with newest installed 7.0.0-39-generic: no reboot" '[[ "$(val REBOOT)" == no ]]'

r="$(mkroot newer-running-two 7.0.0-4-generic 7.0.0-39-generic)"
probe 7.0.0-40-generic "$r"
check "running kernel newer than every installed one (numeric order): no reboot" '[[ "$(val REBOOT)" == no ]]'

r="$(mkroot older-running 7.0.0-39-generic 7.0.0-40-generic)"
probe 7.0.0-39-generic "$r"
check "running 7.0.0-39-generic with newest installed 7.0.0-40-generic: reboot" '[[ "$(val REBOOT)" == yes ]]'

# ── Guarded-reboot audit projection ──────────────────────────────────────────
AUDIT=""
aline() { # epoch mode action triggers guards detail
  printf '{"ts":"2026-10-26T00:00:00Z","epoch":%s,"host":"fixture","mode":"%s","action":"%s","triggers":"%s","guards":"%s","boot_id":"b-%s","detail":"%s"}\n' \
    "$1" "$2" "$3" "$4" "$5" "$1" "$6"
}
audit_root() { r="$(mkroot "audit-$1" 6.12.48+deb13-amd64)"; AUDIT="$r/var/lib/brokkr/guarded-reboot/audit.jsonl"; : >"$AUDIT"; }

audit_root counts
{
  aline $((NOW - 3 * 86400)) reboot reboot kernel "" "old reboot, outside the window"
  aline $((NOW - 2 * 86400)) reboot deferred reboot-required load "old deferral"
  aline $((NOW - 20 * 3600)) reboot reboot kernel "" "reboot 20 h ago"
  aline $((NOW - 19 * 3600)) reboot post-boot-ok kernel "" "ok"
  aline $((NOW - 18 * 3600)) report would-reboot kernel "" "x"
  aline $((NOW - 10 * 3600)) reboot deferred kernel load "d1"
  aline $((NOW - 9 * 3600)) reboot deferred kernel session "d2"
  aline $((NOW - 8 * 3600)) reboot alert kernel "" "escalation"
  aline $((NOW - 7 * 3600)) reboot post-boot-issues kernel "" "unit failed"
  aline $((NOW - 6 * 3600)) reboot health-issues "" "" "service gone"
  aline $((NOW - 5 * 3600)) reboot health-ok "" "" "fine"
  aline $((NOW - 4 * 3600)) reboot health-issues "" "" "again"
  # Hostile detail: embedded quoted text must not forge an action, and garbage lines are skipped.
  aline $((NOW - 3600)) reboot none "" "" 'x\",\"action\":\"reboot'
  printf 'not json at all\n'
  printf '{"ts":"x","epoch":"oops","action":"reboot"}\n'
  printf '{"ts":"2026-10-26T00:00:00Z","epoch":%s,"host":"fixture","mode":"reboot","action":"reb' $((NOW - 60))
} >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "audit: present" '[[ "$(val GUARDED_REBOOT)" == present ]]'
check "audit: last action and epoch come from the last valid line" '[[ "$(val GUARDED_REBOOT_LAST_ACTION)" == none && "$(val GUARDED_REBOOT_LAST_EPOCH)" == "$((NOW - 3600))" ]]'
check "audit: 24 h reboot count ignores lines older than 24 h" '[[ "$(val GUARDED_REBOOT_REBOOTS_24H)" == 1 ]]'
check "audit: 24 h deferrals, alerts, post-boot issues" '[[ "$(val GUARDED_REBOOT_DEFERRALS_24H)" == 2 && "$(val GUARDED_REBOOT_ALERTS_24H)" == 1 && "$(val GUARDED_REBOOT_ISSUES_24H)" == 1 ]]'
check "audit: 24 h daily-health issue count" '[[ "$(val GUARDED_REBOOT_HEALTH_ISSUES_24H)" == 2 ]]'
check "audit: reboot followed by post-boot-ok is recovered" '[[ "$(val GUARDED_REBOOT_UNRECOVERED)" == 0 ]]'
check "audit: no latch" '[[ "$(val GUARDED_REBOOT_LATCHED)" == 0 ]]'

audit_root absent; rm -f "$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "audit absent: GUARDED_REBOOT=absent and no counters" '[[ "$(val GUARDED_REBOOT)" == absent && -z "$(val GUARDED_REBOOT_LAST_ACTION)" && -z "$(val GUARDED_REBOOT_REBOOTS_24H)" ]]'

audit_root empty
probe 6.12.48+deb13-amd64 "$r"
check "audit empty: present, last action none, all counters zero" \
  '[[ "$(val GUARDED_REBOOT)" == present && "$(val GUARDED_REBOOT_LAST_ACTION)" == none && "$(val GUARDED_REBOOT_LAST_EPOCH)" == 0 && "$(val GUARDED_REBOOT_REBOOTS_24H)" == 0 && "$(val GUARDED_REBOOT_UNRECOVERED)" == 0 ]]'

audit_root unknown
aline $((NOW - 100)) report "rm -rf" "" "" "x" >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "audit: an unknown action value is reported as unknown, never echoed" '[[ "$(val GUARDED_REBOOT_LAST_ACTION)" == unknown ]]'

if [[ "$(id -u)" != 0 ]]; then
  audit_root unreadable
  aline $((NOW - 100)) report none "" "" "x" >"$AUDIT"; chmod 000 "$AUDIT"
  probe 6.12.48+deb13-amd64 "$r"
  check "audit exists but is unreadable: GUARDED_REBOOT=unreadable" '[[ "$(val GUARDED_REBOOT)" == unreadable ]]'
  chmod 600 "$AUDIT"
fi

# ── Unrecovered reboot (reboot record with no post-boot record, >= 60 min old) ─
audit_root unrec
{ aline $((NOW - 2 * 3600)) reboot reboot kernel "" "rebooting"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "unrecovered: a reboot 2 h ago with no post-boot record" \
  '[[ "$(val GUARDED_REBOOT_UNRECOVERED)" == 1 && "$(val GUARDED_REBOOT_LAST_REBOOT_EPOCH)" == "$((NOW - 2 * 3600))" ]]'

audit_root unrec-young
{ aline $((NOW - 30 * 60)) reboot reboot kernel "" "rebooting"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "unrecovered: a reboot only 30 minutes ago is still in its grace period" '[[ "$(val GUARDED_REBOOT_UNRECOVERED)" == 0 ]]'

audit_root unrec-issues
{ aline $((NOW - 5 * 3600)) reboot reboot kernel "" "rebooting"; aline $((NOW - 5 * 3600 + 700)) reboot post-boot-issues kernel "" "bad"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "unrecovered: post-boot-issues also counts as the post-boot report" '[[ "$(val GUARDED_REBOOT_UNRECOVERED)" == 0 ]]'

audit_root unrec-old
{ aline $((NOW - 5 * 3600)) reboot reboot kernel "" "r1"; aline $((NOW - 5 * 3600 + 700)) reboot post-boot-ok kernel "" "ok"
  aline $((NOW - 2 * 3600)) reboot reboot kernel "" "r2"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "unrecovered: a post-boot record BEFORE the latest reboot does not count" '[[ "$(val GUARDED_REBOOT_UNRECOVERED)" == 1 ]]'

audit_root unrec-forged
{ aline $((NOW - 2 * 3600)) reboot reboot kernel "" "r"; aline $((NOW - 3600)) reboot alert kernel "" 'x\",\"action\":\"post-boot-ok'; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "unrecovered: a post-boot-ok forged inside a detail field does not recover it" '[[ "$(val GUARDED_REBOOT_UNRECOVERED)" == 1 ]]'

# The job writes the "reboot" line as an intent record; an abort after it is recorded as a
# "deferred" whose detail starts "reboot aborted", and no reboot happened.
audit_root unrec-aborted
{ aline $((NOW - 2 * 3600)) reboot reboot kernel "" "rebooting"; aline $((NOW - 2 * 3600 + 5)) reboot deferred kernel peer:node-b.example "reboot aborted before it was executed: peer unreachable"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "aborted reboot intent: not unrecovered and not counted as a reboot" \
  '[[ "$(val GUARDED_REBOOT_UNRECOVERED)" == 0 && "$(val GUARDED_REBOOT_REBOOTS_24H)" == 0 && "$(val GUARDED_REBOOT_DEFERRALS_24H)" == 1 ]]'

audit_root unrec-plain-deferred
{ aline $((NOW - 2 * 3600)) reboot reboot kernel "" "rebooting"; aline $((NOW - 3600)) reboot deferred kernel load "deferred: load"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "a later ordinary deferral does not resolve a reboot intent" '[[ "$(val GUARDED_REBOOT_UNRECOVERED)" == 1 ]]'

audit_root unrec-aborted-forged
{ aline $((NOW - 2 * 3600)) reboot reboot kernel "" "rebooting"; aline $((NOW - 3600)) reboot alert kernel "" 'x\",\"action\":\"deferred\",\"detail\":\"reboot aborted'; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "a forged 'reboot aborted' inside another record's detail does not resolve it" '[[ "$(val GUARDED_REBOOT_UNRECOVERED)" == 1 ]]'

# ── Latch (an alert record whose detail starts with "latched") ───────────────
audit_root latch
{ aline $((NOW - 7200)) reboot alert kernel "" "latched: trigger survived the reboot"; aline $((NOW - 600)) reboot deferred kernel latched "d"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "latch: a latched alert record sets GUARDED_REBOOT_LATCHED=1" '[[ "$(val GUARDED_REBOOT_LATCHED)" == 1 ]]'

audit_root nolatch
{ aline $((NOW - 7200)) reboot alert kernel "" "three nights deferred"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "latch: an ordinary alert (detail not starting with latched) does not latch" '[[ "$(val GUARDED_REBOOT_LATCHED)" == 0 ]]'

# Only the owner's clear-latch command clears the latch: it appends action "none" with a detail
# starting "latch-cleared". A later reboot record (or anything else) does not.
audit_root latch-reboot
{ aline $((NOW - 7200)) reboot alert kernel "" "latched: x"; aline $((NOW - 3600)) reboot reboot kernel "" "rebooted"; aline $((NOW - 3000)) reboot post-boot-ok kernel "" ok; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "latch: a later reboot record does NOT clear the latch" '[[ "$(val GUARDED_REBOOT_LATCHED)" == 1 ]]'

audit_root latch-cleared
{ aline $((NOW - 7200)) reboot alert kernel "" "latched: x"; aline $((NOW - 3600)) reboot none "" "" "latch-cleared by the owner"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "latch: a later latch-cleared record (action none) clears the latch" '[[ "$(val GUARDED_REBOOT_LATCHED)" == 0 ]]'

audit_root latch-again
{ aline $((NOW - 7200)) reboot alert kernel "" "latched: x"; aline $((NOW - 3600)) reboot none "" "" "latch-cleared by the owner"; aline $((NOW - 600)) reboot alert kernel "" "latched: again"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "latch: a latched alert after latch-cleared latches again" '[[ "$(val GUARDED_REBOOT_LATCHED)" == 1 ]]'

audit_root latch-wrong-action
{ aline $((NOW - 7200)) reboot alert kernel "" "latched: x"; aline $((NOW - 3600)) reboot alert kernel "" "latch-cleared but as an alert"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "latch: latch-cleared only counts on an action none record" '[[ "$(val GUARDED_REBOOT_LATCHED)" == 1 ]]'

audit_root latch-forged
{ aline $((NOW - 7200)) reboot alert kernel "" "latched: x"; aline $((NOW - 3600)) reboot none "" "" 'harmless\",\"detail\":\"latch-cleared'; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "latch: a latch-cleared forged inside another detail does not clear it" '[[ "$(val GUARDED_REBOOT_LATCHED)" == 1 ]]'

# An alert whose detail starts with eeprom-cancelled (a staged EEPROM update found outside a
# guarded reboot and cancelled) is an ordinary alert: counted with the alerts, no latch, no new
# action value.
audit_root eeprom
{ aline $((NOW - 3600)) reboot alert eeprom "" "eeprom-cancelled: staged update found outside a guarded reboot"; } >"$AUDIT"
probe 6.12.48+deb13-amd64 "$r"
check "eeprom-cancelled alert is counted with the alerts" \
  '[[ "$(val GUARDED_REBOOT_ALERTS_24H)" == 1 && "$(val GUARDED_REBOOT_LAST_ACTION)" == alert && "$(val GUARDED_REBOOT_LATCHED)" == 0 && "$(val GUARDED_REBOOT_UNRECOVERED)" == 0 ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
