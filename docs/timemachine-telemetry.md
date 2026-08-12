# M5 Time Machine destination telemetry

M5 is the Linux server that hosts the Time Machine destination, not the Mac
client. This producer therefore does not call `tmutil`. It reads bounded
metadata from the sparsebundle **band-files directory** on M5: writes change a
band file, while the sparsebundle directory timestamp alone is not evidence.

## Truth and privacy contract

The M5 user service reads one owner-only, mode-0600 configuration file at
`~/.config/brokkr/timemachine-probe.env` by default. It contains exactly:

```sh
BROKKR_TM_BANDS_DIR=/absolute/private/bands-directory
```

The value is parsed as data, never sourced. The configuration must be a regular
non-symlink owned by the service user; traversal and symlink inputs fail closed.
Its path and contents never enter git, output, or the Heimdall payload.

`destination-probe.py` scans regular band files only, without following
symlinks. A depth, entry cap, and monotonic runtime deadline bound the read-only
scan. It normalizes only result/reason, observation time, newest-band time and
age, count, and aggregate size.

| Observation | Heimdall state |
|---|---|
| Recent regular band-file update | `pass` |
| Scan completed with no band files or only stale band files | `fail` |
| Missing/unreadable source, policy rejection, invalid timestamp, entry cap, or timeout | `warn` — explicit unknown |

The snapshot is atomically replaced before the existing authenticated Heimdall
`brokkr` / `timemachine` panel transport runs. A write/rename error stops before
delivery, so an older snapshot cannot be replayed as current. The probe never
starts, modifies, mounts, or deletes a backup.

The systemd unit treats the observed state and the telemetry run outcome as
separate signals. A `warn` or `fail` probe result is valid health evidence; if
its snapshot is delivered successfully, the unit exits successfully so the
warning remains visible without becoming a delivery failure. A result is valid
only when status and probe exit code match exactly: `pass`/0, `warn`/1, or
`fail`/2. Any mismatch, snapshot publication error, or Heimdall transport
failure exits non-zero and remains retryable/observable to systemd.

## Install, readback, and reversal

Nothing is installed automatically. On M5, create the protected probe file and
the existing protected `heimdall.env` delivery file, then bind an exact clean
Brokkr source revision into a private release target:

```bash
./scripts/deploy-m5-timemachine-telemetry.sh /absolute/clean/worktree FULL_COMMIT_SHA
# review the dry run, then:
./scripts/deploy-m5-timemachine-telemetry.sh /absolute/clean/worktree FULL_COMMIT_SHA --apply
systemctl --user start brokkr-timemachine-telemetry.service
```

The existing protected Heimdall fleet environment must be available to the
service user. Confirm one HTTP acknowledgement and the resulting panel; retain
only its time, result, count, and size in the operator record.

To stop observations without affecting backups:

```bash
systemctl --user disable --now brokkr-timemachine-telemetry.timer
```

The installed unit points at the exact private release, never the canonical
checkout. The installer preserves the preceding unit next to it; restore that
file (if present), disable the timer, and reload the user manager to reverse an
installation. The local snapshot is cached telemetry metadata only.
