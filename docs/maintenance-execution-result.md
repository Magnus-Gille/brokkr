# Maintenance execution result v1 (brokkr#78)

`maintenance-execution-result/v1` is Brokkr's closed, metadata-only read model
for the authoritative ADR-008 v2 maintenance journal and its terminal receipt.
Its schema is [maintenance-execution-result-v1.schema.json](maintenance-execution-result-v1.schema.json).
It is deliberately not a plan, a policy, a command envelope, or a lifecycle
authority. The journal, terminal receipt, and their existing ADR-008 validators
remain authoritative.

`projectMaintenanceExecutionResult()` accepts only a v2 journal tail, a
self-digested receipt bound to that exact journal ID, binding digest and tail
digest, source revision and configuration digests, freshness evidence, epoch,
and aggregate probe coverage. The caller must provide an explicit trusted
evaluation instant; omission fails closed. Before projecting, it revalidates
the complete closed v2 shape, maintenance-domain binding, every identity,
authority-reference, digest and timestamp field, R-forward recovery/canary
invariants, the append-only receipt chain, legal phase transitions, actors,
deadline and watch bounds measured from the durable, self-bound watch anchor,
quarantine/disarm narrowing, and exact source/configuration linkage. A watch
entry without its exact self-digested anchor fails closed. It does not read or
write files, invoke a process, contact a service, or mutate state.

This read model does not re-authorize a historical attempt. Owner signatures,
coverage and authority snapshots remain the responsibility of the
authoritative ADR-008 admission and journal path. The projector verifies the
closed evidence it receives and cannot elevate it into authority.
Its SHA-256 digests provide deterministic integrity and correlation, not sender
authentication. A future delivery adapter must preserve Brokkr's trusted
producer boundary and authenticate transport; a consumer must not accept an
arbitrary caller's recomputed self-digests as production evidence.

The result includes the journal tail instant, complete durable-watch anchor,
explicit `evaluated_at` instant, and a self-binding `result_digest`, so changing
source identity, freshness, receipt, reconciliation, coverage, watch evidence,
or derived state invalidates the result. A result is
`healthy` and `promotion_eligible` only when its terminal phase is `commit`,
receipt reconciliation is `reconciled`, evidence is fresh, the authoritative
one-hour watch bounds are satisfied, and a non-zero observed probe count
exactly covers the expected count. Zero or partial probe coverage is
`unknown`, never clean. `unknown`,
`stale`, `unreconciled`, `failed`, `recovered-by-worker`, `disarmed`, and
`terminally-blocked` are never healthy or promotion-eligible.

The optional command-line delivery boundary is intentionally inert:
`scripts/maintenance-execution-result-delivery.mjs --result FILE` validates a
result and prints a `delivery_disabled` acknowledgement. It has no transport,
installation, enablement, service, arming, disarming, recovery, retry, plan,
package, or host-mutation capability. Enabling delivery requires a future,
separately reviewed versioned adapter and explicit owner authorization.

## Redaction and retention

Only opaque IDs, SHA-256 digests, canonical UTC timestamps, aggregate probe
counts, and closed status enums may cross this seam. Commands, package names or
versions, logs, credentials, policy fields, paths, URLs, private locators, and
raw recovery material are prohibited. Brokkr owns source journal and receipt
retention. Consumers such as Heimdall own their copied result-retention policy
and must compare `valid_until` with their own trusted current clock. Once
expired, a previously clean result is stale regardless of its historical
`evaluated_at`; it must never render as currently healthy or promotable.
Consumers must treat the result as an expiring observation, not evidence to
retain indefinitely or authority to act.

## Evolution and authority boundary

Consumers negotiate the literal `v1` schema and reject unknown fields/enums.
Breaking changes require `v2`; compatible additions also require a new version
because v1 is closed. Brokkr alone projects producer facts from its authoritative
ADR-008 evidence. Heimdall may read, validate, alert on, or display this result;
it cannot infer omitted facts, alter lifecycle state, promote a target, or issue
maintenance/recovery commands from it.

The eight positive state fixtures and the mutation-based adversarial fixture
set under `tests/fixtures/maintenance-execution-result/` are the cross-repo
producer/consumer conformance corpus. JSON Schema validation establishes shape;
the semantic validator remains required for cross-field health, coverage, and
receipt-tail contradictions that ordinary JSON Schema cannot express.
