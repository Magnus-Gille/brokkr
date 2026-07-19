# heimdall-agent watchdog (brokkr#14)

Auto-restarts a **wedged** Heimdall fleet push agent — one that stays
`active/running` but has stopped delivering pushes. `systemd`'s
`Restart=on-failure` can't see this: the process never dies.

## The incident this fixes

2026-07-02, `orin-nano`: `heimdall-agent` (user unit) showed `active`,
`NRestarts=0`, but stopped pushing for **~14h** after a load spike (runaway
`jtop`, load ~21) wedged its push loop. It only surfaced because a human noticed
the red "Offline" card. Manual fix was `systemctl --user restart heimdall-agent`.

## How it works

- Runs on **every configured fleet host** as a **user** oneshot
  (`heimdall-agent-watchdog.service`) driven by a 1-minute timer. It's a *user*
  unit because the agent it restarts is a `systemctl --user` unit — the restart
  must run on the same bus.
- Freshness signal: the agent writes a **heartbeat file** whose mtime is the time
  of its last *successful* push, at
  `${XDG_STATE_HOME:-~/.local/state}/heimdall-agent/last-push`.
- Each tick: if the unit is **active** AND the heartbeat is older than
  `STALE_SECS` (default **150s** = 5× the 30s push interval) → `systemctl --user
  restart heimdall-agent`, logged to the journal.
- Purely **local** — no network, no token, no coupling to Heimdall's server or
  dashboard (that's Heimdall's domain; Brokkr owns only substrate health).

### Fail-safe

- **Heartbeat absent** (agent predates heartbeat support, or hasn't pushed yet) →
  the watchdog **no-ops**. It never restarts on a missing signal, so deploying
  Brokkr's side *before* the heimdall heartbeat enabler lands is harmless.
- **Unit inactive/failed** → no-op (that's systemd's `Restart=` job or a
  deliberate stop; never fight it).
- **Cooldown** → a restart only fixes a *local* wedge. If pushes are stale because
  of an external outage (Heimdall/network/creds down), a restart won't help, so
  restarts are bounded to once per `RESTART_COOLDOWN_SECS` (default 900s) — no
  once-a-minute restart storm against an unrecoverable condition.
- **Bad tunables** (non-numeric / zero `STALE_SECS`) → logged no-op, not a crash.
- The script always exits 0 (a watchdog must not fail its own timer).

## Dependency (the heartbeat writer)

The heartbeat file is written by the agent, which lives in the **heimdall** repo
(`heimdall/agent/core.py`). Per the repo-ownership boundary, that change is filed
as a `from:brokkr` ticket to heimdall — **heimdall#101** (write `last-push` at
startup and on each successful push, to the path above). Until it merges, the
watchdog is deployed but dormant (safe no-op).

## Config (optional; `~/.config/brokkr/env` or environment)

| Var | Default | Meaning |
|-----|---------|---------|
| `HEIMDALL_AGENT_UNIT` | `heimdall-agent` | user unit to guard |
| `HEIMDALL_AGENT_STATE_DIR` | `…/.local/state/heimdall-agent` | dir holding `last-push` |
| `HEIMDALL_AGENT_STALE_SECS` | `150` | wedge threshold (seconds) |
| `HEIMDALL_AGENT_RESTART_COOLDOWN_SECS` | `900` | min seconds between restarts (anti-storm) |

## Deploy

```
./scripts/deploy-agent-watchdog.sh                 # configured default role hosts
./scripts/deploy-agent-watchdog.sh brokkr@edge-host     # a single host
```

## Test

Logic is covered by a mock-`systemctl` unit test (runs on macOS or Linux, no real
agent needed):

```
./scripts/test/heimdall-agent-watchdog.test.sh
```

## Acceptance (on a real host, after the heartbeat enabler ships)

Simulate a wedge and confirm auto-recovery:

```
# freeze the agent so it stops pushing but stays 'active'
systemctl --user kill -s STOP heimdall-agent            # or: kill -STOP <pid>
# wait > STALE_SECS, then let the watchdog tick (or run it directly):
systemctl --user start heimdall-agent-watchdog.service
journalctl --user -u heimdall-agent-watchdog.service -n 5 --no-pager   # expect: WEDGE … restarting
# confirm a fresh push landed (host back Online in Heimdall)
```
