#!/usr/bin/env bash
#
# maintenance-report.sh — Brokkr software-update visibility layer.
#
# Two modes (run as separate oneshot timers on control-node):
#
#   os    Daily. For EVERY Pi host in services.json (local + SSH to the rest),
#         report: pending security updates, reboot-required, disk usage,
#         whether unattended-upgrades is installed/healthy, AND firmware status
#         (Pi bootloader EEPROM via rpi-eeprom-update; UEFI capsule/LVFS via
#         fwupd on x86/Jetson — brokkr#9–#12). The actual OS patching is done
#         autonomously by unattended-upgrades (see setup-host-patching.sh);
#         firmware is DETECT+REPORT only (apply+reboot is a deliberate,
#         per-host, scheduled step). Pushes an action-needed Telegram alert when
#         a reboot is pending, security updates are still outstanding, disk is
#         tight, a host lacks the patcher, or a firmware update is available.
#
#   deps  Weekly. Run `npm outdated` across every service repo checked out under
#         ~/repos and report counts (total + major bumps) to Munin. DETECT +
#         REPORT ONLY — never auto-applies (per the auto-ops debate verdict).
#
# Results go to Munin (maintenance/* namespace) and Heimdall; alerts go to
# Telegram via Ratatoskr. Mirrors security-scan.sh conventions and reuses the
# shared lib/munin.sh + lib/notify.sh helpers. Compatible with bash 3.2+.
#
# Runtime coupling: reads the host registry from REGISTRY_PATH (defaults to
# /opt/grimnir/services.json — grimnir owns the canonical inventory).
# By default it reads the COMMITTED origin default-branch copy (best-effort fetch
# + git-show snapshot), NOT the working file — that checkout doubles as hugin's
# mutable task tree and is often stale/on the wrong branch (brokkr#20). Falls back
# to the working file if the path isn't a git repo or git/network is unavailable.
# Override path via REGISTRY_PATH=…; force the working file via REGISTRY_NO_GIT=1.
#
# Usage:
#   scripts/maintenance-report.sh os    [--dry-run] [--verbose] [--munin-token T]
#   scripts/maintenance-report.sh deps  [--dry-run] [--verbose] [--munin-token T]
set -euo pipefail

REPORT_VERSION="1.2.0"

# ── Registry path: grimnir owns the canonical host inventory ─────────────────
: "${REGISTRY_PATH:=/opt/grimnir/services.json}"
export REGISTRY_PATH

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="$REGISTRY_PATH"
# Cleaned up on exit if resolve_registry() snapshots the committed registry.
# Preserve the real exit code and avoid a short-circuiting `&&` as the trap's
# last command — under `set -e` a false `[[ -n … ]]` (no snapshot) would
# otherwise become the script's exit status and spuriously fail the run.
REGISTRY_SNAPSHOT=""
cleanup_registry_snapshot() {
  local rc=$?
  if [[ -n "${REGISTRY_SNAPSHOT:-}" ]]; then
    rm -f "$REGISTRY_SNAPSHOT" || true
  fi
  return "$rc"
}
trap cleanup_registry_snapshot EXIT
REGISTRY_JS="$SCRIPT_DIR/lib/registry.js"
REPOS_DIR="${REPOS_DIR:-$HOME/repos}"
DEPLOY_USER="${DEPLOY_USER:-brokkr}"

# shellcheck source=scripts/lib/munin.sh
source "$SCRIPT_DIR/lib/munin.sh"
# shellcheck source=scripts/lib/notify.sh
source "$SCRIPT_DIR/lib/notify.sh"

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_DATE="$(date -u +%Y-%m-%d)"
LOCAL_HOST="$(hostname -s)"
DISK_WARN_PCT=85

# ─── Args ────────────────────────────────────────────────────────────────────
MODE="${1:-}"; shift || true
DRY_RUN=false; VERBOSE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --munin-token) MUNIN_TOKEN="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
case "$MODE" in
  os|deps|brew) ;;
  *) echo "Usage: $0 {os|deps|brew} [--dry-run] [--verbose] [--munin-token T]" >&2; exit 1 ;;
esac

log_verbose() { $VERBOSE && echo "  $*" >&2 || true; }

# ── Canonical registry resolution ────────────────────────────────────────────
# grimnir owns services.json, but an operator checkout can also be a mutable
# automation workspace, so the working file can be stale or on the wrong branch
# (brokkr#20). The canonical registry is
# the COMMITTED origin default branch, not the working tree. Resolve REGISTRY to
# a snapshot of that ref (best-effort `fetch` first), so the report is immune to
# whatever automation last left checked out. Falls back to the plain working file when the
# path isn't in a git repo, or git/network is unavailable. Set REGISTRY_NO_GIT=1
# to force the working file (used by tests / offline overrides).
resolve_registry() {
  [[ "${REGISTRY_NO_GIT:-0}" == 1 ]] && return 0
  [[ -f "$REGISTRY" ]] || return 0
  local reg_dir reg_base repo_root rel ref snap
  reg_dir="$(cd "$(dirname "$REGISTRY")" 2>/dev/null && pwd)" || return 0
  reg_base="$(basename "$REGISTRY")"
  repo_root="$(git -C "$reg_dir" rev-parse --show-toplevel 2>/dev/null)" || return 0
  rel="${reg_dir#"$repo_root"}"; rel="${rel#/}"; rel="${rel:+$rel/}$reg_base"
  ref="$(git -C "$reg_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
  git -C "$reg_dir" fetch -q --no-tags origin 2>/dev/null || true
  snap="$(mktemp "${TMPDIR:-/tmp}/brokkr-registry.XXXXXX")" || return 0
  if git -C "$reg_dir" show "$ref:$rel" > "$snap" 2>/dev/null && [[ -s "$snap" ]]; then
    REGISTRY_SNAPSHOT="$snap"; REGISTRY="$snap"
    log_verbose "registry: using committed $ref:$rel (working tree bypassed)"
  else
    rm -f "$snap"
    log_verbose "registry: git snapshot unavailable — using working file $REGISTRY"
  fi
}
resolve_registry

munin_discover_token "$REPOS_DIR" || true
if [[ -z "${MUNIN_TOKEN:-}" ]]; then
  echo "WARNING: no Munin token found — Munin writes will be skipped" >&2
fi

# memory_write/memory_log wrappers honouring --dry-run and missing token.
report_write() {  # namespace key content tags_json
  $DRY_RUN && { log_verbose "[dry-run] memory_write $1/$2"; return 0; }
  [[ -z "${MUNIN_TOKEN:-}" ]] && return 0
  local args
  args=$(NS="$1" K="$2" C="$3" T="$4" node --input-type=commonjs -e '
    console.log(JSON.stringify({namespace:process.env.NS,key:process.env.K,content:process.env.C,tags:JSON.parse(process.env.T)}))') \
    || { echo "WARNING: Munin payload build failed ($1/$2)" >&2; return 0; }
  munin_tool_call memory_write "$args" >/dev/null || echo "WARNING: Munin write failed ($1/$2)" >&2
}
report_log() {    # namespace content tags_json
  $DRY_RUN && { log_verbose "[dry-run] memory_log $1"; return 0; }
  [[ -z "${MUNIN_TOKEN:-}" ]] && return 0
  local args
  args=$(NS="$1" C="$2" T="$3" node --input-type=commonjs -e '
    console.log(JSON.stringify({namespace:process.env.NS,content:process.env.C,tags:JSON.parse(process.env.T)}))') \
    || { echo "WARNING: Munin payload build failed ($1)" >&2; return 0; }
  munin_tool_call memory_log "$args" >/dev/null || echo "WARNING: Munin log failed ($1)" >&2
}
alert() { $DRY_RUN && { echo "  [dry-run] telegram: $1"; return 0; }; notify_telegram "$1"; }

# ═════════════════════════════════════════════════════════════════════════════
# OS MODE
# ═════════════════════════════════════════════════════════════════════════════
os_probe_cmd() {
cat <<'PROBE'
RR=no; [ -e /var/run/reboot-required ] && RR=yes
# Backup signal (Debian 13): needrestart kernel status >=2 means the running
# kernel is older than the installed one — a reboot is recommended.
if [ "$RR" = no ] && command -v needrestart >/dev/null 2>&1; then
  KSTA=$(needrestart -b 2>/dev/null | awk -F: '/NEEDRESTART-KSTA/{print $2+0}')
  [ "${KSTA:-0}" -ge 2 ] 2>/dev/null && RR=yes
fi
RRPKGS=0; [ -f /var/run/reboot-required.pkgs ] && RRPKGS=$(wc -l < /var/run/reboot-required.pkgs | tr -d ' ')
UU=$(dpkg -l unattended-upgrades 2>/dev/null | grep -c '^ii' || true)
if [ -x /usr/lib/update-notifier/apt-check ]; then
  AC=$(/usr/lib/update-notifier/apt-check 2>&1); ALLUP=${AC%;*}; SEC=${AC#*;}
else
  ALLUP=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)
  SEC=$(apt-get -s upgrade 2>/dev/null | awk '/^Inst/ && /security/{c++} END{print c+0}')
fi
DISK=$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
echo "REBOOT=$RR"; echo "REBOOT_PKGS=$RRPKGS"; echo "UU_INSTALLED=$UU"
echo "SEC_PENDING=${SEC:-0}"; echo "ALL_PENDING=${ALLUP:-0}"; echo "DISK=${DISK:-0}"; echo "KERNEL=$(uname -r)"

# ── Firmware status — mechanism auto-detected, DETECT+REPORT only ────────────
# rpi-eeprom handles Pi bootloader EEPROM; fwupd handles UEFI capsule/LVFS hosts;
# nvbootctrl-only Jetsons report as unmanaged. Applying firmware is a
# deliberate, scheduled, per-host step (reboot policy differs by host) — this
# layer only surfaces "pending". All probes are read-only and run unprivileged.
FW_MECH=none; FW_STATUS=unknown; FW_PENDING=0; FW_CUR=; FW_LAT=; FW_DETAIL=
if command -v rpi-eeprom-update >/dev/null 2>&1; then
  FW_MECH=rpi-eeprom
  FWOUT=$(rpi-eeprom-update 2>/dev/null || true)
  if [ -z "$FWOUT" ]; then FW_STATUS=unknown
  elif printf '%s' "$FWOUT" | grep -qi 'update available'; then FW_STATUS=update-available; FW_PENDING=1
  else FW_STATUS=current; fi
  FW_CUR=$(printf '%s' "$FWOUT" | sed -n 's/.*CURRENT:[[:space:]]*//p' | head -1 | sed 's/ *([0-9]*) *$//')
  FW_LAT=$(printf '%s' "$FWOUT" | sed -n 's/.*LATEST:[[:space:]]*//p' | head -1 | sed 's/ *([0-9]*) *$//')
  FW_DETAIL=$(printf '%s' "$FWOUT" | sed -n 's/.*RELEASE:[[:space:]]*\([^ ]*\).*/release=\1/p' | head -1)
elif command -v fwupdmgr >/dev/null 2>&1; then
  FW_MECH=fwupd
  # JSON is the source of truth: `get-upgrades --json` lists ONLY devices that
  # have a pending upgrade (empty {"Devices":[]} when current, even at exit 2).
  # Text output is the fallback for when JSON is unavailable/unparseable.
  FWPARSED=""
  if command -v python3 >/dev/null 2>&1; then
    FWPARSED=$(fwupdmgr get-upgrades --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR|"); sys.exit(0)
devs = d.get("Devices") or []
out = []
for dev in devs:
    rel = dev.get("Releases") or []
    ver = rel[0].get("Version", "?") if rel else "?"
    out.append(dev.get("Name", "?") + "->" + ver)
print(str(len(devs)) + "|" + ", ".join(out))' 2>/dev/null || true)
  fi
  FW_PENDING=${FWPARSED%%|*}; FW_DETAIL=${FWPARSED#*|}
  case "$FW_PENDING" in
    0)       FW_STATUS=current; FW_DETAIL= ;;
    [1-9]*)  FW_STATUS=update-available ;;
    *)       # JSON missing/unparseable (no python3, bad json, ERR): fall back to
             # the text signal, and fail LOUD as pending if it is not clearly current.
             FWOUT=$(LC_ALL=C fwupdmgr get-upgrades 2>&1 || true)
             if printf '%s' "$FWOUT" | grep -qiE 'No updates available|No updatable devices|No upgrades'; then
               FW_STATUS=current; FW_PENDING=0; FW_DETAIL=
             else
               FW_STATUS=update-available; FW_PENDING=1; FW_DETAIL="pending (fwupd enumeration unavailable)"
             fi ;;
  esac
elif command -v nvbootctrl >/dev/null 2>&1; then
  FW_MECH=jetson-nvboot; FW_STATUS=unmanaged; FW_DETAIL=nvbootctrl-only
fi
echo "FW_MECH=$FW_MECH"; echo "FW_STATUS=$FW_STATUS"; echo "FW_PENDING=${FW_PENDING:-0}"
echo "FW_CUR=$FW_CUR"; echo "FW_LAT=$FW_LAT"; echo "FW_DETAIL=$FW_DETAIL"
PROBE
}

# Resolve a host to a usable SSH target, mirroring deploy.sh/setup-host-patching:
# "LOCAL" if it's this machine, else user@.local, else user@bare (Tailscale),
# else empty (unreachable). Avoids a transient mDNS blip false-flagging a host.
# SSH options shared by every probe: BatchMode (never prompt) + accept-new so a
# first-contact node's host key is auto-added (refuses a CHANGED key — safe),
# which matters for newly discovered inventory nodes the local host has not
# contacted before.
SSH_OPTS=(-o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

resolve_remote() {
  local host="$1" short="${1%%.*}" bare="${1%.local}"
  if [[ "$short" == "$LOCAL_HOST" ]]; then echo "LOCAL"; return 0; fi
  if ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$host" true 2>/dev/null; then
    echo "$DEPLOY_USER@$host"; return 0; fi
  if [[ "$bare" != "$host" ]] && ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$bare" true 2>/dev/null; then
    echo "$DEPLOY_USER@$bare"; return 0; fi
  return 1
}

run_os() {
  echo "Brokkr OS maintenance report — $TIMESTAMP (v$REPORT_VERSION)"
  echo

  # Deploy-tier: the service-deploy targets — the critical service substrate.
  # Always fully reported AND alerted.
  local DEPLOY_HOSTS=()
  while IFS= read -r h; do
    [[ -n "$h" ]] && DEPLOY_HOSTS+=("$h")
  done < <(REGISTRY_PATH="$REGISTRY" QUERY=deploy \
    node --input-type=commonjs "$REGISTRY_JS" | cut -d'|' -f3 | grep -v '^$' | sort -u)
  [[ ${#DEPLOY_HOSTS[@]} -gt 0 ]] || { echo "No deploy hosts found in $REGISTRY" >&2; exit 1; }

  # Node-tier: active infra/inference nodes from the hardware inventory
  # (services.json → nodes) that aren't already deploy targets — e.g. m5, orin,
  # skald. Extends firmware/OS visibility to the whole substrate (brokkr#9, #12,
  # #18). BEST-EFFORT: an unreachable node is recorded but NOT alerted, and only
  # a pending-firmware finding raises Telegram (OS-patch conditions surface in
  # Munin/Heimdall without alert noise on these newly-monitored hosts).
  # Resolved via each node's hostname (preferred) or ssh_alias; nodes with
  # neither (not-yet-provisioned) are skipped — this tracks grimnir keeping the
  # node hostnames current (grimnir#41).
  local NODE_HOSTS=()
  while IFS='|' read -r _ n_host n_alias _ n_status _rest; do
    [[ "$n_status" == "active" ]] || continue
    local nh="${n_host:-$n_alias}"
    [[ -n "$nh" ]] || continue
    local nshort="${nh%%.*}" dup=0 dh
    [[ "$nshort" == "$LOCAL_HOST" ]] && continue
    for dh in "${DEPLOY_HOSTS[@]}"; do
      [[ "${dh%%.*}" == "$nshort" ]] && { dup=1; break; }
    done
    [[ "$dup" == 0 ]] && NODE_HOSTS+=("$nh")
  done < <(REGISTRY_PATH="$REGISTRY" QUERY=nodes \
    node --input-type=commonjs "$REGISTRY_JS")

  # Combined, tier-tagged worklist: "deploy|host" and "node|host". Guard the
  # NODE_HOSTS expansion: it can be empty, and under `set -u` bash 3.2/4.3 abort
  # on "${empty[@]}"; this script deliberately supports bash 3.2+.
  local ENTRIES=() e
  for e in "${DEPLOY_HOSTS[@]}"; do ENTRIES+=("deploy|$e"); done
  if [[ ${#NODE_HOSTS[@]} -gt 0 ]]; then
    for e in "${NODE_HOSTS[@]}"; do ENTRIES+=("node|$e"); done
  fi

  local probe; probe="$(os_probe_cmd)"
  local summary="OS patch status ($RUN_DATE):" alerts="" any_action=false

  for entry in "${ENTRIES[@]}"; do
    local tier="${entry%%|*}" host="${entry#*|}"
    local short="${host%%.*}" blob target
    echo "▶ $host ($tier)"
    if target="$(resolve_remote "$host")"; then
      if [[ "$target" == "LOCAL" ]]; then
        blob="$(bash -c "$probe" 2>/dev/null || true)"
      else
        blob="$(ssh "${SSH_OPTS[@]}" "$target" "$probe" 2>/dev/null || true)"
      fi
    else
      target=""; blob=""
    fi
    if [[ -z "$blob" ]]; then
      echo "  unreachable"
      # Overwrite per-host latest so consumers don't keep seeing a stale
      # "healthy" value (both OS and firmware) while the host is unreachable.
      report_write "maintenance/os/$short" "latest" \
        "$short OS status @ $TIMESTAMP"$'\n'"  $short: UNREACHABLE" \
        "[\"maintenance\",\"os\",\"$short\",\"automated\",\"error\"]"
      report_write "maintenance/firmware/$short" "latest" \
        "$short firmware @ $TIMESTAMP: mech=unknown, status=unreachable, pending=0" \
        "[\"maintenance\",\"firmware\",\"$short\",\"automated\",\"error\"]"
      if [[ "$tier" == "node" ]]; then
        # Best-effort node (may be legitimately powered off, e.g. orin) —
        # record it, but do NOT alert or flag action.
        summary+=$'\n'"  $short: unreachable (node, best-effort)"
      else
        summary+=$'\n'"  $short: UNREACHABLE"
        alerts+=$'\n'"⚠️ $short unreachable for OS maintenance check"
        any_action=true
      fi
      continue
    fi
    local rr rrpkgs uu sec all disk kern
    rr=$(grep '^REBOOT=' <<<"$blob" | cut -d= -f2)
    rrpkgs=$(grep '^REBOOT_PKGS=' <<<"$blob" | cut -d= -f2)
    uu=$(grep '^UU_INSTALLED=' <<<"$blob" | cut -d= -f2)
    sec=$(grep '^SEC_PENDING=' <<<"$blob" | cut -d= -f2)
    all=$(grep '^ALL_PENDING=' <<<"$blob" | cut -d= -f2)
    disk=$(grep '^DISK=' <<<"$blob" | cut -d= -f2)
    kern=$(grep '^KERNEL=' <<<"$blob" | cut -d= -f2)

    # Tolerant extraction: a truncated blob (OS lines present but FW_* cut off)
    # must not abort os-mode under set -euo pipefail — default each field.
    local fw_mech fw_status fw_pending fw_cur fw_lat fw_detail
    fw_mech=$(grep -m1 '^FW_MECH=' <<<"$blob" | cut -d= -f2 || true);   fw_mech="${fw_mech:-none}"
    fw_status=$(grep -m1 '^FW_STATUS=' <<<"$blob" | cut -d= -f2 || true); fw_status="${fw_status:-unknown}"
    fw_pending=$(grep -m1 '^FW_PENDING=' <<<"$blob" | cut -d= -f2 || true)
    fw_cur=$(grep -m1 '^FW_CUR=' <<<"$blob" | cut -d= -f2- || true)
    fw_lat=$(grep -m1 '^FW_LAT=' <<<"$blob" | cut -d= -f2- || true)
    fw_detail=$(grep -m1 '^FW_DETAIL=' <<<"$blob" | cut -d= -f2- || true)

    # Sanitize numeric fields — apt-check writes to stderr and can emit a
    # non-numeric error (e.g. apt-lock contention); a non-numeric value would
    # make the `[[ x -gt 0 ]]` tests below return 2 and abort under set -e.
    local v
    for v in rrpkgs uu sec all disk fw_pending; do
      case "${!v}" in *[!0-9]*|'') printf -v "$v" '%s' 0 ;; esac
    done

    # Human-readable description of what firmware update is pending (mechanism
    # dependent: Pi EEPROM reports a current→latest date pair, fwupd reports
    # device->version names).
    local fw_desc=""
    if [[ "$fw_pending" -gt 0 ]] 2>/dev/null; then
      if [[ "$fw_mech" == "rpi-eeprom" ]]; then fw_desc="${fw_cur:-?} → ${fw_lat:-?}"
      else fw_desc="${fw_detail:-pending}"; fi
    fi

    printf "  reboot=%s(%s) security_pending=%s all_pending=%s uu=%s disk=%s%% kernel=%s\n" \
      "$rr" "$rrpkgs" "$sec" "$all" "$uu" "$disk" "$kern"
    printf "  firmware[%s]=%s pending=%s%s\n" \
      "$fw_mech" "$fw_status" "$fw_pending" "${fw_desc:+ ($fw_desc)}"

    local line="  $short: security_pending=$sec, all_pending=$all, reboot=$rr, disk=${disk}%, uu_installed=$uu, kernel=$kern, firmware=$fw_mech:$fw_status${fw_desc:+ ($fw_desc)}"
    summary+=$'\n'"$line"

    # Per-host Munin state
    report_write "maintenance/os/$short" "latest" \
      "$short OS status @ $TIMESTAMP"$'\n'"$line" \
      "[\"maintenance\",\"os\",\"$short\",\"automated\"]"
    # Dedicated firmware namespace so Heimdall / the faults layer (brokkr#8) can
    # consume firmware state independently of the OS-patch state.
    report_write "maintenance/firmware/$short" "latest" \
      "$short firmware @ $TIMESTAMP: mech=$fw_mech, status=$fw_status, pending=$fw_pending${fw_desc:+ — $fw_desc}${fw_cur:+ (cur=$fw_cur, lat=$fw_lat)}" \
      "[\"maintenance\",\"firmware\",\"$short\",\"$fw_mech\",\"automated\"]"

    # OS-condition alerts fire for deploy-tier (critical service hosts) only;
    # node-tier OS status is recorded to Munin but not alerted, to avoid surprise
    # alert storms on newly-monitored inference hosts.
    if [[ "$tier" == "deploy" ]]; then
      [[ "$rr" == "yes" ]] && { alerts+=$'\n'"🔁 $short needs a REBOOT ($rrpkgs pkg(s)): $(ssh_pkglist "$target")"; any_action=true; }
      [[ "${sec:-0}" -gt 0 ]] 2>/dev/null && { alerts+=$'\n'"🔒 $short has $sec security update(s) still pending"; any_action=true; }
      [[ "${uu:-0}" -eq 0 ]] 2>/dev/null && { alerts+=$'\n'"❗ $short: unattended-upgrades NOT installed"; any_action=true; }
      [[ "${disk:-0}" -ge "$DISK_WARN_PCT" ]] 2>/dev/null && { alerts+=$'\n'"💾 $short disk at ${disk}%"; any_action=true; }
    fi
    # Firmware-pending alerts fire for EVERY tier — surfacing a pending firmware
    # update is the point of the node sweep (brokkr#9, #12).
    [[ "${fw_pending:-0}" -gt 0 ]] 2>/dev/null && { alerts+=$'\n'"🧩 $short firmware update available ($fw_mech): ${fw_desc:-pending} — apply+reboot is a scheduled manual step"; any_action=true; }
  done

  echo
  echo "$summary"

  report_write "maintenance/os/$RUN_DATE" "summary" "$summary" \
    "[\"maintenance\",\"os\",\"automated\"]"
  report_log "maintenance/" "OS maintenance report run @ $TIMESTAMP — action_needed=$any_action" \
    "[\"maintenance\",\"os-event\",\"automated\"]"

  if $any_action && [[ -n "$alerts" ]]; then
    alert "🛠️ Brokkr OS maintenance ($RUN_DATE)${alerts}"
  fi
  echo
  $any_action && echo "Action needed (alert sent)." || echo "All hosts patched & healthy."
}

# Best-effort fetch of the reboot-required package list for the alert.
# Arg is a resolved target from resolve_remote ("LOCAL" or user@host).
ssh_pkglist() {  # target
  local target="$1" cmd='head -3 /var/run/reboot-required.pkgs 2>/dev/null | tr "\n" "," | sed "s/,$//"'
  if [[ "$target" == "LOCAL" ]]; then bash -c "$cmd" 2>/dev/null || true
  else ssh "${SSH_OPTS[@]}" "$target" "$cmd" 2>/dev/null || true; fi
}

# ═════════════════════════════════════════════════════════════════════════════
# DEPS MODE
# ═════════════════════════════════════════════════════════════════════════════
run_deps() {
  echo "Brokkr npm dependency report — $TIMESTAMP (v$REPORT_VERSION)"
  echo

  local repos; repos="$(REGISTRY_PATH="$REGISTRY" QUERY=scan node --input-type=commonjs "$REGISTRY_JS")"
  local summary="npm outdated ($RUN_DATE):" grand_total=0 grand_major=0 checked=0 errors=0

  for repo in $repos; do
    local dir="$REPOS_DIR/$repo"
    if [[ ! -f "$dir/package.json" ]]; then
      log_verbose "skip $repo (no package.json under $dir)"; continue
    fi
    checked=$((checked + 1))
    local out rc counts total major
    # npm outdated exits 0 when up to date, 1 when packages ARE outdated, and
    # nonzero with empty/invalid stdout on a real error (network/registry).
    # Capture both stdout and exit code so a failed check isn't read as "0".
    set +e
    out="$(cd "$dir" && npm_config_cache="${npm_config_cache:-/tmp/npm-cache}" npm outdated --json 2>/dev/null)"
    rc=$?
    set -e
    counts="$(OUT="$out" RC="$rc" node --input-type=commonjs -e '
      const out=(process.env.OUT||"").trim(), rc=process.env.RC||"0";
      let o;
      try { o = out === "" ? {} : JSON.parse(out); }
      catch (e) { process.stdout.write("ERR"); process.exit(0); }
      // Error states (only when rc!=0): empty output, or npm error envelope
      // {"error":{code,summary,...}}. Distinguish that from a real dependency
      // literally named "error" (which has current/wanted/latest fields).
      const errEnv = o && o.error && typeof o.error === "object" &&
        !("latest" in o.error || "current" in o.error || "wanted" in o.error);
      if (rc !== "0" && (out === "" || errEnv)) { process.stdout.write("ERR"); process.exit(0); }
      let total=0, major=0;
      for (const k of Object.keys(o)) {
        const e = o[k];
        if (!e || typeof e !== "object") continue;   // skip non-dependency entries
        total++;
        const cur=(e.current||e.wanted||"0").split(".")[0];
        const lat=(e.latest||"0").split(".")[0];
        if (Number(lat) > Number(cur)) major++;
      }
      process.stdout.write(total+" "+major);
    ')"
    if [[ "$counts" == "ERR" ]]; then
      errors=$((errors + 1))
      printf "  %-16s CHECK FAILED (npm rc=%s)\n" "$repo" "$rc"
      summary+=$'\n'"  $repo: CHECK FAILED"
      report_write "maintenance/deps/$repo" "latest" \
        "$repo dependency check FAILED @ $TIMESTAMP (npm outdated rc=$rc)" \
        "[\"maintenance\",\"deps\",\"$repo\",\"automated\",\"error\"]"
      continue
    fi
    total="${counts%% *}"; major="${counts##* }"
    grand_total=$((grand_total + total)); grand_major=$((grand_major + major))

    printf "  %-16s outdated=%s (major=%s)\n" "$repo" "$total" "$major"
    summary+=$'\n'"  $repo: outdated=$total, major=$major"
    report_write "maintenance/deps/$repo" "latest" \
      "$repo outdated deps @ $TIMESTAMP: total=$total, major=$major" \
      "[\"maintenance\",\"deps\",\"$repo\",\"automated\"]"
  done

  summary+=$'\n'"TOTAL: $grand_total outdated across $checked repos ($grand_major major); $errors check error(s)"
  echo
  echo "$summary"

  report_write "maintenance/deps/$RUN_DATE" "summary" "$summary" \
    "[\"maintenance\",\"deps\",\"automated\"]"
  report_log "maintenance/" "npm dependency report run @ $TIMESTAMP — $grand_total outdated ($grand_major major) across $checked repos, $errors error(s)" \
    "[\"maintenance\",\"deps-event\",\"automated\"]"

  if [[ "$grand_total" -gt 0 || "$errors" -gt 0 ]]; then
    alert "📦 Brokkr deps ($RUN_DATE): $grand_total outdated across $checked repos ($grand_major major bump(s)), $errors check error(s). Review & bump deliberately.${summary#npm outdated ($RUN_DATE):}"
  fi
  echo
  echo "Done — detect+report only, nothing auto-applied."
}

# ═════════════════════════════════════════════════════════════════════════════
# BREW MODE — reports a laptop Homebrew run forwarded over SSH from the laptop.
# Data arrives via env (heredoc-free single ssh command, robust under launchd):
#   BREW_SUMMARY_B64  base64 of the one-line summary
#   BREW_NCASKS       count of casks needing manual upgrade (>0 ⇒ Telegram)
#   BREW_ALERT        "1" if the laptop run had update/upgrade failures (⇒ Telegram)
# ═════════════════════════════════════════════════════════════════════════════
run_brew() {
  local summary ncasks balert
  summary="$(printf '%s' "${BREW_SUMMARY_B64:-}" | base64 -d 2>/dev/null || true)"
  [[ -n "$summary" ]] || summary="brew (laptop) @ $TIMESTAMP: (no summary provided)"
  ncasks="${BREW_NCASKS:-0}"
  case "$ncasks" in *[!0-9]*|'') ncasks=0 ;; esac
  balert="${BREW_ALERT:-0}"
  echo "$summary"

  report_write "maintenance/brew/laptop" "latest" "$summary" \
    "[\"maintenance\",\"brew\",\"laptop\",\"automated\"]"
  report_log "maintenance/" "brew laptop report @ $TIMESTAMP — $ncasks cask(s) need manual upgrade, alert=$balert" \
    "[\"maintenance\",\"brew-event\",\"automated\"]"

  { [[ "$ncasks" -gt 0 ]] || [[ "$balert" == "1" ]]; } && alert "🍺 $summary"
  echo "Done."
}

case "$MODE" in
  os) run_os ;;
  deps) run_deps ;;
  brew) run_brew ;;
esac
