# NAS Samba Time Machine retirement

The NAS deployment defaults to a retired `[TimeMachine]` share. This keeps a
future Samba deployment from re-enabling an obsolete destination. The M5 Time
Machine destination and its independent telemetry producer are separate.

Keep the service-backup mount and producer paths unchanged when retiring the
share. This operation does not delete data, migrate backups, or alter mounts.

## Configuration and immutable source

Copy `samba/timemachine.example.conf` into an ignored operator configuration and
adapt its storage path and user. The retired section must contain both:

```ini
[TimeMachine]
   available = no
   fruit:time machine = no
```

An old enabled configuration is rejected before any network call. The operator
configuration must be a regular, non-symlink file. The deploy entry requires a
clean selected worktree, an explicit accepted full commit SHA, and an explicit
`user@hostname` or `user@IPv4` target. The remote executable comes from a Git
archive of that commit, rather than mutable working-tree bytes.

Run from the selected worktree root only after approval of the exact release,
target, command, verification, and rollback:

```sh
BROKKR_EXPECTED_SOURCE=/absolute/clean/worktree \
BROKKR_EXPECTED_COMMIT=<accepted-full-commit-sha> \
BROKKR_SAMBA_CONFIG=/absolute/operator/timemachine.conf \
  ./samba/deploy.sh brokkr@nas.example
```

`BROKKR_SAMBA_TIME_MACHINE_STATE` accepts `retired` (default) or `active`.
An intentionally active destination needs its own explicit approval, an adapted
configuration with `fruit:time machine = yes`, and the explicit `active` state.
No other value is accepted. This opt-in preserves reuse of the deployment tool
without turning the retired NAS destination back on by default.

## Verification and rollback

The installer removes inline Time Machine sections, preserves other sections,
and ensures the include exists. It validates the section's effective state with
`testparm`, including on a no-op invocation. Retired means both `available = no`
and `fruit:time machine = no`; flags in another section do not satisfy it.

Only a validated change reloads `smbd`. Validation or reload failure restores
both configuration files and exits with failure. After a failed reload, verify
the live service before retrying: restored files alone do not prove the service
has loaded them. Earlier rollback copies are preserved when a later deployment
is a no-op. SSH rejects unknown host keys and does not forward the agent.

Use a separate read-only check of the effective share state, `smbd` activity,
the service-backup mount and paths, and NAS health delivery as the final
production acceptance. Keep dated operator evidence outside the public repo.
