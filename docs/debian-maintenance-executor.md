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
or postcondition behind a valid-looking outer claim. The adapter receives one
deep-frozen, closed no-reboot/no-drain request containing the exact target,
candidates, policy/plan/adapter configuration, pre-state and expected
postconditions, together with the current execution-lease epoch. Its receipt
must bind that request digest and epoch exactly. The older drain/reboot executor
is module-private and is not an exported journal-bypass capability.

The private executor retains the #35 policy checks as a second, narrower boundary. It
re-reads current policy and synchronized clock before inventory and
before apply, verifies exact plan and policy digests, freshness, node
selection, window, holds, package-manager/disk/power/clock/workload gates, and
allowed package class/source. Reboot-capable, kernel, third-party,
workload-draining, and pillar maintenance are structurally outside the only
exported autonomous execution path.

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
readback from a fresh host inventory matching the bound postconditions digest.
The cached post-apply inventory is diagnosis only and can never satisfy commit.
The initial journal uses
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
owner action. That same record owns the single execution lease: a monotonic
epoch, holder token and trusted-time expiry. There are no separate initial and
resume claims and no caller assertion that a claim was abandoned. An expired
lease may transfer mechanically; every journal append and target transition is
fenced by the exact epoch/token, and the adapter request/receipt carries the
epoch so a stale actuator cannot later publish success.

An existing non-terminal receipt is ambiguous. Only a `prepare` receipt plus an
independent `not-applied` reconciliation may resume apply after the persisted
lease expires and transfers. Any later phase,
applied/indeterminate result, invalid reconciliation, deadline breach, failed
phase, or kill-switch transition enters recovery. The same fenced lease
prevents concurrent initial, resume, and recovery actuators.

## Forward recovery and narrowing

This class is permanently `R-forward`: failures follow

`unknown → recover → quarantine → disarm`

The recovery worker must report recovered state, verified maintenance-safe
state, and active quarantine. It—not the controller—then appends a signed,
target-bound narrowing entry from the admitted state to `shadow`. Brokkr
verifies the signature against the owner-authorized recovery registry, the
authorization digest, append-only chain, protected tail, actor, target, and
exact disarm receipt before committing the authoritative `disarm` event.

Before the execution lease is claimed, Brokkr fsyncs an exact historical
authority snapshot containing the signed authorization, owner-bound artifacts,
recovery-key fingerprint, initial narrowing tail and immutable admission
digest. Recovery then fsyncs its idempotent request and `unknown` receipt in a
staged outbox before any recovery effect. Every later boundary is restartable:
unknown append, target transition, recovery invocation/result, recover and
quarantine receipts, signed-ledger append, protected-checkpoint advance,
terminal append and atomic terminal release. Before appending narrowing, a
retry verifies current signed history and consumes an already-present exact
domain/target/from-state/to-state/worker/terminal tuple instead of duplicating
it. A later owner-key or registry rotation therefore cannot strand an already
prepared or recovered attempt.

Commit release is equally crash-safe. The commit receipt is CAS-appended first;
target, domain and lease release then happen in one domain-state replacement,
and exact terminal replay repairs a crash in that gap without actuating again.

If forward recovery fails its postconditions, the journal records a distinct
reason and ends `terminally-blocked`, again only after consuming an equivalent
signed target demotion. Recovery exceptions are surfaced as explicit
`recovery_error` values. Transport uncertainty leaves the staged,
idempotency-keyed recovery request restartable rather than inventing a terminal
result. No automatic rollback, reboot, retry loop, protected
lane mutation, or Verdandi dependency is introduced.

The executor's private before/after evidence journal remains separate and
content-limited. It records bounded inventory and adapter-result digests for
diagnosis; the ADR-008 domain journal is authoritative for admission,
promotion/recovery phases, quarantine, and target state.
