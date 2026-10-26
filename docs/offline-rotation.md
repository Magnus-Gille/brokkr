# Offline rotation disk

An encrypted USB disk that is attached to the control node only during a rotation and
otherwise stays disconnected in a safe. It closes two gaps:

- **No offline copy.** Every other copy is reachable from the network, so ransomware, a
  compromised account, or a bad sync can reach them too. A disk in a safe cannot be
  reached.
- **Unbacked control-node service data.** Service-data snapshot directories go onto the
  same disk.

The disk holds two kinds of data:

- a read-only archive tree, verified against its sha256 manifest on every rotation;
- dated service-data snapshots, verified against a manifest built from the source.

## Safety contract

`scripts/offline-rotation.sh`:

1. Sources its config from a private env file, default `/etc/brokkr/offline-rotation.env`.
   The file must be regular, not a symlink, owned by the account running the script, and
   have no group/other permissions (0600). It is checked before it is parsed.
2. Holds an exclusive run lock (`/run/lock/brokkr-offline-rotation.lock`, a
   directory). It validates a private snapshot of the archive manifest and later
   verifies against that same snapshot. Manifest entries must be relative, with no `..`
   component, and no entry may be `-`.
3. Identifies the disk only by its LUKS UUID, through `/dev/disk/by-uuid`. It refuses
   to continue unless all of these hold:
   - the header is LUKS2;
   - `cryptsetup luksUUID` reports the same UUID;
   - the `brokkr-offline` mapping is not already active;
   - the mount point is empty and unmounted.
4. Opens the disk with cryptsetup's own passphrase prompt, or with an owner-only keyfile
   named in the env file. The script never reads, stores or prints the passphrase.
   Without a keyfile it refuses to run unless stdin is a terminal, so cryptsetup cannot
   read a passphrase from a pipe.
5. Mounts with `nodev,nosuid,noexec` and requires the `BROKKR-OFFLINE-DISK` marker
   written at the format ceremony. `archive`, `manifests`, `services` and `receipts`
   must be real directories on the mounted filesystem, not symlinks. This is checked
   before copying and again before the receipt is written. The script never writes to a
   path that existed before the run:
   - every manifest and receipt temp file is created with `mktemp` inside a fresh 0700
     `manifests/.work-<stamp>.*` directory, or in the local receipt directory;
   - completed files are moved into place only if their final name is absent, and a
     dangling symlink counts as present.

   A failed run may leave a `.work-*` directory of temp manifests. It is safe to remove
   by hand.
6. **Never deletes.** The archive is copied with `rsync -a --ignore-existing`, without
   `--delete`. A changed, truncated or ransomware-encrypted source file therefore cannot
   overwrite the good copy on the disk. The `sha256sum -c --strict` check of the disk copy
   then fails loudly. The run also refuses if the disk archive contains any symlink,
   because `sha256sum -c` would follow it to the live source. Service snapshots are
   written to a new `services/<UTC stamp>/` tree, hard-linked against the previous one
   (`--link-dest`). The tree only gets its final name after it has been verified.
   Verification walks the disk copy without following links and compares the resulting
   manifest with the one built from the source. A file that turned into a symlink
   therefore fails the check. Symlinks inside service snapshots are kept as links and
   are not checksummed.
7. Runs a SMART short self-test with `smartctl -d sat` on the parent disk. The run passes
   only if the test was observed running, the newest self-test log entry is
   `Completed without error`, and overall health is `PASSED`.
8. Writes a receipt on the disk, syncs, unmounts, `luksClose`s, and then writes the local
   receipt. `offline rotation complete: safe to unplug` is printed only after all of
   that.
9. On any failure it still tries to unmount and close the disk, and writes no receipt.
   This includes HUP (a closed terminal), INT, QUIT and TERM, which all run the same
   cleanup. The disk counts as closed only when `mountpoint` and `cryptsetup status`
   confirm it, or when `umount` and `luksClose` succeed. An error from those tools is
   unknown state, never success. In that case the script prints `do NOT unplug`.

A receipt is integrity evidence (see [backup evidence](backup-evidence.md)): it proves
the stored copy matched the manifests at that moment. It does not prove a restore or key
recovery. Those come from the drills below.

## Disk layout

```text
BROKKR-OFFLINE-DISK            marker: luks_uuid=<uuid>  (written at the ceremony)
archive/                       the archive tree (append-only)
manifests/<stamp>-archive.sha256
manifests/<stamp>-services.sha256
services/<stamp>/<name>/       one dated tree per rotation
receipts/<stamp>.receipt
```

Local receipts go to `/var/lib/brokkr/offline-rotation/receipts/<stamp>.receipt`. They
hold counts, the manifest hash, service names and the SMART result. They hold no paths
or secrets.

## One-time format ceremony (owner-attended)

This wipes the disk. Run it only after confirming that its old contents have
independently verified copies elsewhere. The destructive steps run through
`scripts/offline-rotation-format.sh`, which stops at the first failure. Each guard runs
before the step it protects:

- The disk must be named by its `/dev/disk/by-id` link and be a whole USB disk, with
  nothing mounted (swap included) and no active holders. Every `lsblk` query must
  succeed and return output.
- You must type `ERASE` within 120 seconds of seeing the disk's size and model. The
  timeout is `BROKKR_OFFLINE_CONFIRM_TIMEOUT`.
- The helper records the disk's identity (major:minor, size in bytes, serial). After
  confirmation, and again right before `wipefs`, `parted`, `luksFormat` and
  `mkfs.ext4`, it re-checks the by-id link, that identity, the mounts and the
  holders. If the disk is unplugged, its `/dev` name is reused, or anything else
  changes, it stops.
- The `brokkr-offline` mapping must be inactive, and the helper takes the same lock as
  the rotation.
- The new partition must belong to that disk.
- Immediately before `mkfs.ext4`, the open mapping must be backed by that partition and
  carry the LUKS UUID just created. Otherwise nothing is formatted, and the mapping is
  left open for inspection.

1. Generate a long random passphrase in the password manager. Create an entry for the
   rotation disk.
2. Attach the disk and find it by its stable `by-id` name, not by `sdX` order:

   ```bash
   lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
   ls -l /dev/disk/by-id/ | grep usb-
   ```

   Confirm the model and size, then set `DISK=/dev/disk/by-id/usb-<model>_<serial>-0:0`
   for this shell. Do not paste the serial into tickets or this repository.
3. Run the format helper. It wipes and partitions the disk, then runs LUKS2 `luksFormat`.
   Paste the passphrase from the password manager at cryptsetup's prompt; it asks twice.
   The helper then writes the LUKS header backup, creates the ext4 filesystem, the marker
   and the layout, and closes the disk:

   ```bash
   sudo install -d -m 0700 /mnt/brokkr-offline
   sudo ./scripts/offline-rotation-format.sh --i-understand-this-erases "$DISK" \
     --header-backup /root/brokkr-offline-header.img
   ```

   Record the printed `OFFLINE_LUKS_UUID=` value in the password manager entry and in
   `/etc/brokkr/offline-rotation.env`.

4. Attach the LUKS header backup to the password manager entry. A damaged header makes
   the disk unreadable, even with the passphrase. Then remove the local copy with
   `sudo shred -u /root/brokkr-offline-header.img`.

   The helper refuses to run if anything is mounted, the mapping is already active, the
   partition does not appear, or the mapping is backed by the wrong device. If it stops
   partway, read the error. It reports `do NOT unplug` whenever it cannot confirm the
   disk is closed. Once nothing is open, re-run it from the start.
5. `--key-file FILE` is optional and uses the file's exact bytes as the key. Rotations
   must then use the same file as `OFFLINE_KEYFILE`. The prompt is recommended.

6. Key-recovery check: re-open the disk with the passphrase copied from the password
   manager, not from shell history, then close it again. Record this as key-recovery
   evidence in the operator log.
7. Install the config from [`scripts/offline-rotation.env.example`](../scripts/offline-rotation.env.example)
   (root-owned, mode 0600), then run the first rotation below.

A keyfile (`OFFLINE_KEYFILE`) is optional. It adds a LUKS keyslot whose key lives on the
control node, so anyone holding the node and the disk together can open it. The terminal
prompt is the default and is recommended.

## Rotation routine

Rotate every one to three months. Spin the disk up at least quarterly even when nothing
has changed. The freshness check warns after 90 days.

1. Take the disk out of the safe and attach it to the control node.
2. Run the rotation and enter the passphrase when cryptsetup prompts:

   ```bash
   sudo ./scripts/offline-rotation.sh
   ```

   USB 2 runs at about 34 MB/s. The first copy of a 186 GB archive takes about 1.5 hours.
   Later copies only transfer new files. Every rotation re-reads and re-verifies the
   whole archive, which takes about another 1.5 hours.
3. Wait for `offline rotation complete: safe to unplug`. Then unplug the disk and return
   it to the safe.
4. Check freshness. The check exits 0 when fresh, 1 when stale or the state is unknown,
   and 2 when no receipt exists:

   ```bash
   ./scripts/offline-rotation-freshness.sh
   ```

   `--push` publishes the result as the Heimdall `offline-rotation` panel through
   `heimdall/push.sh` (needs `HEIMDALL_HUB_URL` and `HEIMDALL_FLEET_TOKEN`).
   `BROKKR_OFFLINE_MAX_AGE_DAYS` changes the 90-day threshold.

If verification fails, the rotation leaves no receipt. Do not "fix" it by deleting files
on the disk. Compare the reported paths against the source and the previous manifests.
A mismatch may mean the source was changed or encrypted.

The script never prunes. Only an intentional, attended correction may move an archive
file on the disk aside. When the disk fills, remove the oldest `services/<stamp>/` trees
by hand while it is mounted. Because unchanged files are hard links, the newer trees
keep them.

## Restore

Restore to a separate scratch destination first, never over live data. The disk's
filesystem root is mode 0700 and root-owned, so run the steps in a root shell
(`sudo -i`). Use absolute paths throughout:

```bash
D=/mnt/brokkr-offline
cryptsetup open --type luks2 --readonly "/dev/disk/by-uuid/$UUID" brokkr-offline
mount -o ro,nodev,nosuid,noexec /dev/mapper/brokkr-offline "$D"
ls "$D/receipts" "$D/manifests" "$D/services"     # pick the newest <stamp>
(cd "$D/archive" && sha256sum -c --strict --quiet "$D/manifests/<stamp>-archive.sha256")
(cd "$D/services/<stamp>" && sha256sum -c --strict --quiet "$D/manifests/<stamp>-services.sha256")
rsync -a "$D/archive/<path>/" "/restore-scratch/archive/<path>/"
rsync -a "$D/services/<stamp>/<name>/" "/restore-scratch/<name>/"
umount "$D" && cryptsetup luksClose brokkr-offline
```

Open and validate the restored files (photos open, service dumps load in the owning
application's own restore procedure) before you call the restore verified. If the header
is damaged, restore it from the password manager attachment first, using
`cryptsetup luksHeaderRestore`.

## Acceptance evidence

| Evidence | How |
|---|---|
| Configured | Ceremony done, UUID and passphrase recorded in the password manager |
| Integrity verified | A rotation receipt (local and on the disk) |
| Restore verified | A sampled restore to scratch, opened and validated |
| Key recovery verified | The disk opened with the passphrase taken from the password manager |
