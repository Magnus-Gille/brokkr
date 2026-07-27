# Debian maintenance executor seam (brokkr#35, brokkr#66)

`scripts/debian-maintenance-executor.mjs` is the closed, library-only public
surface for Debian maintenance. It exports only immutable derivation and
`runDebianMaintenance()`. The raw effect seam and generic journal state machine
are closure-private inside `scripts/debian-maintenance-autonomy.mjs`; direct
imports of that module expose the same mandatory public wrapper rather than an
unbridged runner.
`scripts/maintenance-attempt-journal.mjs` exposes conformance helpers only.
A direct importer therefore cannot supply arbitrary phase callbacks behind a
valid lease and bypass the exact Debian plan, policy, target, inventory, or
execution request. The library has no package-manager, reboot, shell, remote
host, deployment, or production-signing capability of its own. Brokkr ships no
live adapter, no private key, and no armed target.

## Authorization and scope

Every attempt independently verifies the W0.2 owner-authorization bundle before
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

The W0.2 constitution and coverage artifacts, plus the unchanged v1 owner
authorization, attestation, recovery-worker, and runtime-narrowing envelopes,
are checked against byte-pinned copies of Grimnir's closed schemas before
their signatures or digests are trusted.
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
Every candidate is a closed object containing exactly `id`, `name`, `class`,
`source`, `current_version`, `candidate_version`, `eligible`, and `reasons`;
IDs are unique and canonically sorted, package names are unique, eligibility
must be true, and all strings and reason lists are bounded. Inventory and
postconditions are likewise closed to exactly `kernel`, `packages`,
`reboot_required`, and `dpkg_status`; packages are bounded, unique and sorted,
reboot must remain false, and dpkg state must remain clean.

`runDebianMaintenance()` also derives the outer immutable binding from the
inputs it will actually execute. The plan digest becomes the candidate digest;
the exact current policy becomes the policy digest; target/node plus the
adapter's reported revision become the configuration digest; and the
normalized pre-inventory and expected safe-state inventory become the baseline
and postcondition digests. Their combined evidence digest must match both the
outer envelope and the fresh evidence proof. The wrapper re-reads the target,
policy, adapter revision and inventory immediately before apply, then rechecks
the immutable authority/admission material before apply and commit. Every
immediate pre-mutation preflight obtains a new host inventory; the exact last
accepted snapshot becomes both the baseline digest and the `pre_state` passed
to the executor. Inventory drift therefore stops before the adapter is called.
Commit uses a separate binding check plus a fresh postcondition readback, so
post-mutation inventory cannot be reinterpreted as the admitted baseline.

The recovery host is an opaque, module-branded composition capability, not a
pair of caller-supplied `publishActivation`/`dispatch` callbacks. The bounded
dispatcher first persists the exact successor activation, then invokes only
the fixed host-adapter recovery action. Its returned outbox receipt includes
the activation digest and a terminal-receipt digest, each bound to the exact
successor revalidation fence. The original effect-lease digest remains a
separate historical value; it is never substituted for the successor fence.

A caller cannot substitute a different plan, policy, node, target, inventory,
adapter, or postcondition behind a valid-looking outer claim. The adapter
receives one deep-frozen, closed no-reboot/no-drain request containing the
exact target, candidates, policy/plan/adapter configuration, pre-state and
expected postconditions. There is deliberately no autonomous `apply`
fallback. Durable `prepare` remains the first adapter-facing attempt record.
Immediately after it (or after loading an existing prepared journal) and before
any initial, resumed, or recovery work, the effect owner must
implement `activateFence()` for the full target/binding/attempt/mutation/epoch/
token/activation/expiry capability. Mutation is available only through `applyFenced()`,
whose effect-owning transaction must atomically compare that entire active
capability immediately before and together with host actuation. Lower epochs
and same-epoch/different-token activations are invalid. Its receipt
binds both the immutable request and full fence digests. Controller-side
before/after assertions are defense in depth, not the fencing mechanism. The
older drain/reboot executor is module-private and is not an exported
journal-bypass capability.

The private executor retains the #35 policy checks as a second, narrower boundary. It
re-reads current policy and synchronized clock before inventory and
before apply, verifies exact plan and policy digests, freshness, node
selection, window, holds, package-manager/disk/power/clock/workload gates, and
allowed package class/source. Reboot-capable, kernel, third-party,
workload-draining, and pillar maintenance are structurally outside the only
exported autonomous execution path.

## Authoritative attempt journal

The journal uses the exact `autonomous-mutation-journal` v2 schema copied from
merged Grimnir commit `16edee0a5a0111f0142569f5b0cf2f90e807060c`;
the journal, v2 constitution, and v2 coverage schema bytes and IDs are pinned.
Brokkr adds semantic validation for authority bindings, actors, timing, phase
transitions, receipts, quarantine, and target-bound narrowing. Entries contain
only bounded IDs, digests, and opaque `ref:` handles—never commands, package
logs, private locators, credentials, or recovery material.

The earlier v1 journal, constitution, coverage schemas and fixtures remain
vendored as provenance for the rejected draft epoch. PR #71 was never merged,
armed, deployed, or given a live adapter, so no legitimate v1 maintenance
attempt exists and no v1 runtime recovery path is accepted. The fixed v2 pins
reject new v1 journals and mixed v1/v2 authority bundles.

The local verifier also enforces the canonical cross-field semantics that JSON
Schema cannot express: attempt and recovery-disarm identities differ, entry
IDs are unique within the journal, and `terminally-blocked` remains actively
quarantined. Re-digesting an adversarial journal cannot bypass these checks.

Success follows exactly:

`prepare → apply → verify → watch → commit`

Each transition obtains a new trusted timestamp. Prepare through apply,
readback, verify, and the durable authenticated `watch` receipt plus its
post-readback clock anchor are limited to 300 seconds. The controller fsyncs
and reads back the exact watch journal tail before it samples the anchor's
trusted timestamp. It then exclusively creates, fsyncs, and reads back a
closed anchor sidecar bound to the exact journal tail, journal, mutation,
attempt, target, candidate, and binding digests. That post-durability
anchor—not the earlier journal timestamp or a caller-prebound deadline—starts
the minimum 3600-second watch. Commit has at most 300 seconds of grace after
the earliest valid commit instant, while every success phase and the immutable
attempt deadline remain within 4200 seconds of prepare. Timestamps use the
exact canonical UTC form pinned by Grimnir; zero milliseconds are written as
`Z`, never `.000Z`. A start that cannot fit the minimum watch before its bound
deadline recovers instead of creating an unfinishable success path.

`watch` is a persisted, nonblocking continuation: after writing the receipt
and durable anchor the controller atomically releases its execution/resource
lease in target state `watching`. Earlier invocations remain `watching` and
release again. Every restart validates and reuses the immutable anchor; it
cannot replace or backdate it. A crash after the journal readback but before
anchor creation leaves no eligible watch clock and therefore enters forward
recovery rather than deriving one from the earlier journal timestamp. A crash
after persisting an authenticated anchor that exceeds the 300-second budget
likewise resumes into bounded forward recovery instead of throwing outside the
attempt state machine. The resulting recovery history and terminal disarm stay
readable and exactly replayable without another recovery effect, but a journal
containing `commit` always requires the anchor and all anchor-derived timing to
remain valid. At or after the anchor-derived earliest commit instant, the same
attempt reacquires a new epoch without consuming another proposal/rate slot,
installs that epoch in the effect and recovery resources, and performs the
final safe-state/authority checks. A continuation beyond commit grace
recovers. No process or lease is held synchronously during the one-hour watch.

The kill switch is checked at admission and between mutation phases, and commit
additionally requires a maintenance-safe-state readback from a fresh host
inventory matching the bound postconditions digest.
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
epoch, holder token, trusted activation instant and trusted-time expiry. There
are no separate initial and resume claims and no caller assertion that a claim
was abandoned. An expired
lease may transfer mechanically; every journal append and target transition is
fenced by the exact epoch/token. Lease acquisition also installs the full
capability in the effect owner. A later epoch/token supersedes it, so an old
writer blocked before its transaction cannot produce the host effect after
transfer, irrespective of whether it could later publish a journal receipt.
The hermetic concurrency test uses one fake resource transaction for fence
activation and check-plus-effect to prove this property.

An existing non-terminal receipt is ambiguous. Only a `prepare` receipt plus an
independent `not-applied` reconciliation may resume apply after the persisted
lease expires and transfers. Any later phase,
applied/indeterminate result, invalid reconciliation, deadline breach, failed
phase, or kill-switch transition enters recovery. The one exception is the
explicit persisted `watch` continuation described above; it never reapplies.
The same fenced lease prevents concurrent initial, resume, and recovery
actuators.

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
digest. An existing prepared attempt enters recovery from that authenticated
historical envelope even after current owner authorization rotates. Current
authority is consulted only for a valid signed narrowing posture and the kill
switch; it cannot rewrite the old attempt's mutation authority or make it
resume actuation. A corrupt or unavailable current bundle likewise forces
historical recovery rather than stranding the attempt; it can never authorize
resume. Pending outboxes still consult the current kill/signed-narrowing
posture.

Recovery has the same resource-bound fencing requirement as apply. Every lease
activation is installed monotonically in the recovery resource. The durable
outbox request immutably carries the original full
target/binding/attempt/mutation/epoch/token/activation/expiry fence and digest.
It is never rewritten during takeover. A separate successor revalidation fence
advances monotonically; `recover()` must atomically compare that current fence
inside the idempotent resource transaction. If the original effect already
has a receipt, replay preserves its original effect-fence digest while adding
the successor revalidation digest and timestamp. If no effect occurred, the
successor effect receipt is bound to the successor fence. In both cases an old
blocked recovery writer cannot actuate after transfer.

Recovery then fsyncs its idempotent request and `unknown`
receipt in a staged outbox before any recovery effect. Every later boundary is restartable:
unknown append, target transition, recovery invocation/result, recover and
quarantine receipts, signed-ledger append, protected-checkpoint advance,
terminal append and terminal release. A crash after the durable release but
before advancing the outbox stage is repaired from the authenticated terminal
journal before any new claim or rate-limit check. Before appending narrowing, a
retry verifies current signed history and consumes an already-present exact
domain/target/from-state/to-state/worker/terminal tuple instead of duplicating
it. If another valid target was appended in the same historical authorization
epoch, recovery rebases on that freshly verified tail before signing rather
than trusting the attempt's initial snapshot. Concurrent exact outbox creation
adopts the already-created matching binding/idempotency record. A later
owner-key or registry rotation therefore cannot strand an already prepared or
recovered attempt.

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
