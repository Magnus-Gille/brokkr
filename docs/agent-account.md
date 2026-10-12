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

Idempotent; re-running converges and never duplicates anything. The account stays
**expired** (no login possible) from the first step until every protection has been
verified, so any failure leaves it closed.

1. Creates the account expired (`useradd --expiredate 1`, home `0700`) and records a
   marker `/var/lib/brokkr/agent-account/<user>.managed` holding the UID; a re-run first
   expires an existing account. An existing account without the marker is never adopted.
2. Fails closed if the account has any group beyond its own (sudo, adm, lxd, docker,
   render, ...) or any `/etc/subuid`/`/etc/subgid` range. It is created with
   `-K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0`: with subordinate IDs, `newuidmap` and rootless
   containers (`podman --network=host`) could run processes under other uids in the host
   network namespace, outside the per-uid egress rules. It never removes groups or ranges
   itself.
3. Writes a `user-<uid>.slice` resource drop-in (below), starts or updates the slice, and
   reads the kernel's `memory.max`, `memory.high`, `memory.swap.max`, `pids.max` and
   `cpu.max` back; a mismatch aborts.
4. Writes the SSH key to `/etc/brokkr/agent-account/<user>.keys` (root-owned), validates
   the nftables ruleset with `nft -c`, and installs `brokkr-agent-egress-<user>.service`.
   The unit loads the ruleset and only then publishes the key to
   `/run/brokkr-agent-keys/<user>`; stopping it withdraws the key but keeps the table.
   No loaded ruleset means no key, so a failed boot-time load cannot leave the account
   reachable. A `user@<uid>.service` drop-in `Requires=` the unit, so lingering user
   services do not start without isolation either. The unit runs after and is `PartOf=`
   and `ReloadPropagatedFrom=` `nftables.service`, so starting, restarting or reloading a
   ruleset that flushes everything re-creates this table. If `/etc/nftables.conf` exists,
   it also gains one line, `include "/etc/brokkr/agent-account/*.nft"` (validated with
   `nft -c`, restored on failure), so any start or reload of the canonical ruleset re-creates
   the agent tables in the same transaction. Re-runs `reload` the unit: it withdraws the
   key, replaces the table in one nft transaction, and republishes the key only on success.
   If a re-run finds the table missing, it ends the account's sessions, which ran without
   isolation.
5. Refuses if the account is in `/etc/cron.allow` or `/etc/at.allow`, already has a
   crontab or has queued at jobs, then lists it in `/etc/cron.deny` and `/etc/at.deny`:
   their jobs run outside the user slice and would bypass the budget.
6. Installs `sshd_config.d/00-brokkr-agent-<user>.conf`, a `Match User` block whose
   `AuthorizedKeysFile` is the published key. Every other key source is disabled
   (`AuthorizedKeysCommand`, `AuthorizedPrincipalsFile`/`Command`, `TrustedUserCAKeys`,
   host-based authentication), and the block also sets public key only, no agent/X11
   forwarding, no tunnels and no `~/.ssh/rc`. The `00-` prefix makes it the first value sshd
   obtains, so a later `Match Address` block cannot override it. It is validated with
   `sshd -t`, and with `sshd -T -C` for loopback and the network address of every
   `--ssh-from` range, before sshd is reloaded; a rejected or overridden policy restores
   the previous drop-in. sshd never reads `~/.ssh` for this
   account, so the agent cannot add keys or drop the `from=` restriction, and root never
   writes inside the agent's home.
7. Enables linger (tmux and user services survive logout) and, as the very last step,
   the account itself (no usable password, no expiry).

Run it as the operator without `sudo`; it escalates per command. It refuses root.
`--apply` requires `BROKKR_EXPECTED_SOURCE` and `BROKKR_EXPECTED_COMMIT`
([source binding](deployment-source-binding.md)). `AllowUsers`/`AllowGroups` are not
touched; make sure they admit the account.

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

- Allowed: packets of connections that are already established (replies from the
  agent's own servers), DNS (TCP/UDP 53) to the local resolver, and new TCP connections
  to **loopback only** on `--allow-local-tcp` (default `1420,4173,5173,32768-60999`:
  common dev-server ports plus the ephemeral range used by tests that bind port 0).
- Rejected: every other local destination (including the host's tailnet and LAN
  addresses), IPv4 `10/8`, `100.64/10`, `169.254/16`, `172.16/12`, `192.168/16`,
  multicast `224/4` and broadcast, IPv6 `fc00::/7`, `fe80::/10` and multicast `ff00::/8`.

sshd's connection socket is root-owned, so SSH itself is unaffected. `ssh -L` forwarding
runs as the agent and is subject to the same rules; use it to reach an agent's dev server.

## Known residual risks

- Any service bound to loopback on an allowlisted port is reachable, including helpers
  that pick a random port in the ephemeral range (for example a database query engine).
  Audit `ss -ltne` for listeners in that range owned by other users; a stricter
  separation needs a network namespace for agent sessions.
- `/proc` shows other users' process arguments unless the host mounts it with `hidepid`;
  the script reports the current mount. Keep secrets out of command lines.
- Global IPv6 LAN addresses are not blocked; check `ip -6 addr show scope global`.
- The rules match the socket's uid. Setuid-root programs and system daemons that connect
  on the agent's behalf are not covered; audit fstab `user` mounts and world-writable
  daemon sockets. The Tailscale LocalAPI socket is world-accessible but grants non-root,
  non-operator users read access only (status), not dialing.
- A hand-run `nft flush ruleset` (outside `nftables.service`) removes the table until the
  unit is reloaded; established agent connections are not cut. Do not flush by hand.
- Expiring the account during a re-run blocks new logins but leaves running sessions;
  sessions are ended only when the table was found missing.
- `/tmp` is shared; do not put secrets there.
- The repository tests use stubs and never exercise a live kernel, sshd or systemd, so
  run the verification below after every apply.

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

As the operator: `sudo nft list table inet brokkr_agent_<user>`,
`systemctl is-active brokkr-agent-egress-<user>`, and that
`sudo sshd -T -C user=<user>,host=localhost,addr=127.0.0.1 | grep authorizedkeysfile`
shows `/run/brokkr-agent-keys/%u`.

## Revoke and removal

```bash
./scripts/provision-agent-account.sh --revoke --user agent            # dry-run
BROKKR_EXPECTED_SOURCE=... BROKKR_EXPECTED_COMMIT=... \
  ./scripts/provision-agent-account.sh --revoke --apply --user agent
```

Revoke first locks and expires the account, then empties the key file, withdraws the
published key, disables linger and ends its sessions. Every step runs even if an earlier
one fails, and any failure is reported with a non-zero exit. It keeps the account, home,
drop-ins and egress unit so isolation stays in force. Re-running provision with `--apply`
re-enables the account. Full removal is manual and destructive; revoke prints the commands
(`userdel -r`, deleting the table, unit, files, drop-ins and deny entries) without running
them.
