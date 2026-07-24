#!/usr/bin/env bash
# Hermetic acceptance tests for the read-only relocation planner (brokkr#9).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PLANNER="$ROOT/scripts/relocation-planner.mjs"
LIB="$ROOT/scripts/lib/node-substrate-contract.mjs"
SCHEMA="$ROOT/docs/node-substrate-contract-v1.schema.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "relocation-planner.test.sh: FAIL: $1" >&2; exit 1; }

# Build public-safe input records. The inventory digest is recomputed with the
# exact #7 helper, so the planner must reject any later tampering.
node - "$ROOT" "$TMP" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const [root, tmp] = process.argv.slice(2);
const inventory = JSON.parse(fs.readFileSync(`${root}/tests/fixtures/node-inventory/fixture-m5.json`, "utf8"));
const canonical = (v) => Array.isArray(v) ? `[${v.map(canonical).join(",")}]` : v && typeof v === "object" ? `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}` : JSON.stringify(v);
const digest = (v) => `sha256:${crypto.createHash("sha256").update(canonical(v)).digest("hex")}`;
inventory.extensions = inventory.extensions.filter((entry) => entry.id !== "workload-fixture-hugin");
inventory.extensions.push({ id: "workload-fixture-hugin", version: "v1", decision_effect: "informational" });
delete inventory.evidence.digest;
inventory.evidence.digest = digest(inventory);
const records = JSON.parse(fs.readFileSync(`${root}/tests/fixtures/node-substrate-contract/positive.json`, "utf8")).records;
const workload = records.find((record) => record.kind === "workload-requirement");
const intent = records.find((record) => record.kind === "placement-intent");
const profile = JSON.parse(fs.readFileSync(`${root}/profiles/location-network-storage.example.json`, "utf8"));
const profileBytes = JSON.stringify(profile);
const profileDigest = `sha256:${crypto.createHash("sha256").update(profileBytes).digest("hex")}`;
const evidence = {
  kind: "brokkr-location-preflight-evidence", schema_version: "v1", location: "house-2", node_id: inventory.node_id,
  observation_evidence_id: inventory.evidence.evidence_id, observed_at: "2026-07-23T10:00:00Z", valid_until: "2026-07-23T11:00:00Z",
  profile_digest: profileDigest, outcome: "verified", network_capabilities: ["wired", "wifi", "tailnet"],
  storage: [{ logical_storage_id: "backup-primary", class: "local_ssd", status: "known", writable: true, capacity: "sufficient", transfer_window: "sufficient" }]
};
evidence.digest = digest(evidence);
const detail = { kind: "brokkr-node-inventory-detail", schema_version: "v1", observation_evidence_id: inventory.evidence.evidence_id,
  unit_state: { status: "known", units: [{ name: "hugin.service", installed_state: "loaded", active_state: "running", sub_state: "running" }] },
  workloads: ["fixture-hugin"], backup_roles: ["producer"] };
for (const [name, value] of Object.entries({ inventory, workload, intent, evidence, detail })) fs.writeFileSync(`${tmp}/${name}.json`, JSON.stringify(value));
fs.writeFileSync(`${tmp}/profile.json`, profileBytes);
NODE

run_plan() {
  node "$PLANNER" --json --now 2026-07-23T10:05:00Z \
    --intent "$TMP/intent.json" --workload "$TMP/workload.json" --inventory "$TMP/inventory.json" \
    --detail "$TMP/detail.json" --location-profile "$TMP/profile.json" --location-evidence "$TMP/evidence.json"
}

# Red first: before the planner exists, the command must fail instead of
# accidentally accepting an unimplemented path.
if [ ! -f "$PLANNER" ]; then
  if run_plan >"$TMP/red.out" 2>"$TMP/red.err"; then fail "missing planner unexpectedly succeeded"; fi
  grep -q 'MODULE_NOT_FOUND' "$TMP/red.err" || fail "missing planner did not fail clearly"
  echo "relocation-planner.test.sh: red case passed"
  exit 1
fi

run_plan >"$TMP/plan.json"
node - "$TMP/plan.json" "$SCHEMA" "$LIB" <<'NODE'
import fs from "node:fs";
const { schemaErrors } = await import(process.argv[4]);
const plan = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const schema = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
if (plan.kind !== "brokkr-relocation-plan" || plan.schema_version !== "v1") throw new Error("unversioned plan");
if (plan.outcome !== "promoted" || plan.blockers.length) throw new Error("golden plan was unexpectedly blocked");
if (schemaErrors(schema, plan.lifecycle_result).length) throw new Error("lifecycle result violates pinned schema");
for (const key of ["workloads", "backup_roles", "mounts", "network_tunnel_dependencies", "health", "hooks", "interruption", "rollback"]) {
  if (!(key in plan)) throw new Error(`plan omitted ${key}`);
}
NODE

# Stale, tampered, and semantic gaps fail closed in a deterministic blocked
# result whose human rendering names the owning repository.
node - "$TMP/evidence.json" <<'NODE'
const fs = require("fs"), crypto = require("crypto"); const v = JSON.parse(fs.readFileSync(process.argv[2])); const c = x => Array.isArray(x) ? `[${x.map(c).join(",")}]` : x && typeof x === "object" ? `{${Object.keys(x).sort().map(k => `${JSON.stringify(k)}:${c(x[k])}`).join(",")}}` : JSON.stringify(x); v.valid_until = "2026-07-23T10:00:00Z"; delete v.digest; v.digest = `sha256:${crypto.createHash("sha256").update(c(v)).digest("hex")}`; fs.writeFileSync(process.argv[2], JSON.stringify(v));
NODE
if run_plan >"$TMP/stale.json"; then fail "stale evidence unexpectedly passed"; fi
node - "$TMP/stale.json" <<'NODE'
const v = JSON.parse(require("fs").readFileSync(process.argv[2]));
if (v.outcome !== "blocked" || !v.blockers.some(b => b.code === "stale-location-evidence" && b.owner_repo === "brokkr")) throw new Error("stale evidence accepted");
NODE

node - "$TMP/evidence.json" <<'NODE'
const fs = require("fs"), crypto = require("crypto"); const v = JSON.parse(fs.readFileSync(process.argv[2])); const c = x => Array.isArray(x) ? `[${x.map(c).join(",")}]` : x && typeof x === "object" ? `{${Object.keys(x).sort().map(k => `${JSON.stringify(k)}:${c(x[k])}`).join(",")}}` : JSON.stringify(x); v.valid_until = "2026-07-23T11:00:00Z"; v.storage[0].writable = false; delete v.digest; v.digest = `sha256:${crypto.createHash("sha256").update(c(v)).digest("hex")}`; fs.writeFileSync(process.argv[2], JSON.stringify(v));
NODE
if run_plan >"$TMP/gap.json"; then fail "storage gap unexpectedly passed"; fi
node - "$TMP/gap.json" <<'NODE'
const v = JSON.parse(require("fs").readFileSync(process.argv[2]));
if (v.outcome !== "blocked" || !v.blockers.some(b => b.code === "storage-not-writable" && b.owner_repo === "brokkr")) throw new Error("storage gap accepted");
NODE

node - "$TMP/evidence.json" <<'NODE'
const fs = require("fs"); const v = JSON.parse(fs.readFileSync(process.argv[2])); v.storage[0].capacity = "insufficient"; fs.writeFileSync(process.argv[2], JSON.stringify(v));
NODE
if run_plan >"$TMP/location-tampered.out" 2>"$TMP/location-tampered.err"; then fail "tampered location evidence was accepted"; fi
grep -q 'location evidence digest' "$TMP/location-tampered.err" || fail "location tampering was not named"

node - "$TMP/inventory.json" <<'NODE'
const fs = require("fs"); const v = JSON.parse(fs.readFileSync(process.argv[2])); v.resources.memory_mib = 1; fs.writeFileSync(process.argv[2], JSON.stringify(v));
NODE
if run_plan >"$TMP/tampered.out" 2>"$TMP/tampered.err"; then fail "tampered inventory was accepted"; fi
grep -q 'inventory evidence digest' "$TMP/tampered.err" || fail "tampering was not named"

# NAS -> house-2 is a distinct public-safe fixture. It exercises a different
# target, external storage, workload, hooks and wired-only location profile.
node - "$ROOT" "$TMP" <<'NODE'
const fs = require("fs"), crypto = require("crypto"); const [root, tmp] = process.argv.slice(2);
const inventory = JSON.parse(fs.readFileSync(`${root}/tests/fixtures/node-inventory/fixture-nas.json`));
const profile = JSON.parse(fs.readFileSync(`${root}/profiles/location-network-storage.example.json`));
profile.locations["house-2"].network.wifi.required = false;
const profileBytes = JSON.stringify(profile); const profileDigest = `sha256:${crypto.createHash("sha256").update(profileBytes).digest("hex")}`;
const workload = { kind: "workload-requirement", schema_version: "v1", workload_id: "mimir", supported_architectures: ["arm64"], persistent_data: "required", ports: [8080], units: ["mimir.service"], timers: ["backup-offsite.timer"], secrets_boundary: "owner_overlay", dependencies: [], backup_restore: "required", health: "external_probe", hooks: [
  { name: "preflight", mode: "read_only", contract_versions: ["v1"], deadline_seconds: 60, idempotency_required: true },
  { name: "drain", mode: "mutating", contract_versions: ["v1"], deadline_seconds: 60, idempotency_required: true, compensation_hook: "rollback" },
  { name: "verify", mode: "read_only", contract_versions: ["v1"], deadline_seconds: 60, idempotency_required: true },
  { name: "rollback", mode: "mutating", contract_versions: ["v1"], deadline_seconds: 60, idempotency_required: true }], extensions: [] };
const intent = { kind: "placement-intent", schema_version: "v1", placement_id: "place-mimir-nas", workload_id: "mimir", target_node_id: inventory.node_id, desired_revision: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", created_at: "2026-07-23T10:01:00Z", planned_drift: ["placement"], extensions: [] };
const detail = { kind: "brokkr-node-inventory-detail", schema_version: "v1", observation_evidence_id: inventory.evidence.evidence_id, unit_state: { status: "known", units: [{ name: "mimir.service", installed_state: "enabled", active_state: "active", sub_state: "running" }, { name: "backup-offsite.timer", installed_state: "enabled", active_state: "active", sub_state: "waiting" }] }, workloads: ["mimir"], backup_roles: ["producer", "consumer"] };
const evidence = { kind: "brokkr-location-preflight-evidence", schema_version: "v1", location: "house-2", node_id: inventory.node_id, observation_evidence_id: inventory.evidence.evidence_id, observed_at: "2026-07-23T10:00:00Z", valid_until: "2026-07-23T11:00:00Z", profile_digest: profileDigest, outcome: "verified", network_capabilities: ["wired", "tailnet"], storage: [{ logical_storage_id: "backup-primary", class: "external_ssd", status: "known", writable: true, capacity: "sufficient", transfer_window: "sufficient" }] }; const canonical = v => Array.isArray(v) ? `[${v.map(canonical).join(",")}]` : v && typeof v === "object" ? `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}` : JSON.stringify(v); evidence.digest = `sha256:${crypto.createHash("sha256").update(canonical(evidence)).digest("hex")}`;
for (const [name, value] of Object.entries({ inventory, workload, intent, detail, evidence })) fs.writeFileSync(`${tmp}/nas-${name}.json`, JSON.stringify(value)); fs.writeFileSync(`${tmp}/nas-profile.json`, profileBytes);
NODE
node "$PLANNER" --json --now 2026-07-23T10:05:00Z --intent "$TMP/nas-intent.json" --workload "$TMP/nas-workload.json" --inventory "$TMP/nas-inventory.json" --detail "$TMP/nas-detail.json" --location-profile "$TMP/nas-profile.json" --location-evidence "$TMP/nas-evidence.json" >"$TMP/nas-plan.json"
node - "$TMP/nas-plan.json" <<'NODE'
const v = JSON.parse(require("fs").readFileSync(process.argv[2]));
if (v.outcome !== "promoted" || v.workloads[0].workload_id !== "mimir" || v.mounts[0].class !== "external_ssd") throw new Error("NAS -> house-2 fixture did not plan");
NODE

echo "relocation-planner.test.sh: PASS"
