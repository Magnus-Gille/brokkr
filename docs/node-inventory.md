# Read-only node inventory (brokkr#7)

Run `make node-inventory`. Standard output is exactly one Grimnir v1
`node-capability` record, validated by the producer itself against the pinned
normative schema (`docs/node-substrate-contract-v1.schema.json`) with the
dependency-free validator in `scripts/lib/node-substrate-contract.mjs` before it
is emitted. Standard error is the concise operator view, including observed unit
names; treat that view as private runtime evidence.

## Inputs (validated strictly before any collection)

- `BROKKR_NODE_ID`: `^[a-z][a-z0-9-]{2,57}$` (defaults to the lowercased short
  hostname; the cap keeps the derived `obs-<node_id>` evidence id inside the
  contract id pattern).
- `BROKKR_INVENTORY_NOW`: optional exact UTC instant `YYYY-MM-DDTHH:MM:SSZ` on a
  real calendar date (defaults to the current time).
- `BROKKR_INVENTORY_TTL_SECONDS`: integer in `[60, 86400]` (default `3600`);
  `valid_until` is exactly `observed_at + TTL`.
- `BROKKR_INVENTORY_OVERLAY`: optional owner-only overlay file (below).

Malformed input fails with a clear message on stderr and emits no JSON.

## Probes

All probes are read-only, bounded (5 s timeout, 1 MiB output cap), and
distinguish "not installed" from "installed but broken":

- Network paths come only from links that are administratively `UP` with
  carrier (`LOWER_UP`) in `ip -o link show`; down or carrier-less links never
  become capabilities. `tailnet` requires valid `tailscale status --json` output
  with `BackendState == "Running"`; a stopped or absent tailscale is an
  observation of no tailnet, while malformed output is a probe failure.
- Storage classes are never guessed from `df`. The owner overlay declares
  logical stores (class + mount); `df -Pm` only confirms the mount and measures
  available MiB. A declared but unmounted store is reported with
  `status: unknown`, and without an overlay the record carries a single explicit
  `unknown` storage entry.
- A failed probe forces `capability_status: unknown` (the only decision-driving
  signal) and is named in the machine record itself as a closed, versioned,
  `informational` extension (`probe-failed-<name>`). Facts from probes that did
  succeed are preserved; schema-required floors (`cpu_cores`/`memory_mib` = 1)
  stand in only next to their matching `probe-failed-*` marker. Omission never
  satisfies a requirement.

## Owner overlay

Operator-declared facts that cannot be probed read-only (uptime class,
deployment mechanisms, health reporting, logical storage classes, hosted
workloads, backup producer/consumer roles) come from an untracked JSON overlay:
a regular, non-symlink, current-user-owned file with no group/other permissions
and a closed key set (`uptime_class`, `deployment_mechanisms`,
`health_reporting`, `logical_storage`, `workloads`, `backup_roles`). Workloads
and backup roles are emitted as informational extensions
(`workload-<id>`, `backup-role-<role>`); they record observation, not desired
topology. Anything not declared is reported as `unknown`, never invented.

## Evidence digest

`evidence.digest` is `sha256:` over the canonical JSON form (recursively
key-sorted, no insignificant whitespace) of the whole record with only the
`evidence.digest` field itself excluded. Tests recompute it from emitted records
and from the committed fixtures.

## Fixtures

`tests/fixtures/node-inventory/fixture-{nas,m5}.json` are golden producer
records generated from fully mocked probes and public-safe overlays (reserved
names, no private locators): the NAS fixture covers Mimir/tunnel/agent units, a
T7-class external SSD, both backup roles, and active wired+tailnet paths; the M5
fixture covers launchd, the `sysctl` memory fallback, and wired+wifi+tailnet.
The hermetic suite (`scripts/test/node-inventory.test.sh`) also re-verifies the
pinned upstream schema/fixture SHA-256 provenance on every run.

This is the Brokkr observation producer side of the versioned node-agent
boundary in #2. It intentionally does not add an ownership or upgrade protocol:
that work remains with #2, while the cross-system schema remains pinned to
Grimnir and its decision-driving v1 semantics are consumed unchanged.
