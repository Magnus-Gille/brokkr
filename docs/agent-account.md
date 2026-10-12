# Agent account on a shared inference host

`scripts/provision-agent-account.sh` creates and maintains a dedicated, unprivileged
Linux account where coding agents (Claude Code or Codex sessions running builds) work on
a host that also serves inference or other services. The account is resource-bounded and
cannot reach the operator's account, local services or private networks.

## Threat model

- Protect: the operator account and its files, services listening on this host
  (loopback and host addresses), and tailnet, LAN and other private destinations.
- Allow: the public internet, for git, crates, npm and model APIs.
- The agent runs model-driven shell commands, so treat it as untrusted code that is
  well supervised, not as a person.

## What `--apply` does

Idempotent; re-running converges and never duplicates anything.

1. Creates the account (`useradd`, no usable password, home `0700`) and records a
   marker `/var/lib/brokkr/agent-account/<user>.managed` holding the UID. An existing
   account without that marker is never adopted.
2. Fails closed if the account has any group beyond its own (sudo, adm, lxd, docker,
   render, ...). It never removes groups itself.
3. Writes a `user-<uid>.slice` resource drop-in (below) and applies it to a live slice.
4. Renders an nftables ruleset, validates it with `nft -c`, and installs
   `brokkr-agent-egress-<user>.service`, which loads it before `user@<uid>.service`
   and `systemd-user-sessions.service`, after (and `PartOf=`) `nftables.service`, so an
   `nftables.service` start or restart that flushes the ruleset reloads this table too.
   Re-runs `reload` the unit; the file replaces the table in one nft transaction, so the
   rules are never absent.
5. Adds the account to `/etc/cron.deny`: cron jobs run in `cron.service`, outside the
   user slice, and would bypass the resource budget. (If `/etc/cron.allow` exists, cron
   already ignores the deny list and only listed users may use it.)
6. Only after the unit is active and the table reads back, writes
   `~/.ssh/authorized_keys` (one key, restricted to `--ssh-from`, no agent or X11
   forwarding; the script owns and overwrites this file) and enables linger so tmux and
   user services survive logout.

Run it as the operator without `sudo`; it escalates per command. It refuses root.
`--apply` requires `BROKKR_EXPECTED_SOURCE` and `BROKKR_EXPECTED_COMMIT`
([source binding](deployment-source-binding.md)). The sshd policy (`AllowUsers`,
`AllowGroups`) is not touched; make sure it admits the account.

## Default resource budget

| Setting | Default | Why |
|---|---|---|
| `CPUQuota` | `2000%` | Hard ceiling; size to the host's cores |
| `CPUWeight`, `IOWeight` | `20` | Yield to services (default weight is 100) under contention |
| `MemoryHigh` | `20G` | Reclaim pressure starts inside the slice |
| `MemoryMax` | `24G` | A runaway build hits a cgroup OOM inside the slice, not host pressure |
| `MemorySwapMax` | `0` | No swap storms on the shared host |
| `TasksMax` | `4096` | Bounds fork bombs |

Derive real values from the host's measured headroom and the memory its resident
services need (see [m5-memory-limits.md](m5-memory-limits.md)).

## Egress rules

Applied per UID in an nftables `output` hook (`policy accept`, so the internet works):

- Allowed to local addresses: DNS (TCP/UDP 53, local resolver) and the TCP allowlist
  `--allow-local-tcp` (default `1420,4173,5173,32768-60999`: common dev-server ports plus
  the ephemeral range, which also carries replies from the agent's own servers).
- Rejected: every other local destination, IPv4 `10/8`, `100.64/10`, `169.254/16`,
  `172.16/12`, `192.168/16`, and IPv6 `fc00::/7` and `fe80::/10`.

The SSH connection itself belongs to sshd's socket, not the agent UID, so it should be
unaffected. Reach an agent's dev server with `ssh -L`, not by connecting to it directly
from the tailnet.

## Known residual risks

- `/proc` shows other users' process arguments unless the host mounts it with `hidepid`.
  The script reports the current mount; recommend a separate, reviewed `hidepid` change.
- Any service listening on an allowlisted port (including ephemeral ports) is reachable
  by the agent. Keep sensitive services outside the allowlist and outside 32768-60999.
- `/tmp` is shared; do not put secrets there.
- Example of the above: a database query engine or similar helper that binds a random
  localhost port lands in the ephemeral range and stays reachable. Audit `ss -ltn`.
- Only private IPv4 and IPv6 ULA/link-local destinations are blocked. LAN devices with
  global IPv6 addresses remain reachable.
- `ssh -L` forwarding runs as the agent, so it is subject to the same rules.
- The ruleset is only syntax-checked (`nft -c`) on apply; the repository tests use stubs
  and never exercise a live kernel, so run the verification below after every change.

## Usage

```bash
ssh-keygen -t ed25519 -f ~/agent -C agent-account     # on the client
# on the host, as the operator (no sudo):
./scripts/provision-agent-account.sh --user agent --pubkey ~/agent.pub \
  --ssh-from 100.64.0.0/10,fd7a:115c:a1e0::/48          # dry-run: prints every file
BROKKR_EXPECTED_SOURCE="$(pwd -P)" BROKKR_EXPECTED_COMMIT=<accepted-full-sha> \
  ./scripts/provision-agent-account.sh --apply --user agent --pubkey ~/agent.pub \
  --ssh-from 100.64.0.0/10,fd7a:115c:a1e0::/48 --memory-max 16G --memory-high 14G
```

## Verify after apply

As the agent account (`ssh agent@host`):

```bash
curl -sS -m 3 http://127.0.0.1:<local-service-port>   # must fail (connection refused)
curl -sSI https://github.com                           # must succeed
systemctl show user-$(id -u).slice -p MemoryMax -p MemoryHigh -p TasksMax
id -nG                                                 # only the account's own group
```

As the operator: `sudo nft list table inet brokkr_agent_<user>` and
`systemctl is-active brokkr-agent-egress-<user>`.

## Revoke and removal

```bash
./scripts/provision-agent-account.sh --revoke --user agent            # dry-run
BROKKR_EXPECTED_SOURCE=... BROKKR_EXPECTED_COMMIT=... \
  ./scripts/provision-agent-account.sh --revoke --apply --user agent
```

Revoke empties `authorized_keys`, disables linger, locks and expires the account, and
ends its sessions. It keeps the account, home, slice drop-in and egress unit so isolation
stays in force. Re-running provision with `--apply` re-enables the account. Full removal
is manual and destructive; revoke prints the commands (`userdel -r`, removing the unit,
nft file, slice drop-in and marker) without running them.
