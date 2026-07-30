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
occurrence.

For a due record, the occurrence key is exactly the canonical SHA-256 of
`policy_digest + target_scope_digest + window.start`. Under an exclusive
occurrence lock this maps to deterministic attempt, mutation, recovery-disarm,
and idempotency identities. The complete proposal is atomically persisted
before dispatch. A crash, persistent-timer retry, or duplicate invocation
therefore resumes the same proposal; it cannot mint another identity set.

Immediately before W2 effect, the factory re-reads the protected freshness
record. Policy, target, window, and kill-switch identity must still match and
all liveness/eligibility/kill/hold/validity predicates must still be true. W2
independently repeats authority, evidence, liveness, window, policy, inventory,
fence, and kill-switch checks before effect.

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

Every attempt uses the one constrained release-bound
`brokkr-debian-maintenance-recovery@.service` template. W2's authenticated
successor fence causes the fixed bridge to durably create the exact recovery
authorization before starting that instance. Recovery cannot select a command,
target, package set, unit, or replacement proposal.

The ceremony configuration fixes `watch_seconds` to 3600 and
`deadline_seconds` to 4200. The binding deadline is the earlier of the
canonical window end or 4200 seconds after the freshness observation; the
factory refuses an attempt unless at least the full constitutional watch hour
remains. W2's durable watch anchor, retry, recovery, quarantine, and disarm
machinery remains authoritative.

## Release closure

`install-debian-maintenance-canary.sh` archives the factory, W2 runner,
autonomy/policy helpers, fixed adapter, recovery bridge, pinned journal schema,
recovery template, and factory service/timer from the exact commit. Existing
release or unit bytes are never overwritten when they differ. Installation
never enables or starts the timer.
