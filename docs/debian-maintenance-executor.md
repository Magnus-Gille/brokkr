# Debian maintenance executor seam (brokkr#35, brokkr#66)

`scripts/debian-maintenance-executor.mjs` is a library-only, hermetic execution
seam for Debian maintenance. It has no package-manager, reboot, shell, remote
host, deployment, or production-signing capability of its own. Brokkr ships no
live adapter, no private key, and no armed target. `runDebianMaintenance()`
composes the executor with Brokkr's authoritative ADR-008 domain journal; this
PR therefore implements and observes the contract without arming autonomous
maintenance.

## Authorization and scope

Every attempt independently verifies the W0.1 owner-authorization bundle before
writing `prepare` or invoking an adapter:

- the owner Ed25519 public key must equal the separately pinned key, and the
  detached authorization signature and protected checkpoint must verify;
- the signed authorization must bind the exact constitution, coverage intent,
  Brokkr owner-attestation registry, and recovery-worker registry digests;
- the maintenance coverage row, exact target binding, writer/configuration
  owners, five actor identities, and owner attestation must agree;
- the protected runtime-narrowing tail must verify against the owner-bound
  recovery key, and a previously signed demotion to `shadow` makes the target
  ineligible.

Admission is fail closed. A caller must supply a trusted UTC clock, matching
kill-switch identity and safe state, fresh eligible evidence, healthy liveness
within the constitutional silence bound, an open maintenance window, and a
non-pillar Debian target. The plan may contain only unique `security` and/or
`bugfix` classes from the distribution repository, with `reboot_policy:
never` and no workload hooks. Constitutional deadline and rate/window limits
are derived from the verified artifacts rather than caller-selected values.

The executor retains the #35 policy checks as a second, narrower boundary. It
re-reads current policy and synchronized clock before inventory/drain and
before apply, verifies exact plan and policy digests, freshness, node
selection, window, holds, package-manager/disk/power/clock/workload gates, and
allowed package class/source. The ADR-008 wrapper is stricter than the older
executor surface: reboot-capable, kernel, third-party, workload-draining, and
pillar maintenance are outside this autonomous class even where the underlying
manual executor can represent them.

## Authoritative attempt journal

The journal uses the exact
`autonomous-mutation-journal` v1 schema copied from Grimnir commit
`298526972b46d4f8f0c40fbe92e830adb91087a8`; its bytes, schema ID, and supported
JSON-Schema keywords are pinned. Brokkr adds semantic validation for authority
bindings, actors, deadlines, phase transitions, receipts, quarantine, and
target-bound narrowing. Entries contain only bounded IDs, digests, and opaque
`ref:` handles—never commands, package logs, private locators, credentials, or
recovery material.

Success follows exactly:

`prepare → apply → verify → watch → commit`

Each transition obtains a new trusted timestamp. `watch` must consume the
declared interval, the kill switch is checked at admission and between
mutation phases, and commit additionally requires a maintenance-safe-state
readback matching the bound postconditions digest. The initial journal uses
exclusive creation and all durable replacements are fsynced. An exact terminal
retry under the same verified authorization snapshot is read-only; conflicting
bindings fail, and a consumed signed demotion blocks later admission.

An existing non-terminal receipt is ambiguous. Only a `prepare` receipt plus an
independent `not-applied` reconciliation may resume apply. Any later phase,
applied/indeterminate result, invalid reconciliation, deadline breach, failed
phase, or kill-switch transition enters recovery. Process-safe recovery
ownership prevents a second controller from executing the one-shot recovery
worker.

## Forward recovery and narrowing

This class is permanently `R-forward`: failures follow

`unknown → recover → quarantine → disarm`

The recovery worker must report recovered state, verified maintenance-safe
state, and active quarantine. It—not the controller—then appends a signed,
target-bound narrowing entry from the admitted state to `shadow`. Brokkr
verifies the signature against the owner-authorized recovery registry, the
authorization digest, append-only chain, protected tail, actor, target, and
exact disarm receipt before committing the authoritative `disarm` event.

If forward recovery fails its postconditions, the journal records a distinct
reason and ends `terminally-blocked`, again only after consuming an equivalent
signed target demotion. Recovery exceptions are surfaced as explicit
`recovery_error` values. No automatic rollback, reboot, retry loop, protected
lane mutation, or Verdandi dependency is introduced.

The executor's private before/after evidence journal remains separate and
content-limited. It records bounded inventory and adapter-result digests for
diagnosis; the ADR-008 domain journal is authoritative for admission,
promotion/recovery phases, quarantine, and target state.
