# Debian maintenance attempt factory

The attempt factory is the closed production producer between the owner
ceremony and the existing W2 `runDebianMaintenance` / fixed-host-adapter path.
It is not a generic controller. Its root CLI accepts zero arguments:

```
/usr/local/lib/brokkr/releases/<sha>/scripts/debian-maintenance-attempt-factory.mjs
```

The installed service reads only the fixed root-owned ceremony configuration
at `/etc/brokkr/debian-maintenance-attempt-factory.json`, protected authority
files below `/etc/brokkr/debian-maintenance-authority`, the recurring evidence
record at `/run/brokkr/debian-maintenance-window-freshness.json`, and the fixed
state root at `/var/lib/brokkr/debian-maintenance`. Target, path, package,
actor, policy, identity, and command selection are not accepted from the
scheduler or argv. All inputs must be root-owned regular non-symlink files with
no group/other permissions. The owner ceremony installs them before enabling
the timer; installation leaves both service and timer disabled.

## Occurrence and crash contract

Every evaluation reads a fresh record covering liveness, eligibility, kill
switch, hold, exact policy, canonical window, fixed target, plan, inventory
baseline, expected postconditions, and apt-source evidence. Unavailable,
unknown, stale, held, killed, ineligible, or non-due evidence creates no
occurrence. `observed_at` may be at most 300 seconds old even when
`valid_until` is later.

For a due record, the occurrence key is exactly the canonical SHA-256 of
`policy_digest + target_scope_digest + window.start`. Under an exclusive
occurrence lock this maps to deterministic attempt, mutation, recovery-disarm,
and idempotency identities. The complete proposal is atomically persisted
before dispatch. A crash, persistent-timer retry, or duplicate invocation
therefore resumes the same proposal; it cannot mint another identity set.
Stale-lock takeover first wins an immutable hard-link claim for the exact
owner and directory inode generation, then revalidates both immediately before
rename. Competing reclaimers cannot rename a winner's replacement lock; a
crashed reclaimer is superseded through another atomically claimed generation.

Immediately before W2 effect, the factory re-reads the protected freshness
record. Until the fixed host journal ends in its valid `verify` phase, policy, target,
window, kill-switch identity, plan, inventory baseline, expected
postconditions, and apt-source evidence must exactly match the persisted
proposal, and all liveness/eligibility/kill/hold/validity predicates must still
be true. Apt evidence is checked again at the fixed adapter immediately before
the package effect. W2 independently repeats authority, evidence, liveness,
window, policy, inventory, fence, and kill-switch checks before effect.

After that terminal host verification, the immutable proposal and W2 binding
remain the effect authority. A refreshed record may legitimately contain a recomputed
plan, inventory, projected postconditions, and apt evidence because installed
state has changed; those values are no longer compared to the pre-effect
proposal. The record must still be current, live, eligible, unheld, unkilled,
in the same policy/target/window/kill-switch occurrence, and otherwise valid.
During durable-watch continuation, W2 reads the current protected freshness
inventory rather than synthesizing the proposal's expected state. The one-hour
readback compares that current inventory with the immutable binding's
postconditions digest; drift cannot commit and enters fail-closed recovery.
The immediate post-apply inventory remains grounded in the fixed host adapter's
verified `applied` outcome.

## Acyclic digest graph

The production graph is:

```
plan + baseline + postconditions -> execution request
recovery descriptor v2 (never binding_digest) -> descriptor_digest
execution digests + descriptor_digest -> full W2 binding -> binding_digest
binding_digest -> lease fence + request v2 + registration + recovery authorization
```

The descriptor binds the attempt, mutation, recovery-disarm, target,
candidate, postcondition, recovery worker, exact package set, allowlisted
restart set, and budget. The host request includes the complete W2 binding.
The fixed adapter recomputes both digests and all actor/identity echoes.
Placeholder digests, cyclic descriptors, and changed edges fail closed.

## Fixed runtime and recovery

The production runtime builds W2's artifact reader, admission probes, recovery
ledger signer/checkpoint writer, and Debian adapters only from fixed protected
files. It calls `runDebianMaintenance` directly. Immediately before the host
effect it persists the final lease-fenced request and registration and invokes
only the release-local fixed host adapter. Configuration cannot supply code,
callbacks, commands, paths, packages, or units.

The factory service intentionally uses `ProtectSystem=false`, matching the
fixed apply and recovery units. It directly runs the real `apt-get` transaction
through the fixed host adapter. Debian package payloads and maintainer scripts
may write host paths such as `/usr`, `/etc`, `/boot`, and
`/var/lib/apt/extended_states`; a strict systemd root would make valid upgrades
fail with `EROFS`. The retained
`ReadWritePaths=/var/lib/brokkr/debian-maintenance /var/lib/dpkg /var/cache/apt
/var/log/apt` line is the exact state/dpkg/apt convention shared by the fixed
units, but with `ProtectSystem=false` it is not an allowlist for all package
writes. `ReadOnlyPaths=/etc/brokkr /run/brokkr` still protects the factory's
configuration and freshness inputs.

Factory evidence digests use the canonical JSON byte representation for every
value, including strings; the fixed host adapter consumes those exact bytes,
so string and object evidence have identical digest semantics across the
factory-to-host boundary.

This is an inherent host-filesystem write authority, not a sandbox that makes
apt/dpkg harmless. The security boundary is the release-bound fixed adapter,
the factory's zero-argument CLI, the exact persisted request/attempt/package
set and root-owned inputs, plus the remaining systemd hardening controls:
`NoNewPrivileges`, `PrivateTmp`, `ProtectHome`, the kernel/control-group/log
protections, `PrivateDevices`, `RestrictSUIDSGID`, and the exact read-only input
paths. The installer requires exactly one of each fixed service-hardening,
identity, environment, and execution directive, including `NoNewPrivileges`,
`PrivateTmp`, `ProtectHome`, the kernel/control-group/log protections,
`PrivateDevices`, and `RestrictSUIDSGID`. It also requires exactly one
`ProtectSystem=false`, the exact read-only and read-write path lines, the
release-bound zero-argument `ExecStart`, and rejects extra path-authority
directives or duplicate assignments.

The installer also writes the legacy per-canary marker and the exact
revision-bound global gate
`/var/lib/brokkr/debian-maintenance/disarmed/factory-<release-sha>.json` before
any systemd action. The factory validates that gate against its
`BROKKR_RELEASE_SHA` and returns `no-attempt` before creating, resuming, or
effecting an occurrence; the fixed production bridge checks it again at the
effect boundary immediately before invoking the host adapter. Disable then
disables/stops the shared timer and
factory service, followed by the canary apply unit and its recovery instance;
all actions are attempted even when one fails, and the gate/evidence remain
available for recovery and audit. A later revision uses a different gate path,
so an old disable cannot accidentally disarm the new release.

Every attempt uses the one constrained release-bound
`brokkr-debian-maintenance-recovery@.service` template. W2's authenticated
successor fence causes the fixed bridge to durably create the exact recovery
authorization before starting that instance. Recovery cannot select a command,
target, package set, unit, or replacement proposal.

The ceremony configuration fixes `watch_seconds` to 3600 and
`deadline_seconds` to 4200. The binding deadline is the earlier of the
canonical window end or 4200 seconds after the freshness observation; the
factory refuses a new or not-yet-applied attempt unless 300 seconds of
apply/verify budget plus the full 3600-second constitutional watch remain at
the current pre-effect time. An already verified effect may resume its durable
watch without pretending it needs another apply budget. W2's durable watch
anchor, retry, recovery, quarantine, and disarm machinery remains authoritative.

## Release closure

`install-debian-maintenance-canary.sh` archives the factory, W2 runner,
autonomy/policy helpers, fixed adapter, recovery bridge, pinned journal schema,
recovery template, and factory service/timer from the exact commit. Existing
release or unit bytes are never overwritten when they differ. Installation
never enables or starts the timer.
