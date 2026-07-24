#!/usr/bin/env node
// Deterministic, read-only relocation/workload preflight planner (brokkr#9).
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  assertPinnedContractFiles, canonicalJson, checkSchema, evidenceDigest,
  observationEvidenceId, schemaErrors, strictUtc,
} from "./lib/node-substrate-contract.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CONTRACT = path.join(ROOT, "docs/node-substrate-contract-v1.schema.json");
const MANIFEST = path.join(ROOT, "tests/fixtures/node-substrate-contract/consumer-fixture-set.json");
const PROVENANCE = path.join(ROOT, "docs/node-substrate-contract-provenance.md");
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const PROFILE_ID = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const REPO = /^[a-z0-9][a-z0-9._-]{1,99}$/;
const DIGEST = /^sha256:[a-f0-9]{64}$/;
const JSON_MODE = process.argv.includes("--json");
const ZERO_DIGEST = `sha256:${"0".repeat(64)}`;
const context = {};

class PlannerError extends Error {
  constructor(code, owner, message) {
    super(message); this.code = code; this.owner = owner;
  }
}
const fail = (code, owner, message) => { throw new PlannerError(code, owner, message); };
const plain = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const hash = (value) => `sha256:${crypto.createHash("sha256").update(typeof value === "string" || Buffer.isBuffer(value) ? value : canonicalJson(value)).digest("hex")}`;
const exactKeys = (value, keys) => plain(value) && canonicalJson(Object.keys(value).sort()) === canonicalJson([...keys].sort());
const sorted = (items) => [...items].sort((a, b) => canonicalJson(a).localeCompare(canonicalJson(b)));
const idFrom = (prefix, material) => `${prefix}-${crypto.createHash("sha256").update(canonicalJson(material)).digest("hex").slice(0, 52)}`;
const blocker = (code, owner_repo, message) => ({ code, owner_repo, message });
const add = (items, condition, code, owner, message) => { if (condition) items.push(blocker(code, owner, message)); };

const usage = () => "Usage: relocation-planner.mjs --intent FILE --workload FILE --requirements FILE --inventory FILE --detail FILE --detail-public-key FILE --location-profile FILE --location-evidence FILE --now UTC [--json]";
const parseArgs = () => {
  const known = new Set(["intent", "workload", "requirements", "inventory", "detail", "detail_public_key", "location_profile", "location_evidence", "now"]);
  const result = { json: false };
  const raw = process.argv.slice(2);
  for (let index = 0; index < raw.length; index += 1) {
    if (raw[index] === "--json") { result.json = true; continue; }
    if (!raw[index].startsWith("--") || index + 1 === raw.length) fail("arguments-invalid", "brokkr", usage());
    const key = raw[index].slice(2).replaceAll("-", "_");
    if (!known.has(key) || result[key] !== undefined) fail("arguments-invalid", "brokkr", usage());
    result[key] = raw[++index];
  }
  for (const key of known) if (typeof result[key] !== "string") fail("arguments-invalid", key === "intent" || key === "workload" || key === "requirements" ? "grimnir" : "brokkr", usage());
  if (!strictUtc(result.now)) fail("now-invalid", "brokkr", "now must be an exact real UTC instant");
  context.now = result.now;
  return result;
};

const readJson = (file, label, owner, prefix) => {
  let stat;
  try { stat = fs.lstatSync(file); } catch { fail(`${prefix}-unavailable`, owner, `${label} is unavailable`); }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1_000_000) fail(`${prefix}-unavailable`, owner, `${label} must be a regular bounded file`);
  const bytes = fs.readFileSync(file);
  try { return { value: JSON.parse(bytes), bytes }; }
  catch { fail(`${prefix}-invalid`, owner, `${label} is not valid JSON`); }
};
const readPublicKey = (file) => {
  let stat;
  try { stat = fs.lstatSync(file); } catch { fail("detail-public-key-unavailable", "brokkr", "detail public key is unavailable"); }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 64_000) fail("detail-public-key-unavailable", "brokkr", "detail public key must be a regular bounded file");
  try {
    const key = crypto.createPublicKey(fs.readFileSync(file));
    if (key.asymmetricKeyType !== "ed25519") throw new Error();
    return key;
  } catch {
    fail("detail-public-key-invalid", "brokkr", "detail public key must be Ed25519");
  }
};
const validateProfile = (file) => {
  const result = spawnSync("python3", [path.join(ROOT, "profiles/preflight.py"), "--validate-profile", "--profile", file], { encoding: "utf8" });
  if (result.status !== 0 || result.stdout.trim() !== "OK: location profile schema validated") fail("location-profile-invalid", "brokkr", "location profile failed Brokkr schema validation");
};

const validateDetail = (detail, inventory, publicKey) => {
  const keys = ["backup_roles", "detail_digest", "kind", "observation_digest", "observation_evidence_id", "observed_at", "schema_version", "signature", "signing_key_id", "unit_state", "valid_until", "workloads"];
  if (!exactKeys(detail, keys) || detail.kind !== "brokkr-node-inventory-detail" || detail.schema_version !== "v1") fail("detail-invalid", "brokkr", "inventory detail has an unsupported shape");
  const expectedKeyId = hash(publicKey.export({ type: "spki", format: "der" }));
  if (detail.signing_key_id !== expectedKeyId || !DIGEST.test(detail.detail_digest) || typeof detail.signature !== "string") fail("detail-signature-invalid", "brokkr", "inventory detail signing identity is invalid");
  const signed = structuredClone(detail); const signature = signed.signature; delete signed.signature;
  const material = structuredClone(signed); delete material.detail_digest;
  let verified = false;
  try { verified = detail.detail_digest === hash(material) && crypto.verify(null, Buffer.from(canonicalJson(signed)), publicKey, Buffer.from(signature, "base64")); } catch { verified = false; }
  if (!verified) fail("detail-signature-invalid", "brokkr", "inventory detail signature or digest does not verify");
  if (detail.observation_evidence_id !== inventory.evidence.evidence_id || detail.observation_digest !== inventory.evidence.digest || detail.observed_at !== inventory.observed_at || detail.valid_until > inventory.valid_until) fail("detail-observation-mismatch", "brokkr", "inventory detail is not bound to the target observation");
  if (!strictUtc(detail.observed_at) || !strictUtc(detail.valid_until) || detail.observed_at > detail.valid_until) fail("detail-invalid", "brokkr", "inventory detail freshness is invalid");
  if (!plain(detail.unit_state) || !exactKeys(detail.unit_state, ["status", "units"]) || detail.unit_state.status !== "known" || !Array.isArray(detail.unit_state.units)) fail("detail-unit-state-invalid", "brokkr", "inventory unit detail is not decision-ready");
  if (!Array.isArray(detail.workloads) || new Set(detail.workloads).size !== detail.workloads.length || !detail.workloads.every(id => typeof id === "string" && ID.test(id))) fail("detail-invalid", "brokkr", "inventory workload detail is invalid");
  if (!Array.isArray(detail.backup_roles) || !detail.backup_roles.every(role => role === "producer" || role === "consumer")) fail("detail-invalid", "brokkr", "inventory backup-role detail is invalid");
  const installed = new Set(["enabled", "enabled-runtime", "static", "indirect", "disabled", "masked", "generated", "transient", "loaded", "not-found", "alias", "unknown"]);
  const active = new Set(["active", "inactive", "failed", "activating", "deactivating", "reloading", "maintenance", "running", "not-running"]);
  const sub = new Set([
    "dead", "condition", "start-pre", "start", "start-post", "running", "exited",
    "reload", "stop", "stop-watchdog", "stop-sigterm", "stop-sigkill", "stop-post",
    "final-watchdog", "final-sigterm", "final-sigkill", "failed", "auto-restart",
    "elapsed", "waiting", "unknown",
  ]);
  for (const unit of detail.unit_state.units) {
    if (!exactKeys(unit, ["active_state", "installed_state", "name", "sub_state"]) || typeof unit.name !== "string" || !installed.has(unit.installed_state) || !active.has(unit.active_state) || !sub.has(unit.sub_state)) fail("detail-unit-state-invalid", "brokkr", "inventory unit detail contains an unsupported state");
  }
};

const validateLocationEvidence = (evidence, inventory, profileBytes) => {
  const keys = ["backup_roles", "digest", "kind", "location", "network_capabilities", "node_id", "observation_evidence_id", "observed_at", "outcome", "profile_digest", "schema_version", "storage", "valid_until"];
  if (!exactKeys(evidence, keys) || evidence.kind !== "brokkr-location-preflight-evidence" || evidence.schema_version !== "v1") fail("location-evidence-invalid", "brokkr", "location evidence has an unsupported shape");
  if (!PROFILE_ID.test(evidence.location) || evidence.node_id !== inventory.node_id || evidence.observation_evidence_id !== inventory.evidence.evidence_id) fail("location-evidence-mismatch", "brokkr", "location evidence is not bound to the inventory");
  const material = structuredClone(evidence); delete material.digest;
  if (!strictUtc(evidence.observed_at) || !strictUtc(evidence.valid_until) || evidence.observed_at > evidence.valid_until || evidence.profile_digest !== hash(profileBytes) || evidence.outcome !== "verified" || evidence.digest !== hash(material)) fail("location-evidence-invalid", "brokkr", "location evidence digest does not verify");
  if (!Array.isArray(evidence.network_capabilities) || new Set(evidence.network_capabilities).size !== evidence.network_capabilities.length || !evidence.network_capabilities.every(kind => ["wired", "wifi", "tailnet"].includes(kind))) fail("location-evidence-invalid", "brokkr", "location network evidence is invalid");
  if (!Array.isArray(evidence.storage) || !evidence.storage.length) fail("location-evidence-invalid", "brokkr", "location storage evidence is missing");
  if (new Set(evidence.storage.map(store => store?.logical_storage_id)).size !== evidence.storage.length) fail("location-evidence-invalid", "brokkr", "location storage evidence contains duplicate ids");
  for (const store of evidence.storage) {
    if (!exactKeys(store, ["capacity", "class", "logical_storage_id", "status", "transfer_window", "writable"]) || !PROFILE_ID.test(store.logical_storage_id) || !["local_ssd", "external_ssd", "network_share"].includes(store.class) || !["known", "unknown"].includes(store.status) || typeof store.writable !== "boolean" || !["sufficient", "insufficient", "unknown"].includes(store.capacity) || !["sufficient", "insufficient", "unknown"].includes(store.transfer_window)) fail("location-evidence-invalid", "brokkr", "location storage evidence is invalid");
  }
  if (!Array.isArray(evidence.backup_roles)) fail("location-evidence-invalid", "brokkr", "location backup-role evidence is invalid");
  for (const role of evidence.backup_roles) {
    if (!exactKeys(role, ["actor", "logical_storage_id", "role", "status"]) || !PROFILE_ID.test(role.actor) || !PROFILE_ID.test(role.logical_storage_id) || !["producer", "consumer"].includes(role.role) || !["verified", "unknown"].includes(role.status)) fail("location-evidence-invalid", "brokkr", "location backup-role evidence is invalid");
  }
};

const validateRequirements = (bundle) => {
  if (!exactKeys(bundle, ["dependency_evidence", "digest", "kind", "schema_version", "workloads"]) || bundle.kind !== "brokkr-relocation-requirements" || bundle.schema_version !== "v1") fail("requirements-invalid", "grimnir", "relocation requirements have an unsupported shape");
  const material = structuredClone(bundle); delete material.digest;
  if (bundle.digest !== hash(material) || !Array.isArray(bundle.workloads) || !Array.isArray(bundle.dependency_evidence)) fail("requirements-invalid", "grimnir", "relocation requirements digest does not verify");
  const workloadIds = new Set();
  for (const item of bundle.workloads) {
    const keys = ["cohost_forbidden", "dependencies", "min_cpu_cores", "min_memory_mib", "owner_repo", "required_backup_roles", "timers", "units", "workload_id"];
    if (!exactKeys(item, keys) || !ID.test(item.workload_id) || !REPO.test(item.owner_repo) || !Number.isInteger(item.min_cpu_cores) || item.min_cpu_cores < 1 || !Number.isInteger(item.min_memory_mib) || item.min_memory_mib < 1) fail("requirements-invalid", "grimnir", "workload planning requirements are invalid");
    if (workloadIds.has(item.workload_id)) fail("requirements-invalid", "grimnir", "workload planning requirements contain duplicates");
    workloadIds.add(item.workload_id);
    for (const field of ["units", "timers", "dependencies", "cohost_forbidden"]) if (!Array.isArray(item[field]) || new Set(item[field]).size !== item[field].length || !item[field].every(value => typeof value === "string" && ID.test(value.replace(/[.@_]/g, "-")))) fail("requirements-invalid", "grimnir", `workload ${field} requirements are invalid`);
    if (!Array.isArray(item.required_backup_roles)) fail("requirements-invalid", item.owner_repo, "backup role requirements are invalid");
    for (const role of item.required_backup_roles) if (!exactKeys(role, ["actor", "logical_storage_id", "role"]) || !PROFILE_ID.test(role.actor) || !PROFILE_ID.test(role.logical_storage_id) || !["producer", "consumer"].includes(role.role)) fail("requirements-invalid", item.owner_repo, "backup role requirements are invalid");
    if (new Set(item.required_backup_roles.map(canonicalJson)).size !== item.required_backup_roles.length) fail("requirements-invalid", item.owner_repo, "backup role requirements contain duplicates");
  }
  const dependencyIds = new Set();
  for (const evidence of bundle.dependency_evidence) {
    if (!exactKeys(evidence, ["digest", "evidence_id", "observed_at", "owner_repo", "status", "valid_until", "workload_id"]) || !ID.test(evidence.workload_id) || !ID.test(evidence.evidence_id) || !REPO.test(evidence.owner_repo) || !["available", "unavailable", "unknown"].includes(evidence.status)) fail("requirements-invalid", "grimnir", "dependency evidence is invalid");
    const material = structuredClone(evidence); delete material.digest;
    if (!strictUtc(evidence.observed_at) || !strictUtc(evidence.valid_until) || evidence.digest !== hash(material)) fail("requirements-invalid", evidence.owner_repo, "dependency evidence digest is invalid");
    if (dependencyIds.has(evidence.workload_id)) fail("requirements-invalid", "grimnir", "dependency evidence contains duplicates");
    dependencyIds.add(evidence.workload_id);
  }
};

const lifecycle = ({ now, desiredRevision, observationId, planMaterial, outcome }) => {
  const safeNow = strictUtc(now) ? now : "1970-01-01T00:00:00Z";
  const material = planMaterial ?? { now: safeNow, outcome };
  return {
    kind: "lifecycle-result", schema_version: "v1", result_id: idFrom("result", material), attempt_id: idFrom("attempt", material),
    plan_id: idFrom("plan", material), plan_digest: hash(material), desired_revision: DIGEST.test(desiredRevision) ? desiredRevision : ZERO_DIGEST,
    observation_evidence_id: ID.test(observationId) ? observationId : "obs-unavailable", action: "preflight",
    deadline: new Date(Date.parse(safeNow) + 60_000).toISOString().replace(".000Z", "Z"), idempotency_key: idFrom("idem", material),
    phase: "preflight", outcome, drift: "planned", hook_results: [],
    substrate: { outcome: "not_started", rollback: "not_applicable", pre_state_evidence_id: ID.test(observationId) ? observationId : "obs-unavailable" },
    created_at: safeNow, extensions: [],
  };
};
const failurePlan = (error) => {
  const item = blocker(error.code ?? "planner-failure", error.owner ?? "brokkr", error.message ?? "planner failed closed");
  const material = { error: item, now: context.now ?? "1970-01-01T00:00:00Z" };
  const life = lifecycle({ now: context.now, desiredRevision: context.intent?.desired_revision, observationId: context.inventory?.evidence?.evidence_id, planMaterial: material, outcome: "blocked" });
  return {
    kind: "brokkr-relocation-plan", schema_version: "v1", plan_id: life.plan_id, plan_digest: life.plan_digest, outcome: "blocked",
    lifecycle_result: life, input_evidence: {}, workloads: [], resources: {}, backup_roles: {}, mounts: [], dependencies: [],
    network_tunnel_dependencies: [], health: "unknown", hooks: [], interruption: { expected_seconds: 0, mode: "no mutation performed" },
    rollback: { available: false }, blockers: [item],
  };
};

const main = () => {
  const args = parseArgs();
  try { assertPinnedContractFiles({ schemaPath: CONTRACT, manifestPath: MANIFEST, provenancePath: PROVENANCE }); }
  catch { fail("pinned-contract-invalid", "grimnir", "pinned Grimnir contract artifacts do not verify"); }
  const schema = readJson(CONTRACT, "pinned contract", "grimnir", "pinned-contract").value; checkSchema(schema);
  const intent = readJson(args.intent, "placement intent", "grimnir", "intent").value; context.intent = intent;
  const workload = readJson(args.workload, "workload requirement", "grimnir", "workload").value;
  const requirements = readJson(args.requirements, "relocation requirements", "grimnir", "requirements").value;
  const inventory = readJson(args.inventory, "node inventory", "brokkr", "inventory").value; context.inventory = inventory;
  const detail = readJson(args.detail, "inventory detail", "brokkr", "detail").value;
  const publicKey = readPublicKey(args.detail_public_key);
  const profileFile = readJson(args.location_profile, "location profile", "brokkr", "location-profile");
  const locationEvidence = readJson(args.location_evidence, "location evidence", "brokkr", "location-evidence").value;
  for (const [label, record, owner, code] of [["placement intent", intent, "grimnir", "intent-invalid"], ["workload requirement", workload, "grimnir", "workload-invalid"], ["node inventory", inventory, "brokkr", "inventory-invalid"]]) {
    if (schemaErrors(schema, record).length) fail(code, owner, `${label} violates the pinned Grimnir v1 schema`);
  }
  if (inventory.evidence.digest !== `sha256:${evidenceDigest(inventory)}`) fail("inventory-digest-invalid", "brokkr", "inventory evidence digest does not verify");
  if (inventory.evidence.evidence_id !== observationEvidenceId(inventory)) fail("inventory-evidence-id-invalid", "brokkr", "inventory observation evidence id does not match its observation material");
  if (inventory.evidence.observed_at !== inventory.observed_at) fail("inventory-observed-at-mismatch", "brokkr", "inventory evidence timestamp does not match the observation timestamp");
  validateDetail(detail, inventory, publicKey);
  validateRequirements(requirements);
  validateProfile(args.location_profile);
  validateLocationEvidence(locationEvidence, inventory, profileFile.bytes);
  const profile = profileFile.value;
  const location = profile.locations?.[locationEvidence.location];
  if (!location) fail("location-profile-mismatch", "brokkr", "verified location is absent from the profile");

  const now = args.now;
  const blockers = [];
  const profileStorageIds = Object.keys(location.storage).sort();
  const evidenceStorageIds = locationEvidence.storage.map(store => store.logical_storage_id).sort();
  add(blockers, canonicalJson(profileStorageIds) !== canonicalJson(evidenceStorageIds), "storage-enumeration-mismatch", "brokkr", "Location profile and evidence storage ids disagree.");
  add(blockers, inventory.observed_at > now || inventory.valid_until <= now, "stale-inventory-evidence", "brokkr", "Target inventory evidence is stale.");
  add(blockers, detail.observed_at > now || detail.valid_until <= now, "stale-detail-evidence", "brokkr", "Signed operational detail is stale.");
  add(blockers, locationEvidence.observed_at > now || locationEvidence.valid_until <= now, "stale-location-evidence", "brokkr", "Location preflight evidence is stale.");
  add(blockers, inventory.capability_status !== "known", "unknown-capability", "brokkr", "Target capability evidence is not decision-ready.");
  add(blockers, intent.workload_id !== workload.workload_id || intent.target_node_id !== inventory.node_id, "intent-mismatch", "grimnir", "Desired placement does not bind this workload to this target.");
  add(blockers, !workload.supported_architectures.includes(inventory.architecture), "architecture-incompatible", "brokkr", "Target architecture is incompatible with the requested workload.");
  const requestedProfile = requirements.workloads.find(item => item.workload_id === workload.workload_id);
  add(blockers, !requestedProfile, "workload-requirements-missing", "grimnir", "Requested workload planning requirements are missing.");
  const targetIds = [...new Set([...detail.workloads, workload.workload_id])].sort();
  const profiles = new Map(requirements.workloads.map(item => [item.workload_id, item]));
  for (const id of detail.workloads) add(blockers, !profiles.has(id), "cohost-requirements-missing", "grimnir", "A currently hosted workload lacks planning requirements.");
  const observedWorkloads = inventory.extensions.filter(entry => entry.id.startsWith("workload-")).map(entry => entry.id.slice(9)).sort();
  add(blockers, canonicalJson(observedWorkloads) !== canonicalJson([...detail.workloads].sort()), "workload-enumeration-mismatch", "brokkr", "Signed detail does not enumerate all inventory workloads.");
  const targetProfiles = targetIds.map(id => profiles.get(id)).filter(Boolean);
  const requiredCpu = targetProfiles.reduce((sum, item) => sum + item.min_cpu_cores, 0);
  const requiredMemory = targetProfiles.reduce((sum, item) => sum + item.min_memory_mib, 0);
  add(blockers, requiredCpu > inventory.resources.cpu_cores, "cpu-capacity-insufficient", requestedProfile?.owner_repo ?? "grimnir", "Target CPU capacity is below the summed workload minima.");
  add(blockers, requiredMemory > inventory.resources.memory_mib, "memory-capacity-insufficient", requestedProfile?.owner_repo ?? "grimnir", "Target memory capacity is below the summed workload minima.");
  for (const item of targetProfiles) for (const forbidden of item.cohost_forbidden) add(blockers, targetIds.includes(forbidden), "cohost-forbidden", item.owner_repo, `Workload ${item.workload_id} forbids a planned cohost.`);

  const healthyUnit = unit => inventory.service_manager === "systemd"
    ? unit.active_state === "active" && ["running", "waiting", "exited"].includes(unit.sub_state)
    : unit.active_state === "running" && unit.sub_state === "exited";
  for (const id of detail.workloads) {
    const item = profiles.get(id); if (!item) continue;
    for (const name of [...item.units, ...item.timers]) {
      const unit = detail.unit_state.units.find(candidate => candidate.name === name);
      add(blockers, !unit, "unit-evidence-missing", item.owner_repo, `Hosted workload ${id} is missing unit evidence.`);
      add(blockers, unit && !healthyUnit(unit), "unit-not-healthy", item.owner_repo, `Hosted workload ${id} has a non-healthy unit.`);
    }
  }

  const requiredDependencies = requestedProfile ? requestedProfile.dependencies : [];
  add(blockers, requestedProfile && canonicalJson([...workload.units].sort()) !== canonicalJson([...requestedProfile.units].sort()), "unit-requirement-mismatch", requestedProfile?.owner_repo ?? "grimnir", "Pinned and planning unit requirements disagree.");
  add(blockers, requestedProfile && canonicalJson([...workload.timers].sort()) !== canonicalJson([...requestedProfile.timers].sort()), "timer-requirement-mismatch", requestedProfile?.owner_repo ?? "grimnir", "Pinned and planning timer requirements disagree.");
  add(blockers, requestedProfile && canonicalJson([...workload.dependencies].sort()) !== canonicalJson([...requiredDependencies].sort()), "dependency-requirement-mismatch", requestedProfile?.owner_repo ?? "grimnir", "Pinned and planning dependency requirements disagree.");
  for (const item of targetProfiles) {
    for (const dependency of item.dependencies) {
      const evidence = requirements.dependency_evidence.find(candidate => candidate.workload_id === dependency);
      add(blockers, !evidence, "dependency-evidence-missing", item.owner_repo, `Dependency ${dependency} lacks evidence.`);
      add(blockers, evidence && (evidence.observed_at > now || evidence.valid_until <= now), "dependency-evidence-stale", evidence?.owner_repo ?? item.owner_repo, `Dependency ${dependency} evidence is stale.`);
      add(blockers, evidence && evidence.status !== "available", "dependency-unavailable", evidence?.owner_repo ?? item.owner_repo, `Dependency ${dependency} is unavailable.`);
    }
  }

  const requestedRoles = requestedProfile?.required_backup_roles ?? [];
  if (workload.backup_restore === "required") {
    const roleNames = requestedRoles.map(role => role.role).sort();
    add(blockers, canonicalJson(roleNames) !== canonicalJson(["consumer", "producer"]), "backup-role-requirement-incomplete", requestedProfile?.owner_repo ?? "grimnir", "Backup-required workload must name exactly one producer and one consumer.");
  }
  const profileRoles = location.backup_roles.flatMap(role => [
    { role: "producer", actor: role.producer, logical_storage_id: role.logical_storage_id },
    { role: "consumer", actor: role.consumer, logical_storage_id: role.logical_storage_id },
  ]);
  const allRequiredRoles = [];
  for (const item of targetProfiles) {
    for (const role of item.required_backup_roles) {
      allRequiredRoles.push(role);
      add(blockers, !Object.hasOwn(location.storage, role.logical_storage_id), "backup-storage-ref-invalid", item.owner_repo, `Workload ${item.workload_id} backup role references undeclared location storage.`);
      add(blockers, !profileRoles.some(profileRole => canonicalJson(profileRole) === canonicalJson(role)), "backup-role-profile-mismatch", item.owner_repo, `Workload ${item.workload_id} backup role is absent from the selected location profile.`);
      add(blockers, !locationEvidence.backup_roles.some(evidenceRole => evidenceRole.status === "verified" && evidenceRole.role === role.role && evidenceRole.actor === role.actor && evidenceRole.logical_storage_id === role.logical_storage_id), "backup-role-evidence-missing", item.owner_repo, `Workload ${item.workload_id} backup role lacks exact verified evidence.`);
    }
  }

  const requiredNetwork = new Set();
  if (location.tailnet.required) requiredNetwork.add("tailnet");
  if (location.network.wifi.required) requiredNetwork.add("wifi");
  if (!requiredNetwork.size) requiredNetwork.add("wired");
  for (const network of requiredNetwork) add(blockers, !inventory.network_capabilities.includes(network) || !locationEvidence.network_capabilities.includes(network), `network-${network}-missing`, "brokkr", `Required ${network} evidence is missing.`);
  for (const logicalId of Object.keys(location.storage)) {
    const store = locationEvidence.storage.find(item => item.logical_storage_id === logicalId);
    add(blockers, !store, "storage-evidence-missing", "brokkr", "Declared logical storage lacks verified evidence.");
    if (!store) continue;
    add(blockers, store.status !== "known", "storage-status-unknown", "brokkr", "Declared logical storage is not known mounted.");
    add(blockers, !store.writable, "storage-not-writable", "brokkr", "Declared logical storage is not writable.");
    add(blockers, store.capacity !== "sufficient", "storage-capacity-insufficient", "brokkr", "Declared logical storage lacks capacity.");
    add(blockers, store.transfer_window !== "sufficient", "transfer-window-insufficient", "brokkr", "Declared storage lacks a sufficient transfer window.");
    add(blockers, !inventory.logical_storage.some(entry => entry.class === store.class && entry.status === "known"), "inventory-storage-incompatible", "brokkr", "Inventory lacks the verified storage class.");
  }
  add(blockers, inventory.health_reporting !== "supported" || workload.health === "unknown", "health-evidence-missing", requestedProfile?.owner_repo ?? "grimnir", "Workload health cannot be verified through the target.");
  const hooks = workload.hooks;
  for (const name of ["preflight", "drain", "verify"]) add(blockers, !hooks.some(hook => hook.name === name), `hook-${name}-missing`, requestedProfile?.owner_repo ?? "grimnir", `Required ${name} hook is missing.`);
  const rollbackHook = hooks.find(hook => hook.name === "rollback" || hook.name === "compensate");
  add(blockers, !rollbackHook || !hooks.some(hook => hook.name === "drain" && hook.compensation_hook === rollbackHook?.name), "rollback-missing", requestedProfile?.owner_repo ?? "grimnir", "A drain compensation path is required.");

  const planMaterial = { intent, requirements_digest: requirements.digest, inventory_evidence_id: inventory.evidence.evidence_id, detail_digest: detail.detail_digest, location_evidence_digest: locationEvidence.digest, now };
  const outcome = blockers.length ? "blocked" : "promoted";
  const life = lifecycle({ now, desiredRevision: intent.desired_revision, observationId: inventory.evidence.evidence_id, planMaterial, outcome });
  if (schemaErrors(schema, life).length) fail("lifecycle-output-invalid", "grimnir", "planner produced an invalid pinned lifecycle result");
  const result = {
    kind: "brokkr-relocation-plan", schema_version: "v1", plan_id: life.plan_id, plan_digest: life.plan_digest, outcome, lifecycle_result: life,
    input_evidence: { inventory: inventory.evidence.evidence_id, detail: detail.detail_digest, location: locationEvidence.digest, requirements: requirements.digest, desired_revision: intent.desired_revision },
    workloads: targetIds.map(id => ({ workload_id: id, owner_repo: profiles.get(id)?.owner_repo ?? "grimnir", placement: id === workload.workload_id && !detail.workloads.includes(id) ? "planned" : "current", units: profiles.get(id)?.units ?? [], timers: profiles.get(id)?.timers ?? [], cohost_forbidden: profiles.get(id)?.cohost_forbidden ?? [] })),
    resources: { available_cpu_cores: inventory.resources.cpu_cores, available_memory_mib: inventory.resources.memory_mib, required_cpu_cores: requiredCpu, required_memory_mib: requiredMemory },
    backup_roles: { required: sorted(allRequiredRoles), verified: sorted(locationEvidence.backup_roles) },
    mounts: sorted(locationEvidence.storage.map(store => ({ logical_storage_id: store.logical_storage_id, class: store.class, status: store.status }))),
    dependencies: sorted(targetProfiles.flatMap(item => item.dependencies.map(id => {
      const evidence = requirements.dependency_evidence.find(candidate => candidate.workload_id === id);
      return { workload_id: id, owner_repo: evidence?.owner_repo ?? item.owner_repo, status: evidence?.status ?? "missing" };
    }))),
    network_tunnel_dependencies: [...requiredNetwork].sort(), health: workload.health,
    hooks: sorted(hooks.map(({ name, mode, deadline_seconds, compensation_hook }) => ({ name, mode, deadline_seconds, ...(compensation_hook ? { compensation_hook } : {}) }))),
    interruption: { expected_seconds: hooks.filter(hook => hook.name === "drain").reduce((sum, hook) => sum + hook.deadline_seconds, 0), mode: "no mutation performed" },
    rollback: rollbackHook ? { available: true, hook: rollbackHook.name, mode: rollbackHook.mode } : { available: false },
    blockers: sorted(blockers),
  };
  process.stdout.write(JSON_MODE ? `${canonicalJson(result)}\n` : `${outcome === "promoted" ? "GO" : "BLOCKED"}: relocation preflight ${life.plan_id}\n${result.blockers.map(item => `- [${item.owner_repo}] ${item.code}: ${item.message}`).join("\n")}${result.blockers.length ? "\n" : ""}`);
  process.exit(outcome === "promoted" ? 0 : 3);
};

try {
  main();
} catch (error) {
  const grounded = error instanceof PlannerError ? error : new PlannerError("planner-failure", "brokkr", "planner failed closed");
  if (JSON_MODE) process.stdout.write(`${canonicalJson(failurePlan(grounded))}\n`);
  else process.stderr.write(`FAIL [${grounded.owner}] ${grounded.code}: ${grounded.message}\n`);
  process.exit(3);
}
