// Authoritative Brokkr journal for Grimnir ADR-008's bounded no-reboot
// security/bugfix maintenance class. No production authority is bundled here:
// every attempt must independently verify W0.1 owner authorization, coverage,
// owner attestation, recovery keys, and the protected narrowing tail.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  autonomyDigest, canonicalJson, effectiveTargetState, strictUtc,
  verifyOwnerAuthorizationBundle, verifyRuntimeNarrowingLedger,
} from "./lib/autonomy-authorization.mjs";
import {
  durationToMs, policyDigest,
} from "./lib/maintenance-policy-contract.mjs";
import { windowStatus } from "./maintenance-controller.mjs";

const DOMAIN = "no-reboot-security-bugfix-maintenance";
const SCHEMA_ID = "https://grimnir.gille.ai/contracts/autonomous-mutation-journal/v1/schema.json";
const SCHEMA_SHA256 = "237eb4336a84645b88319b4cbd5112b6dd0c3a3a97e7343e0fdc73869b1cac3b";
const LOCAL_SCHEMA_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../docs/autonomous-mutation-journal-v1.schema.json",
);
const PINNED_SCHEMAS = new WeakSet();
const MAX_BYTES = 256 * 1024;
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const REF = /^ref:[a-z][a-z0-9-]{2,120}$/;
const DIGEST = /^sha256:[a-f0-9]{64}$/;
const TERMINAL = new Set(["commit", "disarm", "terminally-blocked"]);
const OUTCOME = Object.freeze({
  prepare: "prepared", apply: "applied", verify: "verified", watch: "watching",
  commit: "committed", unknown: "unknown", recover: "recovered",
  quarantine: "quarantined", disarm: "disarmed", "terminally-blocked": "terminally-blocked",
});
const NEXT = Object.freeze({
  prepare: new Set(["apply", "unknown"]),
  apply: new Set(["verify", "unknown"]),
  verify: new Set(["watch", "unknown"]),
  watch: new Set(["commit", "unknown"]),
  commit: new Set(),
  unknown: new Set(["recover", "terminally-blocked"]),
  recover: new Set(["quarantine", "terminally-blocked"]),
  quarantine: new Set(["disarm", "terminally-blocked"]),
  disarm: new Set(),
  "terminally-blocked": new Set(),
});
const fail = code => {
  const error = new Error(code);
  error.code = code;
  throw error;
};
const assert = (condition, code) => { if (!condition) fail(code); };
const plain = value => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value, keys) => (
  plain(value) && Object.keys(value).sort().join(",") === [...keys].sort().join(",")
);
const sha256 = bytes => crypto.createHash("sha256").update(bytes).digest("hex");
const boundedJson = file => {
  const raw = fs.readFileSync(file, "utf8");
  assert(Buffer.byteLength(raw) <= MAX_BYTES, "journal_too_large");
  try { return JSON.parse(raw); } catch { fail("journal_invalid_json"); }
};
const fsyncDirectory = directory => {
  const fd = fs.openSync(directory, "r");
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
};
function writeAtomic(file, value) {
  const encoded = `${canonicalJson(value)}\n`;
  assert(Buffer.byteLength(encoded) <= MAX_BYTES, "journal_too_large");
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  const fd = fs.openSync(temporary, "wx", 0o600);
  try { fs.writeFileSync(fd, encoded); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(temporary, file);
  fsyncDirectory(path.dirname(file));
}
function createExclusive(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const encoded = `${canonicalJson(value)}\n`;
  assert(Buffer.byteLength(encoded) <= MAX_BYTES, "journal_too_large");
  let fd;
  try { fd = fs.openSync(file, "wx", 0o600); }
  catch (error) { if (error.code === "EEXIST") return false; throw error; }
  try { fs.writeFileSync(fd, encoded); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fsyncDirectory(path.dirname(file));
  return true;
}
const stateRoot = journalDir => path.join(journalDir, ".autonomy-state");
const targetKey = binding => binding.target_scope_digest.slice("sha256:".length);
const domainStateFile = journalDir => path.join(stateRoot(journalDir), "domain-state.json");
const domainLockDir = journalDir => path.join(stateRoot(journalDir), "domain-state.lock");
function withExclusiveDirectory(lockDir, code, operation) {
  const tickets = `${lockDir}.tickets`;
  fs.mkdirSync(tickets, { recursive: true, mode: 0o700 });
  const token = crypto.randomUUID();
  const entries = fs.readdirSync(tickets).filter(name => /^\d{8}\.json$/.test(name)).sort();
  assert(entries.length < 10_000, "lock_ticket_limit");
  let sequence = 1;
  if (entries.length) {
    const latestName = entries.at(-1);
    sequence = Number.parseInt(latestName.slice(0, 8), 10) + 1;
    const existing = boundedJson(path.join(tickets, latestName));
    assert(exactKeys(existing, ["kind", "schema_version", "pid", "token", "sequence"]) &&
      existing.kind === "brokkr-lock-ticket" && existing.schema_version === "v1" &&
      Number.isSafeInteger(existing.pid) && typeof existing.token === "string" &&
      existing.sequence === sequence - 1, "lock_owner_invalid");
    const completed = fs.existsSync(path.join(tickets, `${latestName.slice(0, 8)}.done`));
    if (!completed) {
    let alive = true;
    try { process.kill(existing.pid, 0); }
    catch (error) { if (error.code === "ESRCH") alive = false; else throw error; }
    if (alive) fail(code);
    }
  }
  const prefix = String(sequence).padStart(8, "0");
  const ticket = {
    kind: "brokkr-lock-ticket", schema_version: "v1", pid: process.pid, token, sequence,
  };
  assert(createExclusive(path.join(tickets, `${prefix}.json`), ticket), code);
  try { return operation(); }
  finally {
    assert(createExclusive(path.join(tickets, `${prefix}.done`), {
      kind: "brokkr-lock-ticket-completion", schema_version: "v1", token, sequence,
    }), "lock_completion_conflict");
  }
}
function readOptional(file) {
  try { return boundedJson(file); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
}
function claimTarget({
  journalDir, binding, bindingDigest, now, policy, resumeWatch = false,
}) {
  return withExclusiveDirectory(domainLockDir(journalDir), "domain_claim_contended", () => {
    const leaseExpiry = new Date(Math.min(
      Date.parse(binding.deadline) - 1000,
      Date.parse(now) + policy.bounds.max_silence_seconds * 1000,
    )).toISOString().replace(".000Z", "Z");
    const domainFile = domainStateFile(journalDir);
    const domain = readOptional(domainFile) ?? {
      kind: "brokkr-autonomy-domain-state", schema_version: "v1",
      active_target_scope_digest: null, active_attempt_id: null, recent_starts: [],
      targets: {}, revision: 0,
    };
    assert(exactKeys(domain, [
      "kind", "schema_version", "active_target_scope_digest", "active_attempt_id",
      "recent_starts", "targets", "revision",
    ]) && domain.kind === "brokkr-autonomy-domain-state" && domain.schema_version === "v1" &&
      Array.isArray(domain.recent_starts) && plain(domain.targets) &&
      Number.isSafeInteger(domain.revision), "domain_state_invalid");
    const key = targetKey(binding);
    const current = domain.targets[key] ?? {
      state: binding.admission_binding_state, lease_epoch: 0, execution_lease: null,
      last_started_at: null, proposal_attempts: {},
    };
    assert(exactKeys(current, [
      "state", "lease_epoch", "execution_lease", "last_started_at", "proposal_attempts",
    ]) && plain(current.proposal_attempts), "target_state_invalid");
    const suspendedWatch = resumeWatch && current.state === "watching" &&
      current.execution_lease === null;
    if (domain.active_attempt_id !== binding.attempt_id) {
      assert(domain.active_attempt_id === null && domain.active_target_scope_digest === null,
        "domain_concurrency_exceeded");
      if (!suspendedWatch) {
        const nowMs = Date.parse(now);
        domain.recent_starts = domain.recent_starts.filter(start => (
          strictUtc(start) && nowMs - Date.parse(start) <
            policy.bounds.attempt_window_seconds * 1000
        ));
        assert(!domain.recent_starts.some(start => (
          nowMs - Date.parse(start) <
            policy.bounds.min_seconds_between_attempts * 1000
        )), "attempt_interval_exceeded");
        assert(domain.recent_starts.length < policy.bounds.max_attempts_per_window,
          "attempt_window_exceeded");
        domain.recent_starts.push(now);
      }
      domain.active_target_scope_digest = binding.target_scope_digest;
      domain.active_attempt_id = binding.attempt_id;
    } else {
      assert(domain.active_target_scope_digest === binding.target_scope_digest,
        "domain_target_mismatch");
    }
    if (current.execution_lease !== null) {
      assert(exactKeys(current.execution_lease, [
        "attempt_id", "mutation_id", "binding_digest", "epoch", "holder_pid",
        "holder_token", "expires_at",
      ]) && current.execution_lease.attempt_id === binding.attempt_id &&
        current.execution_lease.mutation_id === binding.mutation_id &&
        current.execution_lease.binding_digest === bindingDigest &&
        current.execution_lease.epoch === current.lease_epoch &&
        Number.isSafeInteger(current.execution_lease.holder_pid) &&
        typeof current.execution_lease.holder_token === "string" &&
        strictUtc(current.execution_lease.expires_at),
      "execution_lease_invalid");
      if (Date.parse(now) <= Date.parse(current.execution_lease.expires_at)) {
        return { acquired: false, lease: current.execution_lease, target: current };
      }
      current.lease_epoch += 1;
      current.execution_lease = {
        attempt_id: binding.attempt_id, mutation_id: binding.mutation_id,
        binding_digest: bindingDigest, epoch: current.lease_epoch,
        holder_pid: process.pid, holder_token: crypto.randomUUID(),
        expires_at: leaseExpiry,
      };
      domain.revision += 1;
      writeAtomic(domainFile, domain);
      return { acquired: true, transferred: true, lease: current.execution_lease, target: current };
    }
    const attempts = current.proposal_attempts[binding.mutation_id] ?? 0;
    if (resumeWatch) {
      assert(current.state === "watching" && attempts === 1,
        "watch_continuation_invalid");
    } else {
      assert(current.state === binding.admission_binding_state,
        "target_state_not_armed");
      assert(attempts < policy.bounds.max_attempts,
        "proposal_attempts_exceeded");
    }
    current.lease_epoch += 1;
    current.execution_lease = {
      attempt_id: binding.attempt_id, mutation_id: binding.mutation_id,
      binding_digest: bindingDigest, epoch: current.lease_epoch,
      holder_pid: process.pid, holder_token: crypto.randomUUID(),
      expires_at: leaseExpiry,
    };
    if (!resumeWatch) {
      current.last_started_at = now;
      current.proposal_attempts[binding.mutation_id] = attempts + 1;
    }
    domain.targets[key] = current;
    domain.revision += 1;
    writeAtomic(domainFile, domain);
    return { acquired: true, transferred: false, lease: current.execution_lease, target: current };
  });
}
function assertLeaseRecord(domain, binding, bindingDigest, lease) {
  const current = domain?.targets?.[targetKey(binding)];
  assert(current?.execution_lease?.attempt_id === binding.attempt_id &&
    current.execution_lease.binding_digest === bindingDigest &&
    current.execution_lease.epoch === lease?.epoch &&
    current.execution_lease.holder_pid === process.pid &&
    current.execution_lease.holder_token === lease?.holder_token &&
    domain.active_attempt_id === binding.attempt_id &&
    domain.active_target_scope_digest === binding.target_scope_digest,
  "execution_lease_fenced");
  return current;
}
function assertExecutionLease({ journalDir, binding, bindingDigest, lease }) {
  return withExclusiveDirectory(domainLockDir(journalDir), "domain_state_contended", () => (
    assertLeaseRecord(readOptional(domainStateFile(journalDir)), binding, bindingDigest, lease)
  ));
}
function executionLeaseFence(binding, bindingDigest, lease) {
  const fence = {
    kind: "brokkr-effect-lease-fence", schema_version: "v1", domain: DOMAIN,
    target_scope_digest: binding.target_scope_digest,
    attempt_id: binding.attempt_id, mutation_id: binding.mutation_id,
    binding_digest: bindingDigest, epoch: lease.epoch,
    holder_token: lease.holder_token, expires_at: lease.expires_at,
  };
  assert(DIGEST.test(fence.target_scope_digest) && DIGEST.test(fence.binding_digest) &&
    Number.isSafeInteger(fence.epoch) && fence.epoch >= 1 &&
    typeof fence.holder_token === "string" && fence.holder_token.length >= 16 &&
    strictUtc(fence.expires_at), "execution_lease_fence_invalid");
  return Object.freeze(fence);
}
function activateResourceFence(resource, binding, bindingDigest, lease) {
  const fence = executionLeaseFence(binding, bindingDigest, lease);
  const receipt = resource.activateFence(structuredClone(fence));
  const fenceDigest = autonomyDigest(fence);
  assert(exactKeys(receipt, ["activated", "lease_fence_digest"]) &&
    receipt.activated === true && receipt.lease_fence_digest === fenceDigest,
  "effect_lease_fence_unconfirmed");
  return fence;
}
function transitionTarget({ journalDir, binding, bindingDigest, lease, state, release = false }) {
  return withExclusiveDirectory(domainLockDir(journalDir), "domain_state_contended", () => {
    const domainFile = domainStateFile(journalDir);
    const domain = readOptional(domainFile);
    const current = assertLeaseRecord(domain, binding, bindingDigest, lease);
    current.state = state;
    if (release) {
      current.execution_lease = null;
      domain.active_attempt_id = null;
      domain.active_target_scope_digest = null;
    }
    domain.revision += 1;
    writeAtomic(domainFile, domain);
    return current;
  });
}
function repairTerminalRelease({ journalDir, binding, bindingDigest, state }) {
  return withExclusiveDirectory(domainLockDir(journalDir), "domain_state_contended", () => {
    const file = domainStateFile(journalDir);
    const domain = readOptional(file);
    const current = domain?.targets?.[targetKey(binding)];
    if (domain?.active_attempt_id === null && current?.execution_lease === null) {
      assert(current.state === state, "terminal_release_state_mismatch");
      return true;
    }
    assert(domain?.active_attempt_id === binding.attempt_id &&
      domain.active_target_scope_digest === binding.target_scope_digest &&
      current?.execution_lease?.attempt_id === binding.attempt_id &&
      current.execution_lease.binding_digest === bindingDigest,
    "terminal_release_owner_mismatch");
    current.state = state;
    current.execution_lease = null;
    domain.active_attempt_id = null;
    domain.active_target_scope_digest = null;
    domain.revision += 1;
    writeAtomic(file, domain);
    return true;
  });
}

// Dependency-free Draft-2020-12 subset used by the exact Grimnir journal
// schema. This refuses unknown schema keywords so a future contract cannot be
// silently interpreted with old semantics.
function schemaChecker(rootSchema) {
  const supported = new Set([
    "$schema", "$id", "$defs", "$ref", "title", "description", "oneOf", "const", "enum",
    "type", "minLength", "pattern", "format", "minimum", "maximum", "minItems", "maxItems",
    "uniqueItems", "items", "required", "properties", "additionalProperties",
  ]);
  const resolve = ref => ref.slice(2).split("/").reduce((value, raw) => value?.[raw.replaceAll("~1", "/").replaceAll("~0", "~")], rootSchema);
  const inspect = (node, at = "$") => {
    if (typeof node === "boolean") return;
    assert(plain(node), `schema_node_invalid:${at}`);
    for (const key of Object.keys(node)) assert(supported.has(key), `schema_keyword_unsupported:${key}`);
    if (node.$ref) assert(node.$ref.startsWith("#/") && resolve(node.$ref), "schema_ref_invalid");
    for (const child of Object.values(node.properties ?? {})) inspect(child, at);
    for (const child of Object.values(node.$defs ?? {})) inspect(child, at);
    if (node.items) inspect(node.items, at);
    for (const child of node.oneOf ?? []) inspect(child, at);
  };
  const typeMatches = (type, value) => ({
    object: plain(value), array: Array.isArray(value), string: typeof value === "string",
    integer: Number.isInteger(value), boolean: typeof value === "boolean", null: value === null,
  })[type];
  const errors = (node, value, at = "$") => {
    if (node === true) return [];
    if (node === false) return [`${at}:forbidden`];
    if (node.$ref) return errors(resolve(node.$ref), value, at);
    if (node.oneOf) return node.oneOf.filter(branch => errors(branch, value, at).length === 0).length === 1 ? [] : [`${at}:oneOf`];
    const result = [];
    if (Object.hasOwn(node, "const") && canonicalJson(node.const) !== canonicalJson(value)) result.push(`${at}:const`);
    if (node.enum && !node.enum.some(item => canonicalJson(item) === canonicalJson(value))) result.push(`${at}:enum`);
    if (node.type && !typeMatches(node.type, value)) return [...result, `${at}:type`];
    if (typeof value === "string") {
      if (node.minLength !== undefined && value.length < node.minLength) result.push(`${at}:minLength`);
      if (node.pattern && !new RegExp(node.pattern).test(value)) result.push(`${at}:pattern`);
      if (node.format === "date-time" && !strictUtc(value)) result.push(`${at}:date-time`);
    }
    if (Number.isInteger(value)) {
      if (node.minimum !== undefined && value < node.minimum) result.push(`${at}:minimum`);
      if (node.maximum !== undefined && value > node.maximum) result.push(`${at}:maximum`);
    }
    if (Array.isArray(value)) {
      if (node.minItems !== undefined && value.length < node.minItems) result.push(`${at}:minItems`);
      if (node.maxItems !== undefined && value.length > node.maxItems) result.push(`${at}:maxItems`);
      if (node.uniqueItems && new Set(value.map(canonicalJson)).size !== value.length) result.push(`${at}:uniqueItems`);
      value.forEach((item, index) => { if (node.items) result.push(...errors(node.items, item, `${at}[${index}]`)); });
    }
    if (plain(value)) {
      for (const required of node.required ?? []) if (!Object.hasOwn(value, required)) result.push(`${at}.${required}:required`);
      if (node.additionalProperties === false) for (const key of Object.keys(value)) if (!Object.hasOwn(node.properties ?? {}, key)) result.push(`${at}.${key}:additional`);
      for (const [key, child] of Object.entries(node.properties ?? {})) if (Object.hasOwn(value, key)) result.push(...errors(child, value[key], `${at}.${key}`));
    }
    return result;
  };
  inspect(rootSchema);
  return value => errors(rootSchema, value);
}

function ownerBindingFor({ coverage, ownerAttestations, binding }) {
  const rows = coverage.domains?.filter(entry => entry.domain === DOMAIN) ?? [];
  const row = rows[0];
  const ownerBindings = row?.bindings?.filter(entry => (
    entry.target_scope_digest === binding.target_scope_digest &&
    entry.writer_owner === binding.writer_owner &&
    entry.owner_authority_ref === binding.owner_authority_ref &&
    entry.owner_authority_digest === binding.owner_authority_digest &&
    entry.configuration_owner === binding.configuration_owner &&
    entry.configuration_owner_authority_ref === binding.configuration_owner_authority_ref &&
    entry.configuration_owner_authority_digest === binding.configuration_owner_authority_digest
  )) ?? [];
  const ownerBinding = ownerBindings[0];
  const attestations = ownerAttestations.attestations?.filter(entry => (
    `ref:${entry.attestation_id}` === binding.configuration_owner_authority_ref &&
    entry.attestation_digest === binding.configuration_owner_authority_digest &&
    entry.domain === DOMAIN && entry.target_scope_digest === binding.target_scope_digest &&
    entry.configuration_owner === binding.configuration_owner &&
    entry.attestation_digest === autonomyDigest(entry, "attestation_digest")
  )) ?? [];
  assert(rows.length === 1 && ownerBindings.length === 1 && attestations.length === 1, "target_owner_attestation_invalid");
  assert(coverage.global_state === "armed" && row.coverage === row.target_state &&
    row.coverage === ownerBinding.state && ["armed-canary", "armed-fleet"].includes(row.coverage), "coverage_not_armed");
  assert(binding.admission_coverage_digest === coverage.registry_digest && binding.admission_binding_state === ownerBinding.state, "coverage_binding_mismatch");
  assert(binding.writer_owner === "brokkr" && binding.configuration_owner === "brokkr", "maintenance_owner_invalid");
  const identities = ownerBinding.identities;
  assert(exactKeys(identities, ["owner", "controller", "watchdog", "kill_switch", "recovery_worker"]) &&
    new Set(Object.values(identities)).size === 5, "coverage_identity_ambiguity");
  assert(binding.owner_identity === identities.owner && binding.controller_identity === identities.controller &&
    binding.watchdog_identity === identities.watchdog && binding.kill_switch_identity === identities.kill_switch &&
    binding.recovery_worker_identity === identities.recovery_worker, "coverage_identity_mismatch");
  return ownerBinding;
}
function classPolicy(constitution) {
  const policies = constitution.autonomous_classes?.filter(entry => entry.class === DOMAIN) ?? [];
  const policy = policies[0];
  assert(policies.length === 1 && policy.recovery_class === "R-forward" && policy.owner === "brokkr" &&
    policy.bounds?.max_concurrent_targets === 1 && policy.bounds?.max_attempts === 1 &&
    policy.bounds?.trusted_watchdog_time_required === true, "maintenance_constitution_invalid");
  return policy;
}
function trustedNow(clock, previous = null) {
  const proof = clock();
  assert(exactKeys(proof, ["trusted", "now"]) && proof.trusted === true && strictUtc(proof.now), "trusted_clock_invalid");
  if (previous !== null) assert(Date.parse(proof.now) >= Date.parse(previous), "trusted_clock_backdated");
  return proof.now;
}
function checkKillSwitch(killSwitch, binding) {
  const proof = killSwitch();
  assert(exactKeys(proof, ["safe", "identity"]) && proof.safe === true && proof.identity === binding.kill_switch_identity, "kill_switch_unsafe");
}
function makeEntry(journal, { phase, at, actor, contentRef, reason = null, quarantine = false, coverageTransition = null }) {
  const previous = journal.entries.at(-1);
  assert(!previous || NEXT[previous.phase].has(phase), "journal_transition_invalid");
  const entry = {
    entry_id: `entry-${crypto.createHash("sha256").update(`${journal.journal_id}:${phase}:${journal.entries.length + 1}`).digest("hex").slice(0, 32)}`,
    sequence: journal.entries.length + 1,
    recorded_at: at,
    phase,
    outcome: OUTCOME[phase],
    executor_identity: actor,
    binding_digest: journal.binding_digest,
    quarantine: { state: quarantine ? "active" : "not-applicable", reason_digest: journal.binding.recovery.descriptor_digest },
    coverage_transition: coverageTransition,
    terminal_reason_digest: reason,
    previous_receipt_digest: previous?.receipt_digest ?? null,
    receipt_digest: "sha256:".padEnd(71, "0"),
    content_refs: [contentRef],
  };
  entry.receipt_digest = autonomyDigest(entry, "receipt_digest");
  return entry;
}
function append(file, journal, options) {
  const lock = `${file}.append-lock`;
  return withExclusiveDirectory(lock, "journal_append_contended", () => {
    const current = boundedJson(file);
    assert(current.binding_digest === journal.binding_digest, "journal_binding_changed");
    const expectedTail = journal.entries.at(-1)?.receipt_digest ?? null;
    const actualTail = current.entries.at(-1)?.receipt_digest ?? null;
    assert(actualTail === expectedTail, "journal_tail_conflict");
    current.entries.push(makeEntry(current, options));
    writeAtomic(file, current);
    return current;
  });
}
function appendExact(file, journal, entry) {
  const lock = `${file}.append-lock`;
  return withExclusiveDirectory(lock, "journal_append_contended", () => {
    const current = boundedJson(file);
    const expectedTail = journal.entries.at(-1)?.receipt_digest ?? null;
    const actualTail = current.entries.at(-1)?.receipt_digest ?? null;
    assert(current.binding_digest === journal.binding_digest && actualTail === expectedTail,
      "journal_tail_conflict");
    assert(entry.previous_receipt_digest === actualTail &&
      entry.sequence === current.entries.length + 1 &&
      entry.binding_digest === current.binding_digest &&
      entry.receipt_digest === autonomyDigest(entry, "receipt_digest"), "journal_prepared_entry_invalid");
    current.entries.push(structuredClone(entry));
    writeAtomic(file, current);
    return current;
  });
}
function appendFenced(file, journal, options, leaseContext) {
  return withExclusiveDirectory(domainLockDir(leaseContext.journalDir), "domain_state_contended", () => {
    assertLeaseRecord(
      readOptional(domainStateFile(leaseContext.journalDir)), journal.binding,
      journal.binding_digest, leaseContext.lease,
    );
    return append(file, journal, options);
  });
}
function ensureFencedEntry(file, entry, leaseContext) {
  return withExclusiveDirectory(domainLockDir(leaseContext.journalDir), "domain_state_contended", () => {
    const current = boundedJson(file);
    assertLeaseRecord(
      readOptional(domainStateFile(leaseContext.journalDir)), current.binding,
      current.binding_digest, leaseContext.lease,
    );
    const existing = current.entries[entry.sequence - 1];
    if (existing !== undefined) {
      assert(canonicalJson(existing) === canonicalJson(entry), "journal_exact_entry_conflict");
      return current;
    }
    assert(current.entries.length === entry.sequence - 1, "journal_exact_entry_gap");
    return appendExact(file, current, entry);
  });
}
function coverageTransition(binding) {
  return {
    from_state: binding.admission_binding_state,
    to_state: "shadow",
    target_scope_digest: binding.target_scope_digest,
    actor_identity: binding.recovery_worker_identity,
  };
}
function validateJournalSemantics(journal, { schema, constitution, coverage, ownerAttestations }, { allowActive = false } = {}) {
  assert(PINNED_SCHEMAS.has(schema) && schema.$id === SCHEMA_ID, "journal_schema_not_pinned");
  const shapeErrors = schemaChecker(schema)(journal);
  if (!(allowActive && journal.entries.length === 1 && shapeErrors.every(error => error.endsWith(":minItems")))) {
    assert(shapeErrors.length === 0, `journal_schema_invalid:${shapeErrors[0] ?? "unknown"}`);
  }
  assert(journal.constitution_digest === constitution.constitution_digest, "journal_constitution_mismatch");
  const policy = classPolicy(constitution);
  const binding = journal.binding;
  ownerBindingFor({ coverage, ownerAttestations, binding });
  assert(journal.binding_digest === autonomyDigest(binding), "journal_binding_digest_invalid");
  assert(binding.attempt_id !== binding.recovery_disarm_id,
    "journal_attempt_recovery_identity_aliased");
  assert(binding.risk_scope === DOMAIN && binding.recovery.class === "R-forward" &&
    binding.recovery.worker_identity === binding.recovery_worker_identity &&
    binding.recovery.disarms_after_action === true, "journal_recovery_binding_invalid");
  assert(binding.canary.scope_digest === binding.target_scope_digest && binding.canary.target_count === 1 &&
    Date.parse(binding.canary.watch_deadline) <= Date.parse(binding.deadline), "journal_canary_invalid");
  assert(Date.parse(binding.deadline) - Date.parse(journal.entries[0].recorded_at) <= policy.bounds.deadline_seconds * 1000, "journal_deadline_bound_invalid");
  let previous = null;
  const entryIds = new Set();
  for (let index = 0; index < journal.entries.length; index += 1) {
    const entry = journal.entries[index];
    assert(!entryIds.has(entry.entry_id), "journal_entry_identity_replayed");
    entryIds.add(entry.entry_id);
    assert(entry.sequence === index + 1 && entry.previous_receipt_digest === previous &&
      entry.binding_digest === journal.binding_digest && entry.receipt_digest === autonomyDigest(entry, "receipt_digest"), "journal_receipt_invalid");
    assert(entry.outcome === OUTCOME[entry.phase], "journal_outcome_invalid");
    if (index) {
      assert(Date.parse(entry.recorded_at) >= Date.parse(journal.entries[index - 1].recorded_at), "journal_clock_backdated");
      assert(NEXT[journal.entries[index - 1].phase].has(entry.phase), "journal_transition_invalid");
    }
    if (["prepare", "apply", "verify", "watch", "commit"].includes(entry.phase)) assert(Date.parse(entry.recorded_at) <= Date.parse(binding.deadline), "journal_deadline_exceeded");
    if (entry.phase === "watch") {
      assert(Date.parse(entry.recorded_at) <= Date.parse(binding.canary.watch_deadline), "journal_watch_started_late");
      assert(Date.parse(binding.canary.watch_deadline) - Date.parse(entry.recorded_at) <= policy.bounds.watch_seconds * 1000, "journal_watch_bound_invalid");
    }
    if (entry.phase === "commit") assert(Date.parse(entry.recorded_at) >= Date.parse(binding.canary.watch_deadline), "journal_watch_incomplete");
    const recoveryPhase = ["recover", "quarantine", "disarm", "terminally-blocked"].includes(entry.phase);
    if (entry.phase === "unknown") assert([binding.controller_identity, binding.watchdog_identity].includes(entry.executor_identity), "journal_actor_invalid");
    else assert(entry.executor_identity === (recoveryPhase ? binding.recovery_worker_identity : binding.controller_identity), "journal_actor_invalid");
    if (["unknown", "disarm", "terminally-blocked"].includes(entry.phase)) assert(DIGEST.test(entry.terminal_reason_digest), "journal_reason_missing");
    if (entry.phase === "terminally-blocked") {
      assert(entry.quarantine.state === "active",
        "journal_terminally_blocked_not_quarantined");
    }
    if (["disarm", "terminally-blocked"].includes(entry.phase)) assert(canonicalJson(entry.coverage_transition) === canonicalJson(coverageTransition(binding)), "journal_narrowing_invalid");
    else assert(entry.coverage_transition === null, "journal_unexpected_narrowing");
    assert(entry.content_refs.every(ref => REF.test(ref) && !/[/:.]/.test(ref.slice(4))), "journal_content_ref_invalid");
    previous = entry.receipt_digest;
  }
  assert(journal.entries[0].phase === "prepare", "journal_prepare_missing");
  if (!allowActive) assert(TERMINAL.has(journal.entries.at(-1).phase), "journal_not_terminal");
  return true;
}

export function loadPinnedJournalSchema(schemaPath) {
  const raw = fs.readFileSync(schemaPath);
  assert(sha256(raw) === SCHEMA_SHA256, "journal_schema_pin_mismatch");
  const schema = JSON.parse(raw);
  assert(schema.$id === SCHEMA_ID, "journal_schema_id_invalid");
  PINNED_SCHEMAS.add(schema);
  return schema;
}
export function validateJournalConformance(journal, context) {
  return validateJournalSemantics(journal, context);
}
export function attemptIdentity(binding) {
  assert(ID.test(binding?.idempotency_key), "attempt_identity_invalid");
  return binding.idempotency_key;
}
function readArtifacts(artifacts) {
  const snapshot = typeof artifacts?.read === "function" ? artifacts.read() : artifacts;
  assert(plain(snapshot), "authorization_artifacts_unavailable");
  return snapshot;
}
function historicalAuthoritySnapshot(snapshot, recovery, immutableAdmissionDigest) {
  return {
    kind: "brokkr-autonomy-authority-snapshot", schema_version: "v1",
    authorization: structuredClone(snapshot.authorization),
    constitution: structuredClone(snapshot.constitution),
    coverage: structuredClone(snapshot.coverage),
    ownerAttestations: structuredClone(snapshot.ownerAttestations),
    recoveryRegistry: structuredClone(snapshot.recoveryRegistry),
    pinnedOwnerPublicKeyPem: snapshot.pinnedOwnerPublicKeyPem,
    authorizationCheckpoint: structuredClone(snapshot.authorizationCheckpoint),
    runtimeNarrowing: structuredClone(snapshot.runtimeNarrowing),
    runtimeNarrowingCheckpoint: structuredClone(snapshot.runtimeNarrowingCheckpoint),
    recoveryWorkerIdentity: recovery.workerIdentity,
    recoveryPublicKeyFingerprint: recovery.publicKeyFingerprint,
    immutableAdmissionDigest,
  };
}
function verifyHistoricalAuthority(snapshot, binding, recovery) {
  assert(exactKeys(snapshot, [
    "kind", "schema_version", "authorization", "constitution", "coverage",
    "ownerAttestations", "recoveryRegistry", "pinnedOwnerPublicKeyPem",
    "authorizationCheckpoint", "runtimeNarrowing", "runtimeNarrowingCheckpoint",
    "recoveryWorkerIdentity", "recoveryPublicKeyFingerprint", "immutableAdmissionDigest",
  ]) && snapshot.kind === "brokkr-autonomy-authority-snapshot" &&
    snapshot.schema_version === "v1" &&
    snapshot.recoveryWorkerIdentity === recovery.workerIdentity &&
    snapshot.recoveryPublicKeyFingerprint === recovery.publicKeyFingerprint &&
    DIGEST.test(snapshot.immutableAdmissionDigest),
  "historical_authority_invalid");
  return verifyAuthority({ binding, snapshot, recovery });
}
function verifyAuthority({ binding, snapshot, recovery }) {
  const bundle = verifyOwnerAuthorizationBundle(snapshot);
  const narrowing = verifyRuntimeNarrowingLedger({
    ledger: snapshot.runtimeNarrowing,
    recoveryRegistry: bundle.recoveryRegistry,
    authorizationDigest: bundle.authorizationDigest,
    tailCheckpoint: snapshot.runtimeNarrowingCheckpoint,
  });
  ownerBindingFor({ coverage: bundle.coverage, ownerAttestations: bundle.ownerAttestations, binding });
  const recoveryBindings = bundle.recoveryRegistry.entries.filter(entry => (
    entry.domain === DOMAIN && entry.target_scope_digest === binding.target_scope_digest &&
    entry.recovery_worker_identity === binding.recovery_worker_identity
  ));
  assert(recoveryBindings.length === 1 && recovery?.workerIdentity === binding.recovery_worker_identity &&
    recovery.publicKeyFingerprint === recoveryBindings[0].public_key_fingerprint, "recovery_capability_unbound");
  return { bundle, narrowing, recoveryBinding: recoveryBindings[0] };
}
function verifyAdmission({ binding, snapshot, admission, recovery, journalDir, conformance }) {
  const authority = verifyAuthority({ binding, snapshot, recovery });
  const { bundle, narrowing } = authority;
  assert(effectiveTargetState({ coverage: bundle.coverage, narrowingEntries: narrowing.entries, targetScopeDigest: binding.target_scope_digest }) === binding.admission_binding_state, "runtime_demotion_consumed");
  const policy = classPolicy(bundle.constitution);
  const now = trustedNow(admission.trustedClock);
  checkKillSwitch(admission.killSwitch, binding);
  const evidence = admission.evidence();
  assert(exactKeys(evidence, ["fresh", "eligible", "digest"]) && evidence.fresh === true && evidence.eligible === true && evidence.digest === binding.evidence_digest, "maintenance_evidence_ineligible");
  const liveness = admission.liveness();
  assert(exactKeys(liveness, ["healthy", "observed_at"]) && liveness.healthy === true && strictUtc(liveness.observed_at) &&
    Date.parse(liveness.observed_at) <= Date.parse(now) &&
    Date.parse(now) - Date.parse(liveness.observed_at) <= policy.bounds.max_silence_seconds * 1000, "maintenance_liveness_stale");
  const maintenance = admission.maintenance();
  assert(exactKeys(maintenance, ["window", "target", "plan"]) &&
    exactKeys(maintenance.window, ["start", "end"]) && strictUtc(maintenance.window.start) && strictUtc(maintenance.window.end) &&
    Date.parse(maintenance.window.start) <= Date.parse(now) && Date.parse(now) < Date.parse(maintenance.window.end), "maintenance_window_closed");
  assert(exactKeys(maintenance.target, ["platform", "non_pillar"]) && maintenance.target.platform === "debian" && maintenance.target.non_pillar === true, "maintenance_target_ineligible");
  assert(exactKeys(maintenance.plan, ["classes", "reboot_policy", "source", "workload_hooks"]) &&
    Array.isArray(maintenance.plan.classes) && maintenance.plan.classes.length > 0 && maintenance.plan.classes.length <= 2 &&
    new Set(maintenance.plan.classes).size === maintenance.plan.classes.length &&
    maintenance.plan.classes.every(item => ["security", "bugfix"].includes(item)) &&
    maintenance.plan.reboot_policy === "never" && maintenance.plan.source === "distro_repository" &&
    maintenance.plan.workload_hooks === "not_applicable", "maintenance_plan_out_of_scope");
  assert(Date.parse(now) < Date.parse(binding.deadline), "attempt_deadline_closed");
  return {
    ...authority, policy, now, maintenance,
    immutableAdmissionDigest: autonomyDigest({
      authorization_digest: bundle.authorizationDigest,
      coverage_digest: bundle.coverage.registry_digest,
      evidence_digest: evidence.digest,
      maintenance,
      recovery_registry_digest: bundle.recoveryRegistry.registry_digest,
      target_state: binding.admission_binding_state,
    }),
  };
}
function verifyRecoveryPosture({ binding, snapshot, admission }) {
  let authorityDigest = null;
  let coverageDigest = null;
  let narrowingTailDigest = null;
  let postureAvailable = false;
  try {
    const bundle = verifyOwnerAuthorizationBundle(snapshot);
    const narrowing = verifyRuntimeNarrowingLedger({
      ledger: snapshot.runtimeNarrowing,
      recoveryRegistry: bundle.recoveryRegistry,
      authorizationDigest: bundle.authorizationDigest,
      tailCheckpoint: snapshot.runtimeNarrowingCheckpoint,
    });
    authorityDigest = bundle.authorizationDigest;
    coverageDigest = bundle.coverage.registry_digest;
    narrowingTailDigest = narrowing.tailDigest;
    postureAvailable = true;
  } catch {
    // Current corruption cannot authorize mutation, but it also cannot strand
    // containment of an authenticated historical attempt.
  }
  let killSafe = false;
  try {
    const proof = admission.killSwitch();
    killSafe = exactKeys(proof, ["safe", "identity"]) &&
      proof.safe === true && proof.identity === binding.kill_switch_identity;
  } catch {
    killSafe = false;
  }
  return {
    now: trustedNow(admission.trustedClock),
    mustRecover: !postureAvailable || !killSafe,
    authorityDigest, coverageDigest, narrowingTailDigest, postureAvailable,
  };
}
function reasonDigest(code) {
  return autonomyDigest({ code: String(code || "unknown").slice(0, 96) });
}
function verifyTerminalNarrowing({ narrowed, authorizationDigest, recoveryRegistry, terminal }) {
  const verified = verifyRuntimeNarrowingLedger({
    ledger: narrowed.ledger, recoveryRegistry,
    authorizationDigest, tailCheckpoint: narrowed.tailCheckpoint,
  });
  const tail = verified.entries.at(-1);
  assert(tail?.journal_receipt_digest === terminal.receipt_digest &&
    tail.domain === DOMAIN &&
    tail.target_scope_digest === terminal.coverage_transition.target_scope_digest &&
    tail.from_state === terminal.coverage_transition.from_state &&
    tail.recovery_worker_identity === terminal.coverage_transition.actor_identity &&
    tail.to_state === "shadow", "runtime_narrowing_not_consumed");
  return verified;
}
function outboxCheckpoint(file, outbox, stage, recovery, faultPoint) {
  outbox.stage = stage;
  writeAtomic(file, outbox);
  recovery.fault?.(faultPoint);
}
function syntheticCheckpoint(authorizationDigest, ledger) {
  return {
    kind: "autonomy-runtime-narrowing-checkpoint", schema_version: "v1",
    owner_authorization_digest: authorizationDigest,
    ledger_tail_digest: ledger.entries.at(-1)?.entry_digest ?? null,
    minimum_entries: ledger.entries.length,
  };
}
function verifiedRawNarrowing({ history, authorizationDigest, recoveryRegistry }) {
  return verifyRuntimeNarrowingLedger({
    ledger: history.ledger, recoveryRegistry, authorizationDigest,
    tailCheckpoint: syntheticCheckpoint(authorizationDigest, history.ledger),
  });
}
function exactNarrowingEntry(entry, terminal) {
  return entry.journal_receipt_digest === terminal.receipt_digest &&
    entry.domain === DOMAIN &&
    entry.target_scope_digest === terminal.coverage_transition.target_scope_digest &&
    entry.from_state === terminal.coverage_transition.from_state &&
    entry.to_state === terminal.coverage_transition.to_state &&
    entry.recovery_worker_identity === terminal.coverage_transition.actor_identity;
}
function finishRecoveryOutbox({ file, journal, context, admission, recovery, outboxFile, lease }) {
  return withExclusiveDirectory(`${outboxFile}.lock`, "recovery_outbox_contended", () => {
    let outbox = boundedJson(outboxFile);
    assert(exactKeys(outbox, [
      "kind", "schema_version", "binding_digest", "stage", "owner_authorization_digest",
      "previous_narrowing_digest", "narrowing_sequence", "narrowing_tail_digest",
      "recovery_request", "recovery_result", "recovery_error", "unknown_entry",
      "recover_entry", "quarantine_entry", "terminal_entry",
    ]) && outbox.kind === "brokkr-autonomy-recovery-outbox" &&
      outbox.schema_version === "v1" && outbox.binding_digest === journal.binding_digest,
    "recovery_outbox_invalid");
    const currentFence = executionLeaseFence(
      journal.binding, journal.binding_digest, lease,
    );
    const currentFenceDigest = autonomyDigest(currentFence);
    assert(exactKeys(outbox.recovery_request, [
      "idempotency_key", "descriptor_digest", "target_scope_digest",
      "binding_digest", "lease_fence", "lease_fence_digest",
    ]) && outbox.recovery_request.idempotency_key ===
      journal.binding.recovery_disarm_id &&
      outbox.recovery_request.descriptor_digest ===
        journal.binding.recovery.descriptor_digest &&
      outbox.recovery_request.target_scope_digest ===
        journal.binding.target_scope_digest &&
      outbox.recovery_request.binding_digest === journal.binding_digest,
    "recovery_request_invalid");
    assert(DIGEST.test(outbox.recovery_request.lease_fence_digest) &&
      outbox.recovery_request.lease_fence?.kind ===
        "brokkr-effect-lease-fence" &&
      autonomyDigest(outbox.recovery_request.lease_fence) ===
        outbox.recovery_request.lease_fence_digest,
    "recovery_request_fence_invalid");
    const recoveryEffectPending = [
      "intent", "unknown-journaled", "target-unknown", "recovering",
    ].includes(outbox.stage);
    if (recoveryEffectPending) {
      if (outbox.recovery_request.lease_fence_digest !== currentFenceDigest) {
        outbox.recovery_request.lease_fence = structuredClone(currentFence);
        outbox.recovery_request.lease_fence_digest = currentFenceDigest;
        writeAtomic(outboxFile, outbox);
      }
      assert(outbox.recovery_request.lease_fence_digest === currentFenceDigest &&
        canonicalJson(outbox.recovery_request.lease_fence) ===
          canonicalJson(currentFence), "recovery_request_stale_fence");
    }
    const leaseContext = { journalDir: context.journalDir, lease };
    const historical = context.authoritySnapshot;
    const historicalAuthority = verifyHistoricalAuthority(historical, journal.binding, recovery);
    assert(historicalAuthority.bundle.authorizationDigest === outbox.owner_authorization_digest,
      "recovery_authority_history_mismatch");

    journal = ensureFencedEntry(file, outbox.unknown_entry, leaseContext);
    if (outbox.stage === "intent") {
      recovery.fault?.("after-unknown-append");
      outboxCheckpoint(outboxFile, outbox, "unknown-journaled", recovery, "after-unknown-journal");
    }
    transitionTarget({
      journalDir: context.journalDir, binding: journal.binding,
      bindingDigest: journal.binding_digest, lease, state: "unknown",
    });
    if (outbox.stage === "unknown-journaled") {
      recovery.fault?.("after-target-transition");
      outboxCheckpoint(outboxFile, outbox, "target-unknown", recovery, "after-target-unknown");
    }
    if (["target-unknown", "recovering"].includes(outbox.stage)) {
      if (outbox.stage === "target-unknown") {
        outboxCheckpoint(outboxFile, outbox, "recovering", recovery, "before-recover-invocation");
      }
      assertExecutionLease({
        journalDir: context.journalDir, binding: journal.binding,
        bindingDigest: journal.binding_digest, lease,
      });
      const result = recovery.recover(structuredClone(outbox.recovery_request));
      recovery.fault?.("after-recover-return");
      assert(exactKeys(result, [
        "idempotency_key", "lease_fence_digest", "recovered",
        "safe_state_verified", "quarantine_active", "reason_code",
      ]) && result.idempotency_key === outbox.recovery_request.idempotency_key &&
        result.lease_fence_digest === currentFenceDigest &&
        typeof result.recovered === "boolean" && typeof result.safe_state_verified === "boolean" &&
        typeof result.quarantine_active === "boolean" &&
        (result.reason_code === null || typeof result.reason_code === "string"),
      "recovery_receipt_invalid");
      outbox.recovery_result = structuredClone(result);
      outbox.recovery_error = result.reason_code;
      let at = trustedNow(admission.trustedClock, outbox.unknown_entry.recorded_at);
      let prepared = structuredClone(journal);
      if (result.recovered && result.safe_state_verified && result.quarantine_active) {
        outbox.recover_entry = makeEntry(prepared, {
          phase: "recover", at, actor: journal.binding.recovery_worker_identity,
          contentRef: context.contentRef, quarantine: true,
        });
        prepared.entries.push(outbox.recover_entry);
        at = trustedNow(admission.trustedClock, at);
        outbox.quarantine_entry = makeEntry(prepared, {
          phase: "quarantine", at, actor: journal.binding.recovery_worker_identity,
          contentRef: context.contentRef, quarantine: true,
        });
        prepared.entries.push(outbox.quarantine_entry);
        at = trustedNow(admission.trustedClock, at);
        outbox.terminal_entry = makeEntry(prepared, {
          phase: "disarm", at, actor: journal.binding.recovery_worker_identity,
          contentRef: context.contentRef, reason: outbox.unknown_entry.terminal_reason_digest,
          quarantine: true, coverageTransition: coverageTransition(journal.binding),
        });
      } else {
        outbox.terminal_entry = makeEntry(prepared, {
          phase: "terminally-blocked", at, actor: journal.binding.recovery_worker_identity,
          contentRef: context.contentRef,
          reason: reasonDigest(result.reason_code ?? "recovery-postconditions-failed"),
          quarantine: true, coverageTransition: coverageTransition(journal.binding),
        });
      }
      outboxCheckpoint(outboxFile, outbox, "recovery-recorded", recovery, "after-recovery-result");
    }
    if (outbox.stage === "recovery-recorded") {
      if (outbox.recover_entry) {
        journal = ensureFencedEntry(file, outbox.recover_entry, leaseContext);
        recovery.fault?.("after-recover-journal");
      }
      if (outbox.quarantine_entry) {
        journal = ensureFencedEntry(file, outbox.quarantine_entry, leaseContext);
        recovery.fault?.("after-quarantine-journal");
      }
      outboxCheckpoint(outboxFile, outbox, "journal-recovery-recorded", recovery, "after-recovery-journal-checkpoint");
    }
    if (outbox.stage === "journal-recovery-recorded") {
      const history = recovery.readNarrowingHistory({
        authorization_digest: outbox.owner_authorization_digest,
      });
      const verified = verifiedRawNarrowing({
        history, authorizationDigest: outbox.owner_authorization_digest,
        recoveryRegistry: historicalAuthority.bundle.recoveryRegistry,
      });
      const exact = verified.entries.filter(entry => exactNarrowingEntry(entry, outbox.terminal_entry));
      assert(exact.length <= 1, "runtime_narrowing_duplicate");
      if (exact.length === 0) {
        outbox.previous_narrowing_digest = verified.tailDigest;
        outbox.narrowing_sequence = verified.entries.length + 1;
        writeAtomic(outboxFile, outbox);
        const appended = recovery.appendSignedNarrowing({
          journal_receipt_digest: outbox.terminal_entry.receipt_digest,
          recorded_at: outbox.terminal_entry.recorded_at,
          binding: journal.binding,
          authorization_digest: outbox.owner_authorization_digest,
          previous_entry_digest: outbox.previous_narrowing_digest,
          sequence: outbox.narrowing_sequence,
        });
        const appendedVerified = verifiedRawNarrowing({
          history: appended, authorizationDigest: outbox.owner_authorization_digest,
          recoveryRegistry: historicalAuthority.bundle.recoveryRegistry,
        });
        const appendedExact = appendedVerified.entries.filter(entry => (
          exactNarrowingEntry(entry, outbox.terminal_entry)
        ));
        assert(appendedExact.length === 1, "runtime_narrowing_append_unverified");
        outbox.narrowing_tail_digest = appendedExact[0].entry_digest;
        recovery.fault?.("after-ledger-return");
      } else {
        outbox.narrowing_tail_digest = exact[0].entry_digest;
      }
      outboxCheckpoint(outboxFile, outbox, "narrowing-appended", recovery, "after-ledger-append");
    }
    if (outbox.stage === "narrowing-appended") {
      recovery.advanceNarrowingCheckpoint({
        authorization_digest: outbox.owner_authorization_digest,
        ledger_tail_digest: outbox.narrowing_tail_digest,
        minimum_entries: outbox.narrowing_sequence,
      });
      recovery.fault?.("after-checkpoint-return");
      outboxCheckpoint(outboxFile, outbox, "checkpointed", recovery, "after-checkpoint-advance");
    }
    if (outbox.stage === "checkpointed") {
      const narrowedHistory = recovery.readNarrowingHistory({
        authorization_digest: outbox.owner_authorization_digest,
      });
      const verified = verifyTerminalNarrowing({
        narrowed: narrowedHistory, authorizationDigest: outbox.owner_authorization_digest,
        recoveryRegistry: historicalAuthority.bundle.recoveryRegistry,
        terminal: outbox.terminal_entry,
      });
      assert(verified.tailDigest === outbox.narrowing_tail_digest,
        "recovery_outbox_narrowing_missing");
      journal = ensureFencedEntry(file, outbox.terminal_entry, leaseContext);
      outboxCheckpoint(outboxFile, outbox, "terminal-journaled", recovery, "after-terminal-journal");
    }
    if (outbox.stage === "terminal-journaled") {
      const terminalState = outbox.terminal_entry.phase === "disarm" ? "shadow" : "terminally-blocked";
      transitionTarget({
        journalDir: context.journalDir, binding: journal.binding,
        bindingDigest: journal.binding_digest, lease, state: terminalState, release: true,
      });
      recovery.fault?.("after-terminal-release-before-stage");
      outboxCheckpoint(outboxFile, outbox, "released", recovery, "after-terminal-release");
    }
    if (outbox.stage === "released") {
      outboxCheckpoint(outboxFile, outbox, "complete", recovery, "after-outbox-complete");
    }
    journal = boundedJson(file);
    validateJournalSemantics(journal, {
      schema: context.conformance.schema, constitution: historical.constitution,
      coverage: historical.coverage, ownerAttestations: historical.ownerAttestations,
    });
    return {
      journal, ran: false,
      reason: outbox.terminal_entry.phase === "disarm" ? "recovered-disarmed" : "terminally-blocked",
      recovery_error: outbox.recovery_error,
    };
  });
}
function enterRecovery({ file, journal, context, admission, recovery, code, lastAt, lease }) {
  const outboxFile = `${file}.recovery-outbox.json`;
  if (!readOptional(outboxFile)) {
    const at = trustedNow(admission.trustedClock, lastAt);
    const unknownEntry = journal.entries.at(-1).phase === "unknown" ?
      structuredClone(journal.entries.at(-1)) :
      makeEntry(journal, {
        phase: "unknown", at, actor: journal.binding.watchdog_identity,
        contentRef: context.contentRef, reason: reasonDigest(code), quarantine: true,
      });
    const outbox = {
      kind: "brokkr-autonomy-recovery-outbox", schema_version: "v1",
      binding_digest: journal.binding_digest, stage: "intent",
      owner_authorization_digest: context.bundle.authorizationDigest,
      previous_narrowing_digest: context.narrowing.tailDigest,
      narrowing_sequence: context.narrowing.entries.length + 1,
      narrowing_tail_digest: null,
      recovery_request: {
        idempotency_key: journal.binding.recovery_disarm_id,
        descriptor_digest: journal.binding.recovery.descriptor_digest,
        target_scope_digest: journal.binding.target_scope_digest,
        binding_digest: journal.binding_digest,
        lease_fence: structuredClone(executionLeaseFence(
          journal.binding, journal.binding_digest, lease,
        )),
        lease_fence_digest: autonomyDigest(executionLeaseFence(
          journal.binding, journal.binding_digest, lease,
        )),
      },
      recovery_result: null, recovery_error: null, unknown_entry: unknownEntry,
      recover_entry: null, quarantine_entry: null, terminal_entry: null,
    };
    if (createExclusive(outboxFile, outbox)) {
      recovery.fault?.("after-recovery-intent");
    } else {
      const adopted = boundedJson(outboxFile);
      assert(adopted?.kind === outbox.kind &&
        adopted.schema_version === outbox.schema_version &&
        adopted.binding_digest === outbox.binding_digest &&
        adopted.recovery_request?.idempotency_key ===
          outbox.recovery_request.idempotency_key,
      "recovery_outbox_conflict");
    }
  }
  return finishRecoveryOutbox({
    file, journal, context, admission, recovery, outboxFile, lease,
  });
}

function executionBindingDigest(binding) {
  return autonomyDigest({
    baseline_digest: binding.baseline_digest,
    candidate_digest: binding.candidate_digest,
    config_digest: binding.config_digest,
    evidence_digest: binding.evidence_digest,
    policy_digest: binding.policy_digest,
    postconditions_digest: binding.postconditions_digest,
    target_scope_digest: binding.target_scope_digest,
  });
}
function verifyExecutionPreflight(phases, binding) {
  const result = phases.preflight();
  assert(exactKeys(result, ["execution_digest"]) &&
    result.execution_digest === executionBindingDigest(binding), "execution_binding_substituted");
}
function verifyExecutionCommitBinding(phases, binding) {
  const result = phases.commitBinding();
  assert(exactKeys(result, ["execution_digest"]) &&
    result.execution_digest === executionBindingDigest(binding), "execution_binding_substituted");
}
function runMaintenanceAttempt({
  journalDir, binding, artifacts, admission, phases, recovery, contentRef = "ref:maintenance-candidate",
  reconcile = null,
}) {
  assert(typeof journalDir === "string" && path.isAbsolute(journalDir) && REF.test(contentRef), "attempt_arguments_invalid");
  assert(plain(binding) && plain(artifacts) && typeof artifacts.read === "function" &&
    plain(admission) && plain(phases) && plain(recovery), "attempt_arguments_invalid");
  for (const fn of ["trustedClock", "killSwitch", "evidence", "liveness", "maintenance"]) assert(typeof admission[fn] === "function", "admission_verifier_missing");
  for (const fn of [
    "preflight", "commitBinding", "activateFence", "applyFenced",
    "verify", "safeStateReadback",
  ]) assert(typeof phases[fn] === "function", "maintenance_phase_missing");
  for (const fn of [
    "activateFence", "recover", "appendSignedNarrowing",
    "advanceNarrowingCheckpoint", "readNarrowingHistory",
  ]) {
    assert(typeof recovery[fn] === "function", "maintenance_recovery_missing");
  }
  const file = path.join(journalDir, `${attemptIdentity(binding)}.json`);
  const authorityFile = `${file}.authority.json`;
  const bindingDigest = autonomyDigest(binding);
  let existing = readOptional(file);
  let pendingOutbox = null;
  let authoritySnapshot = readOptional(authorityFile);
  let initialSnapshot = null;
  if (!authoritySnapshot) {
    initialSnapshot = readArtifacts(artifacts);
  } else {
    try { initialSnapshot = readArtifacts(artifacts); } catch {}
  }
  const schema = initialSnapshot?.journalSchema ??
    loadPinnedJournalSchema(LOCAL_SCHEMA_PATH);
  let admitted;
  let recoveryPosture = null;
  if (!authoritySnapshot) {
    assert(!existing, "historical_authority_missing");
    const currentConformance = {
      schema, constitution: initialSnapshot.constitution, coverage: initialSnapshot.coverage,
      ownerAttestations: initialSnapshot.ownerAttestations,
    };
    admitted = verifyAdmission({
      binding, snapshot: initialSnapshot, admission, recovery,
      journalDir, conformance: currentConformance,
    });
    verifyExecutionPreflight(phases, binding);
    authoritySnapshot = historicalAuthoritySnapshot(
      initialSnapshot, recovery, admitted.immutableAdmissionDigest,
    );
    assert(createExclusive(authorityFile, authoritySnapshot), "historical_authority_conflict");
    recovery.fault?.("after-authority-snapshot");
  }
  const persistedAuthority = verifyHistoricalAuthority(authoritySnapshot, existing?.binding ?? binding, recovery);
  const conformance = {
    schema, constitution: authoritySnapshot.constitution, coverage: authoritySnapshot.coverage,
    ownerAttestations: authoritySnapshot.ownerAttestations,
  };
  const context = {
    ...persistedAuthority, policy: classPolicy(persistedAuthority.bundle.constitution),
    contentRef, conformance, journalDir, authoritySnapshot,
  };
  if (existing) {
    validateJournalSemantics(existing, conformance, { allowActive: true });
    const conflicting = canonicalJson(existing.binding) !== canonicalJson(binding);
    pendingOutbox = readOptional(`${file}.recovery-outbox.json`);
    if (pendingOutbox) {
      recoveryPosture = verifyRecoveryPosture({
        binding: existing.binding, snapshot: initialSnapshot, admission,
      });
    }
    if (pendingOutbox?.stage === "complete") {
      assert(!conflicting, "attempt_conflicting_replay");
      assert(TERMINAL.has(existing.entries.at(-1).phase), "recovery_outbox_terminal_missing");
      const state = existing.entries.at(-1).phase === "disarm" ? "shadow" : "terminally-blocked";
      assert(repairTerminalRelease({
        journalDir, binding: existing.binding, bindingDigest: existing.binding_digest, state,
      }), "execution_lease_active");
      return { journal: existing, ran: false, reason: `terminal-${existing.entries.at(-1).phase}` };
    }
    if (pendingOutbox?.stage === "released") {
      assert(!conflicting && TERMINAL.has(existing.entries.at(-1).phase),
        "recovery_outbox_terminal_missing");
      const state = existing.entries.at(-1).phase === "disarm" ? "shadow" : "terminally-blocked";
      assert(repairTerminalRelease({
        journalDir, binding: existing.binding, bindingDigest: existing.binding_digest, state,
      }), "execution_lease_active");
      outboxCheckpoint(
        `${file}.recovery-outbox.json`, pendingOutbox, "complete", recovery,
        "after-outbox-complete",
      );
      return {
        journal: existing, ran: false,
        reason: existing.entries.at(-1).phase === "disarm" ?
          "recovered-disarmed" : "terminally-blocked",
        recovery_error: pendingOutbox.recovery_error,
      };
    }
    if (pendingOutbox?.stage === "terminal-journaled") {
      assert(!conflicting && TERMINAL.has(existing.entries.at(-1).phase),
        "recovery_outbox_terminal_missing");
      const state = existing.entries.at(-1).phase === "disarm" ?
        "shadow" : "terminally-blocked";
      assert(repairTerminalRelease({
        journalDir, binding: existing.binding, bindingDigest: existing.binding_digest, state,
      }), "execution_lease_active");
      outboxCheckpoint(
        `${file}.recovery-outbox.json`, pendingOutbox, "released", recovery,
        "after-terminal-release",
      );
      outboxCheckpoint(
        `${file}.recovery-outbox.json`, pendingOutbox, "complete", recovery,
        "after-outbox-complete",
      );
      return {
        journal: existing, ran: false,
        reason: existing.entries.at(-1).phase === "disarm" ?
          "recovered-disarmed" : "terminally-blocked",
        recovery_error: pendingOutbox.recovery_error,
      };
    }
    if (TERMINAL.has(existing.entries.at(-1).phase) && !pendingOutbox) {
      assert(!conflicting, "attempt_conflicting_replay");
      const state = existing.entries.at(-1).phase === "commit" ?
        existing.binding.admission_binding_state :
        existing.entries.at(-1).phase === "disarm" ? "shadow" : "terminally-blocked";
      if (!repairTerminalRelease({
        journalDir, binding: existing.binding, bindingDigest: existing.binding_digest, state,
      })) return { journal: existing, ran: false, reason: "execution-lease-active" };
      return { journal: existing, ran: false, reason: `terminal-${existing.entries.at(-1).phase}` };
    }
  }

  let recoveryOnly = false;
  if (!admitted && pendingOutbox) {
    admitted = {
      now: recoveryPosture.now,
      immutableAdmissionDigest: authoritySnapshot.immutableAdmissionDigest,
    };
    recoveryOnly = true;
  } else if (!admitted) {
    recoveryPosture = verifyRecoveryPosture({
      binding: existing?.binding ?? binding, snapshot: initialSnapshot, admission,
    });
    admitted = {
      now: recoveryPosture.now,
      immutableAdmissionDigest: authoritySnapshot.immutableAdmissionDigest,
    };
    recoveryOnly = recoveryPosture.mustRecover ||
      recoveryPosture.authorityDigest !==
        persistedAuthority.bundle.authorizationDigest ||
      recoveryPosture.coverageDigest !==
        persistedAuthority.bundle.coverage.registry_digest ||
      recoveryPosture.narrowingTailDigest !== persistedAuthority.narrowing.tailDigest;
  }
  const activeBinding = existing?.binding ?? binding;
  const activeBindingDigest = existing?.binding_digest ?? bindingDigest;
  const watchContinuation = existing?.entries.at(-1).phase === "watch" &&
    pendingOutbox === null;
  const claimed = claimTarget({
    journalDir, binding: activeBinding, bindingDigest: activeBindingDigest,
    now: admitted.now, policy: context.policy, resumeWatch: watchContinuation,
  });
  if (!claimed.acquired) return {
    journal: existing, ran: false, reason: "execution-lease-active",
  };
  const lease = claimed.lease;
  recovery.fault?.(claimed.transferred ? "after-lease-transfer" : "after-lease-claim");

  let journal = existing;
  if (!journal) {
    journal = {
      kind: "autonomous-mutation-journal", schema_version: "v1", journal_id: binding.mutation_id,
      domain: DOMAIN, constitution_digest: authoritySnapshot.constitution.constitution_digest,
      binding: structuredClone(binding), binding_digest: bindingDigest, entries: [], extensions: [],
    };
    journal.entries.push(makeEntry(journal, {
      phase: "prepare", at: admitted.now, actor: binding.controller_identity, contentRef,
    }));
    validateJournalSemantics(journal, conformance, { allowActive: true });
    assert(createExclusive(file, journal), "journal_prepare_conflict");
    recovery.fault?.("after-prepare-journal");
  }
  const leaseFence = activateResourceFence(
    phases, activeBinding, activeBindingDigest, lease,
  );
  activateResourceFence(recovery, activeBinding, activeBindingDigest, lease);
  if (existing) {
    if (canonicalJson(journal.binding) !== canonicalJson(binding)) {
      return enterRecovery({
        file, journal, context, admission, recovery, lease,
        code: "attempt-conflicting-replay", lastAt: journal.entries.at(-1).recorded_at,
      });
    }
    if (readOptional(`${file}.recovery-outbox.json`)) {
      return finishRecoveryOutbox({
        file, journal, context, admission, recovery,
        outboxFile: `${file}.recovery-outbox.json`, lease,
      });
    }
    if (!recoveryOnly) {
      try {
        const resumedAdmission = verifyAdmission({
          binding: journal.binding, snapshot: initialSnapshot, admission, recovery,
          journalDir, conformance,
        });
        recoveryOnly = resumedAdmission.immutableAdmissionDigest !==
          authoritySnapshot.immutableAdmissionDigest;
      } catch {
        recoveryOnly = true;
      }
    }
    if (recoveryOnly) {
      return enterRecovery({
        file, journal, context, admission, recovery, lease,
        code: "current-posture-requires-recovery",
        lastAt: journal.entries.at(-1).recorded_at,
      });
    }
    if (!watchContinuation) {
      let reconciliation;
      try {
        if (typeof reconcile !== "function") {
          fail("attempt-reconciliation-unavailable");
        }
        reconciliation = reconcile({
          phase: journal.entries.at(-1).phase, lease_epoch: lease.epoch,
        });
        assert(exactKeys(reconciliation, ["state"]) &&
          ["not-applied", "applied", "indeterminate"].includes(
            reconciliation.state,
          ), "attempt_reconciliation_invalid");
      } catch (error) {
        return enterRecovery({
          file, journal, context, admission, recovery, lease,
          code: String(error?.code ?? error?.message ??
            "attempt-reconciliation-failed"),
          lastAt: journal.entries.at(-1).recorded_at,
        });
      }
      if (journal.entries.at(-1).phase !== "prepare" ||
          reconciliation.state !== "not-applied") {
        return enterRecovery({
          file, journal, context, admission, recovery, lease,
          code: `reconcile-${journal.entries.at(-1).phase}-${reconciliation.state}`,
          lastAt: journal.entries.at(-1).recorded_at,
        });
      }
    }
  }

  let at = trustedNow(admission.trustedClock, journal.entries.at(-1).recorded_at);
  try {
    if (watchContinuation &&
        Date.parse(admitted.now) < Date.parse(binding.canary.watch_deadline)) {
      transitionTarget({
        journalDir, binding, bindingDigest, lease,
        state: "watching", release: true,
      });
      return { journal, ran: false, reason: "watching" };
    }
    if (!watchContinuation) {
      const beforeApplySnapshot = readArtifacts(artifacts);
      const beforeApply = verifyAdmission({
        binding, snapshot: beforeApplySnapshot, admission, recovery,
        journalDir, conformance,
      });
      assert(beforeApply.immutableAdmissionDigest ===
        authoritySnapshot.immutableAdmissionDigest,
      "immutable_admission_drifted");
      verifyExecutionPreflight(phases, binding);
      checkKillSwitch(admission.killSwitch, binding);
      assertExecutionLease({ journalDir, binding, bindingDigest, lease });
      const applied = phases.applyFenced({
        lease_fence: structuredClone(leaseFence),
        lease_fence_digest: autonomyDigest(leaseFence),
      });
      assertExecutionLease({ journalDir, binding, bindingDigest, lease });
      assert(applied?.applied === true, "maintenance_apply_failed");
      at = trustedNow(admission.trustedClock, at);
      journal = appendFenced(file, journal, {
        phase: "apply", at, actor: binding.controller_identity, contentRef,
      }, { journalDir, lease });
      checkKillSwitch(admission.killSwitch, binding);
      const verified = phases.verify();
      assert(verified?.verified === true, "maintenance_verify_failed");
      at = trustedNow(admission.trustedClock, at);
      journal = appendFenced(file, journal, {
        phase: "verify", at, actor: binding.controller_identity, contentRef,
      }, { journalDir, lease });
      checkKillSwitch(admission.killSwitch, binding);
      assert(Date.parse(at) <= Date.parse(binding.canary.watch_deadline),
        "maintenance_watch_started_late");
      journal = appendFenced(file, journal, {
        phase: "watch", at, actor: binding.controller_identity, contentRef,
      }, { journalDir, lease });
      transitionTarget({
        journalDir, binding, bindingDigest, lease,
        state: "watching", release: true,
      });
      return { journal, ran: true, reason: "watching" };
    }
    assert(Date.parse(at) >= Date.parse(binding.canary.watch_deadline),
      "maintenance_watch_incomplete");
    checkKillSwitch(admission.killSwitch, binding);
    const readback = phases.safeStateReadback();
    assert(readback?.safe === true && readback.postconditions_digest === binding.postconditions_digest, "maintenance_safe_state_unverified");
    const beforeCommitSnapshot = readArtifacts(artifacts);
    const beforeCommit = verifyAdmission({
      binding, snapshot: beforeCommitSnapshot, admission, recovery, journalDir, conformance,
    });
    assert(beforeCommit.immutableAdmissionDigest === authoritySnapshot.immutableAdmissionDigest,
      "immutable_admission_drifted");
    verifyExecutionCommitBinding(phases, binding);
    at = trustedNow(admission.trustedClock, at);
    assert(Date.parse(at) <= Date.parse(binding.deadline), "attempt_deadline_closed");
    journal = appendFenced(file, journal, {
      phase: "commit", at, actor: binding.controller_identity, contentRef,
    }, { journalDir, lease });
    recovery.fault?.("after-commit-journal");
    validateJournalSemantics(journal, conformance);
    transitionTarget({
      journalDir, binding, bindingDigest, lease,
      state: binding.admission_binding_state, release: true,
    });
    recovery.fault?.("after-commit-release");
    return { journal, ran: true, reason: "committed" };
  } catch (error) {
    return enterRecovery({
      file, journal, context, admission, recovery, lease,
      code: String(error?.code ?? error?.message ?? "maintenance-phase-error"),
      lastAt: at,
    });
  }
}

const DEBIAN_API = (() => {
  const MAX_PLAN_AGE_MS = 5 * 60 * 1000;
  const MAX_EVENTS = 24;
  const MAX_INVENTORY_BYTES = 16_384;
  const hash = value => `sha256:${crypto.createHash("sha256")
    .update(canonicalJson(value)).digest("hex")}`;
  const parseUtc = value => strictUtc(value) ? Date.parse(value) :
    fail("invalid_timestamp");
  const read = file => {
    try { return JSON.parse(fs.readFileSync(file, "utf8")); }
    catch (error) { if (error.code === "ENOENT") return null; throw error; }
  };
  const write = (file, value) => {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    const temporary = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
    const fd = fs.openSync(temporary, "wx", 0o600);
    try {
      fs.writeFileSync(fd, `${canonicalJson(value)}\n`);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(temporary, file);
    fsyncDirectory(path.dirname(file));
  };
  const safeDetail = value => {
    const text = value && typeof value === "object" ?
      canonicalJson(value) : String(value ?? "");
    return {
      digest: hash(text), bytes: Buffer.byteLength(text),
      summary: typeof value?.code === "string" ?
        value.code.slice(0, 96) :
        typeof value?.ok === "boolean" ? `ok=${value.ok}` : "adapter-evidence",
    };
  };
  const inventory = value => {
    if (!plain(value)) fail("inventory_invalid");
    const allowed = new Set([
      "kernel", "packages", "reboot_required", "dpkg_status",
    ]);
    const output = {};
    for (const [key, item] of Object.entries(value)) {
      if (!allowed.has(key)) fail("inventory_field_not_allowed");
      if (typeof item === "string" && item.length <= 256) output[key] = item;
      else if (typeof item === "boolean") output[key] = item;
      else if (Array.isArray(item) && item.length <= 256 &&
          item.every(element => (
            typeof element === "string" && element.length <= 256
          ))) output[key] = [...item].sort();
      else fail("inventory_invalid");
    }
    if (Buffer.byteLength(canonicalJson(output)) > MAX_INVENTORY_BYTES) {
      fail("inventory_too_large");
    }
    return output;
  };
  const deepFreeze = value => {
    if (value && typeof value === "object" && !Object.isFrozen(value)) {
      Object.freeze(value);
      for (const child of Object.values(value)) deepFreeze(child);
    }
    return value;
  };
  const assertPolicy = policy => {
    if (!policy || policy.kind !== "maintenance-policy" ||
        policy.schema_version !== "v1" ||
        typeof policy.policy_id !== "string" ||
        policy.policy_digest !== policyDigest(policy)) fail("policy_invalid");
    return policy;
  };
  const verifyPlan = ({ plan, policy, nowMs, nodeId }) => {
    if (!plan || plan.kind !== "brokkr-maintenance-plan" ||
        plan.schema_version !== "v1" || plan.outcome !== "planned") {
      fail("plan_not_planned");
    }
    const copy = structuredClone(plan);
    const supplied = copy.plan_digest;
    delete copy.plan_digest;
    if (supplied !== hash(copy)) fail("plan_digest_invalid");
    if (!plain(plan.decision) ||
        !["on_schedule", "run_deferred"].includes(plan.decision.effect) ||
        !Array.isArray(plan.blockers) || plan.blockers.length !== 0 ||
        !Array.isArray(plan.hook_gaps) ||
        !Array.isArray(plan.unmet_policy_classes) ||
        typeof plan.inventory_evidence_id !== "string" ||
        typeof plan.running_kernel !== "string" ||
        plan.node_id !== nodeId || !policy.selector.node_ids.includes(nodeId) ||
        plan.policy_digest !== policy.policy_digest ||
        plan.policy_id !== policy.policy_id) fail("plan_not_authorized");
    const age = nowMs - parseUtc(plan.created_at);
    if (age < 0 || age > MAX_PLAN_AGE_MS) fail("plan_stale");
    const gates = plan.gates;
    if (!plain(gates) || gates.package_manager_lock !== "unlocked" ||
        gates.disk !== "sufficient" ||
        !["mains", "not_applicable"].includes(gates.power) ||
        gates.clock !== "synchronized" ||
        gates.workload_hooks !== "not_applicable" ||
        plan.hook_gaps.length !== 0 ||
        !Array.isArray(plan.candidates) || plan.candidates.length < 1 ||
        !plan.candidates.every(candidate => (
          candidate?.eligible === true &&
          ["security", "bugfix"].includes(candidate.class) &&
          candidate.source === "distro_repository" &&
          policy.updates.allowed_classes.includes(candidate.class) &&
          policy.updates.allowed_sources.includes(candidate.source)
        ))) fail("plan_gates_not_safe");
  };
  const currentAdmission = ({ plan, policy, nodeId, adapters }) => {
    const clock = adapters.clock();
    if (!clock || clock.synchronized !== true || !strictUtc(clock.now)) {
      fail("clock_uncertain");
    }
    const current = assertPolicy(adapters.currentPolicy());
    assertPolicy(policy);
    if (current.policy_id !== policy.policy_id ||
        current.policy_digest !== policy.policy_digest) {
      fail("policy_changed_before_mutation");
    }
    if (current.state?.enabled !== true ||
        current.state?.hold?.active === true ||
        adapters.hold().active === true) fail("held");
    const status = windowStatus(current, parseUtc(clock.now));
    if (!status.eligible) fail("window_closed_before_mutation");
    verifyPlan({ plan, policy: current, nowMs: parseUtc(clock.now), nodeId });
    return {
      policy: current, now: clock.now,
      remaining_window_ms:
        Date.parse(status.occurrence.end) - parseUtc(clock.now),
    };
  };

  function deriveDebianAutonomyExecution({
    plan, policy, target, inventory: preState, adapterRevisionDigest,
    postconditions,
  }) {
    assertPolicy(policy);
    if (!target ||
        Object.keys(target).sort().join(",") !==
          "node_id,non_pillar,platform" ||
        target.platform !== "debian" || target.non_pillar !== true ||
        target.node_id !== plan?.node_id ||
        !DIGEST.test(adapterRevisionDigest) || !plain(postconditions)) {
      fail("autonomy_execution_out_of_scope");
    }
    const planCopy = structuredClone(plan);
    const suppliedPlanDigest = planCopy?.plan_digest;
    delete planCopy?.plan_digest;
    if (!DIGEST.test(suppliedPlanDigest) ||
        suppliedPlanDigest !== hash(planCopy) ||
        plan.gates?.workload_hooks !== "not_applicable" ||
        !Array.isArray(plan.candidates) || plan.candidates.length < 1 ||
        !plan.candidates.every(item => (
          item?.eligible === true &&
          ["security", "bugfix"].includes(item.class) &&
          item.source === "distro_repository"
        )) || policy.reboot?.policy !== "never" ||
        !Array.isArray(policy.updates?.allowed_classes) ||
        !policy.updates.allowed_classes.every(item => (
          ["security", "bugfix"].includes(item)
        )) || !Array.isArray(policy.updates?.allowed_sources) ||
        !policy.updates.allowed_sources.every(item => (
          item === "distro_repository"
        ))) fail("autonomy_execution_out_of_scope");
    const normalizedPreState = inventory(preState);
    const normalizedPostconditions = inventory(postconditions);
    const targetScopeDigest = hash({
      node_id: target.node_id, platform: target.platform,
    });
    const configDigest = hash({
      adapter_revision_digest: adapterRevisionDigest,
      node_id: target.node_id, target_scope_digest: targetScopeDigest,
    });
    const baselineDigest = hash({
      inventory: normalizedPreState, node_id: target.node_id,
      target_scope_digest: targetScopeDigest,
    });
    const postconditionsDigest = hash(normalizedPostconditions);
    const evidenceDigest = hash({
      baseline_digest: baselineDigest,
      candidate_digest: suppliedPlanDigest, config_digest: configDigest,
      policy_digest: policy.policy_digest,
    });
    const executionRequest = {
      kind: "brokkr-bounded-debian-maintenance-request",
      schema_version: "v1", target: structuredClone(target),
      candidates: structuredClone(plan.candidates),
      config: {
        adapter_revision_digest: adapterRevisionDigest,
        plan_digest: suppliedPlanDigest,
        policy_digest: policy.policy_digest,
        no_reboot: true, no_drain: true,
      },
      pre_state: normalizedPreState,
      expected_postconditions: normalizedPostconditions,
    };
    return {
      node_id: target.node_id, target_scope_digest: targetScopeDigest,
      candidate_digest: suppliedPlanDigest, config_digest: configDigest,
      evidence_digest: evidenceDigest, policy_digest: policy.policy_digest,
      baseline_digest: baselineDigest,
      postconditions_digest: postconditionsDigest,
      pre_state: normalizedPreState,
      postconditions: normalizedPostconditions,
      adapter_revision_digest: adapterRevisionDigest,
      execution_request: executionRequest,
      execution_request_digest: hash(executionRequest),
    };
  }

  const execute = ({
    plan, policy, nodeId, journalFile, adapters, boundInitialInventory,
    boundExecutionRequest, leaseFence,
  }) => {
    for (const name of [
      "applyFenced", "afterInventory", "currentPolicy", "clock", "hold",
      "substrateHealth",
    ]) if (typeof adapters?.[name] !== "function") {
      fail("adapter_contract_invalid");
    }
    if (read(journalFile) !== null) fail("journal_already_exists");
    const initial = currentAdmission({ plan, policy, nodeId, adapters });
    if (policy.reboot?.policy !== "never" ||
        plan.gates?.workload_hooks !== "not_applicable" ||
        !leaseFence || leaseFence.kind !== "brokkr-effect-lease-fence" ||
        leaseFence.schema_version !== "v1" ||
        !Number.isSafeInteger(leaseFence.epoch) || leaseFence.epoch < 1 ||
        !DIGEST.test(leaseFence.target_scope_digest) ||
        !DIGEST.test(leaseFence.binding_digest) ||
        typeof leaseFence.holder_token !== "string" ||
        !strictUtc(leaseFence.expires_at) ||
        boundExecutionRequest?.kind !==
          "brokkr-bounded-debian-maintenance-request" ||
        boundExecutionRequest.schema_version !== "v1" ||
        boundExecutionRequest.config?.no_reboot !== true ||
        boundExecutionRequest.config?.no_drain !== true) {
      fail("autonomous_adapter_capability_invalid");
    }
    const journal = {
      kind: "brokkr-debian-mutation-journal", schema_version: "v1",
      plan_id: plan.plan_id, plan_digest: plan.plan_digest,
      policy_digest: policy.policy_digest, node_id: nodeId,
      execution_request_digest: hash(boundExecutionRequest),
      lease_epoch: leaseFence.epoch, adapter_receipt_digest: null,
      unmet_policy_classes: plan.unmet_policy_classes.map(item => ({
        class: String(item.class ?? "unknown").slice(0, 64),
        reason: String(item.reason ?? "unspecified").slice(0, 96),
      })),
      outcome: "running", events: [],
      before_inventory: inventory(boundInitialInventory),
      after_inventory: null, reversal: null, failure: null,
    };
    let eventAt = initial.now;
    const event = (phase, outcome, detail) => {
      if (journal.events.length >= MAX_EVENTS) fail("journal_event_limit");
      journal.events.push({
        at: eventAt, phase, outcome, detail: safeDetail(detail),
      });
      write(journalFile, journal);
    };
    try {
      event("inventory_before", "succeeded", journal.before_inventory);
      const immediate = currentAdmission({ plan, policy, nodeId, adapters });
      eventAt = immediate.now;
      event("admission_revalidated", "succeeded", {});
      const limits = {
        timeout_ms: durationToMs(policy.execution_limits.timeout),
        remaining_window_ms: immediate.remaining_window_ms,
      };
      const invocation = deepFreeze({
        kind: "brokkr-bounded-debian-adapter-invocation",
        schema_version: "v1",
        execution_request: structuredClone(boundExecutionRequest),
        execution_request_digest: hash(boundExecutionRequest),
        lease_fence: structuredClone(leaseFence),
        lease_fence_digest: hash(leaseFence), limits,
      });
      event("apply_started", "started", invocation);
      const applied = adapters.applyFenced(invocation);
      const receipt = structuredClone(applied);
      const suppliedReceiptDigest = receipt?.receipt_digest;
      delete receipt?.receipt_digest;
      if (!exactKeys(receipt, [
        "ok", "elapsed_ms", "execution_request_digest",
        "lease_fence_digest", "reboot_required",
      ]) || receipt.ok !== true ||
          receipt.execution_request_digest !== hash(boundExecutionRequest) ||
          receipt.lease_fence_digest !== hash(leaseFence) ||
          receipt.reboot_required !== false ||
          !Number.isFinite(receipt.elapsed_ms) || receipt.elapsed_ms < 0 ||
          receipt.elapsed_ms >
            Math.min(limits.timeout_ms, limits.remaining_window_ms) ||
          suppliedReceiptDigest !== hash(receipt)) {
        fail("adapter_receipt_unbound");
      }
      journal.adapter_receipt_digest = suppliedReceiptDigest;
      event("apply", "succeeded", applied);
      const substrate = adapters.substrateHealth();
      event("substrate_health", substrate?.ok ? "succeeded" : "failed",
        substrate);
      if (!substrate?.ok) fail("substrate_health_failed");
      journal.after_inventory = inventory(adapters.afterInventory());
      event("inventory_after", "succeeded", journal.after_inventory);
      journal.outcome = "succeeded";
      write(journalFile, journal);
      return { outcome: "succeeded", journal };
    } catch (error) {
      journal.failure = {
        code: String(error?.code ?? "executor_failed").slice(0, 96),
        diagnostic: safeDetail({
          message: String(error?.message ?? error).slice(0, 256),
        }),
      };
      journal.outcome = "operator_recovery_required";
      write(journalFile, journal);
      return {
        outcome: journal.outcome, reason: journal.failure.code, journal,
      };
    }
  };

  function runDebianMaintenance(options) {
    const {
      binding, attemptJournalDir, artifacts, admission, recovery,
      reconcile = null, target, expectedPostconditions, plan, policy,
      nodeId = plan?.node_id, adapters,
    } = options ?? {};
    if (!binding || typeof attemptJournalDir !== "string" || !artifacts ||
        !admission || !recovery || !target || !expectedPostconditions ||
        !plan || !policy || !adapters ||
        typeof adapters.revisionDigest !== "function" ||
        typeof adapters.targetMetadata !== "function") {
      fail("attempt_journal_contract_invalid");
    }
    const journalFile = path.join(
      attemptJournalDir, "mutation", `${binding.attempt_id}.json`,
    );
    let executionResult = null;
    let captured = null;
    const staticTarget = () => {
      const actual = adapters.targetMetadata();
      if (canonicalJson(actual) !== canonicalJson(target) ||
          actual.node_id !== nodeId ||
          canonicalJson(adapters.currentPolicy()) !== canonicalJson(policy)) {
        fail("execution_binding_substituted");
      }
      return actual;
    };
    const accept = actual => {
      for (const field of [
        "target_scope_digest", "candidate_digest", "config_digest",
        "evidence_digest", "policy_digest", "baseline_digest",
        "postconditions_digest",
      ]) if (binding[field] !== actual[field]) {
        fail("execution_binding_substituted");
      }
      captured = actual;
      return {
        execution_digest: executionBindingDigest(actual),
      };
    };
    const capture = () => accept(deriveDebianAutonomyExecution({
      plan, policy, target: staticTarget(),
      inventory: inventory(adapters.inventory()),
      adapterRevisionDigest: adapters.revisionDigest(),
      postconditions: expectedPostconditions,
    }));
    const commitBinding = () => {
      const actualTarget = staticTarget();
      if (!captured) {
        const mutation = read(journalFile);
        if (mutation?.outcome !== "succeeded" ||
            !mutation.before_inventory) {
          fail("execution_binding_evidence_missing");
        }
        const actual = deriveDebianAutonomyExecution({
          plan, policy, target: actualTarget,
          inventory: mutation.before_inventory,
          adapterRevisionDigest: adapters.revisionDigest(),
          postconditions: expectedPostconditions,
        });
        if (mutation.execution_request_digest !==
            actual.execution_request_digest) {
          fail("execution_binding_substituted");
        }
        return accept(actual);
      }
      if (adapters.revisionDigest() !== captured.adapter_revision_digest) {
        fail("execution_binding_substituted");
      }
      return { execution_digest: executionBindingDigest(captured) };
    };
    return runMaintenanceAttempt({
      journalDir: attemptJournalDir, binding, artifacts, admission, recovery,
      reconcile,
      phases: {
        preflight: capture, commitBinding,
        activateFence: fence => {
          if (typeof adapters.activateFence !== "function") {
            fail("adapter_fence_capability_missing");
          }
          return adapters.activateFence(
            deepFreeze(structuredClone(fence)),
          );
        },
        applyFenced: ({ lease_fence, lease_fence_digest }) => {
          if (lease_fence_digest !== hash(lease_fence)) {
            fail("effect_lease_fence_unconfirmed");
          }
          executionResult = execute({
            plan, policy, nodeId, journalFile, adapters,
            boundInitialInventory: captured.pre_state,
            boundExecutionRequest: deepFreeze(
              structuredClone(captured.execution_request),
            ),
            leaseFence: deepFreeze(structuredClone(lease_fence)),
          });
          if (executionResult.outcome !== "succeeded") {
            fail("executor_postconditions_unmet");
          }
          return { applied: true };
        },
        verify: () => ({
          verified: executionResult?.outcome === "succeeded",
        }),
        safeStateReadback: () => {
          const fresh = inventory(adapters.inventory());
          return {
            safe: hash(fresh) === binding.postconditions_digest,
            postconditions_digest: hash(fresh),
          };
        },
      },
    });
  }
  return { deriveDebianAutonomyExecution, runDebianMaintenance };
})();

export const {
  deriveDebianAutonomyExecution,
  runDebianMaintenance,
} = DEBIAN_API;
