// Authoritative Brokkr journal for Grimnir ADR-008's bounded no-reboot
// security/bugfix maintenance class. No production authority is bundled here:
// every attempt must independently verify W0.1 owner authorization, coverage,
// owner attestation, recovery keys, and the protected narrowing tail.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  autonomyDigest, canonicalJson, effectiveTargetState, strictUtc,
  verifyOwnerAuthorizationBundle, verifyRuntimeNarrowingLedger,
} from "./lib/autonomy-authorization.mjs";

const DOMAIN = "no-reboot-security-bugfix-maintenance";
const SCHEMA_ID = "https://grimnir.gille.ai/contracts/autonomous-mutation-journal/v1/schema.json";
const SCHEMA_SHA256 = "237eb4336a84645b88319b4cbd5112b6dd0c3a3a97e7343e0fdc73869b1cac3b";
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
function claimExclusive(file, digest) {
  let fd;
  try { fd = fs.openSync(file, "wx", 0o600); }
  catch (error) { if (error.code === "EEXIST") return false; throw error; }
  try { fs.writeFileSync(fd, `${digest}\n`); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fsyncDirectory(path.dirname(file));
  return true;
}
const stateRoot = journalDir => path.join(journalDir, ".autonomy-state");
const targetKey = binding => binding.target_scope_digest.slice("sha256:".length);
const domainStateFile = journalDir => path.join(stateRoot(journalDir), "domain-state.json");
const domainLockDir = journalDir => path.join(stateRoot(journalDir), "domain-state.lock");
const executionClaimFile = (journalDir, binding, kind) => (
  path.join(stateRoot(journalDir), `execution-${binding.attempt_id}-${kind}.json`)
);
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
function claimTarget({ journalDir, binding, now, policy }) {
  return withExclusiveDirectory(domainLockDir(journalDir), "domain_claim_contended", () => {
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
    if (domain.active_attempt_id !== binding.attempt_id) {
      assert(domain.active_attempt_id === null && domain.active_target_scope_digest === null,
        "domain_concurrency_exceeded");
      const nowMs = Date.parse(now);
      domain.recent_starts = domain.recent_starts.filter(start => (
        strictUtc(start) && nowMs - Date.parse(start) < policy.bounds.attempt_window_seconds * 1000
      ));
      assert(!domain.recent_starts.some(start => (
        nowMs - Date.parse(start) < policy.bounds.min_seconds_between_attempts * 1000
      )), "attempt_interval_exceeded");
      assert(domain.recent_starts.length < policy.bounds.max_attempts_per_window,
        "attempt_window_exceeded");
      domain.active_target_scope_digest = binding.target_scope_digest;
      domain.active_attempt_id = binding.attempt_id;
      domain.recent_starts.push(now);
      domain.revision += 1;
      writeAtomic(domainFile, domain);
    } else {
      assert(domain.active_target_scope_digest === binding.target_scope_digest,
        "domain_target_mismatch");
    }
    const key = targetKey(binding);
    const current = domain.targets[key] ?? {
      state: binding.admission_binding_state, active_attempt_id: null,
      active_mutation_id: null, last_started_at: null, proposal_attempts: {},
    };
    assert(exactKeys(current, [
      "state", "active_attempt_id", "active_mutation_id", "last_started_at", "proposal_attempts",
    ]) && plain(current.proposal_attempts), "target_state_invalid");
    if (current.active_attempt_id === binding.attempt_id) return current;
    assert(current.state === binding.admission_binding_state, "target_state_not_armed");
    assert(current.active_attempt_id === null && current.active_mutation_id === null, "target_concurrency_exceeded");
    const attempts = current.proposal_attempts[binding.mutation_id] ?? 0;
    assert(attempts < policy.bounds.max_attempts, "proposal_attempts_exceeded");
    current.active_attempt_id = binding.attempt_id;
    current.active_mutation_id = binding.mutation_id;
    current.last_started_at = now;
    current.proposal_attempts[binding.mutation_id] = attempts + 1;
    domain.targets[key] = current;
    domain.revision += 1;
    writeAtomic(domainFile, domain);
    return current;
  });
}
function transitionTarget({ journalDir, binding, state, release = false }) {
  return withExclusiveDirectory(domainLockDir(journalDir), "domain_state_contended", () => {
    const domainFile = domainStateFile(journalDir);
    const domain = readOptional(domainFile);
    const current = domain?.targets?.[targetKey(binding)];
    assert(current?.active_attempt_id === binding.attempt_id &&
      domain.active_attempt_id === binding.attempt_id &&
      domain.active_target_scope_digest === binding.target_scope_digest, "target_state_owner_mismatch");
    current.state = state;
    if (release) {
      current.active_attempt_id = null;
      current.active_mutation_id = null;
    }
    if (release) {
      domain.active_attempt_id = null;
      domain.active_target_scope_digest = null;
    }
    domain.revision += 1;
    writeAtomic(domainFile, domain);
    return current;
  });
}
function claimExecution({ journalDir, binding, kind, bindingDigest }) {
  const file = executionClaimFile(journalDir, binding, kind);
  return createExclusive(file, {
    kind: "brokkr-autonomy-execution-claim", schema_version: "v1",
    attempt_id: binding.attempt_id, target_scope_digest: binding.target_scope_digest,
    binding_digest: bindingDigest, claim_kind: kind,
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
  assert(binding.risk_scope === DOMAIN && binding.recovery.class === "R-forward" &&
    binding.recovery.worker_identity === binding.recovery_worker_identity &&
    binding.recovery.disarms_after_action === true, "journal_recovery_binding_invalid");
  assert(binding.canary.scope_digest === binding.target_scope_digest && binding.canary.target_count === 1 &&
    Date.parse(binding.canary.watch_deadline) <= Date.parse(binding.deadline), "journal_canary_invalid");
  assert(Date.parse(binding.deadline) - Date.parse(journal.entries[0].recorded_at) <= policy.bounds.deadline_seconds * 1000, "journal_deadline_bound_invalid");
  let previous = null;
  for (let index = 0; index < journal.entries.length; index += 1) {
    const entry = journal.entries[index];
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
    tail.target_scope_digest === terminal.coverage_transition.target_scope_digest &&
    tail.recovery_worker_identity === terminal.coverage_transition.actor_identity &&
    tail.to_state === "shadow", "runtime_narrowing_not_consumed");
  return verified;
}
function finishRecoveryOutbox({ file, journal, context, artifacts, recovery, outboxFile }) {
  return withExclusiveDirectory(`${outboxFile}.lock`, "recovery_outbox_contended", () => {
    let outbox = boundedJson(outboxFile);
    assert(exactKeys(outbox, [
      "kind", "schema_version", "binding_digest", "stage", "terminal_entry",
      "recovery_error", "narrowing_tail_digest", "owner_authorization_digest",
      "previous_narrowing_digest", "narrowing_sequence",
    ]) && outbox.kind === "brokkr-autonomy-recovery-outbox" &&
      outbox.schema_version === "v1" && outbox.binding_digest === journal.binding_digest,
    "recovery_outbox_invalid");
    if (outbox.stage === "prepared") {
      const narrowed = recovery.appendSignedNarrowing({
        journal_receipt_digest: outbox.terminal_entry.receipt_digest,
        recorded_at: outbox.terminal_entry.recorded_at,
        binding: journal.binding,
        authorization_digest: outbox.owner_authorization_digest,
        previous_entry_digest: outbox.previous_narrowing_digest,
        sequence: outbox.narrowing_sequence,
      });
      const historical = recovery.readAuthorityHistory({
        authorization_digest: outbox.owner_authorization_digest,
      });
      const historicalBundle = verifyOwnerAuthorizationBundle(historical);
      assert(historicalBundle.authorizationDigest === outbox.owner_authorization_digest,
        "recovery_authority_history_mismatch");
      const verified = verifyTerminalNarrowing({
        narrowed, authorizationDigest: outbox.owner_authorization_digest,
        recoveryRegistry: historicalBundle.recoveryRegistry, terminal: outbox.terminal_entry,
      });
      outbox.stage = "narrowing-verified";
      outbox.narrowing_tail_digest = verified.tailDigest;
      writeAtomic(outboxFile, outbox);
      recovery.fault?.("after-narrowing-checkpoint");
    }
    const historical = recovery.readAuthorityHistory({
      authorization_digest: outbox.owner_authorization_digest,
    });
    const historicalBundle = verifyOwnerAuthorizationBundle(historical);
    assert(historicalBundle.authorizationDigest === outbox.owner_authorization_digest,
      "recovery_authority_history_mismatch");
    const narrowedHistory = recovery.readNarrowingHistory({
      authorization_digest: outbox.owner_authorization_digest,
    });
    const verifiedCurrent = verifyRuntimeNarrowingLedger({
      ledger: narrowedHistory.ledger, recoveryRegistry: historicalBundle.recoveryRegistry,
      authorizationDigest: outbox.owner_authorization_digest,
      tailCheckpoint: narrowedHistory.tailCheckpoint,
    });
    const tail = verifiedCurrent.entries.at(-1);
    assert(tail?.entry_digest === outbox.narrowing_tail_digest &&
      tail.journal_receipt_digest === outbox.terminal_entry.receipt_digest,
    "recovery_outbox_narrowing_missing");
    let current = boundedJson(file);
    if (current.entries.at(-1).receipt_digest !== outbox.terminal_entry.receipt_digest) {
      current = appendExact(file, current, outbox.terminal_entry);
      recovery.fault?.("after-terminal-journal");
    }
    const terminalState = outbox.terminal_entry.phase === "disarm" ? "shadow" : "terminally-blocked";
    transitionTarget({ journalDir: context.journalDir, binding: journal.binding, state: terminalState });
    outbox.stage = "complete";
    writeAtomic(outboxFile, outbox);
    recovery.fault?.("after-outbox-complete");
    validateJournalSemantics(current, {
      schema: context.conformance.schema, constitution: historical.constitution,
      coverage: historical.coverage, ownerAttestations: historical.ownerAttestations,
    });
    return {
      journal: current, ran: false,
      reason: outbox.terminal_entry.phase === "disarm" ? "recovered-disarmed" : "terminally-blocked",
      recovery_error: outbox.recovery_error,
    };
  });
}
function enterRecovery({ file, journal, context, artifacts, admission, recovery, code, lastAt }) {
  let at = trustedNow(admission.trustedClock, lastAt);
  const reason = reasonDigest(code);
  const claim = `${file}.recovery-claimed`;
  if (!claimExclusive(claim, journal.binding_digest)) {
    const current = boundedJson(file);
    validateJournalSemantics(current, context.conformance, { allowActive: true });
    const existingOutbox = readOptional(`${file}.recovery-outbox.json`);
    if (existingOutbox) return finishRecoveryOutbox({
      file, journal: current, context, artifacts, recovery,
      outboxFile: `${file}.recovery-outbox.json`,
    });
    return { journal: current, ran: false, reason: "recovery-already-claimed", recovery_error: "recovery-already-claimed" };
  }
  if (journal.entries.at(-1).phase !== "unknown") {
    journal = append(file, journal, { phase: "unknown", at, actor: journal.binding.watchdog_identity, contentRef: context.contentRef, reason, quarantine: true });
  }
  transitionTarget({ journalDir: context.journalDir, binding: journal.binding, state: "unknown" });
  let result;
  let recoveryError = null;
  try { result = recovery.recover({ descriptor_digest: journal.binding.recovery.descriptor_digest }); }
  catch (error) { recoveryError = String(error?.code ?? error?.message ?? "recovery-error").slice(0, 96); }
  at = trustedNow(admission.trustedClock, at);
  let terminal;
  if (result?.recovered === true && result.safe_state_verified === true && result.quarantine_active === true) {
    journal = append(file, journal, { phase: "recover", at, actor: journal.binding.recovery_worker_identity, contentRef: context.contentRef, quarantine: true });
    at = trustedNow(admission.trustedClock, at);
    journal = append(file, journal, { phase: "quarantine", at, actor: journal.binding.recovery_worker_identity, contentRef: context.contentRef, quarantine: true });
    at = trustedNow(admission.trustedClock, at);
    terminal = makeEntry(journal, {
      phase: "disarm", at, actor: journal.binding.recovery_worker_identity, contentRef: context.contentRef,
      reason, quarantine: true, coverageTransition: coverageTransition(journal.binding),
    });
  } else {
    const terminalReason = reasonDigest(recoveryError ?? result?.reason_code ?? "recovery-postconditions-failed");
    terminal = makeEntry(journal, {
      phase: "terminally-blocked", at, actor: journal.binding.recovery_worker_identity, contentRef: context.contentRef,
      reason: terminalReason, quarantine: true, coverageTransition: coverageTransition(journal.binding),
    });
  }
  const outboxFile = `${file}.recovery-outbox.json`;
  const outbox = {
    kind: "brokkr-autonomy-recovery-outbox", schema_version: "v1",
    binding_digest: journal.binding_digest, stage: "prepared",
    terminal_entry: terminal,
    recovery_error: recoveryError ?? result?.reason_code ?? null,
    narrowing_tail_digest: null,
    owner_authorization_digest: context.bundle.authorizationDigest,
    previous_narrowing_digest: context.narrowing.tailDigest,
    narrowing_sequence: context.narrowing.entries.length + 1,
  };
  assert(createExclusive(outboxFile, outbox), "recovery_outbox_conflict");
  recovery.fault?.("after-recovery-outbox");
  return finishRecoveryOutbox({ file, journal, context, artifacts, recovery, outboxFile });
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
export function runMaintenanceAttempt({
  journalDir, binding, artifacts, admission, phases, recovery, contentRef = "ref:maintenance-candidate",
  reconcile = null,
}) {
  assert(typeof journalDir === "string" && path.isAbsolute(journalDir) && REF.test(contentRef), "attempt_arguments_invalid");
  assert(plain(binding) && plain(artifacts) && typeof artifacts.read === "function" &&
    plain(admission) && plain(phases) && plain(recovery), "attempt_arguments_invalid");
  for (const fn of ["trustedClock", "killSwitch", "evidence", "liveness", "maintenance"]) assert(typeof admission[fn] === "function", "admission_verifier_missing");
  for (const fn of ["preflight", "apply", "verify", "watch", "safeStateReadback"]) assert(typeof phases[fn] === "function", "maintenance_phase_missing");
  for (const fn of ["recover", "appendSignedNarrowing", "readAuthorityHistory", "readNarrowingHistory"]) {
    assert(typeof recovery[fn] === "function", "maintenance_recovery_missing");
  }
  const initialSnapshot = readArtifacts(artifacts);
  const schema = initialSnapshot.journalSchema;
  const conformance = {
    schema, constitution: initialSnapshot.constitution, coverage: initialSnapshot.coverage,
    ownerAttestations: initialSnapshot.ownerAttestations,
  };
  const file = path.join(journalDir, `${attemptIdentity(binding)}.json`);
  let existing = readOptional(file);
  if (existing) {
    const pendingOutbox = readOptional(`${file}.recovery-outbox.json`);
    if (pendingOutbox) {
      const historical = recovery.readAuthorityHistory({
        authorization_digest: pendingOutbox.owner_authorization_digest,
      });
      const authority = verifyAuthority({ binding: existing.binding, snapshot: historical, recovery });
      const historicalConformance = {
        schema: initialSnapshot.journalSchema, constitution: historical.constitution,
        coverage: historical.coverage, ownerAttestations: historical.ownerAttestations,
      };
      validateJournalSemantics(existing, historicalConformance, { allowActive: true });
      const historicalContext = {
          ...authority, policy: classPolicy(authority.bundle.constitution),
          contentRef, conformance: historicalConformance, journalDir,
      };
      if (pendingOutbox.stage !== "complete") {
        return finishRecoveryOutbox({
          file, journal: existing, context: historicalContext, artifacts, recovery,
          outboxFile: `${file}.recovery-outbox.json`,
        });
      }
      const conflict = canonicalJson(existing.binding) !== canonicalJson(binding);
      assert(!conflict, "attempt_conflicting_replay");
      assert(TERMINAL.has(existing.entries.at(-1).phase), "recovery_outbox_terminal_missing");
      return { journal: existing, ran: false, reason: `terminal-${existing.entries.at(-1).phase}` };
    }
    validateJournalSemantics(existing, conformance, { allowActive: true });
    const authority = verifyAuthority({ binding: existing.binding, snapshot: initialSnapshot, recovery });
    const existingContext = {
      ...authority, policy: classPolicy(authority.bundle.constitution),
      contentRef, conformance, journalDir,
    };
    const conflicting = canonicalJson(existing.binding) !== canonicalJson(binding);
    if (TERMINAL.has(existing.entries.at(-1).phase)) {
      assert(!conflicting, "attempt_conflicting_replay");
      return { journal: existing, ran: false, reason: `terminal-${existing.entries.at(-1).phase}` };
    }
    if (conflicting) {
      claimTarget({
        journalDir, binding: existing.binding,
        now: trustedNow(admission.trustedClock, existing.entries.at(-1).recorded_at),
        policy: existingContext.policy,
      });
      return enterRecovery({
        file, journal: existing, context: existingContext, artifacts, admission, recovery,
        code: "attempt-conflicting-replay", lastAt: existing.entries.at(-1).recorded_at,
      });
    }
  }
  const admitted = verifyAdmission({
    binding, snapshot: initialSnapshot, admission, recovery, journalDir, conformance,
  });
  verifyExecutionPreflight(phases, binding);
  claimTarget({ journalDir, binding, now: admitted.now, policy: admitted.policy });
  let journal = {
    kind: "autonomous-mutation-journal", schema_version: "v1", journal_id: binding.mutation_id,
    domain: DOMAIN, constitution_digest: initialSnapshot.constitution.constitution_digest,
    binding: structuredClone(binding), binding_digest: autonomyDigest(binding), entries: [], extensions: [],
  };
  journal.entries.push(makeEntry(journal, { phase: "prepare", at: admitted.now, actor: binding.controller_identity, contentRef }));
  validateJournalSemantics(journal, conformance, { allowActive: true });
  const created = createExclusive(file, journal);
  const context = { ...admitted, contentRef, conformance, journalDir };
  if (created) {
    assert(claimExecution({
      journalDir, binding, kind: "initial", bindingDigest: journal.binding_digest,
    }), "execution_claim_contended");
  } else {
    journal = boundedJson(file);
    validateJournalSemantics(journal, conformance, { allowActive: true });
    if (canonicalJson(journal.binding) !== canonicalJson(binding)) {
      return enterRecovery({
        file, journal, context, artifacts, admission, recovery,
        code: "attempt-conflicting-replay", lastAt: journal.entries.at(-1).recorded_at,
      });
    }
    if (TERMINAL.has(journal.entries.at(-1).phase)) return { journal, ran: false, reason: `terminal-${journal.entries.at(-1).phase}` };
    if (typeof reconcile !== "function") {
      return { journal, ran: false, reason: "execution-claim-active" };
    }
    let reconciliation;
    try {
      reconciliation = reconcile({ phase: journal.entries.at(-1).phase });
      assert(exactKeys(reconciliation, ["state", "claim_abandoned"]) &&
        ["not-applied", "applied", "indeterminate"].includes(reconciliation.state) &&
        reconciliation.claim_abandoned === true, "attempt_reconciliation_invalid");
    } catch (error) {
      return enterRecovery({
        file, journal, context, artifacts, admission, recovery,
        code: String(error?.code ?? error?.message ?? "attempt-reconciliation-failed"),
        lastAt: journal.entries.at(-1).recorded_at,
      });
    }
    if (journal.entries.at(-1).phase !== "prepare" || reconciliation.state !== "not-applied") {
      return enterRecovery({
        file, journal, context, artifacts, admission, recovery,
        code: `reconcile-${journal.entries.at(-1).phase}-${reconciliation.state}`,
        lastAt: journal.entries.at(-1).recorded_at,
      });
    }
    if (!claimExecution({
      journalDir, binding, kind: "resume", bindingDigest: journal.binding_digest,
    })) return { journal: boundedJson(file), ran: false, reason: "execution-resume-claimed" };
  }

  let at = trustedNow(admission.trustedClock, journal.entries.at(-1).recorded_at);
  try {
    const beforeApplySnapshot = readArtifacts(artifacts);
    const beforeApply = verifyAdmission({
      binding, snapshot: beforeApplySnapshot, admission, recovery, journalDir, conformance,
    });
    assert(beforeApply.immutableAdmissionDigest === admitted.immutableAdmissionDigest,
      "immutable_admission_drifted");
    verifyExecutionPreflight(phases, binding);
    checkKillSwitch(admission.killSwitch, binding);
    const applied = phases.apply();
    assert(applied?.applied === true, "maintenance_apply_failed");
    at = trustedNow(admission.trustedClock, at);
    journal = append(file, journal, { phase: "apply", at, actor: binding.controller_identity, contentRef });
    checkKillSwitch(admission.killSwitch, binding);
    const verified = phases.verify();
    assert(verified?.verified === true, "maintenance_verify_failed");
    at = trustedNow(admission.trustedClock, at);
    journal = append(file, journal, { phase: "verify", at, actor: binding.controller_identity, contentRef });
    checkKillSwitch(admission.killSwitch, binding);
    assert(Date.parse(at) <= Date.parse(binding.canary.watch_deadline), "maintenance_watch_started_late");
    journal = append(file, journal, { phase: "watch", at, actor: binding.controller_identity, contentRef });
    phases.watch({ until: binding.canary.watch_deadline });
    at = trustedNow(admission.trustedClock, at);
    assert(Date.parse(at) >= Date.parse(binding.canary.watch_deadline), "maintenance_watch_incomplete");
    checkKillSwitch(admission.killSwitch, binding);
    const readback = phases.safeStateReadback();
    assert(readback?.safe === true && readback.postconditions_digest === binding.postconditions_digest, "maintenance_safe_state_unverified");
    const beforeCommitSnapshot = readArtifacts(artifacts);
    const beforeCommit = verifyAdmission({
      binding, snapshot: beforeCommitSnapshot, admission, recovery, journalDir, conformance,
    });
    assert(beforeCommit.immutableAdmissionDigest === admitted.immutableAdmissionDigest,
      "immutable_admission_drifted");
    verifyExecutionPreflight(phases, binding);
    at = trustedNow(admission.trustedClock, at);
    assert(Date.parse(at) <= Date.parse(binding.deadline), "attempt_deadline_closed");
    journal = append(file, journal, { phase: "commit", at, actor: binding.controller_identity, contentRef });
    validateJournalSemantics(journal, conformance);
    transitionTarget({
      journalDir, binding, state: binding.admission_binding_state, release: true,
    });
    return { journal, ran: true, reason: "committed" };
  } catch (error) {
    return enterRecovery({
      file, journal, context, artifacts, admission, recovery,
      code: String(error?.code ?? error?.message ?? "maintenance-phase-error"),
      lastAt: at,
    });
  }
}
