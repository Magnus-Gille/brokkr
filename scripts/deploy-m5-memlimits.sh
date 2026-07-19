#!/usr/bin/env bash
set -euo pipefail

# Brokkr · install the per-service memory limits on m5 (brokkr#5). Runs ON m5.
#
# Prevents one runaway service from OOM-killing unrelated work — especially unattended
# overnight agentic runs. Installs the version-controlled drop-ins under systemd/m5/ and
# reloads. Does NOT restart any service (memory knobs take effect on reload for running
# units, on next start for inactive ones; OOMScoreAdjust applies to processes started after
# — see docs/m5-memory-limits.md for making it live on a running service without a restart).
#
# TWO SCOPES (this is the important bit — the workshop culprits are USER units, not system):
#   systemd/m5/system/  → /etc/systemd/system/<svc>.d/   (root; `systemctl` system manager)
#   systemd/m5/user/    → ~/.config/systemd/user/<svc>.d/ (you;  `systemctl --user`)
#
#   ./deploy-m5-memlimits.sh            DRY-RUN: show current vs proposed + safety check
#   ./deploy-m5-memlimits.sh --apply    install both scopes + reload
#
# Run it as YOUR user (NOT `sudo …`): it escalates the system-scope steps with `sudo`
# per-command, and installs the user-scope units as you so they land in your ~/.config.
#
# SAFETY: --apply REFUSES to cap a service that is active and already using more than the
# proposed MemoryMax — a below-usage cap forces immediate reclaim and can OOM that service.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYS_SRC="$HERE/systemd/m5/system"
USER_SRC="$HERE/systemd/m5/user"
APPLY=""
[ "${1:-}" = "--apply" ] && APPLY=1

host="$(hostname)"
[ "$host" = "m5" ] || { echo "refusing: targets m5 but hostname is '$host'. Run on m5." >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "run WITHOUT sudo — the script escalates system steps itself and must install user units as you, not root." >&2; exit 1; }

to_bytes() {
  local v="${1:-}"; case "$v" in
    ""|infinity) echo ""; return;;
    *G) echo $(( ${v%G} * 1024*1024*1024 ));;
    *M) echo $(( ${v%M} * 1024*1024 ));;
    *K) echo $(( ${v%K} * 1024 ));;
    *) echo "$v";;
  esac
}

# systemctl for a scope: system uses sudo-less `systemctl show` (read is unprivileged),
# user uses `systemctl --user`.
show() { # scope svc prop
  if [ "$1" = user ]; then systemctl --user show "$2" -p "$3" --value 2>/dev/null
  else systemctl show "$2" -p "$3" --value 2>/dev/null; fi
}

fail=0
printf '%-8s %-24s %-12s %-12s %s\n' SCOPE SERVICE CURRENT PROPOSED_MAX SAFETY
check_scope() { # scope srcdir
  local scope="$1" srcdir="$2" d svc proposed state cur pb verdict
  [ -d "$srcdir" ] || return 0
  for d in "$srcdir"/*.service.d; do
    [ -e "$d" ] || continue
    svc="$(basename "$d" .service.d).service"
    proposed=$(grep -E '^MemoryMax=' "$d/memory.conf" 2>/dev/null | tail -1 | cut -d= -f2 || true)
    state=$(show "$scope" "$svc" ActiveState); [ -n "$state" ] || state=unknown
    cur=$(show "$scope" "$svc" MemoryCurrent)
    case "$cur" in ''|'[not set]'|infinity) local cur_h="-" curb="";; *) local cur_h="$cur" curb="$cur";; esac
    pb=$(to_bytes "$proposed"); verdict="ok"
    if [ "$state" = "active" ] && [ -n "$curb" ] && [ -n "$pb" ] && [ "$curb" -gt "$pb" ]; then
      verdict="REFUSE (using $curb > cap $pb)"; fail=1
    fi
    printf '%-8s %-24s %-12s %-12s %s\n' "$scope" "${svc%.service}" "$cur_h" "${proposed:--}" "$verdict"
  done
}
check_scope system "$SYS_SRC"
check_scope user   "$USER_SRC"

if [ -z "$APPLY" ]; then
  echo; echo "DRY-RUN. Re-run with '$0 --apply' when the box is quiet to install."
  exit 0
fi
if [ "$fail" -ne 0 ]; then
  echo; echo "ABORTED: an active service exceeds its proposed MemoryMax (see REFUSE)." >&2
  echo "Stop that service or raise the cap, then re-run." >&2
  exit 1
fi

# --- system scope (root via per-command sudo) ---
if [ -d "$SYS_SRC" ]; then
  for d in "$SYS_SRC"/*.service.d; do
    [ -e "$d" ] || continue
    svc="$(basename "$d")"; dest="/etc/systemd/system/$svc"
    sudo install -d -m 755 "$dest"
    sudo install -m 644 "$d/memory.conf" "$dest/memory.conf"
    echo "installed (system) $dest/memory.conf"
  done
  # Make llama-swap's MemoryMin effective (a child's memory.min is capped by its ancestors').
  sudo systemctl set-property system.slice MemoryMin=20G
  echo "set system.slice MemoryMin=20G"
  sudo systemctl daemon-reload
  echo "system daemon-reload done"
fi

# --- user scope (as the invoking user) ---
if [ -d "$USER_SRC" ]; then
  for d in "$USER_SRC"/*.service.d; do
    [ -e "$d" ] || continue
    svc="$(basename "$d")"; dest="$HOME/.config/systemd/user/$svc"
    install -d -m 755 "$dest"
    install -m 644 "$d/memory.conf" "$dest/memory.conf"
    echo "installed (user) $dest/memory.conf"
  done
  systemctl --user daemon-reload
  echo "user daemon-reload done"
fi

echo "No services restarted. Memory caps: live for running units, on next start for inactive."
echo "OOMScoreAdjust applies to processes started AFTER — a still-running service keeps its"
echo "old kernel score until restart. To make it live now (root):"
echo "  for p in \$(cat /sys/fs/cgroup/system.slice/<svc>.service/cgroup.procs); do echo <N> | sudo tee /proc/\$p/oom_score_adj; done"
