# Owner ceremony packet for supervised Debian maintenance

This is a public-safe, non-operational checklist for the owner ceremony that
precedes Brokkr #69 and the live-evidence gate in #70. It records only public
revisions, SHA-256 digests, opaque identifiers, bounded status values, and
evidence conclusions. Keep target identity, network information, trust
material, credentials, commands, package details, logs, and recovery material
in an owner-controlled private record; do not copy them into this packet or
git.

This document grants no authority. The installer remains disabled by default
and the current delivery adapter remains `delivery_disabled`. Live Heimdall
evidence additionally requires Brokkr #81's separately reviewed authenticated
delivery adapter and a separately reviewed scheduler/unit-enablement/arming
mechanism. Before the ceremony, their exact reviewed, revision-bound artifacts
must be available for inspection but must not be installed. Current Brokkr
source provides neither live capability. An incomplete or mismatched row is a
stop condition.

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
| Executor revision and digest | `REQUIRED: full SHA and content digest` |
| Journal revision and digest | `REQUIRED: full SHA and content digest` |
| Host-operation revision and digest | `REQUIRED: full SHA and content digest` |
| Bounded-recovery-dispatcher revision and digest | `REQUIRED: full SHA and content digest` |
| Recovery-unit-template digest | `REQUIRED: content digest` |
| Installer revision and digest | `REQUIRED: full SHA and content digest` |
| Projector revision and digest | `REQUIRED: full SHA and content digest` |
| Inert delivery-boundary revision and digest | `REQUIRED: full SHA, content digest, and delivery_disabled readback` |
| Execution-result schema digest | `REQUIRED: content digest` |
| Fixture-corpus digest and readback | `REQUIRED: aggregate content digest and producer/consumer conformance result` |
| Ceremony-pinned coverage digests | `REQUIRED: policy, constitution, coverage, target-scope, and configuration digests` |
| Owner-authorization, owner-attestation, and recovery-registry digests | `REQUIRED: three content-blind digests` |
| Private target eligibility record | `REQUIRED: checked privately; record only its target-scope digest here` |
| Private trust-root binding record | `REQUIRED: checked privately; record only its authorization/registry digests here` |
| Canary state | `REQUIRED: one eligible canary; target count = 1; no fleet state` |
| Authenticated delivery adapter (#81) | `REQUIRED: exact reviewed revision/digest available before approval but not installed; disabled install, then configured/enabled/readback-ready before arming` |
| Scheduler/unit-enablement/arming mechanism | `REQUIRED: exact reviewed revision/digest available before approval but not installed; disabled install and readback after approval; absent from current source` |
| Per-window attempt facts | `AUTO-RECORDED: attempt ID, plan, evidence, baseline, postconditions, deadline, journal and receipt digests; never ceremony inputs` |

## Roles and separation

The owner must name a person or approved role for each row in the private
record. This public packet carries only the role names and their evidence
digest(s).

| Role | Required responsibility | Evidence to retain privately |
| --- | --- | --- |
| Owner | Approves, holds, or aborts the exact covered target, authority bundle, release, delivery path, scheduler and arming transition; does not authorize per-window attempts | decision and authorization digest |
| Brokkr control plane | Sole arm/disarm authority; derives and journals each eligible window's exact attempt facts | coverage binding and per-window journal-tail digests |
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
- The ceremony pins the policy, constitution, authority, target coverage,
  configuration, release, recovery class, and mechanisms that may operate. It
  does not authorize an exact attempt or pre-bind a future plan, evidence,
  baseline, postconditions, or deadline.
- For each eligible scheduled window, the Brokkr control plane automatically
  derives and records the exact attempt ID, plan, fresh evidence, baseline,
  postconditions, deadline, journal, and receipt under that armed coverage.
  Those per-window facts must not be ceremony inputs and every mismatch fails
  closed without per-run human approval.
- The timing budget is at most 300 seconds through durable watch anchoring, at
  least 3,600 seconds of watch, at most 300 seconds commit grace, and at most
  4,200 seconds from prepare to deadline. Forward recovery has at most 300
  seconds and ends quarantined plus disarmed or terminally blocked.
- The authoritative journal and terminal receipt remain source evidence. The
  metadata-only result may contain only opaque IDs, digests, canonical UTC
  timestamps, aggregate probe counts, and closed status values.

## Offline evidence gate — required before any live owner action

- [ ] Record the exact release SHA and the SHA-256 values of the controller,
  executor, journal, host adapter, bounded recovery dispatcher, recovery
  template, installer, projector, delivery boundary, schema, and fixture corpus.
- [ ] Run the full hermetic test suite, shellcheck, and diff check on the exact
  clean release; retain the public-safe summary and evidence digests.
- [ ] Produce and inspect the revision-bound fault-injection dossier. It must
  contain one clean path and ten induced failures; every failure must be
  quarantined and disarmed or terminally blocked within its declared budget.
- [ ] Verify the installer is revision-bound, byte-idempotent, and cannot
  enable, start, arm, dispatch, or create authority inputs.
- [ ] Verify the delivery boundary still reports `delivery_disabled` and that
  all positive and adversarial execution-result fixtures validate.
- [ ] Before live Heimdall evidence, obtain the exact revision and digest of a
  Brokkr #81 separately reviewed authenticated delivery adapter. Verify its
  artifact is available but not installed before owner approval, supports a
  disabled installation, has independently reviewed transport authentication,
  and restricts its result input to the closed v1 projection. Its absence is a
  stop condition; this packet does not design or implement it.
- [ ] Obtain the exact revision and digest of a separately reviewed
  scheduler/unit-enablement/arming mechanism. Verify that its artifact is
  available but not installed before owner approval, supports a disabled
  installation, binds only the recorded release and coverage, exposes
  mechanical readbacks, and cannot bypass the Brokkr control plane. Its absence
  is a stop condition; the current installer and source do not provide live
  scheduling, unit enablement, or arming.
- [ ] Verify Heimdall #16 is merged and deployed as a read-only consumer, then
  check fresh, unknown, stale, unreconciled, and mismatch rendering against the
  shared fixture corpus. This is a live dependency and cannot be inferred from
  Brokkr source alone.

## #69 owner-ceremony gate

Proceed only after the offline gate and private records prove target eligibility
and trust-root binding. Owner explicit approval must precede any live
installation. That approval authorizes the exact ceremony transitions through
disabled installation, authenticated delivery configuration/enablement,
scheduler/unit enablement, and arming. It binds the one canary, coverage,
authority, release, and mechanism revisions—not a future attempt or its
dynamically derived facts.

- [ ] The owner records explicit approve for the exact ceremony record before
  any live installation, configuration, enablement, authority-input creation,
  or arming. A hold or abort leaves every reviewed artifact uninstalled.
- [ ] After approval, install only the exact clean revision-bound release,
  reviewed scheduler/unit-enablement/arming artifact, and Brokkr #81 delivery
  artifact. Leave every installed unit and adapter disabled.
- [ ] Read back the installed revisions, content digests, immutable release
  bytes, root-owned private state protection, reserves, configuration bindings,
  disabled states, and unit identities before any enablement.
- [ ] Bind the private authority inputs to the exact release and all recorded
  public digests. Confirm distinct owner, controller, watchdog, kill-switch,
  and recovery-worker identities without exposing them here.
- [ ] Configure and enable the exact authenticated delivery adapter under the
  ceremony. Prove authenticated readiness and Heimdall readback capability
  while Heimdall remains read-only with no lifecycle authority.
- [ ] Through the reviewed mechanism, configure the exact schedule and enable
  only the bound units after delivery is configured, enabled, and
  readback-ready. Keep the canary unarmed and verify unit/schedule readbacks.
- [ ] Arm one canary last, only under the recorded owner approval and after all
  earlier readbacks pass. Confirm that only the Brokkr control plane can arm or
  disarm and that Heimdall cannot mutate lifecycle state.
- [ ] Before any scheduled window, verify the current target eligibility,
  maintenance-safe state, bounded plan, clock, and protected postconditions.
- [ ] After the one owner arming ceremony, each eligible bound scheduled window
  requires no per-run human approval. A mismatch or negative outcome remains a
  stop-and-disarm condition, never a silent re-authorization.
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
