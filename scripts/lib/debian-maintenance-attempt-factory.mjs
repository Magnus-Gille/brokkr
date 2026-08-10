// Closed, release-bound producer for one W2 Debian-maintenance attempt per
// canonical maintenance-window occurrence.  The public CLI supplies no
// selector: all authority and target data comes from protected fixed inputs.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  deriveDebianAutonomyExecution,
  runDebianMaintenance,
} from "../debian-maintenance-executor.mjs";
import {
  loadPinnedJournalSchema,
} from "../debian-maintenance-autonomy.mjs";
import {
  checkSchema, schemaErrors,
} from "./maintenance-policy-contract.mjs";

const DIGEST = /^sha256:[a-f0-9]{64}$/;
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const UTC = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const APPLY_VERIFY_BUDGET_SECONDS = 300;
const FRESHNESS_MAX_AGE_SECONDS = 300;
const plain = value =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const fail = code => {
  const error = new Error(code);
  error.code = code;
  throw error;
};
export const canonicalJson = value => {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  return `{${Object.keys(value).sort().map(key =>
    `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
};
export const digest = value => `sha256:${crypto.createHash("sha256")
  .update(canonicalJson(value))
  .digest("hex")}`;
const strictUtc = value => {
  if (typeof value !== "string" || !UTC.test(value)) return false;
  const date = new Date(value);
  return !Number.isNaN(date.getTime()) &&
    date.toISOString().replace(".000Z", "Z") === value;
};
const exactKeys = (value, keys) => plain(value) &&
  Object.keys(value).sort().join(",") === [...keys].sort().join(",");
export function validateFactoryDisarm(value, releaseSha) {
  if (!/^[a-f0-9]{40}$/.test(releaseSha ?? "") || !exactKeys(value, [
    "evidence_preserved", "kind", "recorded_at", "release_sha",
    "schema_version", "state_preserved",
  ]) || value.kind !== "brokkr-debian-maintenance-factory-disarm" ||
      value.schema_version !== "v1" || value.release_sha !== releaseSha ||
      value.evidence_preserved !== true || value.state_preserved !== true ||
      !strictUtc(value.recorded_at)) {
    fail("attempt_factory_disarm_invalid");
  }
  return true;
}
const id = (prefix, material) =>
  `${prefix}-${digest(material).slice("sha256:".length, "sha256:".length + 48)}`;
const FACTORY_SCHEMA = JSON.parse(fs.readFileSync(fileURLToPath(new URL(
  "../../docs/debian-maintenance-attempt-factory-config-v1.schema.json",
  import.meta.url,
)), "utf8"));
const FRESHNESS_SCHEMA = JSON.parse(fs.readFileSync(fileURLToPath(new URL(
  "../../docs/debian-maintenance-window-freshness-v1.schema.json",
  import.meta.url,
)), "utf8"));
checkSchema(FACTORY_SCHEMA);
checkSchema(FRESHNESS_SCHEMA);

export function occurrenceIdentity({
  policyDigest, targetScopeDigest, windowStart,
}) {
  if (!DIGEST.test(policyDigest) || !DIGEST.test(targetScopeDigest) ||
      !strictUtc(windowStart)) fail("attempt_factory_occurrence_invalid");
  const occurrence = {
    policy_digest: policyDigest,
    target_scope_digest: targetScopeDigest,
    window_start: windowStart,
  };
  const occurrenceDigest = digest(occurrence);
  return {
    occurrence_digest: occurrenceDigest,
    attempt_id: id("attempt", occurrence),
    mutation_id: id("mutation", occurrence),
    recovery_disarm_id: id("disarm", occurrence),
    idempotency_key: id("idem", occurrence),
  };
}

function validateConfig(config, releaseDigest) {
  if (schemaErrors(FACTORY_SCHEMA, config).length !== 0 ||
    !exactKeys(config, [
    "kind", "schema_version", "release_digest", "target", "actors",
    "authority", "recovery", "watch_seconds", "deadline_seconds",
  ]) || config.kind !== "brokkr-debian-attempt-factory-configuration" ||
      config.schema_version !== "v1" ||
      config.release_digest !== releaseDigest || !DIGEST.test(releaseDigest) ||
      !exactKeys(config.target, ["node_id", "platform", "non_pillar"]) ||
      !ID.test(config.target.node_id) || config.target.platform !== "debian" ||
      config.target.non_pillar !== true ||
      !exactKeys(config.actors, [
        "owner", "controller", "watchdog", "kill_switch", "recovery_worker",
      ]) || !Object.values(config.actors).every(value => ID.test(value)) ||
      new Set(Object.values(config.actors)).size !== 5 ||
      !exactKeys(config.authority, [
        "writer_owner", "owner_authority_ref", "owner_authority_digest",
        "configuration_owner", "configuration_owner_authority_ref",
        "configuration_owner_authority_digest", "admission_coverage_digest",
        "admission_binding_state", "constitution_digest",
      ]) ||
      ![config.authority.writer_owner,
        config.authority.configuration_owner].every(value => ID.test(value)) ||
      ![config.authority.owner_authority_ref,
        config.authority.configuration_owner_authority_ref]
        .every(value => /^ref:[a-z][a-z0-9-]{2,120}$/.test(value)) ||
      ![
        config.authority.owner_authority_digest,
        config.authority.configuration_owner_authority_digest,
        config.authority.admission_coverage_digest,
        config.authority.constitution_digest,
      ].every(value => DIGEST.test(value)) ||
      !["armed-canary", "armed-fleet"]
        .includes(config.authority.admission_binding_state) ||
      !exactKeys(config.recovery, [
        "descriptor_id_prefix", "restart_units", "budget_seconds",
      ]) || !ID.test(config.recovery.descriptor_id_prefix) ||
      !Array.isArray(config.recovery.restart_units) ||
      config.recovery.restart_units.length > 16 ||
      !config.recovery.restart_units.every(value =>
        value === "brokkr-maintenance-safe.service") ||
      !Number.isInteger(config.recovery.budget_seconds) ||
      config.recovery.budget_seconds < 1 ||
      config.recovery.budget_seconds > 300 ||
      config.watch_seconds !== 3600 || config.deadline_seconds !== 4200) {
    fail("attempt_factory_configuration_invalid");
  }
  return structuredClone(config);
}

function validateFreshness(snapshot, now, target) {
  if (schemaErrors(FRESHNESS_SCHEMA, snapshot).length !== 0 ||
    !exactKeys(snapshot, [
    "kind", "schema_version", "observed_at", "valid_until", "liveness",
    "eligibility", "kill_switch", "hold", "policy", "window", "target",
    "plan", "inventory", "postconditions", "apt_source_evidence",
  ]) || snapshot.kind !== "brokkr-debian-window-freshness" ||
      snapshot.schema_version !== "v1" || !strictUtc(now) ||
      !strictUtc(snapshot.observed_at) || !strictUtc(snapshot.valid_until) ||
      Date.parse(snapshot.observed_at) > Date.parse(now) ||
      Date.parse(now) - Date.parse(snapshot.observed_at) >
        FRESHNESS_MAX_AGE_SECONDS * 1000 ||
      Date.parse(now) >= Date.parse(snapshot.valid_until) ||
      !exactKeys(snapshot.liveness, ["healthy"]) ||
      snapshot.liveness.healthy !== true ||
      !exactKeys(snapshot.eligibility, ["eligible"]) ||
      snapshot.eligibility.eligible !== true ||
      !exactKeys(snapshot.kill_switch, ["safe", "identity"]) ||
      snapshot.kill_switch.safe !== true ||
      !ID.test(snapshot.kill_switch.identity) ||
      !exactKeys(snapshot.hold, ["active"]) || snapshot.hold.active !== false ||
      !plain(snapshot.policy) || !DIGEST.test(snapshot.policy.policy_digest) ||
      !exactKeys(snapshot.window, ["start", "end", "due"]) ||
      !strictUtc(snapshot.window.start) || !strictUtc(snapshot.window.end) ||
      snapshot.window.due !== true ||
      !(Date.parse(snapshot.window.start) <= Date.parse(now) &&
        Date.parse(now) < Date.parse(snapshot.window.end)) ||
      canonicalJson(snapshot.target) !== canonicalJson(target) ||
      !plain(snapshot.plan) || !plain(snapshot.inventory) ||
      !plain(snapshot.postconditions) ||
      !plain(snapshot.apt_source_evidence)) {
    fail("attempt_factory_freshness_ineligible");
  }
  return structuredClone(snapshot);
}

function protectedStateRoot(root) {
  if (typeof root !== "string" || !path.isAbsolute(root)) {
    fail("attempt_factory_state_root_invalid");
  }
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(root);
  const expectedUid = typeof process.getuid === "function" ? process.getuid() : stat.uid;
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      stat.uid !== expectedUid || (stat.mode & 0o077) !== 0) {
    fail("attempt_factory_state_root_unsafe");
  }
}
function readJson(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    const expectedUid = typeof process.getuid === "function" ?
      process.getuid() : stat.uid;
    if (!stat.isFile() || stat.uid !== expectedUid ||
        (stat.mode & 0o077) !== 0 || stat.size > 4_000_000) {
      fail("attempt_factory_input_unsafe");
    }
    try { return JSON.parse(fs.readFileSync(fd, "utf8")); }
    catch { fail("attempt_factory_input_invalid"); }
  } finally {
    fs.closeSync(fd);
  }
}
function readProtectedText(file, maxBytes = 1_000_000) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    const expectedUid = typeof process.getuid === "function" ?
      process.getuid() : stat.uid;
    if (!stat.isFile() || stat.uid !== expectedUid ||
        (stat.mode & 0o077) !== 0 || stat.size > maxBytes) {
      fail("attempt_factory_input_unsafe");
    }
    return fs.readFileSync(fd, "utf8");
  } finally {
    fs.closeSync(fd);
  }
}
function atomicCreateResult(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}`;
  const fd = fs.openSync(temporary,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL |
    fs.constants.O_NOFOLLOW, 0o600);
  try {
    fs.writeFileSync(fd, `${canonicalJson(value)}\n`);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  let created = true;
  try {
    fs.linkSync(temporary, file);
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    created = false;
  } finally {
    fs.unlinkSync(temporary);
  }
  const directory = fs.openSync(path.dirname(file), "r");
  try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
  return { created, value: readJson(file) };
}
function atomicCreate(file, value) {
  return atomicCreateResult(file, value).value;
}
function atomicReplace(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}`;
  const fd = fs.openSync(temporary,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL |
    fs.constants.O_NOFOLLOW, 0o600);
  try {
    fs.writeFileSync(fd, `${canonicalJson(value)}\n`);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temporary, file);
  const directory = fs.openSync(path.dirname(file), "r");
  try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
}
const PROCESS_START_EPOCH_MS =
  String(Math.floor(Date.now() - process.uptime() * 1_000));
function processStartTime(pid) {
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
    const tail = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
    return /^\d+$/.test(tail[19] ?? "") ? tail[19] : null;
  } catch {}
  return pid === process.pid ? PROCESS_START_EPOCH_MS : null;
}
function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code !== "ESRCH";
  }
}
function lockOwner() {
  const startTime = processStartTime(process.pid);
  if (startTime === null) fail("attempt_factory_lock_identity_unavailable");
  return {
    kind: "brokkr-attempt-factory-lock", schema_version: "v1",
    pid: process.pid, process_start_time: startTime,
  };
}
function sameLockOwner(left, right) {
  return exactKeys(left, [
    "kind", "schema_version", "pid", "process_start_time",
  ]) && canonicalJson(left) === canonicalJson(right);
}
function validLockOwner(owner) {
  return exactKeys(owner, [
    "kind", "schema_version", "pid", "process_start_time",
  ]) && owner.kind === "brokkr-attempt-factory-lock" &&
    owner.schema_version === "v1" &&
    Number.isSafeInteger(owner.pid) && owner.pid >= 1 &&
    (/^\d+$/.test(owner.process_start_time) ||
      DIGEST.test(owner.process_start_time));
}
function lockOwnerActive(owner) {
  if (!validLockOwner(owner)) return true;
  const observedStart = processStartTime(owner.pid);
  return observedStart === null ?
    processExists(owner.pid) :
    observedStart === owner.process_start_time;
}
function sameInode(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}
function staleLockSnapshot(directory) {
  let before;
  let after;
  let owner;
  try {
    before = fs.lstatSync(directory);
    owner = readJson(path.join(directory, "owner.json"));
    after = fs.lstatSync(directory);
  } catch {
    fail("attempt_factory_occurrence_contended");
  }
  const expectedUid = typeof process.getuid === "function" ?
    process.getuid() : after.uid;
  if (!before.isDirectory() || before.isSymbolicLink() ||
      !sameInode(before, after) || after.uid !== expectedUid ||
      (after.mode & 0o077) !== 0 ||
      !validLockOwner(owner) || lockOwnerActive(owner)) {
    fail("attempt_factory_occurrence_contended");
  }
  return {
    owner,
    dev: String(after.dev),
    ino: String(after.ino),
    digest: digest({
      dev: String(after.dev), ino: String(after.ino), owner,
    }),
  };
}
function claimStaleLock(directory, snapshot, claimant, previous = null,
  depth = 0) {
  if (depth > 32) fail("attempt_factory_occurrence_contended");
  const previousClaimDigest = previous === null ? null : digest(previous);
  const claimKey = digest({
    stale_lock_digest: snapshot.digest,
    previous_claim_digest: previousClaimDigest,
  }).slice("sha256:".length);
  const claimFile = `${directory}.reclaim.${claimKey}.claim`;
  const claim = {
    kind: "brokkr-attempt-factory-reclaim-claim",
    schema_version: "v1",
    stale_lock_digest: snapshot.digest,
    previous_claim_digest: previousClaimDigest,
    claimant,
  };
  let result;
  try { result = atomicCreateResult(claimFile, claim); }
  catch { fail("attempt_factory_occurrence_contended"); }
  if (result.created) return { claim, claimFile };
  const stored = result.value;
  if (!exactKeys(stored, [
    "kind", "schema_version", "stale_lock_digest",
    "previous_claim_digest", "claimant",
  ]) || stored.kind !== claim.kind || stored.schema_version !== "v1" ||
      stored.stale_lock_digest !== snapshot.digest ||
      stored.previous_claim_digest !== previousClaimDigest ||
      !validLockOwner(stored.claimant) ||
      lockOwnerActive(stored.claimant)) {
    fail("attempt_factory_occurrence_contended");
  }
  return claimStaleLock(
    directory, snapshot, claimant, stored, depth + 1,
  );
}
function acquireLock(directory, owner) {
  try {
    fs.mkdirSync(directory, { mode: 0o700 });
  } catch (error) {
    if (!["EEXIST", "ENOTEMPTY"].includes(error.code)) throw error;
    return inspectExistingLock(directory, owner);
  }
  try {
    atomicCreate(path.join(directory, "owner.json"), owner);
    return;
  } catch (error) {
    try { fs.unlinkSync(path.join(directory, "owner.json")); } catch {}
    try { fs.rmdirSync(directory); } catch {}
    throw error;
  }
}
function inspectExistingLock(directory, owner) {
  const snapshot = staleLockSnapshot(directory);
  const claimed = claimStaleLock(directory, snapshot, owner);
  let currentStat;
  let currentOwner;
  let storedClaim;
  try {
    currentStat = fs.lstatSync(directory);
    currentOwner = readJson(path.join(directory, "owner.json"));
    storedClaim = readJson(claimed.claimFile);
  } catch {
    fail("attempt_factory_occurrence_contended");
  }
  if (String(currentStat.dev) !== snapshot.dev ||
      String(currentStat.ino) !== snapshot.ino ||
      !sameLockOwner(currentOwner, snapshot.owner) ||
      canonicalJson(storedClaim) !== canonicalJson(claimed.claim)) {
    fail("attempt_factory_occurrence_contended");
  }
  const stale = `${directory}.stale.${process.pid}.${crypto.randomUUID()}`;
  try { fs.renameSync(directory, stale); }
  catch { fail("attempt_factory_occurrence_contended"); }
  fs.unlinkSync(path.join(stale, "owner.json"));
  fs.rmdirSync(stale);
  acquireLock(directory, owner);
}
function withLock(directory, operation) {
  const owner = lockOwner();
  acquireLock(directory, owner);
  try { return operation(); }
  finally {
    let current = null;
    try { current = readJson(path.join(directory, "owner.json")); } catch {}
    if (sameLockOwner(current, owner)) {
      fs.unlinkSync(path.join(directory, "owner.json"));
      fs.rmdirSync(directory);
    }
  }
}
function freshnessBinding(snapshot, { hostVerified = false } = {}) {
  const binding = {
    policy_digest: snapshot.policy.policy_digest,
    target_scope_digest: digest({
      node_id: snapshot.target.node_id,
      platform: snapshot.target.platform,
    }),
    window: structuredClone(snapshot.window),
    kill_switch_identity: snapshot.kill_switch.identity,
  };
  if (!hostVerified) {
    Object.assign(binding, {
      plan_digest: digest(snapshot.plan),
      inventory_baseline_digest: digest(snapshot.inventory),
      postconditions_digest: digest(snapshot.postconditions),
      apt_source_evidence_digest: digest(snapshot.apt_source_evidence),
    });
  }
  return binding;
}
function hostEffectVerified(stateRoot, attemptId) {
  const journal = path.join(stateRoot, "journals", `${attemptId}.json`);
  if (!fs.existsSync(journal)) return false;
  const value = readJson(journal);
  return exactKeys(value, ["entries", "terminal"]) &&
    value.terminal === null && Array.isArray(value.entries) &&
    value.entries.at(-1)?.phase === "verify";
}

export function composeAttempt({
  config, freshness, identities, releaseDigest, at,
}) {
  if (!strictUtc(at)) fail("attempt_factory_watch_unreachable");
  const execution = deriveDebianAutonomyExecution({
    plan: freshness.plan, policy: freshness.policy, target: config.target,
    inventory: freshness.inventory, adapterRevisionDigest: releaseDigest,
    postconditions: freshness.postconditions,
  });
  if (execution.target_scope_digest !== identities.target_scope_digest) {
    fail("attempt_factory_target_digest_drifted");
  }
  const descriptor = {
    kind: "brokkr-debian-recovery-descriptor", schema_version: "v2",
    descriptor_id: id(config.recovery.descriptor_id_prefix, identities),
    attempt_id: identities.attempt_id,
    mutation_id: identities.mutation_id,
    recovery_disarm_id: identities.recovery_disarm_id,
    target_scope_digest: execution.target_scope_digest,
    candidate_digest: execution.candidate_digest,
    postconditions_digest: execution.postconditions_digest,
    worker_identity: config.actors.recovery_worker,
    packages: execution.execution_request.candidates.map(item => item.name),
    restart_units: structuredClone(config.recovery.restart_units),
    budget_seconds: config.recovery.budget_seconds,
  };
  const descriptorDigest = digest(descriptor);
  const deadline = new Date(Math.min(
    Date.parse(freshness.window.end),
    Date.parse(freshness.observed_at) + config.deadline_seconds * 1000,
  )).toISOString().replace(".000Z", "Z");
  if (Date.parse(deadline) - Date.parse(at) <
      (APPLY_VERIFY_BUDGET_SECONDS + config.watch_seconds) * 1000) {
    fail("attempt_factory_watch_unreachable");
  }
  const binding = {
    mutation_id: identities.mutation_id,
    attempt_id: identities.attempt_id,
    recovery_disarm_id: identities.recovery_disarm_id,
    idempotency_key: identities.idempotency_key,
    writer_owner: config.authority.writer_owner,
    owner_authority_ref: config.authority.owner_authority_ref,
    owner_authority_digest: config.authority.owner_authority_digest,
    configuration_owner: config.authority.configuration_owner,
    configuration_owner_authority_ref:
      config.authority.configuration_owner_authority_ref,
    configuration_owner_authority_digest:
      config.authority.configuration_owner_authority_digest,
    target_scope_digest: execution.target_scope_digest,
    admission_coverage_digest: config.authority.admission_coverage_digest,
    admission_binding_state: config.authority.admission_binding_state,
    owner_identity: config.actors.owner,
    controller_identity: config.actors.controller,
    watchdog_identity: config.actors.watchdog,
    kill_switch_identity: config.actors.kill_switch,
    recovery_worker_identity: config.actors.recovery_worker,
    risk_scope: "no-reboot-security-bugfix-maintenance",
    candidate_digest: execution.candidate_digest,
    config_digest: execution.config_digest,
    evidence_digest: execution.evidence_digest,
    policy_digest: execution.policy_digest,
    baseline_digest: execution.baseline_digest,
    postconditions_digest: execution.postconditions_digest,
    deadline,
    canary: { scope_digest: execution.target_scope_digest, target_count: 1 },
    recovery: {
      class: "R-forward", worker_identity: config.actors.recovery_worker,
      descriptor_digest: descriptorDigest, disarms_after_action: true,
    },
  };
  const bindingDigest = digest(binding);
  const initialFence = {
    kind: "brokkr-effect-lease-fence", schema_version: "v1",
    domain: "no-reboot-security-bugfix-maintenance",
    target_scope_digest: binding.target_scope_digest,
    attempt_id: binding.attempt_id, mutation_id: binding.mutation_id,
    binding_digest: bindingDigest, epoch: 1,
    holder_token: digest({
      occurrence_digest: identities.occurrence_digest,
      release_digest: releaseDigest,
    }).slice("sha256:".length),
    activated_at: freshness.observed_at, expires_at: freshness.window.end,
  };
  const freshnessDigest = digest(freshnessBinding(freshness));
  const request = {
    kind: "brokkr-debian-host-adapter-request", schema_version: "v2",
    action: "apply", attempt_id: binding.attempt_id,
    binding, binding_digest: bindingDigest,
    plan_digest: execution.candidate_digest,
    constitution_digest: config.authority.constitution_digest,
    release_digest: releaseDigest,
    execution_request: execution.execution_request,
    execution_request_digest: execution.execution_request_digest,
    recovery_descriptor: descriptor,
    recovery_descriptor_digest: descriptorDigest,
    lease_fence: initialFence, lease_fence_digest: digest(initialFence),
    apt_source_evidence: freshness.apt_source_evidence,
    apt_source_evidence_digest: digest(freshness.apt_source_evidence),
    freshness_digest: freshnessDigest,
    actors: structuredClone(config.actors),
  };
  const registration = {
    kind: "brokkr-debian-host-adapter-registration", schema_version: "v2",
    attempt_id: binding.attempt_id, mutation_id: binding.mutation_id,
    idempotency_key: binding.idempotency_key,
    recovery_disarm_id: binding.recovery_disarm_id,
    binding_digest: bindingDigest, plan_digest: request.plan_digest,
    constitution_digest: request.constitution_digest,
    release_digest: releaseDigest,
    execution_request_digest: request.execution_request_digest,
    recovery_descriptor_digest: descriptorDigest,
    lease_fence_digest: request.lease_fence_digest,
    apt_source_evidence_digest: request.apt_source_evidence_digest,
    freshness_digest: freshnessDigest,
    actors: structuredClone(config.actors),
  };
  const recoveryAuthorization = {
    kind: "brokkr-debian-recovery-authorization", schema_version: "v2",
    attempt_id: binding.attempt_id, mutation_id: binding.mutation_id,
    recovery_disarm_id: binding.recovery_disarm_id,
    binding_digest: bindingDigest,
    recovery_descriptor_digest: descriptorDigest,
    target_scope_digest: binding.target_scope_digest,
    recovery_worker_identity: binding.recovery_worker_identity,
  };
  return {
    kind: "brokkr-debian-window-attempt", schema_version: "v1",
    occurrence: {
      occurrence_digest: identities.occurrence_digest,
      policy_digest: binding.policy_digest,
      target_scope_digest: binding.target_scope_digest,
      window_start: freshness.window.start,
    },
    identities: {
      attempt_id: identities.attempt_id, mutation_id: identities.mutation_id,
      recovery_disarm_id: identities.recovery_disarm_id,
      idempotency_key: identities.idempotency_key,
    },
    plan: structuredClone(freshness.plan),
    inventory_baseline: structuredClone(freshness.inventory),
    expected_postconditions: structuredClone(freshness.postconditions),
    evidence: structuredClone(freshness),
    binding, binding_digest: bindingDigest, request, registration,
    recovery_authorization: recoveryAuthorization,
  };
}

function fixedAuthoritySnapshot(authorityRoot, stateRoot) {
  return {
    journalSchema: loadPinnedJournalSchema(fileURLToPath(new URL(
      "../../docs/autonomous-mutation-journal-v2.schema.json",
      import.meta.url,
    ))),
    authorization: readJson(path.join(authorityRoot, "authorization.json")),
    constitution: readJson(path.join(authorityRoot, "constitution.json")),
    coverage: readJson(path.join(authorityRoot, "coverage.json")),
    ownerAttestations:
      readJson(path.join(authorityRoot, "owner-attestations.json")),
    recoveryRegistry:
      readJson(path.join(authorityRoot, "recovery-registry.json")),
    pinnedOwnerPublicKeyPem:
      readProtectedText(path.join(authorityRoot, "owner-public-key.pem")),
    authorizationCheckpoint:
      readJson(path.join(authorityRoot, "authorization-checkpoint.json")),
    runtimeNarrowing:
      readJson(path.join(stateRoot, "runtime-narrowing.json")),
    runtimeNarrowingCheckpoint:
      readJson(path.join(stateRoot, "runtime-narrowing-checkpoint.json")),
  };
}
function recoveryFingerprint(publicKey) {
  return `sha256:${crypto.createHash("sha256").update(
    crypto.createPublicKey(publicKey).export({ type: "spki", format: "der" }),
  ).digest("hex")}`;
}
function fixedHostApply(adapter, attempt) {
  const started = Date.now();
  const child = spawnSync("/usr/bin/node", [
    adapter, "--action", "apply", "--attempt", attempt,
  ], { encoding: "utf8", timeout: 300_000 });
  if (child.status !== 0) fail("attempt_factory_fixed_adapter_failed");
  let result;
  try { result = JSON.parse(child.stdout); }
  catch { fail("attempt_factory_fixed_adapter_receipt_invalid"); }
  if (result?.outcome !== "applied") {
    fail("attempt_factory_fixed_adapter_receipt_invalid");
  }
  return { elapsed_ms: Date.now() - started };
}
function proposalRequestForFence(proposal, fence) {
  const request = structuredClone(proposal.request);
  request.lease_fence = structuredClone(fence);
  request.lease_fence_digest = digest(fence);
  const registration = structuredClone(proposal.registration);
  registration.lease_fence_digest = request.lease_fence_digest;
  return { request, registration };
}

export function buildFixedProductionRunOptions({
  proposal, stateRoot, authorityRoot, readFreshness, now,
  hostApply = fixedHostApply, assertArmed = () => true,
}) {
  if (!plain(proposal) || !path.isAbsolute(stateRoot) ||
      !path.isAbsolute(authorityRoot) ||
      typeof readFreshness !== "function" || typeof now !== "function" ||
      typeof hostApply !== "function" || typeof assertArmed !== "function") {
    fail("attempt_factory_runtime_invalid");
  }
  const requireArmed = () => {
    if (assertArmed() !== true) fail("attempt_factory_disarmed");
  };
  const configTarget = proposal.request.execution_request.target;
  const fresh = () => validateFreshness(
    readFreshness(), now(), configTarget,
  );
  const adapterFile = fileURLToPath(new URL(
    "../debian-maintenance-host-adapter.mjs", import.meta.url,
  ));
  const recoveryPrivateKeyFile =
    path.join(authorityRoot, "recovery-worker-private-key.pem");
  const recoveryPublicKeyFile =
    path.join(authorityRoot, "recovery-worker-public-key.pem");
  const recoveryPublicKey = readProtectedText(recoveryPublicKeyFile);
  const recoveryPrivateKey = crypto.createPrivateKey(
    readProtectedText(recoveryPrivateKeyFile),
  );
  if (recoveryFingerprint(recoveryPrivateKey) !==
      recoveryFingerprint(recoveryPublicKey)) {
    fail("attempt_factory_recovery_key_mismatch");
  }
  let activeFence = null;
  let applied = hostEffectVerified(stateRoot, proposal.binding.attempt_id);
  const activation = fence => {
    if (fence.binding_digest !== proposal.binding_digest ||
        fence.attempt_id !== proposal.binding.attempt_id ||
        fence.mutation_id !== proposal.binding.mutation_id ||
        fence.target_scope_digest !== proposal.binding.target_scope_digest) {
      fail("attempt_factory_fence_unbound");
    }
    if (activeFence !== null && (fence.epoch < activeFence.epoch ||
        (fence.epoch === activeFence.epoch &&
          digest(fence) !== digest(activeFence)))) {
      fail("attempt_factory_fence_superseded");
    }
    activeFence = structuredClone(fence);
    return { activated: true, lease_fence_digest: digest(fence) };
  };
  const narrowingFile = path.join(stateRoot, "runtime-narrowing.json");
  const narrowingCheckpointFile =
    path.join(stateRoot, "runtime-narrowing-checkpoint.json");
  const recovery = {
    workerIdentity: proposal.binding.recovery_worker_identity,
    publicKeyFingerprint: recoveryFingerprint(recoveryPublicKey),
    activateFence: activation,
    // runDebianMaintenance replaces this with its mandatory bounded dispatcher.
    recover: () => fail("bounded_recovery_dispatch_required"),
    readNarrowingHistory: () => ({
      ledger: readJson(narrowingFile),
      tailCheckpoint: readJson(narrowingCheckpointFile),
    }),
    appendSignedNarrowing: input => {
      const ledger = readJson(narrowingFile);
      const entryWithoutSignature = {
        sequence: input.sequence, recorded_at: input.recorded_at,
        domain: "no-reboot-security-bugfix-maintenance",
        target_scope_digest: input.binding.target_scope_digest,
        from_state: input.binding.admission_binding_state,
        to_state: "shadow",
        recovery_worker_identity: input.binding.recovery_worker_identity,
        journal_receipt_digest: input.journal_receipt_digest,
        previous_entry_digest: input.previous_entry_digest,
      };
      const entry = {
        ...entryWithoutSignature,
        entry_digest: digest(entryWithoutSignature),
      };
      entry.signature = {
        algorithm: "Ed25519",
        value_base64: crypto.sign(
          null, Buffer.from(canonicalJson(entry)), recoveryPrivateKey,
        ).toString("base64"),
      };
      ledger.entries.push(entry);
      atomicReplace(narrowingFile, ledger);
      return { ledger: structuredClone(ledger) };
    },
    advanceNarrowingCheckpoint: input => atomicReplace(
      narrowingCheckpointFile, {
        kind: "autonomy-runtime-narrowing-checkpoint",
        schema_version: "v1",
        owner_authorization_digest: input.authorization_digest,
        ledger_tail_digest: input.ledger_tail_digest,
        minimum_entries: input.minimum_entries,
      },
    ),
  };
  const ensureFresh = () => {
    const current = fresh();
    if (canonicalJson(freshnessBinding(current, {
      hostVerified: applied,
    })) !== canonicalJson(freshnessBinding(proposal.evidence, {
      hostVerified: applied,
    }))) {
      fail("attempt_factory_freshness_drifted");
    }
    return current;
  };
  const admission = {
    trustedClock: () => ({ trusted: true, now: now() }),
    killSwitch: () => {
      const current = ensureFresh();
      return {
        safe: current.kill_switch.safe,
        identity: current.kill_switch.identity,
      };
    },
    evidence: () => {
      ensureFresh();
      return {
        fresh: true, eligible: true,
        digest: proposal.binding.evidence_digest,
      };
    },
    liveness: () => {
      const current = ensureFresh();
      return {
        healthy: current.liveness.healthy,
        observed_at: current.observed_at,
      };
    },
    maintenance: () => {
      const current = ensureFresh();
      const admissionPlan = applied ? proposal.plan : current.plan;
      return {
        window: {
          start: current.window.start, end: current.window.end,
        },
        target: {
          platform: current.target.platform,
          non_pillar: current.target.non_pillar,
        },
        plan: {
          classes: [...new Set(admissionPlan.candidates
            .map(item => item.class))].sort(),
          reboot_policy: "never", source: "distro_repository",
          workload_hooks: "not_applicable",
        },
      };
    },
  };
  const adapters = {
    inventory: () => structuredClone(ensureFresh().inventory),
    activateFence: activation,
    applyFenced: invocation => {
      requireArmed();
      const current = ensureFresh();
      if (digest(current.apt_source_evidence) !==
          proposal.request.apt_source_evidence_digest ||
          digest(invocation.execution_request) !==
            proposal.request.execution_request_digest ||
          invocation.lease_fence_digest !== digest(invocation.lease_fence)) {
        fail("attempt_factory_effect_binding_drifted");
      }
      const bound = proposalRequestForFence(
        proposal, invocation.lease_fence,
      );
      const requestFile = path.join(
        stateRoot, "requests", `${proposal.binding.attempt_id}.json`,
      );
      const registrationFile = path.join(
        stateRoot, "registrations", `${proposal.binding.attempt_id}.json`,
      );
      const storedRequest = atomicCreate(requestFile, bound.request);
      const storedRegistration =
        atomicCreate(registrationFile, bound.registration);
      if (canonicalJson(storedRequest) !== canonicalJson(bound.request) ||
          canonicalJson(storedRegistration) !==
            canonicalJson(bound.registration)) {
        fail("attempt_factory_fixed_input_conflict");
      }
      requireArmed();
      const effect = hostApply(adapterFile, proposal.binding.attempt_id);
      applied = true;
      const receipt = {
        ok: true, elapsed_ms: effect.elapsed_ms,
        execution_request_digest: invocation.execution_request_digest,
        lease_fence_digest: invocation.lease_fence_digest,
        fence_checked_at: now(), reboot_required: false,
      };
      return { ...receipt, receipt_digest: digest(receipt) };
    },
    afterInventory: () =>
      structuredClone(proposal.expected_postconditions),
    currentPolicy: () => structuredClone(ensureFresh().policy),
    clock: () => ({
      synchronized: ensureFresh().liveness.healthy, now: now(),
    }),
    hold: () => structuredClone(ensureFresh().hold),
    substrateHealth: () => ({ ok: applied }),
    revisionDigest: () => proposal.request.release_digest,
    targetMetadata: () => structuredClone(configTarget),
  };
  const journalRoot = path.join(stateRoot, "w2-attempts");
  fs.mkdirSync(journalRoot, { recursive: true, mode: 0o700 });
  return {
    binding: structuredClone(proposal.binding),
    attemptJournalDir: journalRoot,
    artifacts: {
      read: () => fixedAuthoritySnapshot(authorityRoot, stateRoot),
    },
    admission, recovery,
    reconcile: () => {
      const journal = path.join(
        stateRoot, "journals", `${proposal.binding.attempt_id}.json`,
      );
      if (!fs.existsSync(journal)) return { state: "not-applied" };
      const value = readJson(journal);
      return {
        state: value.entries?.at(-1)?.phase === "verify" ?
          "applied" : "indeterminate",
      };
    },
    target: structuredClone(configTarget),
    expectedPostconditions:
      structuredClone(proposal.expected_postconditions),
    plan: structuredClone(proposal.plan),
    policy: structuredClone(proposal.evidence.policy),
    nodeId: configTarget.node_id, adapters,
  };
}

export function runDebianMaintenanceAttemptFactory({
  stateRoot, releaseDigest, readConfiguration, readFreshness, now,
  runAttempt = runDebianMaintenance, buildRunOptions = null,
  fault = () => {},
  authorityRoot = "/etc/brokkr/debian-maintenance-authority",
  hostApply = fixedHostApply,
  readDisarm = () => false,
}) {
  if (typeof readDisarm !== "function") fail("attempt_factory_runtime_invalid");
  const ensureArmed = () => {
    const disarmed = readDisarm();
    if (typeof disarmed !== "boolean") fail("attempt_factory_runtime_invalid");
    return !disarmed;
  };
  if (!ensureArmed()) {
    return { outcome: "no-attempt", reason: "attempt_factory_disarmed" };
  }
  protectedStateRoot(stateRoot);
  if (typeof readConfiguration !== "function" ||
      typeof readFreshness !== "function" || typeof now !== "function" ||
      typeof runAttempt !== "function" ||
      (buildRunOptions !== null && typeof buildRunOptions !== "function") ||
      typeof fault !== "function") {
    fail("attempt_factory_runtime_invalid");
  }
  const at = now();
  const config = validateConfig(readConfiguration(), releaseDigest);
  let fresh;
  try { fresh = validateFreshness(readFreshness(), at, config.target); }
  catch (error) {
    if (error?.code === "attempt_factory_freshness_ineligible") {
      return { outcome: "no-attempt", reason: error.code };
    }
    throw error;
  }
  if (fresh.kill_switch.identity !== config.actors.kill_switch) {
    return { outcome: "no-attempt", reason: "attempt_factory_identity_mismatch" };
  }
  if (!ensureArmed()) {
    return { outcome: "no-attempt", reason: "attempt_factory_disarmed" };
  }
  const targetScopeDigest = digest({
    node_id: config.target.node_id, platform: config.target.platform,
  });
  const identities = {
    ...occurrenceIdentity({
      policyDigest: fresh.policy.policy_digest,
      targetScopeDigest,
      windowStart: fresh.window.start,
    }),
    target_scope_digest: targetScopeDigest,
  };
  if (!ensureArmed()) {
    return { outcome: "no-attempt", reason: "attempt_factory_disarmed" };
  }
  const occurrenceDir = path.join(stateRoot, "occurrences");
  fs.mkdirSync(occurrenceDir, { recursive: true, mode: 0o700 });
  const proposalFile = path.join(occurrenceDir,
    `${identities.occurrence_digest.slice("sha256:".length)}.json`);
  return withLock(`${proposalFile}.lock`, () => {
    if (!ensureArmed()) {
      return { outcome: "no-attempt", reason: "attempt_factory_disarmed" };
    }
    let proposal;
    if (fs.existsSync(proposalFile)) {
      proposal = readJson(proposalFile);
      const expected = composeAttempt({
        config, freshness: proposal.evidence, identities, releaseDigest,
        at: proposal.evidence.observed_at,
      });
      if (canonicalJson(expected) !== canonicalJson(proposal)) {
        fail("attempt_factory_occurrence_conflict");
      }
    } else {
      proposal = composeAttempt({
        config, freshness: fresh, identities, releaseDigest, at,
      });
      proposal = atomicCreate(proposalFile, proposal);
      fault("after-occurrence-persist");
    }
    const effectAt = now();
    const beforeEffect = validateFreshness(
      readFreshness(), effectAt, config.target,
    );
    const verifiedHostEffect = hostEffectVerified(
      stateRoot, proposal.binding.attempt_id,
    );
    if (canonicalJson(freshnessBinding(beforeEffect, {
      hostVerified: verifiedHostEffect,
    })) !== canonicalJson(freshnessBinding(proposal.evidence, {
      hostVerified: verifiedHostEffect,
    }))) {
      fail("attempt_factory_freshness_drifted");
    }
    if (!verifiedHostEffect &&
        Date.parse(proposal.binding.deadline) - Date.parse(effectAt) <
          (APPLY_VERIFY_BUDGET_SECONDS + config.watch_seconds) * 1000) {
      fail("attempt_factory_watch_unreachable");
    }
    if (!ensureArmed()) {
      return { outcome: "no-attempt", reason: "attempt_factory_disarmed" };
    }
    fault("before-run-attempt");
    const options = buildRunOptions === null ?
      buildFixedProductionRunOptions({
        proposal: structuredClone(proposal), stateRoot, authorityRoot,
        readFreshness, now, hostApply, assertArmed: ensureArmed,
      }) :
      buildRunOptions(
        structuredClone(proposal), structuredClone(beforeEffect),
      );
    if (!ensureArmed()) {
      return { outcome: "no-attempt", reason: "attempt_factory_disarmed" };
    }
    const result = runAttempt(options);
    return {
      outcome: "attempt-dispatched",
      occurrence_digest: identities.occurrence_digest,
      attempt_id: identities.attempt_id,
      mutation_id: identities.mutation_id,
      idempotency_key: identities.idempotency_key,
      result,
    };
  });
}
