#!/usr/bin/env bash
# Brokkr · heimdall-agent watchdog — restart a WEDGED fleet push agent (brokkr#14).
#
# WHERE IT RUNS: on every configured fleet host, as a *user*
# oneshot driven by heimdall-agent-watchdog.timer (every ~1 min). The agent it
# guards (heimdall/agent/core.py) is a *user* unit, so the restart must happen on
# the same user bus — hence a user unit, not a system one like brokkr-health.
#
# WHY IT EXISTS: on 2026-07-02 orin-nano's heimdall-agent stayed active/running
# (NRestarts=0) but stopped delivering pushes for ~14h after a load spike wedged
# its push loop. systemd's Restart=on-failure can't see a wedge — the process
# never died. This watchdog catches "alive but not pushing" via a freshness
# signal the process-liveness check can't.
#
# THE SIGNAL: the agent writes a heartbeat file (mtime = time of last *successful*
# push) at HEARTBEAT_FILE. This watchdog stats it; if the agent is active AND the
# heartbeat is older than STALE_SECS, it restarts the agent. Purely local — no
# network, no token, no coupling to Heimdall's server/dashboard (which is
# Heimdall's domain, not Brokkr's).
#
#   Heartbeat writer: heimdall/agent/core.py (heimdall#101 — the from:brokkr
#   enabler ticket). Until that ships, the heartbeat file is absent and this
#   watchdog SAFELY NO-OPS (it never restarts on a missing signal), so deploying
#   Brokkr's side early is harmless.
#
# COOLDOWN: a restart only helps a *local* wedge. If pushes are stale because of
# an external outage (Heimdall/network/creds down), restarting won't fix it — so
# we bound restarts to once per COOLDOWN_SECS to avoid storming an unrecoverable
# condition once a minute.
#
# Config (all optional; via ~/.config/brokkr/env or the environment):
#   HEIMDALL_AGENT_UNIT              systemd --user unit    (default heimdall-agent)
#   HEIMDALL_AGENT_STATE_DIR         heartbeat file's dir   (default per XDG below)
#   HEIMDALL_AGENT_STALE_SECS        wedge threshold, secs  (default 150 = 5×30s push)
#   HEIMDALL_AGENT_RESTART_COOLDOWN_SECS  min secs between restarts (default 900)
#
# Always exits 0 (a watchdog must not fail its own timer); actions go to the journal.
set -uo pipefail

log() { printf '%s heimdall-agent-watchdog: %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*"; }

# Portable mtime (GNU stat on the Linux hosts; BSD stat so the test suite runs on macOS).
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
# Age in seconds of a file, or empty if it can't be read.
file_age() {
  local m; m="$(file_mtime "$1")"
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  echo "$(( $(date +%s) - m ))"
}

UNIT="${HEIMDALL_AGENT_UNIT:-heimdall-agent}"
STALE_SECS="${HEIMDALL_AGENT_STALE_SECS:-150}"
COOLDOWN_SECS="${HEIMDALL_AGENT_RESTART_COOLDOWN_SECS:-900}"

# Validate the tunables before use — a bad value must degrade to a logged no-op,
# never a shell error or a "restart everything / restart nothing" surprise.
if ! [[ "$STALE_SECS" =~ ^[1-9][0-9]*$ ]]; then
  log "no-op: invalid HEIMDALL_AGENT_STALE_SECS='$STALE_SECS' (want a positive integer)"; exit 0
fi
if ! [[ "$COOLDOWN_SECS" =~ ^[0-9]+$ ]]; then
  log "no-op: invalid HEIMDALL_AGENT_RESTART_COOLDOWN_SECS='$COOLDOWN_SECS' (want a non-negative integer)"; exit 0
fi

# Only act on a WEDGE (active but stale). A dead/inactive unit is systemd's job
# (Restart=on-failure) or a deliberate stop — never fight it. (Cheap check first,
# before we need any state paths.)
if ! systemctl --user is-active --quiet "$UNIT"; then
  log "ok: $UNIT is not active (inactive/failed → systemd's job, not ours); no-op"
  exit 0
fi

# Resolve the state dir defensively — under `set -u` an unset HOME must not abort.
if [ -n "${HEIMDALL_AGENT_STATE_DIR:-}" ]; then
  STATE_DIR="$HEIMDALL_AGENT_STATE_DIR"
elif [ -n "${XDG_STATE_HOME:-}" ]; then
  STATE_DIR="$XDG_STATE_HOME/heimdall-agent"
elif [ -n "${HOME:-}" ]; then
  STATE_DIR="$HOME/.local/state/heimdall-agent"
else
  log "no-op: cannot resolve state dir (HEIMDALL_AGENT_STATE_DIR/XDG_STATE_HOME/HOME all unset)"; exit 0
fi
HEARTBEAT_FILE="$STATE_DIR/last-push"
RESTART_MARKER="$STATE_DIR/watchdog-last-restart"

if [ ! -f "$HEARTBEAT_FILE" ]; then
  log "no-op: heartbeat $HEARTBEAT_FILE absent — agent predates heartbeat support (heimdall#101) or has not pushed yet; not restarting on a missing signal"
  exit 0
fi

age="$(file_age "$HEARTBEAT_FILE")" || { log "no-op: could not read heartbeat mtime"; exit 0; }

if [ "$age" -le "$STALE_SECS" ]; then
  log "ok: last push ${age}s ago (≤ ${STALE_SECS}s)"
  exit 0
fi

# Heartbeat is stale and the unit is active → candidate wedge. Respect the cooldown
# so we don't restart every tick if the restart isn't fixing it (external outage).
if [ -f "$RESTART_MARKER" ]; then
  since="$(file_age "$RESTART_MARKER" || true)"
  if [[ "$since" =~ ^[0-9]+$ ]] && [ "$since" -lt "$COOLDOWN_SECS" ]; then
    log "skip: last push ${age}s ago (> ${STALE_SECS}s) but restarted only ${since}s ago (< cooldown ${COOLDOWN_SECS}s) — not storming a restart that isn't helping"
    exit 0
  fi
fi

log "WEDGE: last successful push ${age}s ago (> ${STALE_SECS}s) while $UNIT active — restarting"
if systemctl --user restart "$UNIT"; then
  # Stamp the cooldown marker so a still-stale next tick backs off.
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  : > "$RESTART_MARKER" 2>/dev/null || touch "$RESTART_MARKER" 2>/dev/null || true
  log "restarted $UNIT OK"
else
  rc=$?
  log "restart of $UNIT FAILED (rc=$rc)"
fi
exit 0
