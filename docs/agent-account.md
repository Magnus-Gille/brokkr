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
   network namespace, outside the per-uid egress rules. With `--apply`, an existing account
   that fails these checks is first expired, its published key withdrawn and its sessions
   ended, and only then refused. It never removes groups or ranges
   itself.
3. Writes a `user-<uid>.slice` resource drop-in (below), checks systemd's configured
   values (`systemctl show`), and reads the kernel's `memory.max`, `memory.high`,
   `memory.swap.max`, `pids.max` and `cpu.max` back through a transient root scope in the
   slice (`systemd-run --scope --slice=`). An empty slice has no cgroup, and the expired
   account cannot start `user@<uid>` itself (PAM account check). A mismatch aborts.
   Then it sets up the disk-backed `TMPDIR` and the housekeeping timers
   ([below](#temporary-files-and-orphaned-sessions)): `/etc/tmpfiles.d/brokkr-agent-<user>.conf`
   creates `/var/lib/brokkr/agent-tmp/<user>` (owner the account, `0700`, under a root-owned
   `0755` parent) and ages its contents; `stat` reads both back and a wrong owner, mode or a
   symlink aborts. `findmnt` must also resolve exactly one filesystem type; tmpfs,
   ramfs and hugetlbfs (or a failed/empty probe) abort before login is enabled. It installs `/usr/local/libexec/brokkr-agent-housekeeping` and enables
   `brokkr-agent-tmp-sweep-<user>.timer` and, only when `--closing-session-grace` is given a
   span (the default is `off`), `brokkr-agent-session-reaper-<user>.timer`.
4. Writes the SSH key to `/etc/brokkr/agent-account/<user>.keys` (root-owned), validates
   the nftables ruleset with `nft -c`, and installs `brokkr-agent-egress-<user>.service`.
   The unit loads the ruleset and only then publishes the key to
   `/run/brokkr-agent-keys/<user>`; stopping it withdraws the key but keeps the table.
   No loaded ruleset means no key, so a failed boot-time load cannot leave the account
   reachable. A `user@<uid>.service` drop-in `Requires=` the unit, so lingering user
   services do not start without isolation either; it also sets `TMPDIR` and
   `CLAUDE_CODE_TMPDIR` for the user manager and everything it starts. The unit runs after and is `PartOf=`
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
   forwarding, no tunnels and no `~/.ssh/rc`, and `SetEnv TMPDIR=... CLAUDE_CODE_TMPDIR=...`
   for every SSH session (interactive logins, `ssh host command`, and the remote sessions of
   Claude Desktop and the Codex app alike). sshd keeps the first value it obtains; the
   `00-` prefix puts the block before the other drop-ins (the script refuses if another
   drop-in sorts first), which on a stock `sshd_config` is the first `Include`. It is validated with
   `sshd -t`, and with `sshd -T -C` for loopback and the network address of every
   `--ssh-from` range (including the `setenv` values), before sshd is reloaded; a rejected or overridden policy restores
   the previous drop-in. sshd never reads `~/.ssh` for this
   account, so the agent cannot add keys or drop the `from=` restriction, and root never
   writes inside the agent's home.
7. Enables linger (tmux and user services survive logout), then the account itself (no
   usable password, no expiry), then starts `user@<uid>`, which could not start while the
   account was expired, and hands an already running user manager the new environment
   (`systemctl --user -M <user>@ set-environment`; a failure only warns).

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

## Temporary files and orphaned sessions

Why: on hosts where `/tmp` is a tmpfs (Ubuntu 26.04 mounts one by default), every file in it
is shared memory charged to the writer's cgroup. With `MemorySwapMax=0` it cannot be
reclaimed, and it stays charged after the process that wrote it has exited. Build scratch
left there by agent sessions (a Claude Code scratchpad used as a cargo target directory,
copied baseline binaries, task directories, Node's compile cache) filled the slice up to
`MemoryHigh`. The kernel then throttled every allocation in the slice, so new SSH logins to
the account authenticated but never started a shell. Logins of other accounts were unaffected.

What the provisioner sets up:

| Piece | Effect |
|---|---|
| `TMPDIR=/var/lib/brokkr/agent-tmp/<user>` and `CLAUDE_CODE_TMPDIR` (same value) via sshd `SetEnv` and the `user@<uid>` drop-in | `mktemp`, Node (`os.tmpdir()`, including its compile cache), Rust's `std::env::temp_dir`, and Claude Code's scratch directories (`<dir>/claude-<uid>/`) land on disk. Page cache is still charged to the slice, but it is reclaimable, so it no longer drives the slice into throttling. |
| `/etc/tmpfiles.d/brokkr-agent-<user>.conf` (`--tmp-max-age`, default `7d`) | `systemd-tmpfiles-clean.timer` (daily) removes entries of that directory whose access, modification and change times are all older than the age. The directory itself is recreated at boot. |
| `brokkr-agent-tmp-sweep-<user>.timer` (hourly, `--tmpfs-max-age`, default `1d`) | Runs **as the account** (never root, so it can only delete what the account itself could) in `system.slice` (a throttled agent slice cannot stall it), with no network. It removes the account's regular files and symlinks under `/tmp` whose three times are all older than the age, then its empty directories. Aged directories of the account that it cannot enter (read-only build or module trees) get `u+rwx` first. It does not enter other users' directories, and it keeps sockets and FIFOs (tmux, ssh-agent). Any other error fails the unit after both passes. It covers programs that hard-code `/tmp`. |
| `brokkr-agent-session-reaper-<user>.timer` (opt-in: every 10 min once `--closing-session-grace` is a span such as `6h`; the default `off` installs nothing) | Root, via logind only. A session whose SSH connection is gone but whose processes remain is `State=closing`. Once a session has been seen closing for the grace period, the reaper ends it with `loginctl terminate-session`; if it is still closing on a later run (processes that ignore SIGTERM), it sends SIGKILL with `loginctl kill-session`. It keeps a session whose scope holds a tmux server with an attached client (tmux sets its socket's execute bit while a client is attached), and a session whose processes it cannot read. The first-seen and terminate times are kept in `/run/brokkr-agent-sessions/<user>`. It is resource hygiene for a cooperative account, not a security boundary. |

`CARGO_TARGET_DIR` is deliberately **not** set account-wide. Every checkout or worktree
already builds into its own `target/` on disk. One shared target directory would serialize
parallel agent sessions on cargo's build lock, and different branches would invalidate
each other's artifacts. The incident's target directory was in tmpfs only because a session
put it in its scratchpad, which is now on disk.

### Persistent worktrees and build caches

The provisioner installs `brokkr-agent-worktree` in `/usr/local/bin`. Use it for new
agent task worktrees instead of choosing a path under `/tmp` or an expiring scratchpad:

```bash
brokkr-agent-worktree --repo "$HOME/repos/project" --name example-task \
  --branch codex/example-task --ref origin/main
```

The default root is `${XDG_STATE_HOME:-$HOME/.local/state}/brokkr/worktrees`, with
separate namespaces for each repository and task. It is not subject to the temporary-file
age policy. `BROKKR_WORKTREE_ROOT` may select another persistent root. The helper checks
its backing filesystem before creating a worktree and refuses tmpfs, ramfs, hugetlbfs,
a failed filesystem probe, an existing target, or a redirected root. It preserves Git's
branch and worktree checks and never deletes or prunes existing work.

Cargo's default checkout-local `target/` then stays on the same disk without introducing
one shared build lock across parallel worktrees. Any explicit `CARGO_TARGET_DIR` must also
be disk-backed. Keep project verification storage checks enabled: setting `TMPDIR` alone
cannot protect a build that explicitly chooses `/tmp`.

For an existing account, installing just the reviewed helper does not require re-running
the account provisioner or restarting SSH/user sessions. Do not re-provision merely to
install the helper: the provisioner also manages account expiry, keys and network policy.
Existing worktrees are retained; relocation is a separate, verified operation.

### Deliberate long-lived work (tmux)

A tmux server stays in the scope of the SSH login that started it, for as long as it runs.
When that connection drops, the login becomes `closing`. **Reattaching from a new login
does not move the server out of the old scope and does not reset the reaper's grace
period.** With the reaper on, a tmux server inside a login is spared only while a client is
attached at the time of a check. Once it is detached and the grace period has passed, it is
ended at the next check, together with everything running in it. This also covers the
"laptop off" case of a detached tmux running `claude remote-control`. The reaper cannot tell
deliberate detached work from an abandoned build, so it is off by default.

Start long-lived work outside any login, in its own scope under the user manager, with a
dedicated tmux socket so it does not join a server that lives in an old login scope:

```bash
systemd-run --user --scope --unit=agent-work tmux -L agent-work new-session -d -s work
tmux -L agent-work attach -t work
```

The transient scope holds the tmux server after the starting client exits, survives logout
(the account lingers), and stays inside the account's slice and budget. A plain
`systemd-run --user tmux new-session -d` does **not** work: it creates a `Type=simple`
service, the client exits after starting the detached server, the unit stops and its
control group, the server included, is killed.

Choosing the policy:

| Option | Effect on tmux inside an SSH login | Notes |
|---|---|---|
| `--closing-session-grace off` (default) | Unaffected | Orphaned builds keep their memory until someone ends them by hand |
| `--closing-session-grace 6h` (or another span) | Kept while attached; ended at the first check after the grace period once detached | Per account, no logind restart. Move long-lived work to the `systemd-run --user --scope` form first. |
| `KillUserProcesses=yes` with `KillOnlyUsers=<user>` in `logind.conf.d` (not implemented here) | Killed the moment the connection drops | Plain tmux and `nohup` inside SSH stop working. One global list for the host; takes effect only after logind restarts or the host reboots. |

### Resource budget after the fix

In the incident, the slice (default budget) held about 19 GiB of shmem against about
2.5 GiB of anonymous memory. The limits were not the cause, so the defaults stay as they are:

- `MemoryHigh`/`MemoryMax`: keep `20G`/`24G`. With scratch on disk, `MemoryHigh` again
  bounds anonymous memory plus reclaimable cache, which is its purpose. If anonymous-memory
  pressure from builds recurs, prefer systemd-oomd (`ManagedOOMMemoryPressure=kill` on the
  slice, which needs the daemon running) over raising the limits.
- `cargo -j`: cargo's default jobs come from Rust's `available_parallelism`, which honours the
  slice's cgroup CPU quota (20 with the default `2000%`), not the host's thread count. No
  change is needed.
- `vitest` workers: Node's `os.availableParallelism()` reports the host's threads, not the
  quota, so a default vitest run starts more workers than the slice has CPUs. Each worker is
  a Node process. Cap `maxWorkers` in the project's vitest configuration if a test run is
  memory-heavy. That is application configuration and belongs in the project's repository.

## Egress rules

Applied per UID in an nftables `output` hook (`policy accept`, so the internet works):

- Allowed: packets of connections that are already established (replies from the
  agent's own servers), DNS (TCP/UDP 53) to the local resolver, and new TCP connections
  to **loopback only** on `--allow-local-tcp` (default `1420,4173,5173,32768-60999`:
  common dev-server ports plus the ephemeral range used by tests that bind port 0).
- Rejected: every other local destination (including the host's tailnet and LAN
  addresses), IPv4 `10/8`, `100.64/10`, `169.254/16`, `172.16/12`, `192.168/16`,
  multicast `224/4`, limited and directed broadcast (`fib daddr type broadcast`), IPv6 `fc00::/7`, `fe80::/10` and multicast `ff00::/8`.

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
- `/tmp` is shared; do not put secrets there. Programs that hard-code `/tmp` instead of
  honouring `TMPDIR` still write to the tmpfs, so that use only becomes reclaimable once the
  hourly sweep removes it (after `--tmpfs-max-age`). A hard cap needs a per-user tmpfs quota
  (`usrquota` on the `/tmp` mount plus a per-boot `setquota`), which is not part of this script.
- Scratch on disk is no longer bounded by the size of the tmpfs: a runaway build can fill the
  filesystem that holds `/var/lib/brokkr/agent-tmp` (on a single-partition host, `/`) until the
  tmpfiles age removes it. Watch free space, or put that directory on its own filesystem or
  under a project quota where the host's storage allows it.
- Both cleanups go by age alone. A lock, pid or cache file the account keeps open but has not
  touched for the age is removed too. The `/tmp` sweep relies on `strictatime` on that mount,
  so any read counts as a touch.
- The final `systemctl --user -M <user>@ set-environment` talks to the account's own user bus
  as root. It carries no secrets, its failure only warns, and it is bounded by a 30-second timeout.
- When enabled, the reaper ends any session of the account that stays `closing` for the
  grace period, including a detached tmux server started inside an SSH login, even if it
  was reattached from a later login in between. Use the `systemd-run --user --scope` form
  above for work that must outlive the login. Attached-client detection covers tmux only
  (not screen or zellij).
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

```bash
echo "$TMPDIR"; echo "$CLAUDE_CODE_TMPDIR"             # both /var/lib/brokkr/agent-tmp/<user>
ssh agent@host 'echo $TMPDIR'                          # non-interactive sessions too
systemctl --user show-environment | grep TMPDIR        # the lingering user manager
mktemp                                                 # a path under that directory
```

As the operator: `systemctl list-timers 'brokkr-agent-*' systemd-tmpfiles-clean.timer`,
`journalctl -u brokkr-agent-tmp-sweep-<user> -u brokkr-agent-session-reaper-<user> -n 20`,
`grep -E '^(anon|file|shmem) ' /sys/fs/cgroup/user.slice/user-<uid>.slice/memory.stat`
(shmem should stay small), `sudo nft list table inet brokkr_agent_<user>`,
`systemctl is-active brokkr-agent-egress-<user>`, and that
`sudo sshd -T -C user=<user>,host=localhost,addr=127.0.0.1 | grep authorizedkeysfile`
shows `/run/brokkr-agent-keys/%u` and `grep setenv` shows both variables.

## Updating an existing account

A re-run with `--apply` converges an existing account. The account is expired while the
re-run is in progress, so no new logins succeed until it finishes. Running sessions and
processes are not affected. Then:

1. Sessions that were already open, tmux servers and Claude Code or Codex processes keep
   their old `TMPDIR`. New SSH sessions and new user services get the new one. Restart
   long-lived agent processes when convenient.
2. Files already in `/tmp` are removed by the hourly sweep once they are older than
   `--tmpfs-max-age`. With the reaper enabled, sessions that are already `closing` are ended
   one grace period after the reaper first sees them. Freeing memory sooner is a manual, destructive step for the
   operator: review the account's `/tmp` files and running processes first.

## Rollback of the temporary-file and session housekeeping

```bash
sudo systemctl disable --now brokkr-agent-tmp-sweep-<user>.timer
sudo systemctl disable --now brokkr-agent-session-reaper-<user>.timer   # only if the reaper was enabled
sudo rm -f /etc/systemd/system/brokkr-agent-{tmp-sweep,session-reaper}-<user>.{service,timer} \
  /etc/tmpfiles.d/brokkr-agent-<user>.conf
# Re-run the provisioner at the previous accepted commit: it rewrites the sshd and user@<uid>
# drop-ins without SetEnv/Environment and verifies everything else as before.
BROKKR_EXPECTED_SOURCE=... BROKKR_EXPECTED_COMMIT=<previous-accepted-sha> \
  ./scripts/provision-agent-account.sh --apply --user <user> ...
sudo systemctl daemon-reload
sudo systemctl --user -M <user>@ unset-environment TMPDIR CLAUDE_CODE_TMPDIR
```

Leave `/var/lib/brokkr/agent-tmp/<user>` and `/usr/local/libexec/brokkr-agent-housekeeping`
in place until the directory has been reviewed. Removing them changes nothing once the
timers are gone.

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
