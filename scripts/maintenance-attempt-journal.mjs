// Immutable, content-blind maintenance-attempt journal (brokkr#66).
// This layer admits one opaque attempt before its caller may invoke a host
// adapter. It records only identifiers, digests and declared safety semantics.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { canonicalJson, strictUtc } from "./lib/maintenance-policy-contract.mjs";

const MAX_BYTES = 128 * 1024;
const DIGEST = /^sha256:[0-9a-f]{64}$/;
const OPAQUE_ID = /^[a-z][a-z0-9._:-]{0,127}$/;
const hash = value => `sha256:${crypto.createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
const validRef = value => typeof value === "string" && OPAQUE_ID.test(value);
const validDigest = value => typeof value === "string" && DIGEST.test(value);
const assert = (condition, code) => { if (!condition) { const error = new Error(code); error.code = code; throw error; } };

function atomicWrite(file, value) {
  const encoded = `${canonicalJson(value)}\n`;
  assert(Buffer.byteLength(encoded) <= MAX_BYTES, "attempt_journal_too_large");
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  const fd = fs.openSync(temporary, "wx", 0o600);
  try { fs.writeFileSync(fd, encoded); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(temporary, file);
  const directory = fs.openSync(path.dirname(file), "r");
  try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
}
function read(file) { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (error) { if (error.code === "ENOENT") return null; throw error; } }
function eventDigest(event) { const copy = { ...event }; delete copy.event_digest; return hash(copy); }
function validateBinding(binding) {
  assert(binding && typeof binding === "object" && !Array.isArray(binding), "attempt_binding_invalid");
  const keys = ["adapter_revision_digest", "constitution_digest", "deadline", "inventory", "node_id", "occurrence_id", "plan", "policy", "postconditions_digest", "recovery_class"];
  assert(Object.keys(binding).length === keys.length && keys.every(key => Object.hasOwn(binding, key)), "attempt_binding_shape_invalid");
  assert(validDigest(binding.adapter_revision_digest) && validDigest(binding.constitution_digest) && validDigest(binding.postconditions_digest), "attempt_binding_digest_invalid");
  assert(strictUtc(binding.deadline), "attempt_deadline_invalid");
  assert(validRef(binding.node_id) && validRef(binding.occurrence_id), "attempt_identity_invalid");
  assert(binding.recovery_class === "R-forward", "attempt_recovery_class_invalid");
  for (const field of ["policy", "plan", "inventory"]) {
    const value = binding[field];
    assert(value && typeof value === "object" && !Array.isArray(value), "attempt_reference_invalid");
    assert(Object.keys(value).length === 2 && validRef(value.id) && validDigest(value.digest), "attempt_reference_invalid");
  }
  return structuredClone(binding);
}
function identityMaterial(binding) { return { node_id: binding.node_id, occurrence_id: binding.occurrence_id }; }
function validateJournal(journal) {
  assert(journal && journal.kind === "brokkr-maintenance-attempt-journal" && journal.schema_version === "v1", "attempt_journal_invalid");
  const binding = validateBinding(journal.binding);
  assert(typeof journal.attempt_id === "string" && journal.attempt_id === `attempt-${hash(identityMaterial(binding)).slice(7, 59)}`, "attempt_journal_identity_invalid");
  assert(Array.isArray(journal.events) && journal.events.length > 0 && journal.events.length <= 32, "attempt_journal_events_invalid");
  let previous = null;
  for (const event of journal.events) {
    assert(event && typeof event === "object" && Object.keys(event).length === 5, "attempt_journal_event_invalid");
    assert(strictUtc(event.at) && ["prepared", "reconciled", "adapter_handoff", "committed", "unknown", "terminally-blocked", "disarmed"].includes(event.phase), "attempt_journal_event_invalid");
    assert(event.previous_event_digest === previous && validDigest(event.event_digest) && event.event_digest === eventDigest(event), "attempt_journal_chain_invalid");
    assert(typeof event.reason === "string" && /^[a-z0-9-]{1,96}$/.test(event.reason), "attempt_journal_event_invalid"); previous = event.event_digest;
  }
  assert(["prepared", "reconciled", "committed", "unknown", "terminally-blocked", "disarmed"].includes(journal.state), "attempt_journal_state_invalid");
  return { binding, terminal: ["committed", "disarmed", "terminally-blocked"].includes(journal.state) };
}
function append(journal, at, phase, reason) {
  assert(strictUtc(at) && /^[a-z0-9-]{1,96}$/.test(reason), "attempt_event_invalid");
  const event = { at, phase, reason, previous_event_digest: journal.events.at(-1)?.event_digest ?? null, event_digest: null };
  event.event_digest = eventDigest(event); journal.events.push(event); journal.state = phase;
}
// The idempotency identity is deliberately narrower than the immutable
// binding: a changed policy/plan/deadline for the same node occurrence must
// reopen the same record and be rejected as a conflicting replay, not create
// a second host attempt.
export function attemptIdentity(binding) { const checked = validateBinding(binding); return `attempt-${hash(identityMaterial(checked)).slice(7, 59)}`; }

// `execute` is the only callback that may reach a host adapter. It runs only
// after both prepared and adapter_handoff records are fsynced. An ambiguous
// resumption is disarmed; it never becomes an automatic retry.
export function runMaintenanceAttempt({ journalDir, binding, now, execute, reconcile = null }) {
  assert(typeof journalDir === "string" && path.isAbsolute(journalDir), "attempt_journal_directory_invalid");
  assert(strictUtc(now) && typeof execute === "function" && (reconcile === null || typeof reconcile === "function"), "attempt_arguments_invalid");
  const immutable = validateBinding(binding); const attempt_id = attemptIdentity(immutable);
  const file = path.join(journalDir, `${attempt_id}.json`); let journal = read(file);
  if (journal === null) { journal = { kind: "brokkr-maintenance-attempt-journal", schema_version: "v1", attempt_id, binding: immutable, state: "prepared", events: [] }; append(journal, now, "prepared", "admission-established"); atomicWrite(file, journal); }
  else {
    const inspected = validateJournal(journal); assert(canonicalJson(inspected.binding) === canonicalJson(immutable), "attempt_conflicting_replay");
    if (inspected.terminal) return { attempt_id, journal, ran: false, reason: `terminal-${journal.state}` };
    if (journal.state === "prepared") {
      assert(reconcile !== null, "attempt_reconciliation_required");
      const result = reconcile(); assert(result && ["not-applied", "applied", "indeterminate"].includes(result.state), "attempt_reconciliation_invalid");
      append(journal, now, "reconciled", result.state); atomicWrite(file, journal);
      if (result.state !== "not-applied") { append(journal, now, result.state === "applied" ? "unknown" : "terminally-blocked", result.state); append(journal, now, "disarmed", "reconciliation-not-safe-to-retry"); atomicWrite(file, journal); return { attempt_id, journal, ran: false, reason: "reconciliation-disarmed" }; }
    } else {
      const last = journal.events.at(-1);
      assert(journal.state === "reconciled" && last?.reason === "not-applied", "attempt_not_resumable");
    }
  }
  append(journal, now, "adapter_handoff", "journal-durable"); atomicWrite(file, journal);
  try { const result = execute({ attempt_id, journal_file: file }); append(journal, now, "committed", "postconditions-declared"); atomicWrite(file, journal); return { attempt_id, journal, ran: true, reason: "committed", result }; }
  catch (error) { append(journal, now, "unknown", "executor-error"); append(journal, now, "disarmed", "unknown-state"); atomicWrite(file, journal); return { attempt_id, journal, ran: true, reason: "unknown-disarmed", error: String(error?.code ?? error?.message ?? "executor-error") }; }
}
