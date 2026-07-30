# Owner ceremony packet for supervised Debian maintenance

This is a public-safe, non-operational checklist for the owner ceremony that
precedes Brokkr #69 and the live-evidence gate in #70. It records only public
revisions, SHA-256 digests, opaque identifiers, bounded status values, and
evidence conclusions. Keep target identity, network information, trust
material, credentials, commands, package details, logs, and recovery material
in an owner-controlled private record; do not copy them into this packet or
git.

This document grants no authority. The installer remains disabled by default;
the current delivery adapter remains `delivery_disabled`; and an incomplete or
mismatched row is a stop condition.

## Ceremony record

Create a copy outside git for a specific ceremony. Fill every `REQUIRED` field
from independently checked evidence. A digest is `sha256:` followed by 64
lowercase hexadecimal characters. An opaque ID must not encode a host name,
address, account, path, or recovery detail.

| Field | Required value |
| --- | --- |
| Ceremony ID | `REQUIRED: opaque ID` |
| Owner decision | `REQUIRED: explicit approve / hold / abort` |
| Source release revision | `REQUIRED: full 40-character Git SHA` |
| Source checkout result | `REQUIRED: clean and exactly at the release revision` |
| Controller revision and digest | `REQUIRED: full SHA and content digest` |
| Host-operation revision and digest | `REQUIRED: full SHA and content digest` |
| Recovery-unit-template digest | `REQUIRED: content digest` |
| Execution-result schema digest | `REQUIRED: content digest` |
| Policy, plan, constitution, target-scope, configuration, evidence, baseline, and postconditions digests | `REQUIRED: eight content-blind digests` |
| Owner-authorization, owner-attestation, and recovery-registry digests | `REQUIRED: three content-blind digests` |
| Private target eligibility record | `REQUIRED: checked privately; record only its target-scope digest here` |
| Private trust-root binding record | `REQUIRED: checked privately; record only its authorization/registry digests here` |
| Canary state | `REQUIRED: one eligible canary; target count = 1; no fleet state` |
| Delivery state | `REQUIRED: delivery_disabled before and after the ceremony` |

## Roles and separation

The owner must name a person or approved role for each row in the private
record. This public packet carries only the role names and their evidence
digest(s).

| Role | Required responsibility | Evidence to retain privately |
| --- | --- | --- |
| Owner | Approves, holds, or aborts; authorizes the exact bound attempt | decision and authorization digest |
| Brokkr control plane | Sole arm/disarm authority and journal producer | binding and journal-tail digests |
| Fixed host operation | Executes only the fixed no-reboot Debian request or fixed R-forward recovery | request/registration and terminal-receipt digests |
| Recovery worker | Executes recovery, quarantine, and disarm; never promotes | successor-fence and terminal-receipt digests |
| Heimdall consumer | Read-only projection and freshness/reconciliation display; no lifecycle authority | received result digest and display check |
| Independent verifier | Checks the evidence record and promotion blocks | verifier identity and verdict digest |

## Fixed safety envelope

All entries below must be affirmatively verified for the bound release.

- Scope is one independently reachable Debian, non-pillar canary; it is not a
  control-plane, Hugin, Munin, M5, sole-backup, or sole-ingress dependency.
- Only already-bound `security` or `bugfix` upgrades are eligible. Kernel,
  reboot, firmware, boot-chain, hooks, removals, new dependencies, downgrade,
  remote recovery, and fleet action remain out of scope.
- The attempt binds exact policy, plan, constitution, target scope,
  configuration, source revision, postconditions, recovery descriptor, and
  admission evidence. Any mismatch fails closed.
- The timing budget is at most 300 seconds through durable watch anchoring, at
  least 3,600 seconds of watch, at most 300 seconds commit grace, and at most
  4,200 seconds from prepare to deadline. Forward recovery has at most 300
  seconds and ends quarantined plus disarmed or terminally blocked.
- The authoritative journal and terminal receipt remain source evidence. The
  metadata-only result may contain only opaque IDs, digests, canonical UTC
  timestamps, aggregate probe counts, and closed status values.

## Offline evidence gate — required before any live owner action

- [ ] Record the exact release SHA and the SHA-256 values of the controller,
  executor, journal, host adapter, recovery template, installer, projector,
  delivery boundary, schema, and fixture corpus.
- [ ] Run the full hermetic test suite, shellcheck, and diff check on the exact
  clean release; retain the public-safe summary and evidence digests.
- [ ] Produce and inspect the revision-bound fault-injection dossier. It must
  contain one clean path and ten induced failures; every failure must be
  quarantined and disarmed or terminally blocked within its declared budget.
- [ ] Verify the installer is revision-bound, byte-idempotent, and cannot
  enable, start, arm, dispatch, or create authority inputs.
- [ ] Verify the delivery boundary still reports `delivery_disabled` and that
  all positive and adversarial execution-result fixtures validate.
- [ ] Verify Heimdall #16 is merged and deployed as a read-only consumer, then
  check fresh, unknown, stale, unreconciled, and mismatch rendering against the
  shared fixture corpus. This is a live dependency and cannot be inferred from
  Brokkr source alone.

## #69 owner-ceremony gate

Proceed only after the offline gate and private records prove target eligibility
and trust-root binding. The owner must separately authorize each state change.

- [ ] Install only the exact, clean, revision-bound release; leave its units
  disabled after installation and record the installed release digest.
- [ ] Independently verify the disabled units, immutable release bytes,
  root-owned private state protection, reserves, and absence of an enabled
  timer or delivery transport.
- [ ] Bind the private authority inputs to the exact release and all recorded
  public digests. Confirm distinct owner, controller, watchdog, kill-switch,
  and recovery-worker identities without exposing them here.
- [ ] Arm one canary only after the owner records an explicit approval. Confirm
  that only the Brokkr control plane can arm or disarm and that Heimdall cannot
  mutate lifecycle state.
- [ ] Before any scheduled window, verify the current target eligibility,
  maintenance-safe state, bounded plan, clock, and protected postconditions.
- [ ] Stop and disarm on any missing, stale, unknown, unreconciled, failed, or
  recovery-worker outcome. Do not promote, retry across an ambiguous package
  boundary, or substitute a new plan.

## #70 evidence-run gate

This gate requires #69's exact bound production path and a deployed green
read-only Heimdall #16 consumer. It does not authorize fleet expansion.

- [ ] Run two consecutive eligible scheduled windows through the exact armed
  production path. For each, retain fresh pre/post evidence, journal and
  receipt continuity, postcondition proof, source/configuration digests, and
  result digest.
- [ ] Run a hold/disarm drill through that production path. Independently
  verify durable disarm, quarantine when required, and that no promotion is
  possible.
- [ ] Run an induced R-forward recovery drill through that production path.
  Independently verify deadline recovery with the observer unavailable,
  quarantine, terminal receipt continuity, and disarm.
- [ ] Verify Heimdall displays fresh, unknown, stale, unreconciled, and
  mismatch states correctly, with no mutation authority.
- [ ] Prove mechanically that failed, stale, unknown, unreconciled, disarmed,
  terminally-blocked, and recovered-by-worker results block expansion.
- [ ] Publish only a reviewed, redacted evidence note naming exact merged and
  deployed revisions plus content-blind digests. Obtain root Codex, M5, and
  available Opus review acceptance and green CI before considering the evidence
  complete.

## Stop, rollback, and evidence disposition

- Any mismatch, missing proof, untrusted clock, invalid eligibility, unexpected
  result, failed drill, or unavailable verifier is an abort/hold condition.
- Use the bound disable path to persist disarm before attempting a stop. Retain
  journals, receipts, evidence, and immutable release bytes for investigation.
- A live evidence result is not a promotion decision. Fleet action remains a
  separate owner decision and is outside Brokkr #69 and #70.
