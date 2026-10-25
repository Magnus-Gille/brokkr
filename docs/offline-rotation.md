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
2. Identifies the disk only by its LUKS UUID, through `/dev/disk/by-uuid`. It refuses
   to continue unless all of these hold:
   - the header is LUKS2;
   - `cryptsetup luksUUID` reports the same UUID;
   - the `brokkr-offline` mapping is not already active;
   - the mount point is empty and unmounted.
3. Opens the disk with cryptsetup's own passphrase prompt, or with an owner-only keyfile
   named in the env file. The script never reads, stores or prints the passphrase.
   Without a keyfile it refuses to run unless stdin is a terminal, so cryptsetup cannot
   read a passphrase from a pipe.
4. Mounts with `nodev,nosuid,noexec` and requires the `BROKKR-OFFLINE-DISK` marker
   written at the format ceremony.
5. **Never deletes.** The archive is copied with `rsync -a --ignore-existing`, without
   `--delete`. A changed, truncated or ransomware-encrypted source file therefore cannot
   overwrite the good copy on the disk. The `sha256sum -c --strict` check of the disk copy
   then fails loudly. Service snapshots are written to a new
   `services/<UTC stamp>/` tree, hard-linked against the previous one (`--link-dest`). The
   tree only gets its final name after it has been verified.
6. Runs a SMART short self-test with `smartctl -d sat` on the parent disk. The run passes
   only if the test was observed running, the newest self-test log entry is
   `Completed without error`, and overall health is `PASSED`.
7. Writes a receipt on the disk, syncs, unmounts, `luksClose`s, and then writes the local
   receipt. `offline rotation complete: safe to unplug` is printed only after all of
   that.
8. On any failure it still tries to unmount and close the disk, and writes no receipt.
   It prints `do NOT unplug` if the disk could not be closed.

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
independently verified copies elsewhere. Run every command by hand and read its output
before running the next. No script performs these steps.

1. Generate a long random passphrase in the password manager. Create an entry for the
   rotation disk.
2. Attach the disk and find it by its stable `by-id` name, not by `sdX` order:

   ```bash
   lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
   ls -l /dev/disk/by-id/ | grep usb-
   ```

   Confirm the model and size, then set `DISK=/dev/disk/by-id/usb-<model>_<serial>-0:0`
   for this shell. Do not paste the serial into tickets or this repository.
3. Partition the disk and format LUKS2. `luksFormat` prompts for the passphrase; paste it
   from the password manager:

   ```bash
   sudo wipefs --all "$DISK"
   sudo parted --script "$DISK" mklabel gpt mkpart brokkr-offline 1MiB 100%
   sudo cryptsetup luksFormat --type luks2 "${DISK}-part1"
   UUID="$(sudo cryptsetup luksUUID "${DISK}-part1")"; echo "$UUID"
   ```

   Record the LUKS UUID in the password manager entry and in
   `/etc/brokkr/offline-rotation.env` as `OFFLINE_LUKS_UUID`.
4. Back up the LUKS header. A damaged header makes the disk unreadable, even with the
   passphrase. Store the backup as an attachment on the password manager entry, then
   remove the temporary file (`sudo shred -u /root/offline-header.img`):

   ```bash
   sudo cryptsetup luksHeaderBackup "${DISK}-part1" --header-backup-file /root/offline-header.img
   ```

5. Create the filesystem and the layout. The UUID used here must be the one recorded
   above:

   ```bash
   sudo cryptsetup open --type luks2 "/dev/disk/by-uuid/$UUID" brokkr-offline
   sudo mkfs.ext4 -L brokkr-offline -m 0 /dev/mapper/brokkr-offline
   sudo install -d -m 0700 /mnt/brokkr-offline
   sudo mount -o nodev,nosuid,noexec /dev/mapper/brokkr-offline /mnt/brokkr-offline
   printf 'luks_uuid=%s\n' "$UUID" | sudo tee /mnt/brokkr-offline/BROKKR-OFFLINE-DISK
   sudo chmod 0700 /mnt/brokkr-offline
   sudo umount /mnt/brokkr-offline
   sudo cryptsetup luksClose brokkr-offline
   ```

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

Restore to a separate scratch destination first, never over live data:

```bash
sudo cryptsetup open --type luks2 --readonly "/dev/disk/by-uuid/$UUID" brokkr-offline
sudo mount -o ro,nodev,nosuid,noexec /dev/mapper/brokkr-offline /mnt/brokkr-offline
cd /mnt/brokkr-offline
ls receipts/ manifests/ services/            # pick the newest <stamp>
(cd archive && sha256sum -c --strict --quiet "../manifests/<stamp>-archive.sha256")
(cd services/<stamp> && sha256sum -c --strict --quiet "../../manifests/<stamp>-services.sha256")
sudo rsync -a archive/<path>/ /restore-scratch/archive/<path>/
sudo rsync -a services/<stamp>/<name>/ /restore-scratch/<name>/
cd / && sudo umount /mnt/brokkr-offline && sudo cryptsetup luksClose brokkr-offline
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
