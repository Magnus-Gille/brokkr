#!/usr/bin/env node
// Deterministic, read-only relocation/workload preflight planner (brokkr#9).
// It consumes the pinned Grimnir v1 records unchanged; it never invokes hooks,
// probes a host, or reads an owner overlay.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import {
  assertPinnedContractFiles, canonicalJson, checkSchema, evidenceDigest,
  schemaErrors, strictUtc,
} from "./lib/node-substrate-contract.mjs";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const CONTRACT = path.join(ROOT, "docs/node-substrate-contract-v1.schema.json");
const MANIFEST = path.join(ROOT, "tests/fixtures/node-substrate-contract/consumer-fixture-set.json");
const PROVENANCE = path.join(ROOT, "docs/node-substrate-contract-provenance.md");
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const DIGEST = /^sha256:[a-f0-9]{64}$/;

const usage = () => `Usage: node scripts/relocation-planner.mjs --intent FILE --workload FILE --inventory FILE --detail FILE --location-profile FILE --location-evidence FILE --now UTC [--json]`;
const die = (message) => { process.stderr.write(`FAIL: ${message}\n`); process.exit(2); };
const plain = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const hash = (value) => `sha256:${crypto.createHash("sha256").update(typeof value === "string" || Buffer.isBuffer(value) ? value : canonicalJson(value)).digest("hex")}`;
const exactKeys = (value, keys) => plain(value) && canonicalJson(Object.keys(value).sort()) === canonicalJson([...keys].sort());
const safeRead = (file, label) => {
  let stat;
  try { stat = fs.lstatSync(file); } catch { die(`${label} is unavailable`); }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1_000_000) die(`${label} must be a regular bounded file`);
  try { return { value: JSON.parse(fs.readFileSync(file, "utf8")), bytes: fs.readFileSync(file) }; }
  catch { die(`${label} is not valid JSON`); }
};
const parseArgs = () => {
  const args = process.argv.slice(2); const result = { json: false };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--json") { result.json = true; continue; }
    if (!arg.startsWith("--") || i + 1 === args.length) die(usage());
    const key = arg.slice(2).replaceAll("-", "_");
    if (result[key] !== undefined) die(`duplicate argument ${arg}`);
    result[key] = args[++i];
  }
  for (const key of ["intent", "workload", "inventory", "detail", "location_profile", "location_evidence", "now"]) {
    if (typeof result[key] !== "string") die(usage());
  }
  if (!strictUtc(result.now)) die("now must be a strict UTC instant");
  return result;
};

const validateLocationProfile = (profile) => {
  // The #8 runtime is the sole profile-schema interpreter. Calling its
  // profile-only mode avoids copying or weakening its Draft 2020-12 rules.
  const check = spawnSync("python3", [path.join(ROOT, "profiles/preflight.py"), "--validate-profile", "--profile", profile], { encoding: "utf8" });
  if (check.status !== 0 || check.stdout.trim() !== "OK: location profile schema validated") die("location profile is not validated by Brokkr preflight");
};

const validateDetail = (detail, evidenceId) => {
  const keys = ["backup_roles", "kind", "observation_evidence_id", "schema_version", "unit_state", "workloads"];
  if (!exactKeys(detail, keys) || detail.kind !== "brokkr-node-inventory-detail" || detail.schema_version !== "v1" || detail.observation_evidence_id !== evidenceId) die("inventory detail is incompatible with inventory evidence");
  if (!plain(detail.unit_state) || !exactKeys(detail.unit_state, ["status", "units"]) || detail.unit_state.status !== "known" || !Array.isArray(detail.unit_state.units)) die("inventory detail has unknown unit evidence");
  if (!Array.isArray(detail.workloads) || !Array.isArray(detail.backup_roles) || !detail.workloads.every((id) => typeof id === "string" && ID.test(id)) || !detail.backup_roles.every((role) => role === "producer" || role === "consumer")) die("inventory detail is invalid");
  for (const unit of detail.unit_state.units) {
    if (!exactKeys(unit, ["active_state", "installed_state", "name", "sub_state"]) || typeof unit.name !== "string") die("inventory detail unit evidence is invalid");
  }
};

const validateLocationEvidence = (evidence, inventory, profileBytes) => {
  const keys = ["kind", "schema_version", "location", "node_id", "observation_evidence_id", "observed_at", "valid_until", "profile_digest", "outcome", "network_capabilities", "storage", "digest"];
  if (!exactKeys(evidence, keys) || evidence.kind !== "brokkr-location-preflight-evidence" || evidence.schema_version !== "v1") die("location evidence is invalid");
  if (!ID.test(evidence.location) || evidence.node_id !== inventory.node_id || evidence.observation_evidence_id !== inventory.evidence.evidence_id) die("location evidence is incompatible with inventory");
  const material = structuredClone(evidence); delete material.digest;
  if (!strictUtc(evidence.observed_at) || !strictUtc(evidence.valid_until) || evidence.observed_at > evidence.valid_until || evidence.profile_digest !== hash(profileBytes) || evidence.outcome !== "verified" || !DIGEST.test(evidence.digest) || evidence.digest !== hash(material)) die("location evidence digest does not verify");
  if (!Array.isArray(evidence.network_capabilities) || !evidence.network_capabilities.every((kind) => ["wired", "wifi", "tailnet"].includes(kind))) die("location network evidence is invalid");
  if (!Array.isArray(evidence.storage) || !evidence.storage.length) die("location storage evidence is missing");
  for (const store of evidence.storage) {
    if (!exactKeys(store, ["logical_storage_id", "class", "status", "writable", "capacity", "transfer_window"]) || !ID.test(store.logical_storage_id) || !["local_ssd", "external_ssd", "network_share"].includes(store.class) || !["known", "unknown"].includes(store.status) || typeof store.writable !== "boolean" || !["sufficient", "insufficient", "unknown"].includes(store.capacity) || !["sufficient", "insufficient", "unknown"].includes(store.transfer_window)) die("location storage evidence is invalid");
  }
};

const blocker = (code, owner_repo, message) => ({ code, owner_repo, message });
const sorted = (items) => [...items].sort((a, b) => canonicalJson(a).localeCompare(canonicalJson(b)));
const idFrom = (prefix, material) => `${prefix}-${crypto.createHash("sha256").update(canonicalJson(material)).digest("hex").slice(0, 52)}`;
const add = (blockers, condition, code, owner, message) => { if (condition) blockers.push(blocker(code, owner, message)); };

const main = () => {
  const args = parseArgs();
  assertPinnedContractFiles({ schemaPath: CONTRACT, manifestPath: MANIFEST, provenancePath: PROVENANCE });
  const schema = safeRead(CONTRACT, "pinned contract schema").value; checkSchema(schema);
  const intent = safeRead(args.intent, "placement intent").value;
  const workload = safeRead(args.workload, "workload requirement").value;
  const inventoryFile = safeRead(args.inventory, "node inventory"); const inventory = inventoryFile.value;
  const detail = safeRead(args.detail, "inventory detail").value;
  const profileFile = safeRead(args.location_profile, "location profile");
  const locationEvidence = safeRead(args.location_evidence, "location evidence").value;
  for (const [label, record] of [["placement intent", intent], ["workload requirement", workload], ["node inventory", inventory]]) {
    if (schemaErrors(schema, record).length) die(`${label} violates the pinned Grimnir v1 schema`);
  }
  // Reuse the exact #7 canonical evidence algorithm, not a planner variant.
  if (inventory.evidence.digest !== `sha256:${evidenceDigest(inventory)}`) die("inventory evidence digest does not verify");
  validateDetail(detail, inventory.evidence.evidence_id);
  validateLocationProfile(args.location_profile);
  validateLocationEvidence(locationEvidence, inventory, profileFile.bytes);

  const profile = profileFile.value;
  const location = profile.locations?.[locationEvidence.location];
  if (!location) die("verified location is absent from location profile");
  const now = args.now;
  const blockers = [];
  add(blockers, inventory.observed_at > now || inventory.valid_until <= now, "stale-inventory-evidence", "brokkr", "Target inventory evidence is stale.");
  add(blockers, locationEvidence.observed_at > now || locationEvidence.valid_until <= now, "stale-location-evidence", "brokkr", "Location preflight evidence is stale.");
  add(blockers, inventory.capability_status !== "known", "unknown-capability", "brokkr", "Target capability evidence is not decision-ready.");
  add(blockers, intent.workload_id !== workload.workload_id || intent.target_node_id !== inventory.node_id, "intent-mismatch", "grimnir", "Desired placement does not bind this workload to this target.");
  add(blockers, !workload.supported_architectures.includes(inventory.architecture), "architecture-incompatible", "brokkr", "Target architecture is incompatible with the workload.");
  add(blockers, !Number.isInteger(inventory.resources.cpu_cores) || !Number.isInteger(inventory.resources.memory_mib), "resource-evidence-missing", "brokkr", "Target resource evidence is incomplete.");
  add(blockers, inventory.health_reporting !== "supported" || workload.health === "unknown", "health-evidence-missing", "grimnir", "Workload health cannot be verified through the target.");
  add(blockers, !detail.workloads.includes(workload.workload_id) || !inventory.extensions.some((entry) => entry.id === `workload-${workload.workload_id}`), "workload-enumeration-gap", "brokkr", "Inventory and detail evidence do not enumerate the workload.");
  const missingUnits = workload.units.filter((unit) => !detail.unit_state.units.some((observed) => observed.name === unit));
  add(blockers, missingUnits.length > 0, "unit-evidence-missing", "brokkr", "Required workload unit evidence is missing.");
  const missingTimers = workload.timers.filter((timer) => !detail.unit_state.units.some((observed) => observed.name === timer));
  add(blockers, missingTimers.length > 0, "timer-evidence-missing", "brokkr", "Required workload timer evidence is missing.");
  const requiredNetwork = new Set();
  if (location.tailnet.required) requiredNetwork.add("tailnet");
  if (location.network.wifi.required) requiredNetwork.add("wifi");
  if (!requiredNetwork.size) requiredNetwork.add("wired");
  for (const network of requiredNetwork) add(blockers, !inventory.network_capabilities.includes(network) || !locationEvidence.network_capabilities.includes(network), `network-${network}-missing`, "brokkr", `Required ${network} evidence is missing.`);
  const profileStores = Object.entries(location.storage);
  for (const [logicalId] of profileStores) {
    const store = locationEvidence.storage.find((entry) => entry.logical_storage_id === logicalId);
    add(blockers, !store, "storage-evidence-missing", "brokkr", "Declared logical storage lacks verified evidence.");
    if (store) {
      add(blockers, store.status !== "known", "storage-status-unknown", "brokkr", "Declared logical storage is not known mounted.");
      add(blockers, !store.writable, "storage-not-writable", "brokkr", "Declared logical storage is not writable.");
      add(blockers, store.capacity !== "sufficient", "storage-capacity-insufficient", "brokkr", "Declared logical storage lacks capacity evidence.");
      add(blockers, store.transfer_window !== "sufficient", "transfer-window-insufficient", "brokkr", "Declared storage lacks a sufficient transfer window.");
      add(blockers, !inventory.logical_storage.some((entry) => entry.class === store.class && entry.status === "known"), "inventory-storage-incompatible", "brokkr", "Inventory lacks the verified storage class.");
    }
  }
  if (workload.backup_restore === "required") add(blockers, detail.backup_roles.length === 0 || location.backup_roles.length === 0, "backup-role-missing", "grimnir", "Required backup producer/consumer roles are not both evidenced.");
  const hooks = workload.hooks;
  for (const required of ["preflight", "drain", "verify"]) add(blockers, !hooks.some((hook) => hook.name === required), `hook-${required}-missing`, "grimnir", `Required ${required} hook is missing from workload requirements.`);
  const rollbackHook = hooks.find((hook) => hook.name === "rollback" || hook.name === "compensate");
  add(blockers, !rollbackHook || !hooks.some((hook) => hook.name === "drain" && hook.compensation_hook === rollbackHook?.name), "rollback-missing", "grimnir", "A drain compensation path is required before relocation.");

  const planMaterial = { intent, workload, inventory_evidence_id: inventory.evidence.evidence_id, location: locationEvidence.location, location_evidence: locationEvidence, now };
  const planId = idFrom("plan", planMaterial); const planDigest = hash(planMaterial); const outcome = blockers.length ? "blocked" : "promoted";
  const deadline = new Date(Date.parse(now) + Math.max(60, hooks.reduce((sum, hook) => sum + hook.deadline_seconds, 0)) * 1000).toISOString().replace(".000Z", "Z");
  const lifecycle = {
    kind: "lifecycle-result", schema_version: "v1", result_id: idFrom("result", planMaterial), attempt_id: idFrom("attempt", planMaterial), plan_id: planId, plan_digest: planDigest,
    desired_revision: intent.desired_revision, observation_evidence_id: inventory.evidence.evidence_id, action: "preflight", deadline, idempotency_key: idFrom("idem", planMaterial), phase: "preflight", outcome,
    drift: "planned", hook_results: [], substrate: { outcome: "not_started", rollback: "not_applicable", pre_state_evidence_id: inventory.evidence.evidence_id }, created_at: now, extensions: [],
  };
  if (schemaErrors(schema, lifecycle).length) die("planner produced an invalid pinned lifecycle result");
  const result = {
    kind: "brokkr-relocation-plan", schema_version: "v1", plan_id: planId, plan_digest: planDigest, outcome, lifecycle_result: lifecycle,
    input_evidence: { inventory: inventory.evidence.evidence_id, location: locationEvidence.location, location_observed_at: locationEvidence.observed_at, desired_revision: intent.desired_revision },
    workloads: [{ workload_id: workload.workload_id, persistent_data: workload.persistent_data, ports: sorted(workload.ports), units: sorted(workload.units), timers: sorted(workload.timers), dependencies: sorted(workload.dependencies) }],
    backup_roles: { target_roles: sorted(detail.backup_roles), transfers: sorted(location.backup_roles.map(({ logical_storage_id, producer, consumer, bytes, window_minutes }) => ({ logical_storage_id, producer, consumer, bytes, window_minutes }))) }, mounts: sorted(locationEvidence.storage.map((store) => ({ logical_storage_id: store.logical_storage_id, class: store.class, status: store.status }))),
    network_tunnel_dependencies: [...requiredNetwork].sort(), health: workload.health, hooks: sorted(hooks.map(({ name, mode, deadline_seconds, compensation_hook }) => ({ name, mode, deadline_seconds, ...(compensation_hook ? { compensation_hook } : {}) }))),
    interruption: { expected_seconds: hooks.filter((hook) => hook.name === "drain").reduce((sum, hook) => sum + hook.deadline_seconds, 0), mode: "no mutation performed" },
    rollback: rollbackHook ? { available: true, hook: rollbackHook.name, mode: rollbackHook.mode } : { available: false }, blockers: sorted(blockers),
  };
  if (args.json) process.stdout.write(`${canonicalJson(result)}\n`);
  else {
    process.stdout.write(`${outcome === "promoted" ? "GO" : "BLOCKED"}: relocation preflight ${planId}\n`);
    for (const item of result.blockers) process.stdout.write(`- [${item.owner_repo}] ${item.code}: ${item.message}\n`);
  }
  process.exit(outcome === "promoted" ? 0 : 3);
};

try { main(); } catch (error) { die(error instanceof Error ? error.message : "planner failed closed"); }
