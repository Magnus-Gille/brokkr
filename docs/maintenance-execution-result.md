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
authentication. The delivery adapter preserves Brokkr's trusted producer
boundary with a dedicated Bearer credential and HTTPS; a consumer must not
accept an arbitrary caller's recomputed self-digests as production evidence.

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

## Authenticated delivery adapter

`scripts/maintenance-execution-result-delivery.mjs` accepts the exact result
bytes on standard input, re-runs the closed semantic validator, and accepts only
the `brokkr-maintenance` v1 source. It accepts no arguments. The endpoint,
dedicated Bearer token, enabled state, and exact adapter revision and SHA-256
digest come from the protected systemd credential named
`brokkr-maintenance-result-delivery-v1`. Under `DynamicUser=yes` plus
`LoadCredential=`, the credential directory and file may each be owned either
by uid `0` or by the adapter's effective uid, but never by any other owner.
The file must be a non-symlink regular file with mode `0400` or `0600`, and
its containing credential directory must be an absolute, non-symlink directory
that is not writable by group or other. The adapter never prints the endpoint,
token, credential directory, curl stderr, or Heimdall response body.

The closed configuration is version `v1`. A disabled configuration contains
only its kind, version, `enabled: false`, and the adapter revision/digest
binding. An enabled configuration adds the endpoint and token. The endpoint
must be canonical HTTPS with no userinfo, query, or fragment, and its path must
be exactly `/api/maintenance-execution-results`. The token has a bounded,
configuration-safe alphabet and length. Unknown fields, versions, alternate
paths, HTTP downgrade, missing bindings, and malformed or unsafe credentials
fail before transport. Live endpoint and credential values, and the private
backing-source locator, do not belong in git, a unit, argv, a receipt, or public
evidence.

Delivery uses curl with user configuration disabled, HTTPS-only protocol
selection, TLS 1.2 or newer, no redirects, a five-second connection timeout,
ten-second total attempt timeout, and a 64 KiB response limit. The body sent to
Heimdall is byte-identical to the locally validated input. Its
`result_digest` is also sent as the idempotency key. Only 2xx is accepted.
Transport failures and 5xx responses retry the same bytes at most three total
attempts using fixed 100 ms and 250 ms delays. Redirects, authentication
failures, malformed requests, epoch conflicts/replay rejection, and every
other non-2xx response fail immediately. Heimdall's monotonic
`execution_epoch` plus same-epoch `result_digest` rule makes repeating the
identical result idempotent; a conflicting or older epoch is never converted
into success.

The revision-bound installer is deliberately separate:

```sh
sudo scripts/install-maintenance-execution-result-delivery.sh install \
  --source /absolute/clean/worktree \
  --revision FULL_40_CHARACTER_SHA
```

It archives and blob-verifies only the named commit, installs it under an
immutable revision directory, and renders
`brokkr-maintenance-execution-result-delivery.service` with the exact revision
and adapter digest. The unit has no `[Install]` section, the installer never
calls systemd, and no credential or enabled gate is installed. The unit's
standard input is the fixed authoritative result projection at
`/var/lib/brokkr/debian-maintenance/evidence/maintenance-execution-result.json`;
no result or credential locator appears in its process arguments.

Before writing anything, the installer scans the complete Debian system-unit
load path in this exact precedence order:
`/etc/systemd/system.control`,
`/run/systemd/system.control`,
`/run/systemd/transient`,
`/run/systemd/generator.early`,
`/etc/systemd/system`,
`/etc/systemd/system.attached`,
`/run/systemd/system`,
`/run/systemd/system.attached`,
`/run/systemd/generator`,
`/usr/local/lib/systemd/system`,
`/usr/lib/systemd/system`,
`/run/systemd/generator.late`.
For tests, these roots are mapped beneath `BROKKR_DELIVERY_INSTALL_TEST_ROOT`.
Enumeration is strict and fail-closed: every mapped root is probed with
`lstat(2)`, only `ENOENT` is treated as absent, symlinks and non-directories
are rejected, other filesystem errors propagate, and existing roots are
canonicalized before recursive matching. A dangling mapped search-root symlink
is therefore an installation blocker, not a skipped root.

The effective-unit contract is exact and fail-closed. The canonical main unit
name `brokkr-maintenance-execution-result-delivery.service` is rejected in
every configured root except the intended `/etc/systemd/system` install path,
which remains governed separately by the exact mode, revision, and byte-match
checks for idempotent reinstallation. The installer also rejects any filesystem
object at every applicable top-level drop-in path anywhere in the load path:
the canonical `.service.d` directory, each dash-prefix truncation directory for
that canonical name, the type-wide `service.d`, and the exact/prefix drop-in
directories for aliases in the bounded reverse alias closure derived from
top-level unit symlinks in the configured roots.

It still scans dependency directories in every existing root, rejects symlinked
dependency directories, and follows individual dependency and top-level alias
link chains read-only with bounded depth and cycle detection even when a
terminal leaf is outside the static root set. Recursive enumeration itself
never leaves the configured search roots: external directories are never
recursively scanned, and unexpected filesystem errors other than a missing
terminal parent or leaf fail closed. Dependency targets are matched against the
normalized and available canonical adapter paths for every configured search
root. Dependency entry basenames are also matched against the canonical adapter
unit name and a bounded reverse alias closure derived from top-level unit
symlinks in the configured search roots. A dependency entry is therefore
rejected if its filename is the canonical adapter name or any alias resolving
to it, even when the symlink target itself points somewhere else. This
alias-basename rule is separate from the target-chain checks, so unrelated
external terminals or normal masks do not block installation.

Installation therefore remains inert. The separately authorized #69 owner
ceremony must bind and provision the exact protected credential, atomically
publish the already validated result at that fixed evidence path, and
explicitly start this exact revision-bound unit. Neither the installer nor the
adapter can enable a timer, arm/disarm maintenance, select a target, change
policy, dispatch an operation, mutate packages, recover a host, or grant
Heimdall lifecycle authority.

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
