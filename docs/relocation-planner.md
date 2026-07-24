# Read-only relocation planner

`make relocation-plan ARGS="..."` performs a deterministic preflight only. It
does not contact a host, invoke a workload hook, mount storage, copy data, or
make a deployment decision. A non-zero result means the plan is blocked.

The planner receives explicit files rather than discovering topology:

```sh
make relocation-plan ARGS="--json --now 2026-07-23T10:05:00Z \
  --intent /safe/intent.json --workload /safe/workload.json \
  --requirements /safe/relocation-requirements.json \
  --inventory /safe/node-capability.json --detail /safe/inventory-detail.json \
  --detail-public-key /safe/detail-public.pem \
  --location-profile profiles/location-network-storage.example.json \
  --location-evidence /safe/location-preflight-evidence.json"
```

`intent` and `workload` are Grimnir `placement-intent` and
`workload-requirement` v1 records; `inventory` is the unchanged Brokkr #7
`node-capability` record. The runtime verifies the exact vendored Grimnir
schema, fixture manifest, and provenance pins before it parses them. It also
recomputes #7 inventory evidence digests and requires the #7 detail record to
bind to that observation ID and digest, carry matching timestamps and a
canonical digest, and verify under the explicit Ed25519 public key. Stale,
unsigned, or state-enum-incompatible detail fails closed.

`requirements` is a closed, digest-bound
`brokkr-relocation-requirements/v1` planning input. It supplies the facts absent
from the unchanged shared v1 contract: owner repository, actual CPU/RAM minima,
required units/timers, exact dependencies, producer/consumer actor plus logical
storage references, and forbidden cohosts. It must cover the requested
workload and every workload already hosted on the target. Dependency evidence
is individually digest-bound and timestamped. The planner sums all target
workload minima and permits a genuine move to a clean target; the requested
workload's units need not already be installed.

The public profile is validated by the #8 preflight's profile-only validation
mode, rather than by a second schema interpreter. `location-evidence` is a
public-safe, closed v1 attestation created after that preflight. It contains no
paths, addresses, SSIDs, or credentials:

```json
{
  "kind": "brokkr-location-preflight-evidence",
  "schema_version": "v1",
  "location": "house-2",
  "node_id": "fixture-m5",
  "observation_evidence_id": "obs-example",
  "observed_at": "2026-07-23T10:00:00Z",
  "valid_until": "2026-07-23T11:00:00Z",
  "profile_digest": "sha256:<profile-bytes>",
  "outcome": "verified",
  "network_capabilities": ["wired", "tailnet"],
  "storage": [{"logical_storage_id": "backup-primary", "class": "local_ssd", "status": "known", "writable": true, "capacity": "sufficient", "transfer_window": "sufficient"}],
  "backup_roles": [
    {"role": "producer", "actor": "fixture-hugin", "logical_storage_id": "backup-primary", "status": "verified"},
    {"role": "consumer", "actor": "fixture-backup", "logical_storage_id": "backup-primary", "status": "verified"}
  ],
  "digest": "sha256:<canonical-record-without-digest>"
}
```

The planner rejects stale, malformed, digest-mismatched, missing, unknown, or
incompatible evidence. It also blocks CPU/RAM, cohost, dependency, exact backup
role/storage-reference, capacity, writeability, transfer-window,
network/tunnel, hosted-unit, health, hook, and rollback gaps. JSON output is a
versioned `brokkr-relocation-plan` envelope containing a validated pinned v1
`lifecycle_result`; its plan lists all current and planned workloads, resource
totals, dependencies, backup roles, logical mounts, network/tunnel
dependencies, health, hooks, interruption, rollback, and blockers. Every
blocker includes its owning repository. Even missing or malformed inputs emit
this blocked JSON lifecycle when `--json` is requested.

The output is planning evidence only. A later owner-controlled lifecycle must
invoke hooks and execute any mutation; this planner never does.
