#!/usr/bin/env bash
#
# setup-host-patching.sh — install & configure unattended-upgrades on the fleet
# hosts, so OS security AND regular updates apply automatically (Grimnir ADR-009).
#
# Idempotent: safe to re-run. Per host it first detects the OS over the same SSH
# path (/etc/os-release ID / ID_LIKE) and pushes only the files that fit it:
#   * Debian family (debian, raspbian, or ID_LIKE debian without ubuntu):
#     20auto-upgrades, 50unattended-upgrades (security baseline) and
#     51brokkr-claude-code, plus 52brokkr-debian-updates on approved hosts.
#   * Ubuntu: NEVER overwrites the distribution's 20auto-upgrades or
#     50unattended-upgrades; pushes 51brokkr-claude-code, plus
#     52brokkr-ubuntu-updates on approved hosts, and fails the host if the
#     distribution's 20auto-upgrades does not enable
#     APT::Periodic::Unattended-Upgrade "1".
#   * Anything else: the host fails and nothing is changed on it.
#
# Regular updates (the 52brokkr-* drop-in) are owner-approved per host, not per OS
# family (ADR-009): BROKKR_REGULAR_UPDATE_HOSTS is a whitespace-separated list of
# the approved hosts, matched against the host as given, without ".local", or its
# short name; letters, digits, dot, underscore and hyphen only. It is empty by
# default and is read from the operator's runtime environment; real IDs are never
# committed. An invalid entry aborts the run (exit 2) before any host is touched.
# A host that is not listed gets only its security baseline, and a 52brokkr-*
# drop-in already present there is removed (sudo rm -f) and reported.
# It also installs unattended-upgrades + needrestart, enables the stock apt-daily
# timers, validates with `unattended-upgrade --dry-run`, and prints the effective
# "Allowed origins" line so the operator sees what will really be applied.
# It does NOT enable automatic reboots: reboots belong to Brokkr's guarded-reboot
# job (see apt/50unattended-upgrades and apt/README.md).
#
# Usage:
#   scripts/setup-host-patching.sh                 # all deploy hosts
#   scripts/setup-host-patching.sh control-node    # one host
#   scripts/setup-host-patching.sh --dry-run       # report OS + files, change nothing
#
# The host list comes from the registry when no host is named. A node that is
# not one of the registry's deploy hosts (e.g. an Ubuntu inference node) is
# patched by naming it explicitly, with DEPLOY_USER set to a user that has
# NOPASSWD sudo there:
#   DEPLOY_USER=<operator> scripts/setup-host-patching.sh <node>
#
# Runtime coupling: reads the host registry from REGISTRY_PATH (defaults to
# /opt/grimnir/services.json — grimnir owns the canonical inventory).
# Override via: REGISTRY_PATH=/path/to/services.json ./scripts/setup-host-patching.sh
#
# Relies on the same non-interactive, NOPASSWD-sudo SSH model as deploy.sh.
set -euo pipefail

# ── Registry path: grimnir owns the canonical host inventory ─────────────────
: "${REGISTRY_PATH:=/opt/grimnir/services.json}"
export REGISTRY_PATH

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BROKKR_DIR="$(dirname "$SCRIPT_DIR")"
REGISTRY="$REGISTRY_PATH"
REGISTRY_JS="$SCRIPT_DIR/lib/registry.js"
APT_DIR="$BROKKR_DIR/apt"
DEPLOY_USER="${DEPLOY_USER:-brokkr}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

DRY_RUN=false
HOST_FILTER=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) HOST_FILTER+=("$1"); shift ;;
  esac
done

for f in 20auto-upgrades 50unattended-upgrades 51brokkr-claude-code \
         52brokkr-debian-updates 52brokkr-ubuntu-updates; do
  [[ -f "$APT_DIR/$f" ]] || { echo -e "${RED}Missing apt config $APT_DIR/$f${NC}" >&2; exit 1; }
done

# ─── Hosts approved for regular updates (ADR-009) ────────────────────────────
# Validated before any host is contacted: ignoring a bad entry would silently
# strip regular updates (and remove the drop-in) from the host it was meant to
# approve, so an invalid entry fails closed. The entry text is not echoed.
REGULAR_HOSTS=()
id_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
regular_raw="$(printf '%s' "${BROKKR_REGULAR_UPDATE_HOSTS:-}" | tr -s '[:space:]' ' ')"
if [[ -n "${regular_raw// /}" ]]; then
  read -r -a regular_list <<<"$regular_raw"
  for regular_id in "${regular_list[@]}"; do
    if [[ "$regular_id" =~ $id_re ]]; then
      REGULAR_HOSTS+=("$regular_id")
    else
      echo -e "${RED}BROKKR_REGULAR_UPDATE_HOSTS has an invalid entry (letters, digits, dot, underscore, hyphen only) — nothing changed${NC}" >&2
      exit 2
    fi
  done
fi

# host_is_regular HOST: is HOST approved for regular updates? Matches the host as
# given, without .local, or its short name.
host_is_regular() {
  local host="$1" id
  [[ ${#REGULAR_HOSTS[@]} -gt 0 ]] || return 1
  for id in "${REGULAR_HOSTS[@]}"; do
    [[ "$id" == "$host" || "$id" == "${host%.local}" || "$id" == "${host%%.*}" ]] && return 0
  done
  return 1
}

# ─── Derive unique deploy hosts from services.json ───────────────────────────
# (portable: no mapfile — this script runs on the macOS laptop / bash 3.2)
HOSTS=()
if [[ ${#HOST_FILTER[@]} -gt 0 ]]; then
  HOSTS=("${HOST_FILTER[@]}")
else
  while IFS= read -r h; do
    [[ -n "$h" ]] && HOSTS+=("$h")
  done < <(REGISTRY_PATH="$REGISTRY" QUERY=deploy \
    node --input-type=commonjs "$REGISTRY_JS" | cut -d'|' -f3 | grep -v '^$' | sort -u)
fi

[[ ${#HOSTS[@]} -gt 0 ]] || { echo "No hosts."; exit 1; }
echo "Hosts: ${HOSTS[*]}"
$DRY_RUN && echo -e "${YELLOW}DRY RUN — no changes will be made${NC}"
echo

# Resolve a reachable user@host: try the .local name, then the bare name over
# Tailscale (mirrors deploy.sh's resolve_host — mDNS can flake under automation).
resolve_remote() {
  local host="$1" bare="${1%.local}"
  if ssh -o ConnectTimeout=6 -o BatchMode=yes "$DEPLOY_USER@$host" true 2>/dev/null; then
    echo "$DEPLOY_USER@$host"; return 0
  fi
  if [[ "$bare" != "$host" ]] && ssh -o ConnectTimeout=6 -o BatchMode=yes "$DEPLOY_USER@$bare" true 2>/dev/null; then
    echo "$DEPLOY_USER@$bare"; return 0
  fi
  return 1
}

# Detect the remote OS family from /etc/os-release. Prints debian, ubuntu or
# unknown. The remote values are untrusted text: they are reduced to a
# conservative character set before use and only ever compared, never evaluated.
detect_os() {
  local remote="$1" out id="" like="" line
  out="$(ssh "$remote" '( unset ID ID_LIKE; . /etc/os-release 2>/dev/null && printf "ID=%s\nID_LIKE=%s\n" "${ID:-}" "${ID_LIKE:-}" )' 2>/dev/null)" || true
  while IFS= read -r line; do
    case "$line" in
      ID=*)      id="$(printf '%s' "${line#ID=}" | tr -cd 'A-Za-z0-9._ -' | tr 'A-Z' 'a-z')" ;;
      ID_LIKE=*) like="$(printf '%s' "${line#ID_LIKE=}" | tr -cd 'A-Za-z0-9._ -' | tr 'A-Z' 'a-z')" ;;
    esac
  done <<<"$out"
  case "$id" in
    ubuntu)         echo ubuntu; return 0 ;;
    debian|raspbian) echo debian; return 0 ;;
  esac
  case " $like " in
    *" ubuntu "*) echo unknown; return 0 ;;
    *" debian "*) echo debian; return 0 ;;
  esac
  echo unknown
}

# The files Brokkr pushes per OS family (names under apt/ and /etc/apt/apt.conf.d/):
# the security baseline for every host, plus the 52brokkr drop-in on approved hosts.
files_for_os() {  # os_family regular(true|false)
  local extra=""
  case "$1" in
    debian)
      if [[ "$2" == true ]]; then extra=" 52brokkr-debian-updates"; fi
      echo "20auto-upgrades 50unattended-upgrades 51brokkr-claude-code$extra" ;;
    ubuntu)
      if [[ "$2" == true ]]; then extra=" 52brokkr-ubuntu-updates"; fi
      echo "51brokkr-claude-code$extra" ;;
  esac
}
# Every regular-update drop-in Brokkr ever installed; any that is not wanted is removed.
ALL_REGULAR_DROPINS="52brokkr-debian-updates 52brokkr-ubuntu-updates"

results=()
fail_count=0
for host in "${HOSTS[@]}"; do
  echo -e "${YELLOW}▶ $host${NC}"

  if ! remote="$(resolve_remote "$host")"; then
    echo -e "  ${RED}unreachable (.local and Tailscale bare name both failed)${NC}"
    results+=("${RED}✗${NC} $host (unreachable)")
    fail_count=$((fail_count + 1))
    continue
  fi
  [[ "$remote" != "$DEPLOY_USER@$host" ]] && echo "  resolved via $remote"

  # 0. Detect the OS first (read-only, also in --dry-run). An unsupported OS
  #    fails the host before any package or configuration change.
  os_family="$(detect_os "$remote")"
  if [[ "$os_family" == unknown ]]; then
    echo -e "  ${RED}unsupported OS (not Debian family or Ubuntu per /etc/os-release) — nothing changed${NC}"
    results+=("${RED}✗${NC} $host (unsupported OS)")
    fail_count=$((fail_count + 1))
    continue
  fi
  regular=false
  host_is_regular "$host" && regular=true
  files="$(files_for_os "$os_family" "$regular")"
  echo "  OS: $os_family"
  if $regular; then
    echo "  regular updates: enabled (host is listed in BROKKR_REGULAR_UPDATE_HOSTS)"
    update_mode="regular updates"
  else
    echo "  regular updates: not enabled (host is not listed in BROKKR_REGULAR_UPDATE_HOSTS); security baseline only"
    update_mode="security baseline"
  fi
  # Brokkr regular-update drop-ins this host must not have: all of them except the
  # one it is approved for. Anything present is removed (a stale drop-in would
  # keep applying regular updates on an unapproved host).
  unwanted=""
  for f in $ALL_REGULAR_DROPINS; do
    [[ " $files " == *" $f "* ]] || unwanted+="${unwanted:+ }$f"
  done

  if $DRY_RUN; then
    for f in $unwanted; do
      rc=0; ssh "$remote" "[ -e /etc/apt/apt.conf.d/$f ]" || rc=$?
      if [[ "$rc" -eq 0 ]]; then echo "  would: remove $f (present; not approved for this host)"; fi
    done
    echo "  would: apt-get install -y unattended-upgrades needrestart"
    if [[ "$os_family" == ubuntu ]]; then
      echo "  would: verify the distribution's 20auto-upgrades enables APT::Periodic::Unattended-Upgrade \"1\" (never overwritten)"
    fi
    echo "  would: push ${files// / + } to /etc/apt/apt.conf.d/"
    echo "  would: enable apt-daily.timer apt-daily-upgrade.timer; validate with --dry-run"
    results+=("${YELLOW}?${NC} $host ($os_family, $update_mode, dry-run)")
    continue
  fi

  # 1. Refresh package lists (stale lists cause 404s on install), then install
  #    the patcher + needrestart (on Debian 13/trixie needrestart is what
  #    creates the /var/run/reboot-required flag the OS report relies on; the
  #    old update-notifier-common is gone). Idempotent.
  echo "  apt-get update…"
  ssh "$remote" "sudo DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || true"
  echo "  installing unattended-upgrades + needrestart…"
  if ! ssh "$remote" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades needrestart >/dev/null 2>&1"; then
    echo -e "  ${RED}apt install failed${NC}"
    results+=("${RED}✗${NC} $host (apt install)")
    fail_count=$((fail_count + 1))
    continue
  fi

  # 2. Ubuntu keeps its own 20auto-upgrades / 50unattended-upgrades. Checked
  #    after the install (the package ships 20auto-upgrades) and before any push,
  #    so a host that would not run unattended-upgrades gets no config at all.
  if [[ "$os_family" == ubuntu ]] && ! ssh "$remote" \
      "grep -Eq '^[[:space:]]*APT::Periodic::Unattended-Upgrade[[:space:]]+\"1\"' /etc/apt/apt.conf.d/20auto-upgrades"; then
    echo -e "  ${RED}/etc/apt/apt.conf.d/20auto-upgrades is missing or does not enable APT::Periodic::Unattended-Upgrade \"1\".${NC}"
    echo -e "  ${RED}Brokkr never overwrites the distribution's file on Ubuntu; enable it there, then re-run.${NC}"
    results+=("${RED}✗${NC} $host (periodic unattended-upgrade not enabled)")
    fail_count=$((fail_count + 1))
    continue
  fi

  # 3. Remove any Brokkr regular-update drop-in this host is not approved for
  #    (existence is checked first so the run can say what it removed).
  for f in $unwanted; do
    rc=0; ssh "$remote" "[ -e /etc/apt/apt.conf.d/$f ]" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      if ssh "$remote" "sudo rm -f /etc/apt/apt.conf.d/$f"; then
        echo "  removed $f (not approved for this host)"
      else
        echo -e "  ${RED}failed to remove $f${NC}"
        results+=("${RED}✗${NC} $host (stale drop-in removal)")
        fail_count=$((fail_count + 1))
        continue 2
      fi
    elif [[ "$rc" -ne 1 ]]; then
      echo -e "  ${RED}could not check for $f (ssh rc=$rc)${NC}"
      results+=("${RED}✗${NC} $host (stale drop-in check)")
      fail_count=$((fail_count + 1))
      continue 2
    fi
  done

  # 4. Push the version-controlled config (cat → sudo tee, NOPASSWD).
  echo "  syncing apt config (${files// /, })…"
  push_ok=true
  for f in $files; do
    if ! ssh "$remote" "sudo tee /etc/apt/apt.conf.d/$f >/dev/null" < "$APT_DIR/$f"; then
      push_ok=false; break
    fi
  done
  if ! $push_ok; then
    echo -e "  ${RED}failed to write apt config${NC}"
    results+=("${RED}✗${NC} $host (config push)")
    fail_count=$((fail_count + 1))
    continue
  fi

  # 5. Ensure the stock timers are enabled (idempotent). These drive the
  #    actual unattended-upgrade runs, so a failure here is a real failure.
  if ! ssh "$remote" "sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1"; then
    echo -e "  ${RED}failed to enable apt timers${NC}"
    results+=("${RED}✗${NC} $host (timer enable)")
    fail_count=$((fail_count + 1))
    continue
  fi

  # 6. Validate the config parses and origins resolve — the confirmation that
  #    this host will actually apply the intended upgrades — and show the
  #    effective origins. A failure counts.
  echo "  validating…"
  if uu_out="$(ssh "$remote" "sudo unattended-upgrade --dry-run -d 2>&1")"; then
    origins="$(printf '%s\n' "$uu_out" | grep -i -m1 'allowed origins' || true)"
    echo "  ${origins:-Allowed origins: (no such line in unattended-upgrade -d output)}"
    echo -e "  ${GREEN}OK${NC}"
    results+=("${GREEN}✓${NC} $host ($os_family, $update_mode)")
  else
    printf '%s\n' "$uu_out" | tail -n 5 | sed 's/^/    /'
    echo -e "  ${RED}validation failed (unattended-upgrade --dry-run) — check journalctl${NC}"
    results+=("${RED}✗${NC} $host (validate)")
    fail_count=$((fail_count + 1))
  fi
done

echo
echo "── Summary ──"
for r in "${results[@]}"; do echo -e "  $r"; done

# Non-zero exit if any host hard-failed — unreachable, apt install, config push,
# timer enable, or dry-run validation all count — so `make patching` surfaces
# failures to callers/CI rather than reporting success.
if [[ $fail_count -gt 0 ]]; then
  echo -e "${RED}${fail_count} host(s) failed${NC}"
  exit 1
fi
