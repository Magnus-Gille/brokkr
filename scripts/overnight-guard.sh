#!/usr/bin/env bash
set -euo pipefail

# Brokkr · launch an unattended overnight run inside an OOM-PROTECTED transient scope
# (brokkr#5). The overnight agentic runs are the highest-cost-to-lose class of work (no
# human to restart them), yet they run in bare login-session scopes the kernel will
# happily sacrifice. This wraps a command in a scope with a strongly-negative OOM score so
# a runaway service is killed long before this is.
#
#   sudo ./overnight-guard.sh -- tmux -L overnight new-session -d -s ov 'claude -p "…"'
#   sudo ./overnight-guard.sh -- claude -p "long autonomous task"
#
# WHY sudo (Codex review, brokkr#5): lowering a process's oom_score_adj below its inherited
# value requires CAP_SYS_RESOURCE. A `--user` scope CANNOT do it — the score would silently
# stay non-protective. So this uses the SYSTEM manager (root applies the negative score),
# with --uid/--gid dropping the command back to the invoking user. A preflight PROVES the
# negative score applies before the real launch, and fails loud otherwise.
#
# Env overrides: GUARD_OOM (default -800), GUARD_MEMMIN (default 6G), GUARD_SLICE.

# Tolerate a leading `--` separator.
[ "${1:-}" = "--" ] && shift
[ "$#" -ge 1 ] || { echo "usage: sudo $0 [--] <command...>" >&2; exit 2; }

OOM="${GUARD_OOM:--800}"
MEMMIN="${GUARD_MEMMIN:-6G}"
SLICE="${GUARD_SLICE:-overnight.slice}"
UID_N="$(id -u)"; GID_N="$(id -g)"

command -v systemd-run >/dev/null 2>&1 || { echo "ERROR: systemd-run not found" >&2; exit 1; }

# Preflight: prove the SYSTEM manager can apply a protective (negative) OOM score for us.
# Runs a throwaway scope that just prints its own oom_score_adj.
probe="$(sudo systemd-run --scope -q -p OOMScoreAdjust="$OOM" --uid="$UID_N" --gid="$GID_N" \
           -- cat /proc/self/oom_score_adj 2>/dev/null | tr -dc '0-9-')"
if [ -z "$probe" ] || [ "$probe" -ge 0 ]; then
  echo "ERROR: could not apply a protective negative OOM score (got '${probe:-none}')." >&2
  echo "       Run under sudo on the system manager (needs CAP_SYS_RESOURCE)." >&2
  exit 1
fi
echo "preflight ok: protective OOM score ${probe} confirmed via the system manager"

# MemoryMin is best-effort: cgroup v2 caps a child's effective memory.min by its ancestors'
# (system.slice). deploy-m5-memlimits.sh sets system.slice MemoryMin, but that budget is
# shared — treat MemoryMin as a bonus; OOMScoreAdjust above is the load-bearing protection.
exec sudo systemd-run --scope --slice="$SLICE" --uid="$UID_N" --gid="$GID_N" \
  -p OOMScoreAdjust="$OOM" \
  -p MemoryMin="$MEMMIN" \
  -p ManagedOOMPreference=avoid \
  -- "$@"
