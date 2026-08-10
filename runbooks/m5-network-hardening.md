# M5 default-deny network hardening

This runbook applies Brokkr's fail-closed M5 host-network profile without
assuming live addresses, interface names, ports, or account names. The live
profile is owner-only state and must never be committed.

The design follows Tailscale's current Ubuntu guidance to deny unsolicited
physical-interface inbound traffic. Tailscale's WireGuard UDP port is
configurable, so the profile requires an observed `tailscaled` socket rather
than silently assuming the default.

There is an important extra boundary: Tailscale netfilter mode `on` deliberately
accepts `tailscale0` in its early `ts-input` chain, before UFW INPUT rules.
Therefore UFW per-port rules on `tailscale0` do not enforce service boundaries.
Brokkr installs a separate owned nftables `inet` prerouting chain at filter
priority. Conntrack is already available there, and a final interface-scoped
drop runs before Tailscale INPUT acceptance. It permits established/related
replies, ICMP, the declared management ports, and exact tailnet Samba sources.
UFW remains the default-deny policy for physical interfaces. The verifier
requires both layers and rejects the early-accept posture if the owned
prerouting gate is absent or differs from the rendered policy.

This host policy does not identify individual Tailscale peers: SSH and declared
management listeners remain reachable by any peer that the tailnet control
plane permits to reach M5. Samba is the only service source-scoped here. Tailnet
peer least privilege belongs to Brokkr issue #91. A live apply of this profile
is gated on #91 being deployed and verified, or on an equivalent owner-reviewed
tailnet source policy already being in force.

Samba's own manual warns that `bind interfaces only` needs loopback in
`interfaces`, and that `hosts allow`/`hosts deny` interactions are subtle. The
generated global include keeps loopback, exact interface/source boundaries, no
guest mapping or share-level guest access, SMB3 with required transport
encryption, no anonymous enumeration, no usershares, and no printer/spooler exposure. The include is
last in `[global]` so weak legacy values cannot override it.

OpenSSH uses the first obtained value for most keywords. The managed `00-`
drop-in intentionally sorts before vendor and cloud-init drop-ins; the
post-apply verifier still checks the effective policy rather than trusting file
placement.

Primary references:

- <https://tailscale.com/docs/how-to/secure-ubuntu-server-with-ufw>
- <https://tailscale.com/docs/reference/faq/firewall-ports>
- <https://tailscale.com/docs/reference/netfilter-modes>
- <https://netfilter.org/projects/nftables/manpage.html>
- <https://www.samba.org/samba/docs/4.18/man-html/smb.conf.5.html>

## 1. Console and recovery preparation

Do not begin without local physical-console access. Verify the console login,
sudo path, and recovery boot media before touching networking. Keep the console
open throughout the change.

Record a read-only baseline in an owner-only incident directory:

```bash
date -u
sudo ss -lntup
sudo ufw status verbose
sudo nft list ruleset
sudo iptables -w -S
sudo sshd -T -C user="$USER,host=localhost,addr=127.0.0.1"
sudo testparm -s
sudo systemctl is-enabled smbd nmbd
sudo systemctl is-active smbd nmbd tailscaled
```

Also prove a fresh public-key-only OpenSSH login over `tailscale0` from a second
terminal. Tailscale's built-in SSH need not be enabled; this profile protects
normal OpenSSH by interface. Do not close either session yet.

Console recovery if both sessions fail:

1. Log in locally and inspect `systemctl list-timers 'brokkr-m5-network-*'`.
2. Let the armed timer restore the snapshot, or run the printed transaction's
   `rollback` command locally.
3. Verify the prior UFW and owned nftables-table state, sshd, smbd, and nmbd
   state before retrying.
4. Never disable the timer just to regain access; rollback first, diagnose from
   the preserved receipt, then render a corrected profile.

## 2. Build the owner-only profile

Copy the public example outside the checkout. Replace its documentation values
from the baseline. List every inference listener, including loopback-only ones.
Time Machine normally needs TCP 445 only; retaining TCP 139, UDP 137/138, or
`nmbd` requires `retain_netbios=true` and a specific
`netbios_exception_reason`. Enabling SSH X11, agent, or TCP forwarding similarly
requires a specific `ssh_exception_reason`.

The mutation runs as root and the parser compares profile ownership with its
effective UID. Install the final profile as root-owned mode 0600:

```bash
sudo install -o root -g root -m 0600 /path/to/reviewed-profile \
  /etc/brokkr/m5-network.conf
```

Do not put credentials in this file. CIDRs and live topology are private
locators, which is why the live file is not tracked.

## 3. Render and preflight without mutation

From the exact accepted Brokkr release:

```bash
sudo ./scripts/m5-network-profile.py render \
  --config /etc/brokkr/m5-network.conf
sudo ./scripts/m5-network-profile.py preflight \
  --config /etc/brokkr/m5-network.conf
```

Review every rendered allow. UFW must have deny incoming, allow outgoing, deny
routed, the observed Tailscale UDP transport, and exact physical Samba sources;
it must have no `tailscale0` allowance. The nftables prerouting gate must allow
OpenSSH and declared management listeners, exact tailnet Samba sources, and no
loopback-only listener. `preflight` validates current sshd/Samba, interfaces,
the configured `tailscaled` UDP socket, kernel support for the complete atomic
nftables batch, systemd rollback support, and that the invoking SSH client
routes through the management interface. An advisory local session does not
replace this review.

## 4. Apply with watchdog armed

Do not perform the live apply until the tailnet control-plane dependency above
has been verified. Rendering, preflight, and the rollback drill may be prepared
without claiming that this host policy alone restricts individual tailnet
peers.

Install this exact reviewed script at a root-owned stable path before apply so
the transient rollback timer does not depend on a disposable worktree:

```bash
sudo install -o root -g root -m 0755 scripts/m5-network-profile.py \
  /usr/local/sbin/brokkr-m5-network
sudo /usr/local/sbin/brokkr-m5-network apply \
  --config /etc/brokkr/m5-network.conf
```

The command takes a non-blocking process lock, snapshots UFW, the owned nftables
table/unit, SSH, Samba, and nmbd; arms a systemd rollback timer; installs and
validates daemon policy; atomically applies the pre-INPUT tailnet gate; applies
the exact physical-interface UFW plan; and runs the post-apply verifier. Any
local failure immediately restores the snapshot. Success leaves the watchdog
armed and prints an opaque transaction ID; it is not completion.

## 5. Probe from distinct paths, then confirm

Before the timer expires, collect all acceptance evidence:

- From a new, distinct management session: public-key OpenSSH succeeds and
  password/keyboard-interactive authentication are rejected.
- From an approved Time Machine client: TCP 445 and an authenticated share probe
  succeed; backup discovery/mount still works.
- From a disallowed physical/LAN source: SSH, SMB, Whisper, and other managed
  inference ports are rejected as applicable.
- From a tailnet peer denied by the verified #91 (or equivalent owner-reviewed)
  control-plane policy: the applicable management paths are rejected. Do not
  claim this probe from the host policy alone.
- On the host: `verify` passes; listeners, effective sshd policy, effective Samba
  policy, exact pre-INPUT nftables gate, physical UFW rules,
  Tailscale/UFW coexistence, and nmbd state match intent.

```bash
sudo /usr/local/sbin/brokkr-m5-network verify \
  --config /etc/brokkr/m5-network.conf
sudo /usr/local/sbin/brokkr-m5-network confirm \
  --transaction REPLACE_WITH_PRINTED_ID \
  --authorized-probes-pass \
  --disallowed-probes-rejected \
  --timemachine-pass
```

The applying SSH session cannot confirm its own transaction. Confirmation must
come from a distinct management-routed SSH session, or from an explicitly marked
physical-console invocation (`BROKKR_NETWORK_CONSOLE=1`). This makes the three
probe flags attestations from an independently connected path rather than a
self-assertion by the session whose survival is under test.

Keep the mode-0600 transaction receipt, before/after listeners, effective daemon
settings, ruleset, accepted/rejected probe results, exact deployed revision, and
an observed rollback drill as issue evidence. Sanitize live addresses before any
public comment.

## 6. Manual rollback drill

Before declaring the rollout complete, perform a supervised apply with a harmless
test change and let its timer fire, or invoke explicit rollback while the timer is
armed:

```bash
sudo /usr/local/sbin/brokkr-m5-network rollback \
  --transaction REPLACE_WITH_PRINTED_ID
```

Prove prior UFW and owned nftables-table state and files were restored, sshd and
Samba validate, service enable/active state is restored, and the old access path
works. A rollback receipt without those probes is not restorability evidence.
