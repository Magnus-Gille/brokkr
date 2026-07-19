# systemd/m5 — per-service memory limits on m5 (brokkr#5)

Example drop-in overrides that bound non-critical services and protect critical ones on
a cgroup-v2 inference host, so a runaway service cannot OOM-kill unrelated work —
especially unattended overnight agentic runs. Installed by
`../../scripts/deploy-m5-memlimits.sh`.

## Two scopes (important)

The services split across **two systemd managers** — verified on m5, not assumed:

- **`system/`** → installed to `/etc/systemd/system/<svc>.service.d/` (root; the system
  manager). These are `system.slice` services.
- **`user/`** → installed to `~/.config/systemd/user/<svc>.service.d/` (your user;
  `systemctl --user`). **The two workshop culprits from the incident (`open-webui` and the
  code-server) run as *user* units** (`uid=1000` in the OOM log), not system services — so
  their limits must live in user scope or they're silently inert. The memory controller is
  delegated to the user manager on m5, so user-scope `MemoryMax` is honored.

| Drop-in | Scope | Class | Effect |
|---------|-------|-------|--------|
| `system/llama-swap` | system | critical (models) | protect: `MemoryMin`, no cap, last to be killed |
| `system/home-gateway` | system | critical (API front) | cap 2G, protected from kill list |
| `system/whisper-server` | system | inference | cap 3G/4G, protected from kill list |
| `system/litellm-carmenta` | system | proxy | cap 1G/2G |
| `system/ttyd-carmenta` | system | non-critical | cap 512M/1G |
| `user/workshop-carmenta` (open-webui) | **user** | non-critical | cap 4G/6G, killed first |
| `user/code-carmenta` (code-server + vitest) | **user** | non-critical | cap 3G/5G, killed first |

Overnight runs are launched protected via `../../scripts/overnight-guard.sh` (they are login
scopes, not services, so they get no drop-in here).

**Design, budget rationale, the cgroup-v2 `MemoryMin` caveat, apply/verify/rollback runbook,
and the faults-layer overlap: `../../docs/m5-memory-limits.md`.**

> Nothing here is applied automatically. `deploy-m5-memlimits.sh --apply` is run by the
> host operator (it self-escalates system steps with sudo) when the box is quiet — matching
> Brokkr's convention that live host mutations are hand-run, not auto-mode.
