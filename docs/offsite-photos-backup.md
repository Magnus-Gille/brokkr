# Offsite Photos backup

This feature creates an independent, client-side-encrypted cloud copy of a local
Photos originals directory. It runs on the macOS workstation through launchd and is
adapted from Mimir's offsite-backup safety contract.

Cloud photo sync is useful but is not an independent backup: deletion, corruption, or
account loss can propagate. Brokkr adds a separately encrypted copy whose object names
and contents are opaque to the storage provider.

## Safety contract

`scripts/offsite-photos-backup.sh`:

1. Requires the source directory and `rclone`.
2. Refuses any remote that is not `crypt` with standard filename and directory-name
   encryption.
3. Lists source and destination before a real sync and aborts when the deletion count
   or percentage exceeds configured limits.
4. Moves replaced/deleted objects to timestamped archive directories by default.
5. Exits non-zero on backup failure and, when configured, posts a Heimdall failure
   panel without exposing the token.
6. Sources an optional env file only when it is a regular non-symlink, owned by the
   current user, with no group/other permissions.

The job copies originals, not the entire `.photoslibrary` package. A restore therefore
recovers ordinary image/video files but not Photos albums, edits, face data, or its
internal database.

## One-time setup

### 1. Make originals local

In Photos, enable **Download Originals to this Mac** and wait until the download is
complete. Verify the local originals directory has the expected content. The deletion
gate protects later runs; it cannot know whether an incomplete first run is intentional.

### 2. Install and configure rclone

```bash
brew install rclone
rclone config
```

Create an ordinary cloud-storage remote, then a distinct crypt remote over a dedicated
directory:

```text
name> brokkr-photos-crypt
Storage> crypt
remote> storage:backups/brokkr-photos
filename_encryption> standard
directory_name_encryption> true
```

Generate a strong password and separate salt. Store their plaintext values in an
independent password manager or recovery envelope. The obscured values in
`~/.config/rclone/rclone.conf` are not sufficient key custody if that machine is lost.
Lock the file down with `chmod 600 ~/.config/rclone/rclone.conf`.

### 3. Optional Heimdall and runtime settings

Scheduled failure reporting needs `HEIMDALL_HUB_URL` and `HEIMDALL_FLEET_TOKEN`.
Store them in the default env file or point `BROKKR_OFFSITE_ENV_FILE` elsewhere:

```bash
mkdir -p ~/.config/brokkr
install -m 600 /dev/null ~/.config/brokkr/offsite-photos.env
$EDITOR ~/.config/brokkr/offsite-photos.env
```

Example content:

```bash
HEIMDALL_HUB_URL=https://heimdall.example.com/api/panels
HEIMDALL_FLEET_TOKEN=<fleet-token>
MIMIR_OFFSITE_REMOTE=brokkr-photos-crypt
MIMIR_OFFSITE_ROOT="$HOME/Pictures/Photos Library.photoslibrary/originals"
```

Important overrides:

| Variable | Purpose |
|---|---|
| `MIMIR_OFFSITE_REMOTE` | Crypt remote name only; no colon or path |
| `MIMIR_OFFSITE_ROOT` | Local originals directory |
| `MIMIR_OFFSITE_KEEP_HISTORY` | `1` keeps archive history; `0` is a plain mirror |
| `MIMIR_OFFSITE_RETENTION_DAYS` | Archive retention horizon |
| `MIMIR_OFFSITE_MAX_DELETE` | Absolute deletion gate |
| `MIMIR_OFFSITE_MAX_DELETE_PCT` | Percentage deletion gate |
| `MIMIR_OFFSITE_LOG`, `MIMIR_OFFSITE_STAMP` | Local log and heartbeat paths |
| `RCLONE_BIN` | Explicit rclone binary path |

The `MIMIR_OFFSITE_*` prefix is retained for compatibility with the reference script.

### 4. Dry-run, first run, then schedule

```bash
./scripts/offsite-photos-backup.sh --dry-run
./scripts/offsite-photos-backup.sh
./launchd/install.sh
./launchd/install.sh status
```

Run the first real copy interactively and review its log before enabling the timer.

## Acceptance and recovery

A configured backup is not proof of recovery. After the first copy:

```bash
rclone cryptcheck \
  "$HOME/Pictures/Photos Library.photoslibrary/originals" \
  brokkr-photos-crypt:current

restore_dir="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-photos-restore.XXXXXX")"
rclone copy brokkr-photos-crypt:current "$restore_dir" --max-transfer 500M
```

Open at least one restored image and video, record only non-secret evidence, then remove
the bounded scratch directory. Also verify key recovery on a fresh rclone configuration;
without that check, crypt setup is not proven recoverable.

For disaster recovery, recreate the underlying storage remote, recreate the crypt remote
with the separately held password and salt, and copy `brokkr-photos-crypt:current` to a
new local directory. Never paste `rclone config show`, passwords, salts, OAuth tokens, or
provider-issued URLs into issues or logs.
