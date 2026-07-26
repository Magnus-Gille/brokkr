#!/usr/bin/env node
// Read-only platform-fault projection. It deliberately references the Grimnir
// node/substrate observation instead of re-stating node capability facts.
import fs from "node:fs";
const die = (m) => { process.stderr.write(`platform-fault-detector: ${m}\n`); process.exit(1); };
const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== "--input") die("usage: platform-fault-detector.mjs --input observation.json");
let input; try { input = JSON.parse(fs.readFileSync(args[1], "utf8")); } catch { die("input must be JSON"); }
const utc = (v) => typeof v === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(v) && !Number.isNaN(Date.parse(v));
if (!input || input.kind !== "brokkr-platform-observation" || input.schema_version !== "v1") die("unsupported observation");
if (!utc(input.observed_at) || !utc(input.valid_until) || Date.parse(input.valid_until) <= Date.parse(input.observed_at)) die("invalid freshness");
const now = input.now ?? new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
if (!utc(now) || Date.parse(now) > Date.parse(input.valid_until)) die("observation is stale");
const ref = input.node_substrate_ref;
const nodeId = /^[a-z][a-z0-9-]{2,57}$/;
if (!ref || ref.contract !== "grimnir.node-substrate/v1" || !nodeId.test(ref.node_id) || typeof ref.observation_evidence_id !== "string") die("missing or unsafe node/substrate v1 reference");
if (!Array.isArray(input.signals)) die("signals must be an array");
const rules = {
  filesystem_read_only: ["filesystem-read-only", "critical", "brokkr"],
  clock_unsynchronised: ["clock-unsynchronised", "warning", "node-agent"],
  boot_identity_changed: ["boot-identity-changed", "warning", "operator"],
};
const faults = input.signals.filter(s => s && rules[s.name] && s.state === "fault").map((s, n) => {
  const [category, severity, owner] = rules[s.name];
  if (typeof s.provenance !== "string" || !s.provenance) die(`signal ${s.name} lacks provenance`);
  return { kind: "brokkr-platform-fault", schema_version: "v1", fault_id: `fault-${ref.node_id}-${n + 1}`,
    category, severity, node_substrate_ref: ref,
    evidence: { provenance: s.provenance, assertion: typeof s.assertion === "string" ? s.assertion : s.name },
    freshness: { observed_at: input.observed_at, valid_until: input.valid_until },
    recovery_owner: owner };
});
process.stdout.write(JSON.stringify({ kind: "brokkr-platform-fault-batch", schema_version: "v1", faults }, null, 2) + "\n");
