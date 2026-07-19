#!/usr/bin/env bash
#
# setup-host-patching.sh — install & configure unattended-upgrades on every Pi
# host in services.json, so OS security patches apply automatically.
#
# Idempotent: safe to re-run. Installs the `unattended-upgrades` package, pushes
# Brokkr's version-controlled apt config (apt/*), and ensures the
# stock apt-daily timers are enabled. Does NOT enable automatic reboots — see
# apt/50unattended-upgrades and docs/scheduled-tasks.md in grimnir.
#
# Usage:
#   scripts/setup-host-patching.sh                 # all deploy hosts
#   scripts/setup-host-patching.sh control-node   # one host
#   scripts/setup-host-patching.sh --dry-run       # show actions, change nothing
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

[[ -f "$APT_DIR/20auto-upgrades" && -f "$APT_DIR/50unattended-upgrades" ]] || {
  echo -e "${RED}Missing apt config under $APT_DIR${NC}" >&2; exit 1; }

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

  if $DRY_RUN; then
    echo "  would: apt-get install -y unattended-upgrades"
    echo "  would: push 20auto-upgrades + 50unattended-upgrades to /etc/apt/apt.conf.d/"
    echo "  would: enable apt-daily.timer apt-daily-upgrade.timer; validate with --dry-run"
    results+=("${YELLOW}?${NC} $host (dry-run)")
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

  # 2. Push the version-controlled config (cat → sudo tee, NOPASSWD).
  echo "  syncing apt config…"
  if ! ssh "$remote" "sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null" < "$APT_DIR/20auto-upgrades" \
     || ! ssh "$remote" "sudo tee /etc/apt/apt.conf.d/50unattended-upgrades >/dev/null" < "$APT_DIR/50unattended-upgrades"; then
    echo -e "  ${RED}failed to write apt config${NC}"
    results+=("${RED}✗${NC} $host (config push)")
    fail_count=$((fail_count + 1))
    continue
  fi

  # 3. Ensure the stock timers are enabled (idempotent). These drive the
  #    actual unattended-upgrade runs, so a failure here is a real failure.
  if ! ssh "$remote" "sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1"; then
    echo -e "  ${RED}failed to enable apt timers${NC}"
    results+=("${RED}✗${NC} $host (timer enable)")
    fail_count=$((fail_count + 1))
    continue
  fi

  # 4. Validate the config parses and origins resolve — the confirmation that
  #    this host will actually apply security upgrades. A failure counts.
  echo "  validating…"
  if ssh "$remote" "sudo unattended-upgrade --dry-run >/dev/null 2>&1"; then
    echo -e "  ${GREEN}OK${NC}"
    results+=("${GREEN}✓${NC} $host")
  else
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
