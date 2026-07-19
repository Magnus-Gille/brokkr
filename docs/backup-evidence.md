# Backup evidence and encryption inventory

This is the evidence contract for Brokkr-owned backup substrate. It deliberately
separates configuration from proof: a configured target is not evidence that a recent
copy exists, an integrity check is not a restore test, and encryption is not evidence
that the decryption key is recoverable.

Keep dated operational evidence in an operator-local, access-controlled log. Do not copy
live host details into this public document.

## Evidence levels

Use the strongest level actually demonstrated, and say `unknown` when evidence is absent.

| Level | What it proves | What it does not prove |
|---|---|---|
| Configured | A producer and destination are configured | A copy ran or exists |
| Copy observed | Expected data exists and has a measured timestamp/count | Content integrity or restorability |
| Integrity verified | The source and stored copy passed the owner-specific check | The recovery procedure or key custody works |
| Restore verified | Data was restored to a separate scratch destination and opened/validated | Future runs will remain healthy |
| Key recovery verified | A fresh environment could recover the encryption key and decrypt | The backup is recent or complete |

Never summarize a backup as `pass` or “protected” from configuration alone. Record the
missing level as `unknown` and name the next read-only check or controlled restore drill.

## Encryption inventory

The table describes contracts, not live state. Live encryption must be verified on the
host involved; never infer it from a directory name or from transport over SMB/HTTPS.

| Copy | Storage path | Encryption contract | Truth rule |
|---|---|---|---|
| Time Machine | NAS sparsebundle | Brokkr does not configure client-side encryption for the sparsebundle | Treat at-rest encryption as `unknown` until `tmutil destinationinfo` and the backup's encryption property are captured; SMB transport is not at-rest encryption |
| Mímir artifacts | NAS `backups/mimir/` | Inherits the NAS volume's storage properties; producer behavior belongs to Mímir | Do not claim encryption from Brokkr without live block-device and Mímir evidence |
| Munin memory | NAS `backups/munin-memory/` | Inherits the NAS volume's storage properties; dump format belongs to Munin | Do not claim encryption from Brokkr without live block-device and Munin evidence |
| Photos offsite | `brokkr-photos-crypt:current` | Each run fails closed unless rclone reports `crypt`, standard filename encryption, and directory-name encryption | A successful preflight proves configuration at that moment; only a restore from a fresh key setup proves key recovery |

No hardening task should enable or change disk, Time Machine, or rclone encryption as a
side effect of inventorying it. Encryption changes need their own migration and rollback
plan because an incorrect change can make the only usable copy unreadable.

## Read-only evidence collection

Record output timestamps, counts, and command exit status without recording credentials.

### Time Machine (Mac)

```bash
tmutil destinationinfo
./timemachine/check-health.sh
```

If `tmutil` itself fails, the result is `unknown`, not “no backups.” A successful empty
query is the distinct, proven “no backups” failure state. A result passed to the NAS-side
Heimdall report also needs `BROKKR_TM_OBSERVED_AT` (epoch seconds); an undated or stale
`BROKKR_TM_STATUS` is deliberately downgraded to `unknown`.

### NAS tenants (NAS Pi)

```bash
./disk/check-mount.sh
findmnt -no SOURCE,FSTYPE,OPTIONS /mnt/timemachine
find /mnt/timemachine/backups/mimir -type f -print | wc -l
find /mnt/timemachine/backups/munin-memory -type f -print | wc -l
```

Counts establish presence only. Use the Mímir and Munin owner procedures for integrity
and restore verification; Brokkr must not invent application-level validation.

### Photos offsite (Mac)

Use the fail-closed dry run and the documented integrity/restore drill. The script never
prints the crypt key; do not paste `rclone config show` into logs or tickets.

```bash
./scripts/offsite-photos-backup.sh --dry-run
# Then follow “First-run acceptance” in docs/offsite-photos-backup.md.
```

## Restore evidence record

For a controlled drill, record only non-secret evidence:

- copy/tenant and source snapshot identifier;
- UTC start/end time and host used;
- destination was a separate scratch path;
- integrity command and exit status;
- restored sample type/count and validation performed;
- encryption state (`verified`, `not configured`, or `unknown`);
- key recovery state (`verified` or `unknown`);
- cleanup performed and any follow-up blocker.

Keep dated current results in an access-controlled operations record. Never record
passwords, salts, OAuth tokens, private URLs, or recovery keys in this repository.
