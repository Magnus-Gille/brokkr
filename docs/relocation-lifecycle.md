# Bounded relocation lifecycle

`make relocation-apply` executes a previously promoted, immutable relocation
plan. It is deliberately separate from `relocation-plan`: it discovers no
topology, accepts no shell fragments, and performs no implicit deployment.

The executor consumes a closed operation record that explicitly allowlists the
six attributed hooks (`preflight`, `drain`, `apply`, `verify`,
`representative_data`, `rollback`). Each command must be an executable regular
file, has a 1–300 second timeout, and must emit its declared required output.
Every operation hook must declare `idempotency_required: true`; the executor
passes the fixed `BROKKR_LIFECYCLE_IDEMPOTENCY_KEY`,
`BROKKR_RELOCATION_OPERATION_ID`, and `BROKKR_RELOCATION_HOOK` environment
variables on every attempt. Hooks must use that tuple to make retry effects
idempotent.
The operation is reversible only (`irreversible.allowed: false`) and supplies a
human-readable reversal recipe. The JSON journal is atomically replaced after
every transition and retains the old placement until promotion.

A required physical move stops at `awaiting_operator`; resumption requires both
`--resume` and `--operator-confirm physical-move`. Any failed, timed-out, or
silent hook invokes the explicit rollback hook. A lost process can resume the
same plan/operation digest only; a different input fails closed. A rollback
that exits with the sole retryable status (75) remains an interrupted rollback
and may be resumed idempotently with the same operation; successful rollback is
then a terminal blocked result.

Promotion occurs only after target verification and the representative-data
hook. Each journal event retains optional `brokkr-platform-fault/v1` references
from the operation and emits the exact Heimdall monitoring-agent v1 envelope:
required `lifecycle-result` and `node-capability-freshness` evidence. Heimdall
therefore observes the event but never gains topology or workload authority.
The public test fixtures use synthetic NAS/Hugin identities;
production commands, addresses, and overlays stay private.
