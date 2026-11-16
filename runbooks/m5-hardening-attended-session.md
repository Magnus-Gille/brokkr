# M5 hardening: owner-attended session sheet

Single ordered sheet for BROKKR-90 (default-deny network), BROKKR-91 (tailnet
least privilege), BROKKR-89 (root FDE) and the GOPS-11 SSH follow-ups. It adds no
new mechanism; it sequences the existing ones and states the lockout protection
and rollback for each step. Nothing here is applied unattended, and a merged PR is
not live acceptance. Live values (addresses, accounts, key paths) stay in the
owner-only incident directory, never in git.

Detailed procedures: `m5-network-hardening.md`, `m5-tailnet-access.md`,
`m5-root-fde-migration.md`.

## 0. Preconditions (stop if any is missing)

- Physical console or KVM works and the operator password is known (the console
  login is unaffected by SSH password-auth being off).
- Two independent management sessions open, each inside `tmux` on the M5:
  A is the working session, B is the rescue session and is not used for
  changes. Open session C as a second tailnet client or device, as the operator
  account. After apply SSH is reachable over the tailnet only, so a LAN SSH
  attempt is an expected-denied probe, not a session. If Tailscale itself fails
  (key expiry, policy change) the console is the only way in.
- Check `SSH_CONNECTION` is set correctly in the shell that runs apply/confirm
  (it is read under `sudo`; `env_reset` can strip it and a reattached tmux pane
  can hold a stale value). Run `preflight` once from that exact shell first.
- A second authorized key exists and has logged in once (see step 6). Do not
  start with a single key.
- The exact accepted Brokkr release SHA is chosen and the script installed
  root-owned at `/usr/local/sbin/brokkr-m5-network` from that SHA.
- Quiet window: agent and deploy flows (`m5-build`, gateway deploys, Hugin) are
  paused. About 170 operator logins a day come from automation.
- Baseline captured read-only (section 1 of `m5-network-hardening.md`) plus:
  `sudo sshd -T -C user=<each account>,host=localhost,addr=<tailnet-ip>` and the
  same for a LAN address, for the operator and the build account. These catch
  `Match` overrides that a localhost-only check misses (BROKKR-170 left them
  unknown).

## 2. Dry run

```bash
sudo ./scripts/m5-network-profile.py render    --config /etc/brokkr/m5-network.conf
sudo ./scripts/m5-network-profile.py preflight --config /etc/brokkr/m5-network.conf
```

The live profile must list every inference listener (gateway, llama, whisper and
any other) and a `ssh_probe_context` for the operator, the build account and one
tailnet and one LAN client. Whisper should be `management` only if a tailnet
client genuinely needs it; otherwise bind it to loopback and mark it `loopback`.

## 3. Order of changes

1. **BROKKR-91 first on the control plane** (tailnet policy with embedded tests;
   Tailscale rejects a failing test). The host profile does not identify peers,
   so this must be in force before step 4. Rollback: Tailscale admin console
   policy history, restore the previous version.
2. **BROKKR-90 host profile** (below). Rollback: timers, then
   `brokkr-m5-network rollback --transaction <id>`.
3. **BROKKR-89 FDE** is a separate session with its own recovery contract. Do not
   combine it with this one.

## 4. Apply BROKKR-90

From session A:

```bash
sudo /usr/local/sbin/brokkr-m5-network apply --config /etc/brokkr/m5-network.conf
```

Then, from session C (a distinct path) and the Time Machine client, run the probes
from section 5 of `m5-network-hardening.md`. Required evidence: listeners
before/after, effective sshd per context, firewall ruleset, an allowed and a
denied probe per path, successful Time Machine backup discovery.

```bash
sudo /usr/local/sbin/brokkr-m5-network verify  --config /etc/brokkr/m5-network.conf
sudo /usr/local/sbin/brokkr-m5-network confirm --transaction <id> \
  --authorized-probes-pass --disallowed-probes-rejected --timemachine-pass
```

`confirm` must run as the operator from a distinct tailnet SSH session (C), or at
the console with `sudo BROKKR_NETWORK_CONSOLE=1 ...`. Confirming from a LAN
session is destructive: confirm stops the timer, its preflight then fails the
management-route check and the script rolls everything back.

### Optional extra dead-man (arm immediately before `apply`, not earlier)

The script's own watchdog is the rollback. If you also want an independent
timer, arm it right before `apply` with a window longer than `rollback_seconds`
plus your probes, and re-arm it on any retry (`systemctl reset-failed` if a unit
of that name failed). Its limits: it is a blunt fail-open, not a rollback. It
leaves UFW disabled even if it was active before, deletes a `00-` drop-in that
may have pre-existed, does not restore the Samba include or nmbd, leaves the
persistent tailnet-filter unit enabled (the nft table returns on reboot), takes
no lock against a running transaction, and if you forget to stop it after
`confirm` it silently undoes the hardening. After it fires, run
`brokkr-m5-network rollback --transaction <id>` or compare against the baseline.
It does not help with a lockout from the tailnet policy change.

```bash
sudo systemd-run --unit=attended-fw-deadman --on-active=1200 \
  /bin/sh -c 'ufw --force disable; nft delete table inet brokkr_m5_tailnet 2>/dev/null; rm -f /etc/ssh/sshd_config.d/00-brokkr-m5-network.conf; systemctl reload ssh'
# cancel only after confirm: sudo systemctl stop attended-fw-deadman.timer
```

### SSH drop-ins

The profile writes `00-brokkr-m5-network.conf`; GOPS-11 step 1 already installed
`10-no-password-auth.conf`. The lower number wins. The `00-` file
also sets `AuthenticationMethods publickey`, `PermitRootLogin no` and the
forwarding keys, so compare `sshd -T` before and after rather than assuming the
two agree. A `Match` block overrides both files regardless of number, which is
why `ssh_probe_context` exists. Contexts fix `host=localhost` and do not model
`LocalAddress`/`LocalPort` matches; check the sshd config for those by hand.
Make sure each probe user exists on the host (a typo silently matches nothing). Keep `10-` until the profile is confirmed;
afterwards it is redundant but harmless. Rollback restores `00-` exactly as it was
(absent means removed) and reloads sshd; `10-` is untouched.

## 5. Abort criteria (roll back, diagnose from the receipt, do not improvise)

- Session B or C cannot open a new connection over the tailnet.
- `verify` fails, or any denied probe succeeds.
- Time Machine cannot mount, or the gateway/Whisper probes fail.
- More than 5 minutes pass without a decision: let the timer fire.

Never stop a timer to regain access. Roll back first.

## 6. GOPS-11 follow-ups (separate, later windows)

1. **Hardware keys as a second way in.** Owner generates both keys in their own
   terminal (touch and PIN are entered there, never in chat), e.g.
   `ssh-keygen -t ed25519-sk -O resident -O verify-required -C m5-backup`. Append
   the public keys to `authorized_keys` after a fingerprint check and test each
   with an explicit `-i` login before relying on it.
2. **Agent logins on `sk` keys** (needs `no-touch-required`, changes ~170 logins a
   day): its own plan and quiet window. Not part of this session.
3. **Restrict SSH**: this profile makes SSH tailnet-only (no LAN SSH rule is
   rendered). Check that `m5-build` and fleet automation arrive over the
   tailnet first; anything using the LAN path breaks. Allowing the home LAN
   too would need a deliberate profile extension and review.
4. **Passwordless sudo review**: a design question; agents rely on `sudo -n`.
   Out of scope here; track in GOPS-11.
5. Delete `~/iceage-uninstall-20261002.tar.gz` only after the owner confirms.

## 7. Rollback matrix

| Layer | Undo | Needs |
| --- | --- | --- |
| Host profile (UFW, nft table, sshd `00-`, Samba include, nmbd) | watchdog timer, or `brokkr-m5-network rollback --transaction <id>` | console or any live session |
| Optional extra dead-man (section 4) | fires after its window; blunt, see limits | none |
| sshd only | remove `00-brokkr-m5-network.conf`, `sshd -t`, `systemctl reload ssh` | console |
| Tailnet policy | restore previous policy version in the admin console | admin login |
| Everything, last resort | console login, `ufw --force disable`, `nft delete table inet brokkr_m5_tailnet`, remove `00-` drop-in, reload ssh | console |

After any rollback, prove prior state (UFW, nft table, sshd/smbd/nmbd validate and
enabled state) before retrying; a receipt alone is not restorability evidence.

## 8. Close-out

Attach to BROKKR-90 and GOPS-11, sanitized: before/after listeners, effective sshd
per context, ruleset, probe results, deployed release SHA, rollback drill result.
