# NAS and control-node boundary hardening (owner-attended)

Prepares BROKKR-172. **Nothing here is applied by this repository.** It does not authorize disabling
password login, closing a port, a firewall, service or route change, or a deployment. Each mutation
below needs the owner's just-in-time approval of the exact target, command, verification and
rollback. A merged runbook is not a hardened host.

Start from what was observed (BROKKR-170, read-only, 2026-11-03), which are bind/configuration
observations and **not** proof of internet reachability or of a successful authentication:

| Host | Observation |
|---|---|
| NAS | OpenSSH on TCP 22 listens on wildcard IPv4 and IPv6. Global `sshd -G` reported `PasswordAuthentication yes`, `PermitRootLogin without-password` and forwarding on. |
| NAS | SMB TCP 139 and 445 listen on wildcard. |
| Control node | TCP 111 (rpcbind) and TCP 5900 (VNC) listen on wildcard. |

`Match` rules, service identities, peer allow/deny paths and the router boundary were not
verified. They stay **unknown** until the steps below produce evidence.

Keep dated outputs in the owner-only record described in
[`../docs/backup-evidence.md`](../docs/backup-evidence.md). Never put addresses, accounts, share
names, key material or raw configuration into Git, Munin, tickets or shared logs.

The control node's Tailscale SSH to OpenSSH move is a separate, already-prepared change:
[`control-node-openssh-cutover.md`](control-node-openssh-cutover.md). Do this runbook's SSH
section after it, so you harden the SSH server you will actually keep.

## 0. Consumer inventory (owner-only)

Before closing anything, list who legitimately uses each door. Use evidence, not memory.

- **SSH:** every person and automation that logs in: source device, remote account, owning
  repository, key location. Include this repository's `BROKKR_SSH_TARGET` account, Hugin/deploy
  scripts, Heimdall and the dead-man jobs. Every account must be non-root.
  The NAS was observed with `PermitRootLogin without-password`, so also check, content-blind,
  whether anything logs in as root with a key today: the number of lines in root's
  `authorized_keys` and a *count* of recent root logins in the auth log. If root consumers exist,
  they need a non-root replacement before `PermitRootLogin no`.
- **SMB:** every client device and the share it mounts (Time Machine is retired, see
  [`../docs/nas-samba-retirement.md`](../docs/nas-samba-retirement.md)). Note any client that needs
  SMB1/NetBIOS (port 139).
- **rpcbind (111):** whether anything uses NFS or other ONC-RPC (`rpcinfo -p`, `/etc/exports`, any
  NFS mount in `/proc/mounts`).
- **VNC (5900):** which service owns it, who connects, and whether a tunnel or the tailnet
  can replace direct LAN access.

## 1. Read-only audit (before)

`scripts/host-boundary-audit.py` runs `ss` (TCP and UDP), `sshd -T`, `testparm -s` and `systemctl is-active/enabled`
and prints one line of booleans, port numbers and reason codes. It evaluates `sshd` per
**connection context**, because a global `sshd -T` ignores `Match` blocks. Run it on each host as
root, once per inventoried account and source address:

Put the contexts, one `USER@ADDRESS` per line, in an owner-only mode-0600 file. This keeps accounts and
addresses out of argv, which `sudo` logs and other local processes can read:

```bash
sudo python3 scripts/host-boundary-audit.py --role nas \
  --context-file /absolute/owner-only/nas-contexts.txt \
  > /absolute/owner-only/nas-boundary-before.json
sudo python3 scripts/host-boundary-audit.py --role control-node \
  --context-file /absolute/owner-only/control-node-contexts.txt \
  > /absolute/owner-only/control-node-boundary-before.json
```

(`make host-boundary-audit ARGS="--role nas --context-file ..."` is equivalent.) It covers TCP and UDP
listeners (rpcbind and NetBIOS also use UDP), classifies VNC by process on any port, and reports
`*_not_evaluated` when `sshd` or `testparm` could not be run, instead of a false `clean`. The built-in `stranger` context shows
what an unmatched peer gets. Findings are observations; the report also lists
`controls_not_evaluated` (router boundary, peer reachability, firewall rules, authentication
success, SSH admission filters) so nobody mistakes it for proof. `sshd -T -C` shows keywords for a
context but does **not** evaluate `AllowUsers`/`AllowGroups`/`DenyUsers`; only real logins from each
source prove admission (section 4).

## 2. Disposition per observed boundary

Fill this table with the owner. "Unknown" is a legitimate answer; leave it unknown rather than guess.

| Boundary | Consumers (inventory) | Disposition: keep / scope / disable | Evidence | Rollback |
|---|---|---|---|---|
| NAS SSH 22 | | | audit `ssh` section + probes | remove drop-in, `reload ssh` |
| NAS SMB 445 | | | audit `samba` section + probes | restore saved `smb.conf`, `reload smbd` |
| NAS SMB 139 | | | audit listener + probes | restore saved `smb.conf` |
| Control node rpcbind 111 | | | audit units + `rpcinfo -p` | `systemctl enable --now` the same units |
| Control node VNC 5900 | | | audit listener process class | re-enable unit / restore bind |
| Control node SSH 22 | | | audit `ssh` section + probes | remove drop-in, `reload ssh` |

Default proposals, for the owner to accept or reject per row:

- **SSH:** keys only, no root login, forwarding off, `AllowUsers` limited to the inventoried
  accounts and source ranges. Example: [`../network/sshd-boundary.example.conf`](../network/sshd-boundary.example.conf).
  Prefer source-pattern `AllowUsers` plus a firewall decision over `ListenAddress`: a
  `ListenAddress` that is not configured at boot makes sshd fail to bind.
- **SMB 139:** disable (`smb ports = 445`) unless a client in the inventory needs NetBIOS.
- **SMB 445:** keep only for inventoried LAN clients: `interfaces = <LAN interface/mask> lo`
  (`lo` is required with `bind interfaces only = yes`, or local tools such as `smbpasswd` break),
  `bind interfaces only = yes`, `hosts allow` for the LAN range, no guest access, `server min protocol = SMB2_10`
  or higher, `server smb encrypt = required` if every client supports it. If the NAS no longer
  serves SMB at all, retire `smbd`/`nmbd` instead.
- **rpcbind 111:** disable `rpcbind.socket` and `rpcbind.service` if nothing in the inventory uses
  NFS/RPC.
- **VNC 5900:** bind to loopback and reach it through a tunnel, or disable it. Do not expose VNC
  authentication directly to the LAN. A tunnel needs `AllowTcpForwarding local` plus
  `PermitOpen 127.0.0.1:5900` (ideally in a `Match User` block), which conflicts with the example's
  `AllowTcpForwarding no`; the audit treats that restricted form as acceptable. Setting `no` also
  breaks ProxyJump and VS Code Remote through this host.

## 3. Reachability proof (owner-run, before and after)

Binding is not reachability, and reachability is not authorization. From each **intended** peer and
from each **disallowed** peer (a LAN device not in the inventory; a device off the tailnet), record
only open/closed per port, and record *refused* and *timed out* separately (a timeout may mean a
filter, a refusal means a host answered):

```bash
nc -zv -w 3 <host> 22 ; nc -zv -w 3 <host> 445 ; nc -zv -w 3 <host> 139
nc -zv -w 3 <host> 111 ; nc -zv -w 3 <host> 5900
nc -zvu -w 3 <host> 111 ; nc -zvu -w 3 <host> 137     # UDP: weak evidence, no answer is ambiguous
```

The "from the internet" case is **not** tested from a mobile hotspot against a LAN or tailnet address:
that is unroutable and always looks closed. It needs the router's WAN address and port-forward
configuration, which this runbook does not cover, so it stays `unknown`.

Record booleans and the date, not addresses. A closed port from one vantage point proves nothing
about another. Whatever you did not probe stays `unknown`.

## 4. SSH change procedure (per host, attended, console ready)

Do not start unless you have the physical console or a second verified route (LAN versus tailnet).
No step runs from the only session you depend on. Check `systemctl is-active ssh.socket` first: with
socket activation `ListenAddress` is ignored and the unit to reload differs.

Every proof login below uses a fresh connection that cannot ride an existing one:
`ssh -o ControlPath=none -o ControlMaster=no -o BatchMode=yes -o IdentitiesOnly=yes -i <key> ...`
(called `<flags>` below). A multiplexed `ControlMaster` connection would pass a proof while new logins
are broken.

1. **Fresh key proof, per account and source.**
   `ssh <flags> -o PreferredAuthentications=publickey -o PasswordAuthentication=no <account>@<host> true`
   must succeed for **every** inventoried account and source before touching the server. Password
   login is never disabled on an assumption.
2. **Hold two sessions** open on the host (one to edit, one as a lifeline). `reload` keeps
   established sessions; do not `restart`.
3. **Save the rollback state** under a timestamp so a second run cannot nest into an old copy:
   `sudo cp -a /etc/ssh/sshd_config.d "/root/sshd_config.d.before-$(date +%Y%m%dT%H%M%S)"`
   (root-only parent, mode 0700). Note whether the drop-in file already exists and whether `sudo sshd -T`
   already lists `allowusers`, `allowgroups` or `denyusers`.
4. **Phase 1: authentication and forwarding keywords only** (the example without `AllowUsers`). Stage
   it at `/etc/ssh/sshd_config.d/10-brokkr-boundary.conf`, run `sudo sshd -t` (syntax only), then
   check the real effective result by re-running the audit with the contexts: an earlier-sorting
   drop-in can override single-value keywords.
5. **Arm an automatic rollback** *before* the reload, with enough time for every proof (20 minutes
   or more when automation sources must be tested):

   ```bash
   sudo systemctl reset-failed brokkr-ssh-rollback.service 2>/dev/null || true
   sudo systemd-run --collect --on-active=20min --unit=brokkr-ssh-rollback \
     /bin/sh -c 'rm -f /etc/ssh/sshd_config.d/10-brokkr-boundary.conf && systemctl reload-or-restart ssh'
   ```

   If the file existed before, restore the saved copy in that command instead of removing it. Use
   `sshd` instead of `ssh` where the unit has that name.
6. `sudo systemctl reload ssh`.
7. **Verify with new sessions:** every inventoried account and source logs in with its key (same
   flags); then
   `ssh <flags> -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no <account>@<host>`
   must be refused (PAM keyboard-interactive is the other password path); then re-run the audit and
   confirm `ssh_password_or_interactive_auth_possible` and `ssh_unmatched_peer_may_use_password`
   are gone.
8. **Phase 2: `AllowUsers`.** `AllowUsers` is the real lockout lever and the audit cannot test it.
   First record the source address sshd actually sees for each consumer (`ss -tn state established
   '( sport = :22 )'` during a login, or the auth log): it may be IPv6, a tailnet address, or a
   NAT/subnet-router address that your range does not cover. Add the line, run `sudo sshd -t`, keep the
   timer armed (arm a fresh one with `systemd-run` if the first has run low), reload, and prove
   admission with a real login from every inventoried source again. `MaxAuthTries` stays at the
   default 6 so clients that offer several keys are not locked out.
9. Only then check that the timer still exists and the drop-in is still in place
   (`systemctl is-active brokkr-ssh-rollback.timer`; if it already fired, the change was reverted and
   the proofs above were meaningless), and stop it: `sudo systemctl stop brokkr-ssh-rollback.timer`.

Abort and roll back if any proof fails, a source is missing from the inventory, a root consumer
appears, or the audit shows a `Match` block giving an unexpected context a weaker policy.

## 5. Samba, rpcbind and VNC changes

Each is a separate approval. Keep the order: tighten, verify, then (optionally) close.

- **Samba:** back up the configuration (root-only), edit, run `testparm -s`, then apply. `smb ports`,
  `interfaces` and `bind interfaces only` are read only when `smbd` binds its sockets, so `reload`
  does **not** change the listeners: use `sudo systemctl restart smbd nmbd` (this drops client
  sessions; do it in a quiet window). An `interfaces` address that is not up at service start gives
  no listener, the same boot race as `ListenAddress`; order the unit after `network-online.target`
  or prefer `hosts allow` plus a firewall decision. Verify from one intended client and one
  disallowed peer. Rollback: restore the copy and restart again. Do not delete shares or data. An unchanged retired Time Machine share
  stays retired.
- **rpcbind:** first `systemctl list-dependencies --reverse rpcbind.socket` (`rpc-statd` and
  `nfs-server` pull it back in). If nothing in the inventory uses NFS/RPC:
  `sudo systemctl disable --now rpcbind.socket rpcbind.service`, then
  `sudo systemctl mask rpcbind.socket rpcbind.service` so a later NFS mount or boot cannot revive it.
  Verify the audit no longer reports `rpcbind_listening_non_loopback` for TCP **or** UDP and that
  nothing broke. Rollback: `unmask`, then `enable --now rpcbind.socket`.
- **VNC:** identify the owning unit first (the audit gives only the process class). Change its bind
  to loopback or disable it, verify the tunnel path you intend to use, and keep the old unit file.

## 6. After-state evidence and acceptance

Re-run the audit and the probes in section 3 after the approved changes. The ticket is acceptable
when, for each boundary in section 2: an owning service and an explicit disposition are
documented, intended paths work, and disallowed-path probes are closed. Unprobed controls remain
`unknown`. Record the audit event (date, approval, host, change, evidence file name, reversal used
or not) in the owner record; this is the reversal recipe and audit trail for the mutation.

## Not covered here

Host firewall rules, the router boundary, Tailscale ACLs and Tailscale SSH on the control node. They are
separate decisions; file a ticket rather than folding them into a sshd change.
