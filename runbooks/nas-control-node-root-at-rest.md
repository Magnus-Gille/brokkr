# NAS and control-node root at-rest protection (owner decision, then attended migration)

Prepares BROKKR-173. This document **does not authorize** disk conversion, formatting, key access or
rotation, service changes or data moves, and a merged document is not live encryption. It exists to
get from "no `crypt` device observed" to an explicit owner decision with recovery proven first.

Observed (BROKKR-170, read-only, 2026-11-03): ext4 root filesystems on the NAS and the control node
with no crypt device in their observed backing paths and no `crypto_LUKS` device. That is evidence of
**absent block-layer root encryption**, not proof that every application, file or backup is
unencrypted. The M5 root is separate (BROKKR-89, [`m5-root-fde-migration.md`](m5-root-fde-migration.md));
its design is a pattern here, not NAS or control-node policy. Storage migration BROKKR-132 and the
existing backup controls are coordinated with, not duplicated.

Keep evidence in the owner-only record ([`../docs/backup-evidence.md`](../docs/backup-evidence.md)).
Never put device names, UUIDs, mount paths, LUKS headers, passphrases or recovery material in Git,
Munin, tickets or logs.

## 1. Content-blind inventory (read-only)

`scripts/root-at-rest-inventory.py` reads `lsblk` topology and `findmnt` only. For each owner-labelled
store it reports `block_layer` = `encrypted | absent | unknown`, whether it shares the root's physical
stack, and the medium class (`sd`, `usb`, `nvme`, `sata`, `unknown`). It prints no names, paths or
UUIDs, and also reports capability facts that bound the design: TPM device node, cryptsetup,
non-comment `/etc/crypttab` entries, initramfs remote-unlock setup.

Put the stores, one `LABEL=/mount` per line (plus `swap=[SWAP]`, since unencrypted swap undermines an
encrypted root), in an owner-only mode-0600 file so paths stay out of `sudo`'s argv log:

```bash
sudo python3 scripts/root-at-rest-inventory.py --role nas \
  --store-file /absolute/owner-only/nas-stores.txt > /absolute/owner-only/nas-at-rest.json
sudo python3 scripts/root-at-rest-inventory.py --role control-node \
  --store-file /absolute/owner-only/control-node-stores.txt > /absolute/owner-only/control-node-at-rest.json
```

(or `make root-at-rest-inventory ARGS="--role nas --store-file ..."`). The owner supplies the labels; the
tool does not discover your stores. Common stores that sit on the root of these hosts: service
databases and queues, `.env` and token files, the Tailscale node identity, SSH host keys, logs and
journals, backup staging areas, and the Heimdall/Hugin runtime state. List them from a
**content-blind** survey by file *class* and owner, never by reading values.

## 2. Per-store protection table

Fill with the owner. Three states only; leave `unknown` when unsure.

| Store | Block layer (inventory) | File/application layer | Backup copy encrypted + integrity + restore + key custody |
|---|---|---|---|
| root filesystem | | | |
| service data | | | |
| credentials / env files | | | |
| Tailscale identity, SSH host keys | | | |
| backup staging | | | |

Backups are their own column on purpose: *configured is not healthy*. Distinguish copy,
integrity, restore and key-recovery evidence, as the backup-evidence document defines.

## 3. What at-rest protection buys here

It protects against loss, theft, repair/RMA or disposal of a disk or whole host. It does not
protect a running, compromised host or its network exposure, which is BROKKR-172's job. The highest-value
material on root is usually **identity** rather than data: the Tailscale node key, SSH host keys and
service tokens. Whoever holds an intact unencrypted disk can impersonate the host. That is why the
loss procedure matters regardless of the design chosen: revoke the device in the tailnet, rotate the
tokens it held, and re-key the host. Keep that recovery recipe next to the decision.

## 4. Design options for unattended hosts

Unattended reboot, power loss and remote access are hard constraints. Hardware facts (TPM, boot
medium, whether the root is on SD, USB or NVMe) come from the inventory; do not assume them. Raspberry
Pi class boards generally have no TPM, so TPM-bound unlock is off the table unless the inventory
shows a TPM.

| Option | Unattended reboot | Remote recovery | Cost / risk |
|---|---|---|---|
| **A. Root LUKS2, passphrase typed at boot over SSH (initramfs remote unlock)** | No: waits for a human after every power loss | Yes, if the early-boot network works | Strongest simple posture; a power cut at night means downtime until the owner unlocks. Needs the initramfs SSH key and network to be tested. |
| **B. Root LUKS2, network-bound unlock (Tang/Clevis) with passphrase fallback** | Yes, while the key server is reachable on the LAN | Passphrase fallback | The Tang host must not share the theft boundary, and after a whole-site power loss it may be down too: expect a manual unlock then. More moving parts. |
| **C. Root LUKS2, TPM2-bound** | Yes | Passphrase fallback | Only if hardware has a TPM and Secure Boot state is meaningful; see the M5 runbook for the pattern. |
| **D. Root unencrypted, data on a LUKS2 data volume, identity secrets minimised** | Data volume needs an unlock path too (keyfile on root defeats it) | Easier | Protects bulk data and backups, but identity material on root remains exposed. Pairs with the loss recipe in section 3. |
| **E. Accept the residual risk, explicitly, with compensating controls** | n/a | n/a | Physical security, tailnet device revocation, token rotation recipe, encrypted backups. A legitimate decision when the owner records it. |

Proposed starting position for the owner to accept or change: **E now, plus D for any store that
holds bulk personal data (coordinated with BROKKR-132), and revisit A or B for root once a restore
drill exists**. This is a proposal, not a decision. The one thing not to do is a quiet in-place
conversion: the M5 runbook forbids in-place re-encryption of a live root for good reason, and the
same applies here. The migration path is backup, reinstall or reformat, restore, prove.

## 5. Owner decision record (template)

Stored in the owner record, not in Git:

```
Host: nas | control-node        Date:        Decided by: Magnus
Chosen design: A | B | C | D | E (+ combination)
Why this posture is acceptable / what threat it addresses:
Unattended-reboot behaviour accepted (including after whole-site power loss):
Recovery secret custody (where, who can reach it, independent of the host):
Loss/theft procedure verified on (date):
Restore drill passed on (date) and key-recovery drill passed on (date):
Revisit by (date):
```

## 6. Gate before any migration

All of these must be true and evidenced, and the owner must approve the exact action just in time:

1. Chosen design recorded (section 5), including the accepted reboot behaviour.
2. Backup copy observed, integrity verified, **restore validated** and key recovery proven for every
   store that will be touched. `scripts/m5-fde-preflight.sh` shows the shape of this timestamped,
   attested gate; adapt it for these hosts rather than weakening it.
3. A recovery secret exists in an independent store and has been tested to unlock a *test* volume.
4. Console or equivalent out-of-band access is available for the whole ceremony.
5. A rehearsal of unlock-failure recovery on non-production media.
6. Exact abort criteria and rollback (restore the pre-migration backup to the original media, which
   is kept unmodified until acceptance).

## 7. Ceremony outline (not executable here)

1. Freeze changes, verify gate in section 6, notify (nothing is destroyed yet).
2. Final backup and its independent verification.
3. Provision the new encrypted media or layout beside the old one; leave the old media untouched.
4. Install or restore, set the unlock path from the chosen design, record the recovery secret
   custody, **do not print or log it**.
5. Reboot test: cold boot, power-loss simulation, and the unlock-failure recovery path.
6. Re-run the inventory (expect `encrypted` for the migrated stores) and the platform health/backup
   deliveries; only then retire the old media under a separate destructive-action approval.

## 8. Acceptance for BROKKR-173

Per-store protection recorded as verified/absent/unknown, an explicit owner decision, an
independently reviewed runbook, and fresh recovery evidence before any migration. Unknown controls
remain unknown. A migration that has not happened is not claimed.
