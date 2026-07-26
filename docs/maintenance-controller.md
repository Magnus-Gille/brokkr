# Fail-closed maintenance controller (brokkr#34)

`scripts/maintenance-controller.mjs` turns a pinned Grimnir maintenance-policy v1 record into a deterministic, inspectable **admission decision**. Its CLI is inspection-only; it cannot execute a package manager. A separately reviewed host adapter may call `runController()` with one explicit executor.

The controller writes only an adapter-supplied bounded state directory. `state.json` uses an fsynced same-directory temporary file plus atomic rename; a brief `state.lock` serializes read-modify-write merges across nodes, while `locks/<node>.lock` uses exclusive create for admission. Neither is held during an executor. `hold.json` is a durable kill switch checked during inspection and immediately before execution. An executor is marked `in_flight` durably before it starts. A crash leaves that marker intact, so a restart refuses to run it again until an operator resolves the record—no unsafe timeout lease can guess whether a package manager died.

Closed, unknown, DST-invalid, held, lock-contended, backoff, terminal retry, duplicate completed occurrence, in-flight, and unsynchronized-clock states cannot authorize mutation. Retry state records bounded attempts, backoff, next eligibility and terminal exhaustion. IANA timezone and DST rules use the same pinned contract helper as the read-only planner, and each admission verifies the policy digest. `orderTargets()` produces deterministic dependency-first order; host adapters must serialize members of a redundancy group.

This is a controller seam, not a production package-management deployment. A live adapter still needs an owner-reviewed executor, fresh clock evidence, workload drain/verify hooks, and an explicit in-flight recovery procedure.

If an executor returns or fails but its terminal state cannot be persisted because
the short state lock is contended, the controller returns
`finalization_failed_operator_recovery`. It never falsely reports `succeeded` or
`retry_pending`; the durable `in_flight` marker remains and blocks another run.
