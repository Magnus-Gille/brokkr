# Archive off-site copy and monthly verification

An immutable archive (for example a scanned photo and document collection with a
sha256 manifest) is kept as three copies:

| Copy | Where | How it is verified |
|---|---|---|
| Primary | Read-only on the node that holds it | Source of truth for every check below |
| Near-site | A NAS on the same site | `sha256sum --check` of the manifest, run on the NAS over ssh |
| Off-site | A dedicated rclone `crypt` remote on a separate cloud account | `rclone cryptcheck` plus a sampled restore |

[`scripts/archive-offsite.sh`](../scripts/archive-offsite.sh) pushes the off-site copy
and verifies the copies again later. The push is append-only. The verifier runs monthly
from a systemd user timer and reports to Heimdall. The verifier never writes to
the remote or the NAS.

## The crypt guard

Every mode first refuses the remote unless `rclone config dump` shows all of these:

- `type = crypt`, with an underlying `remote`;
- `filename_encryption = standard` and `directory_name_encryption = true` (the defaults);
- `no_data_encryption` and `pass_bad_blocks` absent or false, so contents are encrypted
  and a damaged block is an error, not zeros;
- both `password` and `password2` (the salt);
- `filename_encoding = base32768`;
- no `global.*` or `override.*` key in the crypt section, in any remote it points
  through, or in a `[local]` section (rclone reads that section for every bare local
  path, the archive source included);
- every hop is a configured named remote (`name:path`, without inline `,opt=value`
  options) or an absolute local path, never a `:backend,...:` connection string.

rclone applies those keys and inline options over command-line flags. A
`global.immutable = false` line in the remote section, for example, makes
`copy --immutable` overwrite a changed object, and `override.size_only = true` would
reduce cryptcheck to sizes. Connection strings can also carry credentials inline.
The guard prints only a verdict and the underlying remote's name, type, `drive_type`
and `drive_id`, never a key, credential, or path. base32768 is required, not just
preferred: OneDrive caps path length, and the default base32 names overflow it on
deep archive paths (`pathIsTooLong`). base32768 names fit. An existing base32 remote
cannot be switched in place: its stored names would no longer decode. Use a new remote
and a new push.

rclone also reads `RCLONE_*` environment variables as config and flag overrides, for
example `RCLONE_CONFIG_<REMOTE>_FILENAME_ENCRYPTION` or `RCLONE_DRY_RUN`, and
`config dump` does not show them. The script therefore refuses to run when any
`RCLONE_*` variable other than `RCLONE_CONFIG` or `RCLONE_CONFIG_PASS` is set.

## Configuration

Copy [`scripts/lib/archive-offsite.conf.example`](../scripts/lib/archive-offsite.conf.example)
to `~/.config/brokkr/archive-offsite.conf` on the archive node and `chmod 600` it.
Pass it with `--config`. The file is parsed, never sourced. It must be a regular,
non-symlink file owned by the invoking user, with no group or other permissions. Only
the documented `ARCHIVE_*` keys are accepted, each at most once, and the values are
literal. Config values override the environment. Without `--config` the same
variables are read from the environment. `ARCHIVE_SRC`, `ARCHIVE_MANIFEST`,
`ARCHIVE_LOG` and `ARCHIVE_RCLONE` must be absolute paths, because the unit runs from
its release directory.

The manifest is `sha256sum` output generated from inside the archive directory, so its
paths are relative: `(cd "$ARCHIVE_SRC" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"$ARCHIVE_MANIFEST"`.
GNU-escaped names (lines starting with `\`) and binary-mode `*` separators are understood.
Every mode refuses when the archive's file count differs from the manifest's line count,
and when the archive is empty: cryptcheck prints no "matching files" notice for zero
matches, so an empty archive could never produce completion evidence.

## Modes

```bash
scripts/archive-offsite.sh --config ~/.config/brokkr/archive-offsite.conf --validate
scripts/archive-offsite.sh --config ~/.config/brokkr/archive-offsite.conf --dry-run
scripts/archive-offsite.sh --config ~/.config/brokkr/archive-offsite.conf --push
scripts/archive-offsite.sh --config ~/.config/brokkr/archive-offsite.conf --check
scripts/archive-offsite.sh --config ~/.config/brokkr/archive-offsite.conf --verify
```

| Mode | Effect |
|---|---|
| `--validate` | Guard and archive/manifest count only |
| `--dry-run` | `rclone copy --dry-run`; writes nothing remotely |
| `--push` | `copy --immutable` of the archive, `copyto --immutable` of the manifest to `<remote>:<name>.sha256`, then `cryptcheck --one-way` and a byte comparison of the remote manifest (copyto skips an existing object of the same size and mtime) |
| `--check` | `cryptcheck --one-way` and a byte comparison of the remote manifest |
| `--verify` | The monthly re-proof below, delivered to Heimdall |

`--immutable` makes rclone fail rather than overwrite a remote object whose content
changed, and `copy` never deletes. A changed archive file therefore fails the push and
leaves the remote copy as it was. Pushes and verifications take a `flock` on
`~/.local/state/brokkr/archive-offsite.lock` where `flock` exists, so a monthly check
cannot run against a half-finished push. Logs go to `ARCHIVE_LOG` (default
`~/.local/state/brokkr/archive-offsite.log`).

## What `--verify` proves

The Heimdall panel is `archive-verify-<node>`, labelled `Archive Verification (<node>)`.
There is one panel per node, as for link health. Each row stands on its own evidence,
following the levels in [backup-evidence.md](backup-evidence.md):

| Row | Evidence | pass | Otherwise |
|---|---|---|---|
| `preflight` | Present only on failure | — | fail: guard or archive/manifest count refused; copy, integrity and restore are then fail `not verified` |
| `copy` | `rclone size` count of `<remote>:<name>` and presence of `<name>.sha256` | count equals the manifest and the manifest exists | fail if fewer objects or no manifest; warn if more |
| `integrity` | `cryptcheck --one-way` and its summary notices, and `rclone cat` of the remote manifest compared byte for byte | exit 0, "N matching files" equal to the manifest count, no "hashes could not be checked" notice, manifest identical | fail |
| `restore` | N random manifest entries (`ARCHIVE_RESTORE_SAMPLES`, default 32) downloaded through the crypt remote into a private scratch directory and hashed with sha256 | every sampled file matches and the scratch copy was removed | fail, including when removal fails |
| `nearsite` | `sha256sum --check --quiet --strict -` of the local manifest, run in `ARCHIVE_NEARSITE_DIR` on `ARCHIVE_NEARSITE_SSH` | exit 0: every entry present and matching | fail (unreachable host, or the count of `FAILED` entries); warn when not configured; omitted with `ARCHIVE_NEARSITE=off` |
| `key-drill` | `ARCHIVE_KEY_DRILL_DATE`, recorded by the owner | the drill is at most 365 days old | warn when overdue or never recorded; fail when malformed or in the future |

rclone lists an object whose stored hash is empty as a match and still exits 0. It
reports such objects only in its "N hashes could not be checked" notice. Every mode
that runs cryptcheck (`--push`, `--check`, `--verify`) therefore reads rclone's summary
notices from a fresh log. It requires rclone's closing "N differences found" notice
and "N matching files" equal to the manifest count, with no unchecked hashes. A log
without those notices, even after exit 0, is "no cryptcheck summary" and fails. The per-file report is not parsed, because names containing a
newline would split its records.

The panel state is the worst row. The panel message starts with every row's status,
for example `copy=pass integrity=pass restore=pass nearsite=pass key-drill=pass`,
followed by the details of any row that is not pass, so passing evidence stays
visible and a long failure detail can only truncate details. A row that could not
run is never pass. The
`key-drill` row is a reminder based on a date the owner records. It does not show that
the key can be recovered today; only the drill shows that.

Exit status: 0 when the panel was delivered with no failing row, 1 when it was delivered
with a failing row (systemd marks the run failed), and 2 when delivery or the setup
failed. Heimdall configuration is required: `--verify` refuses to run without
`HEIMDALL_HUB_URL` and `HEIMDALL_FLEET_TOKEN`. The snapshot is kept at
`~/.local/state/brokkr/archive-verify.json`, and delivery stamps use the
`archive-verify-` prefix.

Limits worth knowing:

- `cryptcheck` reads and encrypts every archive file to compare hashes. The monthly run
  therefore reads the whole archive locally and lists the whole remote. The unit runs at
  idle I/O priority with an 18 h start timeout.
- The restore is a random sample, so it is statistical evidence. Every file is still
  covered by the cryptcheck.
- `sha256sum --check` does not notice extra files on the NAS, only missing or changed
  ones. The NAS check re-reads the whole near-site copy on the NAS.
- The near-site host must accept the archive node's ssh key non-interactively
  (`BatchMode=yes`) and have GNU `sha256sum`.

## Deployment

[`scripts/deploy-archive-verify.sh`](../scripts/deploy-archive-verify.sh) installs the
verifier on the archive node as a revision-bound user-unit release, following
[link-health deployment](link-health.md). It defaults to a dry run. It requires the
exact accepted commit (see [deployment-source-binding.md](deployment-source-binding.md)),
ships only the script, `heimdall/push.sh` and the two units, and renders them on the
node with the verified rclone path.

```bash
BROKKR_EXPECTED_SOURCE="$PWD" BROKKR_EXPECTED_COMMIT=<accepted-full-sha> \
BROKKR_ARCHIVE_DELIVERY_ENV=/home/operator/.config/brokkr/env \
  scripts/deploy-archive-verify.sh operator@node-a.example          # dry run
# … then the same command with --apply
```

The preflight runs the shipped script's `--validate` on the node against the real
config. That reads only the local rclone config dump and the archive, and writes no
state or log. The deploy refuses an archive config that sets `ARCHIVE_LOG`, because
the unit can write only the state directory. It also refuses an archive config,
archive, manifest, or rclone binary under `/tmp` or `/var/tmp`, which `PrivateTmp=yes`
hides from the unit. This check is lexical and does not follow symlinks. `--apply` enables
`brokkr-archive-verify.timer`, which runs on the 1st of each month at 03:30 plus up to
2 h of random delay and catches up after downtime. Deploying does not start a
verification, because one run re-reads the whole archive and takes hours. Start the
first run explicitly and check it:

```bash
systemctl --user start --no-block brokkr-archive-verify.service
systemctl --user status brokkr-archive-verify.service
cat ~/.local/state/brokkr/archive-verify.json
```

The unit can write only `~/.local/state/brokkr` (state, snapshot, restore scratch) and
the rclone config and cache directories, because rclone may persist a refreshed OAuth
token. The rest of the home directory is read-only to it.

## Yearly key-custody drill

The off-site copy is only a backup while its key can be recovered without the archive
node. Once a year, and after any change to the password-manager entry:

1. On a separate machine with a fresh rclone config, rebuild the cloud remote and the
   crypt remote from the password-manager entry alone. Do not copy `rclone.conf`.
2. Run `rclone lsf <crypt-remote>:` and confirm the names decrypt.
3. Restore a few files to a new scratch directory, compare their sha256 with the
   manifest, open them, then delete the scratch copy and the temporary config.
4. Record the drill in the access-controlled operations log, using the
   [restore evidence record](backup-evidence.md#restore-evidence-record) fields.
5. Set `ARCHIVE_KEY_DRILL_DATE` in the archive config to the drill date. The
   `key-drill` row warns once 365 days have passed.

Never paste key material, `rclone config show` output, or account identifiers into a
ticket, log, or this repository.

## Rollback

The verifier only reads, so rolling it back means removing the schedule:
`systemctl --user disable --now brokkr-archive-verify.timer`. The deploy script prints
the exact unit-restore recipe for the steps it completed. It records the timer's
enabled and active state before changing any unit, and the recipe restores exactly
that state. A timer that was disabled before the deploy is never re-enabled or started. Off-site objects are never
deleted by this tooling. Removing a pushed archive from the cloud is a deliberate
manual operation outside it.
