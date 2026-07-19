# Time Machine settings reference

macOS stores client-side Time Machine state in an opaque preference database managed
by `tmutil` and System Settings. Do not commit a real destination URL, destination ID,
client image name, or capacity. The server-side share example is in
[`../samba/timemachine.example.conf`](../samba/timemachine.example.conf).

## Inspect and verify

```bash
tmutil destinationinfo
tmutil latestbackup
tmutil status
tmutil startbackup --auto
```

To point a client at a share, substitute local values without adding them to Git:

```bash
sudo tmutil setdestination -a "smb://backupuser@nas-host/TimeMachine"
tmutil destinationinfo
```

Set any Samba quota from the real storage budget, then verify a completed backup and
a sample restore. Configuration alone is not backup evidence; see
[`../docs/backup-evidence.md`](../docs/backup-evidence.md).
