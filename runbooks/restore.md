# Restoring Brokkr-owned backup copies

Expected paths are not proof that a current, intact copy exists. Classify the available
evidence using [`../docs/backup-evidence.md`](../docs/backup-evidence.md), preserve the
source, and restore to a separate scratch destination before replacing production data.

## Time Machine

- Inspect the configured client destination with `tmutil destinationinfo`; do not store
  its URL or destination ID in Git.
- Run `timemachine/check-health.sh`. Unknown freshness is not success or proven absence.
- On the server, verify the mount, Samba service, and live ignored
  `samba/timemachine.conf` derived from the public example.
- Treat at-rest encryption and key recovery as unknown until explicitly verified.

## Mimir and Munin data

Brokkr owns the destination disk, not application-level integrity. Stage a copy from the
configured tenant directory, then follow the owning repository's validation and restore
procedure. Directory presence alone is not freshness or integrity evidence.

## Encrypted offsite media

Recreate the cloud and crypt remotes with independently held recovery material. Restore
to a new scratch directory and open representative image and video files as described in
[`../docs/offsite-photos-backup.md`](../docs/offsite-photos-backup.md). Record copy,
integrity, restore, and key-recovery evidence separately.

## Preflight

```bash
BROKKR_DISK_MOUNT=/srv/backups ./disk/check-mount.sh
BROKKR_DISK_MOUNT=/srv/backups ./disk/check-capacity.sh
```

Confirm sufficient free space, record the intended cleanup and rollback, and never paste
credentials, private destinations, or recovered personal data into an issue or log.
