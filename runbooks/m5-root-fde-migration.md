# M5 root encryption migration (owner-attended)

This runbook prepares a destructive reinstall of the M5 with Ubuntu Server 26.04
LTS, LVM over LUKS2, and TPM2 automatic unlock. It does **not** authorize or
automate the reinstall. Issue #89 remains open until live post-migration and
recovery evidence exists.

Never put a recovery passphrase, LUKS header, backup locator, device identifier, private
address, or credential export in GitHub, Git, Munin, terminal transcripts, or
shared logs. Store operational evidence in the access-controlled owner record
described by [`../docs/backup-evidence.md`](../docs/backup-evidence.md).

## Selected design and its trade-off

The selected design keeps the current Server flavor and follows Ubuntu Server's
documented TPM-backed LUKS procedure:

- reinstall Ubuntu Server 26.04 with an installer-created **LVM-over-LUKS2** root;
- retain one high-entropy LUKS passphrase in an independent recovery store;
- keep UEFI Secure Boot enabled;
- after the first encrypted boot, install the documented Clevis/Dracut integration;
- bind a separate Clevis keyslot to TPM2 PCR 7, which represents Secure Boot state;
  and
- use TPM auto-unlock for ordinary unattended power recovery and remote reboot.

This preserves the current Ubuntu Server operating model and general Server kernel
and driver compatibility. The alternative Ubuntu Desktop 26.04 integrated TPM/FDE
path would change OS flavor, is still marked Beta, and has kernel-snap/DKMS and
storage limitations that are unnecessary for this inference server.

The selected path also has a support caveat: Canonical's Server documentation calls
Clevis a **community-supported fallback** until a fully integrated Server FDE
solution lands in a future LTS. LUKS, the encrypted layout, and a recovery passphrase
remain usable without Clevis; Clevis supplies the unattended TPM unlock. Magnus must
explicitly accept that trade-off at the ceremony. If community-supported auto-unlock
is unacceptable, abort and wait for an integrated Server solution rather than switch
OS flavors during the change.

TPM binding to PCR 7 means a changed Secure Boot state can make automatic unlock fail.
Canonical also warns that firmware and bootloader changes can require re-binding.
The retained LUKS passphrase is therefore a mandatory offline fallback. This is
desired fail-closed behavior, but it means remote access alone cannot guarantee
recovery after a boot-chain change.

TPM auto-unlock preserves availability, but theft of the whole intact computer does
not require a human pre-boot secret when its measured boot remains acceptable. Login,
SSH, service isolation, and network controls remain essential layers. Requiring the
LUKS passphrase on every boot would improve this theft boundary but is incompatible
with unattended reboot; choosing that posture requires a different operating model.

Primary references:

- [Ubuntu Server: TPM-based LUKS decryption with Clevis](https://ubuntu.com/server/docs/how-to/security/tpm-backed-luks-decryption-with-clevis/)
- [Ubuntu full-disk encryption overview](https://documentation.ubuntu.com/security/security-features/storage/encryption-full-disk/)
- [Ubuntu 26.04 TPM/FDE limitations (rejected Desktop alternative)](https://documentation.ubuntu.com/release-notes/26.04/changes-since-previous-interim/#limitations-of-tpm-backed-full-disk-encryption)

Do not improvise a second design during the ceremony. In-place conversion or
re-encryption of the live root is outside this runbook and forbidden: the selected
procedure is backup, reinstall, restore, and prove. If the Server installer cannot
produce the reviewed LVM-over-LUKS2 layout, or the documented Clevis/Dracut
prerequisites do not apply, abort and redesign in a separate reviewed change.

## Verified starting point

A read-only observation on 2026-08-01 established that the current M5 is Ubuntu
Server 26.04 on x86_64, boots through UEFI with Secure Boot enabled, exposes TPM2,
and has an ext4 root with no crypt ancestor. These are baseline facts, not proof that
the reviewed encrypted layout and TPM unlock will work and not authorization to alter
the disk.

## Non-negotiable operating rules

- Magnus is physically present from first preflight through the recovery and remote
  reboot tests. Do not begin during travel or within seven days before travel.
- A second internet-capable device, display, keyboard, known-good installer media,
  and access to the independent recovery store are present.
- The M5 is removed from unattended workloads and no job is in flight.
- The existing disk and all backups remain untouched until the explicit
  point-of-no-return confirmation.
- The fresh backup is not the only copy, and the restore drill uses a separate
  scratch destination.
- Recovery material is entered only into the installer, boot prompt, trusted local
  recovery environment, or password application. It is never passed as a shell
  argument.

## Phase 0 — prepare a private ceremony record

In an access-controlled operator record, capture only the evidence needed to make a
go/no-go decision:

- UTC start time, change owner, and maintenance window;
- exact Ubuntu 26.04 image version and its publisher checksum verification result;
- backup snapshot identifier and copy/integrity/restore/key-recovery timestamps;
- expected repositories, service units, data stores, and acceptance checks;
- the independent recovery-store locations as private references, not their
  contents; and
- the rollback owner and estimated restore duration.

The pre-install `key-recovery` item means the **backup's** decryption material was
proved from a fresh environment. It is distinct from the new root-LUKS passphrase and
LUKS header evidence created after installation.

Do not paste this record into the public issue. The public issue should receive only
coarse pass/fail evidence and timestamps that reveal no private topology.

**ABORT 0:** stop if there is no physically attended window, second device, console,
or independent recovery store.

## Phase 1 — prove backup and hardware readiness

Classify backup evidence using the four distinct levels in
[`../docs/backup-evidence.md`](../docs/backup-evidence.md). A recent copy alone is
insufficient. The restore drill must open or validate representative data from a
separate scratch destination, and the backup decryption material must have been
recovered from an independent fresh environment.

Run the repository preflight on the M5. Supply Unix epochs from the private record;
these values are evidence timestamps, not secrets:

```bash
sudo scripts/m5-fde-preflight.sh \
  --copy-observed-at <epoch> \
  --integrity-verified-at <epoch> \
  --restore-verified-at <epoch> \
  --key-recovery-verified-at <epoch> \
  --attest-copy-observed \
  --attest-integrity-verified \
  --attest-restore-validated \
  --attest-backup-key-recovered
```

Each attestation means the operator inspected the underlying result: expected data
was observed, integrity checks passed, representative restored data opened or
validated in a separate scratch destination, and independently held backup key
material successfully decrypted the backup. A timestamp without its attestation is
reported as `unattested` and fails closed.

The defaults require copy and integrity evidence no older than 24 hours, a restore
drill no older than 30 days, and a backup-key recovery drill no older than 90 days.
Tighter windows can be passed explicitly. Exit `0` plus `ceremony_gate=pass` is
necessary but not sufficient; the script does not evaluate installer compatibility,
driver support, workload drain, or human readiness.

Also inventory, without exporting secrets:

```bash
uname -a
lsb_release -ds
dkms status
systemctl --failed
systemctl list-unit-files --state=enabled
```

Record package and service names only. Do not record environment files, command-line
credentials, private service arguments, or network locators.

**ABORT 1:** stop unless all four backup states, Secure Boot, TPM2, and readable root
topology pass. Stop if any required repository/data store is absent from the backup,
any restore sample fails, or key recovery is `unknown`.

## Phase 2 — installer and TPM-unlock rehearsal

1. Verify the downloaded Ubuntu 26.04 image against Canonical's published checksum.
2. Boot the installer media without selecting an install target.
3. Confirm networking, console, keyboard, storage, and required hardware are visible.
4. Confirm the Server installer can create the reviewed encrypted LVM layout and that
   the planned root container will be LUKS2. Do not commit the storage changes.
5. Review the current Ubuntu Server Clevis guide. Confirm TPM2, Dracut, and the
   `clevis`, `clevis-tpm2`, `clevis-dracut`, and `clevis-luks` packages apply to the
   exact 26.04 image.
6. Exit the live session without installing, return to the existing system, and rerun
   the backup preflight if the rehearsal changed the maintenance date.

**ABORT 2:** stop if Secure Boot would need to be disabled, storage identity is
ambiguous, the installer cannot create the reviewed LVM-over-LUKS2 layout, required
hardware is unsupported, Dracut/Clevis conflicts with the workload, or the installer
proposes touching another disk.

## Phase 3 — point of no return

Drain all inference and automation work. Disable new job admission using the owning
service procedures, then prove the in-flight count is zero. Confirm the second device
can read the private ceremony record and recovery store while the M5 is offline.

Immediately before choosing the installer's erase action, Magnus must state a fresh,
specific confirmation that identifies this one host and accepts:

- complete erasure of the selected M5 system disk;
- Ubuntu Server 26.04 with LVM-over-LUKS2;
- Clevis/Dracut as a community-supported TPM auto-unlock layer;
- automatic TPM unlock without a human pre-boot secret; and
- restore from backup as the only rollback after erasure starts.

No agent may infer this confirmation from issue approval, previous messages, or this
runbook.

**ABORT 3:** without that immediate confirmation, shut down the live session and boot
the existing system. This is the last guaranteed non-destructive abort point.

## Phase 4 — attended install and recovery custody

After the confirmation, use the Ubuntu Server installer's encrypted LVM path on the
confirmed target disk. Do not use in-place re-encryption or shell commands copied from
another FDE design.

Before the installer asks for the LUKS passphrase:

1. Generate and save a high-entropy passphrase directly in the approved independent
   password application; an agent must neither generate nor see it.
2. Create a second independent, owner-controlled recovery copy if the private
   succession contract requires one.
3. Confirm the stored value can be retrieved on the second device while the M5 is
   offline, then enter it only in the installer prompt.
4. Never pass it as a command argument, print it, or paste it into a terminal or
   ceremony log.

Complete the install and first encrypted boot using the passphrase. Before enabling
public ingress, prove root is LUKS2-backed and Secure Boot remains enabled. Then follow
the current Ubuntu Server guide exactly to install Clevis/Dracut, bind a new TPM2
keyslot to PCR 7, rebuild the initramfs, and inspect that the Clevis modules and token
are present. Resolve the encrypted partition twice from fresh `lsblk -f` output before
any command that names it; do not paste a remembered device path from this document.
Retain the original passphrase keyslot.

Create a LUKS header backup using `cryptsetup luksHeaderBackup` and place it directly
in an independent, access-controlled recovery store with owner-only permissions. A
passphrase cannot recover a damaged LUKS header by itself. The header backup is
sensitive recovery material: its filename, path, contents, checksum, and storage
locator stay out of Git, GitHub, Munin, shell transcripts, and shared logs. Keep it
separate from at least one copy of the passphrase and from the M5 system disk.

The guide's state-changing steps are allowed only inside this already-authorized,
attended phase. Do not run them while preparing or reviewing this PR.

**ABORT 4:** before the install starts, stop if independent passphrase custody is not
proved. After erasure, keep the host at the console and ingress disabled if LUKS2,
Secure Boot, the retained passphrase keyslot, Dracut contents, or the PCR7 Clevis token
cannot be proved. Restore/reinstall rather than delete the only known recovery slot.

## Phase 5 — minimal restore before service exposure

1. Apply current security updates without changing Secure Boot state.
2. Recreate only the required operator account and SSH trust from approved sources.
3. Restore repositories and data from the verified backup using each owning repo's
   restore procedure.
4. Reinstall service units from exact accepted revisions. Restore credentials through
   their owning secret store; never copy them from shell history or Git.
5. Keep public ingress disabled until local and tailnet health checks pass.
6. Compare restored repositories, data stores, enabled units, and service versions
   with the pre-install inventory.

**ABORT 5:** if restore integrity, service identity, or credential provenance is
uncertain, keep ingress disabled. Preserve the backup and installer media; investigate
from the console rather than layering unreviewed fixes onto the new host.

## Phase 6 — live proof and controlled recovery

Run the preflight again with current backup evidence. The expected coarse states are:

```text
secure_boot=enabled
tpm2=present
root_encryption=luks2
migration_required=no
ceremony_gate=pass
```

Resolve the `crypt` ancestor from the fresh `lsblk -s` topology; the root mount source
will be an LV and is not itself a valid `cryptsetup status` target. Then capture
private operational evidence for:

```bash
findmnt -n -o SOURCE /
lsblk -s -f "$(findmnt -n -o SOURCE /)"
sudo cryptsetup status <confirmed-crypt-mapping>
sudo clevis luks list -d <confirmed-encrypted-partition>
sudo lsinitrd | grep '^clevis'
mokutil --sb-state
systemctl --failed
```

The device-specific output stays in the private ceremony record. A public issue update
should say only that root is LUKS2-backed and Secure Boot is enabled.

While Magnus remains physically present:

1. Verify every required local, tailnet, and public service check from its owning repo.
2. Perform one normal reboot. Confirm TPM auto-unlock, network return, SSH access,
   service health, timers, and backup scheduling.
3. From a fresh Ubuntu live environment, resolve the encrypted partition twice. Run
   `cryptsetup open --test-passphrase <confirmed-encrypted-partition>` and enter the
   stored root-LUKS passphrase at the prompt. This validates a keyslot without creating
   a mapping or mounting the filesystem.
4. From that same controlled environment, retrieve the independent header backup and
   run the equivalent `cryptsetup open --test-passphrase --header
   <private-header-backup> <confirmed-encrypted-partition>`. This proves the held
   header and passphrase correspond to the encrypted data without writing the disk.
   Do not record the private header path or passphrase.
5. If a filesystem-level recovery drill is required, open the LUKS mapping read-only
   and mount the ext4 filesystem with read-only/no-journal-replay options in the
   attended live environment. This may still expose recovered data to the local
   operator; keep all output private and close the mapping immediately afterward.
   Never describe the Ubuntu Desktop `snap-tpmctl mount-volume` procedure as read-only;
   it is not the selected Server recovery path.
6. Reboot normally again and confirm TPM auto-unlock and all services.
7. If unattended recovery after power loss is required, perform one controlled AC-loss
   test only while present and only after firmware auto-power-on behavior is known.

**ABORT 6:** do not declare the host travel-ready if any ordinary reboot needs local
intervention, the recovery passphrase or held header validation fails, Secure Boot
changes state, root is not LUKS2, remote access does not return, or a required service
remains unhealthy.

## Travel and maintenance policy after migration

- Do not remove TPM auto-unlock or require an interactive boot factor unless accepting
  that remote reboot and power-loss recovery will require a person at the console.
  The retained recovery passphrase remains enrolled but is not normally required while
  TPM auto-unlock succeeds.
- Do not update firmware, reset TPM state, change Secure Boot keys/state, or alter the
  boot chain while away. Those changes can trigger recovery-passphrase entry.
- Schedule the first firmware update as a separate attended change with recovery
  material available and rerun the full reboot/recovery proof afterward.
- Keep an owner-authorized local recovery contact if the M5 must remain available
  during travel. Remote-control software cannot enter firmware or early-boot recovery
  prompts reliably.
- Continue backup copy, integrity, restore, and key-recovery drills independently;
  root encryption does not make a backup current or restorable.

## Completion evidence for issue #89

The issue can close only after all of the following are true:

- pre-install four-level backup gate passed;
- the exact Server installer version, encrypted storage result, and Clevis/Dracut
  prerequisite check were recorded privately;
- root is proven LUKS2-backed and Secure Boot remains enabled;
- the retained root-LUKS recovery passphrase is independently stored and keyslot-tested
  from fresh live media;
- a sensitive LUKS header backup is independently held and validated with the
  recovery passphrase in a fresh environment;
- a normal unattended reboot returns remote access and all required services;
- the controlled fresh-media recovery drill succeeds; and
- a sanitized GitHub comment records pass/fail outcomes without secrets or private
  locators.

Documentation or a merged preflight PR alone is not completion.
