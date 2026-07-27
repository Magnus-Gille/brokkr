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

The six W0.1 authority artifacts are checked against byte-pinned copies of
Grimnir's closed schemas before their signatures or digests are trusted.
Domain rows, target bindings and attestations must be unique; all five actor
identities must be distinct; and the supplied recovery capability must present
the exact key fingerprint from the owner-signed registry.

Admission is fail closed. A caller must supply a trusted UTC clock, matching
kill-switch identity and safe state, fresh eligible evidence, healthy liveness
within the constitutional silence bound, an open maintenance window, and a
non-pillar Debian target. The plan may contain only unique `security` and/or
`bugfix` classes from the distribution repository, with `reboot_policy:
never` and no workload hooks. Constitutional deadline and rate/window limits
are derived from the verified artifacts rather than caller-selected values.

`runDebianMaintenance()` also derives the outer immutable binding from the
inputs it will actually execute. The plan digest becomes the candidate digest;
the exact current policy becomes the policy digest; target/node plus the
adapter's reported revision become the configuration digest; and the
normalized pre-inventory and expected safe-state inventory become the baseline
and postcondition digests. Their combined evidence digest must match both the
outer envelope and the fresh evidence proof. The wrapper re-reads the target,
policy, adapter revision and inventory immediately before apply, then rechecks
the immutable authority/admission material before apply and commit. A caller
cannot substitute a different plan, policy, node, target, inventory, adapter,
or postcondition behind a valid-looking outer claim.

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
exclusive creation and all durable replacements are fsynced. Every append is a
tail-digest compare-and-swap under a monotonic, exclusive-create lock ticket.
A successor may advance past an incomplete ticket only after its owning
process is proven dead; tickets are never unlinked or reused, eliminating
read-then-delete takeover races. An exact
terminal retry is read-only even after signed demotion; conflicting bindings
cannot masquerade as that retry.

One fsynced domain-state record is authoritative for the active target,
per-target state, per-proposal attempt count, recent attempt window and global
one-target concurrency bound. Claiming or releasing a target changes that one
record in one atomic replacement, so no split domain/target transaction can be
left by a crash. Distinct proposal IDs for the same target, a second active
target, an exhausted proposal, or a rate-window breach fail before actuation.
Unknown, disarmed and terminally blocked targets remain unavailable pending
owner action.

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

Recovery uses a durable two-phase outbox. It first fixes the exact terminal
receipt, appends and verifies its signed narrowing plus protected checkpoint,
and only then CAS-appends the terminal journal receipt. A retry at any boundary
finishes the same outbox without invoking forward recovery twice. Historical
owner authorization and narrowing are retrieved by the prepared authorization
digest, so a later owner-key or registry rotation can narrow but cannot strand
an already recovered attempt.

If forward recovery fails its postconditions, the journal records a distinct
reason and ends `terminally-blocked`, again only after consuming an equivalent
signed target demotion. Recovery exceptions are surfaced as explicit
`recovery_error` values. No automatic rollback, reboot, retry loop, protected
lane mutation, or Verdandi dependency is introduced.

The executor's private before/after evidence journal remains separate and
content-limited. It records bounded inventory and adapter-result digests for
diagnosis; the ADR-008 domain journal is authoritative for admission,
promotion/recovery phases, quarantine, and target state.
