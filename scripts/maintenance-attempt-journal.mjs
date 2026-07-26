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
  const row = coverage.domains?.find(entry => entry.domain === DOMAIN);
  const ownerBinding = row?.bindings?.find(entry => (
    entry.target_scope_digest === binding.target_scope_digest &&
    entry.writer_owner === binding.writer_owner &&
    entry.owner_authority_ref === binding.owner_authority_ref &&
    entry.owner_authority_digest === binding.owner_authority_digest &&
    entry.configuration_owner === binding.configuration_owner &&
    entry.configuration_owner_authority_ref === binding.configuration_owner_authority_ref &&
    entry.configuration_owner_authority_digest === binding.configuration_owner_authority_digest
  ));
  const attestation = ownerAttestations.attestations?.find(entry => (
    `ref:${entry.attestation_id}` === binding.configuration_owner_authority_ref &&
    entry.attestation_digest === binding.configuration_owner_authority_digest &&
    entry.domain === DOMAIN && entry.target_scope_digest === binding.target_scope_digest &&
    entry.configuration_owner === binding.configuration_owner &&
    entry.attestation_digest === autonomyDigest(entry, "attestation_digest")
  ));
  assert(row && ownerBinding && attestation, "target_owner_attestation_invalid");
  assert(coverage.global_state === "armed" && ["armed-canary", "armed-fleet"].includes(row.coverage), "coverage_not_armed");
  assert(binding.admission_coverage_digest === coverage.registry_digest && binding.admission_binding_state === ownerBinding.state, "coverage_binding_mismatch");
  assert(binding.writer_owner === "brokkr" && binding.configuration_owner === "brokkr", "maintenance_owner_invalid");
  const identities = ownerBinding.identities;
  assert(binding.owner_identity === identities.owner && binding.controller_identity === identities.controller &&
    binding.watchdog_identity === identities.watchdog && binding.kill_switch_identity === identities.kill_switch &&
    binding.recovery_worker_identity === identities.recovery_worker, "coverage_identity_mismatch");
  return ownerBinding;
}
function classPolicy(constitution) {
  const policy = constitution.autonomous_classes?.find(entry => entry.class === DOMAIN);
  assert(policy && policy.recovery_class === "R-forward" && policy.owner === "brokkr", "maintenance_constitution_invalid");
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
  journal.entries.push(makeEntry(journal, options));
  writeAtomic(file, journal);
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
function scanAttemptRate(journalDir, currentId, now, policy, conformance) {
  let entries = [];
  try { entries = fs.readdirSync(journalDir, { withFileTypes: true }); }
  catch (error) { if (error.code === "ENOENT") return; throw error; }
  const starts = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".json") || entry.name === `${currentId}.json`) continue;
    const journal = boundedJson(path.join(journalDir, entry.name));
    validateJournalSemantics(journal, conformance, { allowActive: true });
    starts.push(Date.parse(journal.entries[0].recorded_at));
  }
  const nowMs = Date.parse(now);
  assert(!starts.some(start => nowMs - start < policy.bounds.min_seconds_between_attempts * 1000), "attempt_interval_exceeded");
  assert(starts.filter(start => nowMs - start < policy.bounds.attempt_window_seconds * 1000).length < policy.bounds.max_attempts_per_window, "attempt_window_exceeded");
}
function verifyAdmission({ binding, artifacts, admission, journalDir, conformance }) {
  const bundle = verifyOwnerAuthorizationBundle(artifacts);
  const narrowing = verifyRuntimeNarrowingLedger({
    ledger: artifacts.runtimeNarrowing,
    recoveryRegistry: bundle.recoveryRegistry,
    authorizationDigest: bundle.authorizationDigest,
    tailCheckpoint: artifacts.runtimeNarrowingCheckpoint,
  });
  ownerBindingFor({ coverage: bundle.coverage, ownerAttestations: bundle.ownerAttestations, binding });
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
  scanAttemptRate(journalDir, binding.idempotency_key, now, policy, conformance);
  return { bundle, narrowing, policy, now, maintenance };
}
function reasonDigest(code) {
  return autonomyDigest({ code: String(code || "unknown").slice(0, 96) });
}
function enterRecovery({ file, journal, context, artifacts, admission, recovery, code, lastAt }) {
  let at = trustedNow(admission.trustedClock, lastAt);
  const reason = reasonDigest(code);
  const claim = `${file}.recovery-claimed`;
  if (!claimExclusive(claim, journal.binding_digest)) {
    const current = boundedJson(file);
    validateJournalSemantics(current, context.conformance, { allowActive: true });
    return { journal: current, ran: false, reason: "recovery-already-claimed", recovery_error: "recovery-already-claimed" };
  }
  if (journal.entries.at(-1).phase !== "unknown") {
    append(file, journal, { phase: "unknown", at, actor: journal.binding.watchdog_identity, contentRef: context.contentRef, reason, quarantine: true });
  }
  let result;
  let recoveryError = null;
  try { result = recovery.recover({ descriptor_digest: journal.binding.recovery.descriptor_digest }); }
  catch (error) { recoveryError = String(error?.code ?? error?.message ?? "recovery-error").slice(0, 96); }
  at = trustedNow(admission.trustedClock, at);
  if (result?.recovered === true && result.safe_state_verified === true && result.quarantine_active === true) {
    append(file, journal, { phase: "recover", at, actor: journal.binding.recovery_worker_identity, contentRef: context.contentRef, quarantine: true });
    at = trustedNow(admission.trustedClock, at);
    append(file, journal, { phase: "quarantine", at, actor: journal.binding.recovery_worker_identity, contentRef: context.contentRef, quarantine: true });
    at = trustedNow(admission.trustedClock, at);
    const disarm = makeEntry(journal, {
      phase: "disarm", at, actor: journal.binding.recovery_worker_identity, contentRef: context.contentRef,
      reason, quarantine: true, coverageTransition: coverageTransition(journal.binding),
    });
    const narrowed = recovery.appendSignedNarrowing({
      journal_receipt_digest: disarm.receipt_digest,
      recorded_at: at,
      binding: journal.binding,
      authorization_digest: context.bundle.authorizationDigest,
      previous_entry_digest: context.narrowing.tailDigest,
      sequence: context.narrowing.entries.length + 1,
    });
    const verified = verifyRuntimeNarrowingLedger({
      ledger: narrowed.ledger, recoveryRegistry: context.bundle.recoveryRegistry,
      authorizationDigest: context.bundle.authorizationDigest, tailCheckpoint: narrowed.tailCheckpoint,
    });
    const tail = verified.entries.at(-1);
    assert(tail?.journal_receipt_digest === disarm.receipt_digest && tail.target_scope_digest === journal.binding.target_scope_digest &&
      tail.recovery_worker_identity === journal.binding.recovery_worker_identity && tail.to_state === "shadow", "runtime_narrowing_not_consumed");
    journal.entries.push(disarm);
    writeAtomic(file, journal);
    validateJournalSemantics(journal, context.conformance);
    return { journal, ran: false, reason: "recovered-disarmed", recovery_error: null, narrowing: narrowed };
  }
  const terminalReason = reasonDigest(recoveryError ?? result?.reason_code ?? "recovery-postconditions-failed");
  const terminal = makeEntry(journal, {
    phase: "terminally-blocked", at, actor: journal.binding.recovery_worker_identity, contentRef: context.contentRef,
    reason: terminalReason, quarantine: true, coverageTransition: coverageTransition(journal.binding),
  });
  const narrowed = recovery.appendSignedNarrowing({
    journal_receipt_digest: terminal.receipt_digest, recorded_at: at, binding: journal.binding,
    authorization_digest: context.bundle.authorizationDigest, previous_entry_digest: context.narrowing.tailDigest,
    sequence: context.narrowing.entries.length + 1,
  });
  const verified = verifyRuntimeNarrowingLedger({
    ledger: narrowed.ledger, recoveryRegistry: context.bundle.recoveryRegistry,
    authorizationDigest: context.bundle.authorizationDigest, tailCheckpoint: narrowed.tailCheckpoint,
  });
  assert(verified.entries.at(-1)?.journal_receipt_digest === terminal.receipt_digest, "runtime_narrowing_not_consumed");
  journal.entries.push(terminal);
  writeAtomic(file, journal);
  validateJournalSemantics(journal, context.conformance);
  return { journal, ran: false, reason: "terminally-blocked", recovery_error: recoveryError ?? result?.reason_code ?? "recovery-postconditions-failed", narrowing: narrowed };
}

export function runMaintenanceAttempt({
  journalDir, binding, artifacts, admission, phases, recovery, contentRef = "ref:maintenance-candidate",
  reconcile = null,
}) {
  assert(typeof journalDir === "string" && path.isAbsolute(journalDir) && REF.test(contentRef), "attempt_arguments_invalid");
  assert(plain(binding) && plain(artifacts) && plain(admission) && plain(phases) && plain(recovery), "attempt_arguments_invalid");
  for (const fn of ["trustedClock", "killSwitch", "evidence", "liveness", "maintenance"]) assert(typeof admission[fn] === "function", "admission_verifier_missing");
  for (const fn of ["apply", "verify", "watch", "safeStateReadback"]) assert(typeof phases[fn] === "function", "maintenance_phase_missing");
  for (const fn of ["recover", "appendSignedNarrowing"]) assert(typeof recovery[fn] === "function", "maintenance_recovery_missing");
  const schema = artifacts.journalSchema;
  const conformance = { schema, constitution: artifacts.constitution, coverage: artifacts.coverage, ownerAttestations: artifacts.ownerAttestations };
  const admitted = verifyAdmission({ binding, artifacts, admission, journalDir, conformance });
  const file = path.join(journalDir, `${attemptIdentity(binding)}.json`);
  let journal = {
    kind: "autonomous-mutation-journal", schema_version: "v1", journal_id: binding.mutation_id,
    domain: DOMAIN, constitution_digest: artifacts.constitution.constitution_digest,
    binding: structuredClone(binding), binding_digest: autonomyDigest(binding), entries: [], extensions: [],
  };
  journal.entries.push(makeEntry(journal, { phase: "prepare", at: admitted.now, actor: binding.controller_identity, contentRef }));
  validateJournalSemantics(journal, conformance, { allowActive: true });
  const created = createExclusive(file, journal);
  const context = { ...admitted, contentRef, conformance };
  if (!created) {
    journal = boundedJson(file);
    validateJournalSemantics(journal, conformance, { allowActive: true });
    assert(canonicalJson(journal.binding) === canonicalJson(binding), "attempt_conflicting_replay");
    if (TERMINAL.has(journal.entries.at(-1).phase)) return { journal, ran: false, reason: `terminal-${journal.entries.at(-1).phase}` };
    let reconciliation;
    try {
      assert(typeof reconcile === "function", "attempt_reconciliation_required");
      reconciliation = reconcile({ phase: journal.entries.at(-1).phase });
      assert(["not-applied", "applied", "indeterminate"].includes(reconciliation?.state), "attempt_reconciliation_invalid");
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
  }

  let at = trustedNow(admission.trustedClock, journal.entries.at(-1).recorded_at);
  try {
    checkKillSwitch(admission.killSwitch, binding);
    const applied = phases.apply();
    assert(applied?.applied === true, "maintenance_apply_failed");
    at = trustedNow(admission.trustedClock, at);
    append(file, journal, { phase: "apply", at, actor: binding.controller_identity, contentRef });
    checkKillSwitch(admission.killSwitch, binding);
    const verified = phases.verify();
    assert(verified?.verified === true, "maintenance_verify_failed");
    at = trustedNow(admission.trustedClock, at);
    append(file, journal, { phase: "verify", at, actor: binding.controller_identity, contentRef });
    checkKillSwitch(admission.killSwitch, binding);
    assert(Date.parse(at) <= Date.parse(binding.canary.watch_deadline), "maintenance_watch_started_late");
    append(file, journal, { phase: "watch", at, actor: binding.controller_identity, contentRef });
    phases.watch({ until: binding.canary.watch_deadline });
    at = trustedNow(admission.trustedClock, at);
    assert(Date.parse(at) >= Date.parse(binding.canary.watch_deadline), "maintenance_watch_incomplete");
    checkKillSwitch(admission.killSwitch, binding);
    const readback = phases.safeStateReadback();
    assert(readback?.safe === true && readback.postconditions_digest === binding.postconditions_digest, "maintenance_safe_state_unverified");
    at = trustedNow(admission.trustedClock, at);
    assert(Date.parse(at) <= Date.parse(binding.deadline), "attempt_deadline_closed");
    append(file, journal, { phase: "commit", at, actor: binding.controller_identity, contentRef });
    validateJournalSemantics(journal, conformance);
    return { journal, ran: true, reason: "committed" };
  } catch (error) {
    return enterRecovery({
      file, journal, context, artifacts, admission, recovery,
      code: String(error?.code ?? error?.message ?? "maintenance-phase-error"),
      lastAt: at,
    });
  }
}
