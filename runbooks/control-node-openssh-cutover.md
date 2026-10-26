# Control-node OpenSSH cutover (disable Tailscale SSH)

This runbook prepares an owner-attended change that turns off Tailscale SSH on
the control node and keeps remote shell access through the host's normal OpenSSH
service over the tailnet. Nothing here runs unattended. Do not run any step from
a Tailscale SSH session on the control node: turning Tailscale SSH off ends that
session.

## Why

With Tailscale SSH, `tailscaled` itself is the SSH server and performs port and
Unix-socket forwarding as root. The October 2026 Tailworm report describes lab
chains in which an already-compromised tailnet device that an SSH rule permits
gains root on the target through forwarding races. Tailscale had not confirmed
the findings or shipped a fix when this runbook was written. OpenSSH drops
privileges before forwarding, and the report found it unaffected for this class.

The control node runs the coordination services, so it is the most valuable
target in a Brokkr deployment. Other managed nodes already use OpenSSH; the M5
policy keeps its `ssh` section empty.

Tailscale's default policy carries an SSH rule from `autogroup:member` to
`autogroup:self` with users `autogroup:nonroot` and `root` in `check` mode. If
that rule is live, every device of the owner's user can request root on the
control node. Check mode only gates when a session may start; it does not stop
the reported escalation.

Out of scope: Tailnet Lock, client upgrades, tagging the control node, and
least-privilege grants for its application ports.

## Order matters

1. Turn Tailscale SSH off on the node first, then change the policy. While the
   node advertises Tailscale SSH, `tailscaled` answers TCP 22 on the node's
   tailnet address. Removing the policy rule first would leave that port
   answered by `tailscaled` and refusing everyone, so no SSH over the tailnet
   would work at all.
2. For the same reason, OpenSSH over the tailnet cannot be tested before the
   node-side switch. The pre-cutover proof uses the LAN fallback route, which is
   also the rollback path.

## 0. Owner-only inputs

Keep all of the following in an owner-only mode-0700 directory outside the
repository:

- The control node's tailnet DNS name and the operator's SSH alias for it.
- The expected ED25519 host-key fingerprint. Read it on the host from the
  physical console or the already-verified LAN route:
  `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
- An inventory of every person and automation that opens SSH sessions into the
  control node: source device, remote account, and owning repository. Under
  Tailscale SSH none of them needed a key in `authorized_keys`; under OpenSSH
  each one does. Review the owning repositories' deploy and maintenance scripts
  (including this repository's `BROKKR_SSH_TARGET` account), and review the
  node's recent Tailscale SSH activity privately:

  ```bash
  sudo journalctl -u tailscaled --since=-30d --no-pager --grep=ssh \
    > /absolute/owner-only/tailscaled-ssh.log
  ```

  The log wording varies between versions; record only source roles and target
  accounts in the inventory. Every inventoried account must be non-root. A
  change an owning repository needs goes through an issue in that repository
  before the cutover.
- Physical console access, or a LAN SSH route whose host key is already
  verified.

## 1. Read-only preflight (before)

`scripts/control-node-ssh-cutover.py` runs `tailscale status --json`,
`ssh -G`, `ssh-keygen -F`, `sshd -T -C`, and `systemctl is-active`, and reads
key-file metadata. It never connects to the target and changes nothing itself.
`ssh -G` evaluates the workstation's SSH client configuration exactly as `ssh`
would, including any `Match exec` commands in it, so review that configuration
as you would before any `ssh` run. The single-line JSON output contains only
booleans, counts, and reason codes, so it is safe to keep as evidence. Exit
codes: 0 pass, 2 blocked, 1 error.

On the operator workstation:

```bash
python3 scripts/control-node-ssh-cutover.py operator --phase before \
  --target-dns-name control-node.example.ts.net \
  --ssh-host control-node \
  --expected-host-key-fingerprint 'SHA256:<fingerprint from step 0>'
```

This proves the target is online and currently advertises Tailscale SSH, the
alias resolves directly to the target's tailnet name or address on port 22
without a proxy and without root, host-key checking is not weakened, and
`known_hosts` already holds the expected key. It must pass. Two warnings need a
decision:

- `other_tailscale_ssh_nodes_present`: other nodes still use Tailscale SSH. In
  step 4, narrow their rules to explicit destinations instead of deleting them;
  `autogroup:self` cannot exclude a single device.
- `tailscale_ssh_host_key_differs`: Tailscale SSH presents a different host key
  from OpenSSH. The first OpenSSH connection is checked against the expected key
  that the preflight already found in `known_hosts`. Never accept a different
  key during the cutover.

If it blocks with `known_hosts_missing_expected_key`, add the verified key for
the name the alias resolves to without trusting the network. Read
`/etc/ssh/ssh_host_ed25519_key.pub` over the verified LAN route or from the
console, put that name in front of it, append the line to `~/.ssh/known_hosts`,
and re-run the preflight. Never use `ssh-keyscan` or a first-connection prompt
for this.

On the control node, from the console or the LAN route, run the script from a
Brokkr checkout of the reviewed commit, once per inventoried account and source
device:

```bash
sudo python3 scripts/control-node-ssh-cutover.py host --phase before \
  --ssh-user <inventoried-account> \
  --client-address <source device tailnet address>
```

The script asks `sshd -T -C` for the effective configuration of a connection
from that source address, once for the account and once for `root`, so
address- and user-based `Match` blocks apply. It requires `UseDNS no` (the
OpenSSH default), because hostname-based `Match` and `AllowUsers` rules cannot
be evaluated from an address. It proves that:

- `sshd` is active and accepts only public keys;
- `PermitRootLogin` is `no`;
- `sshd` listens on port 22 on the tailnet address of the source's address
  family;
- the account passes `DenyUsers`, `AllowUsers`, `DenyGroups`, and `AllowGroups`
  for that source;
- the account has at least one valid, option-free public key in an
  `authorized_keys` file whose path passes OpenSSH's `StrictModes` ownership
  and permission rules.

It must pass for every account and source.

If it blocks with `root_key_login_possible`, the host still allows root to log
in with keys (Debian's default is `prohibit-password`). Add a drop-in with
`PermitRootLogin no` that sorts before vendor drop-ins. Run `sudo sshd -t`,
reload `sshd` with the console open, and re-run the preflight. Do not continue
while root can log in.

Finally, prove public-key login and the fallback route together from the
operator workstation:

```bash
ssh -o BatchMode=yes -o PreferredAuthentications=publickey \
  -o StrictHostKeyChecking=yes <lan-fallback-alias> true
```

## 2. Snapshot the policy

Save the complete current policy as an owner-only mode-0600 file and record its
SHA-256 digest. List every `ssh` rule whose destination can match the control
node: `autogroup:self`, a host alias for its address, or a tag it carries.

## 3. Node-side cutover

With the owner present and a console or LAN OpenSSH session open on the control
node:

```bash
sudo tailscale set --ssh=false
```

In a new terminal on the operator workstation, prove OpenSSH over the tailnet:

```bash
ssh -o BatchMode=yes -o PreferredAuthentications=publickey \
  -o StrictHostKeyChecking=yes control-node true
python3 scripts/control-node-ssh-cutover.py operator --phase after \
  --target-dns-name control-node.example.ts.net \
  --ssh-host control-node \
  --expected-host-key-fingerprint 'SHA256:<fingerprint from step 0>'
```

Then re-run the host preflight with `--phase after` for every inventoried
account and source. Everything must pass. If the probe fails, roll back (section 6) and
diagnose from the LAN session. Never weaken `StrictHostKeyChecking`, accept a
changed host key, or enable password login to make the probe pass.

## 4. Policy change

The node no longer advertises Tailscale SSH, so this step does not change
reachability. It is the second layer: if Tailscale SSH were later re-enabled on
the node by mistake, no rule would admit a session, and port 22 on the tailnet
would fail closed instead of offering root.

Copy [`network/tailscale/control-node-ssh-policy.example.json`](../network/tailscale/control-node-ssh-policy.example.json)
into the owner-only directory and replace its three markers with exact tailnet
addresses: the control node, the operator workstation, and one other untagged
device of the owner's user (for example a phone or another server) as the peer
deny probe. Confirm that no marker remains:

```bash
grep -c '__BROKKR_' /absolute/owner-only/control-node-ssh-candidate.json
```

The count must be `0`. Merge into a complete owner-only candidate:

- Delete every `ssh` rule listed in step 2. If the preflight reported other
  Tailscale SSH nodes, replace a deleted rule with one whose destinations name
  only those nodes. Otherwise leave `ssh` empty.
- Add the fragment's `hosts`, `grants`, `tests`, and `sshTests` entries. Keep
  every unrelated rule and test.

The grant keeps TCP 22 from the operator device working even after a later
least-privilege policy removes broad rules. The `sshTests` reject the policy if
any surviving SSH rule still lets the operator device or the peer probe reach
the control node as `root` or as a non-root account.

Validate the complete candidate with the admin console preview or the official
`POST /api/v2/tailnet/:tailnet/acl/validate` endpoint, using the owner's approved
credential flow. Apply it from the admin console, record the new digest, and
re-run the OpenSSH probe and the operator preflight with `--phase after`.

## 5. Automations

Run each inventoried automation once through OpenSSH and confirm it succeeds.
Fix failures in the owning repository, not on the host. Remote access to the
control node goes only through OpenSSH from now on; do not re-enable Tailscale
SSH to unblock an automation.

## 6. Rollback

Rolling back re-exposes the reported risk. Record the reason in owner-only
incident evidence.

- After step 3 only, from the console or LAN session:
  `sudo tailscale set --ssh=true`.
- After step 4, restore the exact snapshotted policy first and verify its
  digest, then run `sudo tailscale set --ssh=true`. Reversing that order leaves
  `tailscaled` answering port 22 with no rule that admits a session.

Verify with the former known-good Tailscale SSH session from the operator
workstation.

## 7. Evidence

Keep these: the sanitized preflight JSON for both roles and phases, the policy
digests before and after, and pass/fail outcomes for every probe and
automation. Never record addresses, DNS names, account names, fingerprints, or
raw logs in public evidence.

## References

- [Tailscale SSH: default rule, check mode, and disabling it on a device](https://tailscale.com/kb/1193/tailscale-ssh)
- [Policy file syntax: `tests` and `sshTests`](https://tailscale.com/docs/reference/syntax/policy-file)
- [Grants syntax: host-alias selectors and `tcp:<port>`](https://tailscale.com/docs/reference/syntax/grants)
- [Tailscale security bulletins](https://tailscale.com/security-bulletins)
- [Tailworm report (unconfirmed lab findings, October 2026)](https://tailworm.com/)
