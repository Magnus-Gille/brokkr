// Fail-closed maintenance execution controller (brokkr#34).
// It never chooses a package-manager command: production integration must pass
// an explicitly reviewed executor. The controller makes admission durable,
// atomic, inspectable, and conservative.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { decisionEffect, durationToMs, isValidTimeZone, policyDigest, resolveWindowOccurrence, weekdayOf } from "./lib/maintenance-policy-contract.mjs";

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const parseUtc = (value, name) => { const ms = Date.parse(value); if (!Number.isFinite(ms) || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(value)) throw new Error(`${name} must be a second-resolution UTC instant`); return ms; };
const localDateAt = (ms, timeZone) => { const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(ms)); const get = (type) => parts.find((part) => part.type === type).value; return `${get("year")}-${get("month")}-${get("day")}`; };
const addUtcDays = (date, delta) => { const [year, month, day] = date.split("-").map(Number); return new Date(Date.UTC(year, month - 1, day + delta)).toISOString().slice(0, 10); };
const sha256 = (value) => `sha256:${crypto.createHash("sha256").update(JSON.stringify(value)).digest("hex")}`;
const NODE_ID = /^[a-z][a-z0-9-]{0,62}$/;
function assertNodeId(nodeId) { if (typeof nodeId !== "string" || !NODE_ID.test(nodeId)) throw new Error("node_id must be a canonical lowercase identifier"); }
function assertPolicy(policy) { if (!policy || policy.kind !== "maintenance-policy" || policy.schema_version !== "v1" || policy.policy_digest !== policyDigest(policy)) throw new Error("maintenance policy digest is invalid"); }

export function occurrenceCalendar(policy, nowMs) {
  if (!isValidTimeZone(policy.timezone)) throw new Error("unknown IANA timezone");
  const today = localDateAt(nowMs, policy.timezone); const occurrences = [];
  for (let offset = -8; offset <= 8; offset += 1) {
    const date = addUtcDays(today, offset);
    if (policy.window.days_of_week.includes(weekdayOf(date))) {
      try { occurrences.push(resolveWindowOccurrence(policy, date)); } catch (error) { occurrences.push({ local_date: date, unavailable: String(error.message) }); }
    }
  }
  return occurrences.sort((a, b) => (a.start ?? "").localeCompare(b.start ?? ""));
}
export function windowStatus(policy, nowMs) {
  const occurrences = occurrenceCalendar(policy, nowMs); const valid = occurrences.filter((item) => item.start && item.end);
  const current = valid.find((item) => Date.parse(item.start) <= nowMs && nowMs < Date.parse(item.end));
  const prior = [...valid].reverse().find((item) => Date.parse(item.end) <= nowMs); const next = valid.find((item) => Date.parse(item.start) > nowMs);
  if (current) return { eligible: true, reason: "open_window", occurrence: current, next_eligible_at: current.start };
  return { eligible: false, reason: occurrences.some((item) => item.unavailable) && !next ? "unknown_window_eligibility" : "closed_window", occurrence: prior ?? null, next_eligible_at: next?.start ?? null };
}
export function orderTargets(targets) {
  const byId = new Map(targets.map((target) => [target.node_id, target])); if (byId.size !== targets.length) throw new Error("node_id values must be unique");
  const done = new Set(); const output = [];
  while (done.size < targets.length) {
    const ready = targets.filter((target) => !done.has(target.node_id) && (target.depends_on ?? []).every((dependency) => done.has(dependency)));
    if (!ready.length) throw new Error("target dependencies are cyclic or unknown");
    ready.sort((a, b) => a.node_id.localeCompare(b.node_id)); for (const target of ready) { output.push(target.node_id); done.add(target.node_id); }
  }
  return output;
}
function readJson(file, fallback) { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (error) { if (error.code === "ENOENT") return fallback; throw error; } }
function readState(file) { const state = readJson(file, { version: 1, nodes: {} }); if (state.version !== 1 || state.nodes === null || typeof state.nodes !== "object" || Array.isArray(state.nodes) || Object.keys(state.nodes).length > 1024 || Buffer.byteLength(JSON.stringify(state)) > 1024 * 1024) throw new Error("controller state is invalid or exceeds its bounded limit"); return state; }
function atomicWrite(file, value) { const encoded = `${JSON.stringify(value)}\n`; if (Buffer.byteLength(encoded) > 1024 * 1024) throw new Error("controller state exceeds its bounded limit"); fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 }); const temporary = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`; const fd = fs.openSync(temporary, "wx", 0o600); try { fs.writeFileSync(fd, encoded); fs.fsyncSync(fd); } finally { fs.closeSync(fd); } fs.renameSync(temporary, file); const directory = fs.openSync(path.dirname(file), "r"); try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); } }
function acquireLock(file, owner) { fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 }); try { fs.writeFileSync(file, `${JSON.stringify(owner)}\n`, { mode: 0o600, flag: "wx" }); return true; } catch (error) { if (error.code === "EEXIST") return false; throw error; } }
function releaseLock(file, token) { try { if (readJson(file, {}).token === token) fs.unlinkSync(file); } catch (error) { if (error.code !== "ENOENT") throw error; } }
function isHeld(holdFile, policy) { const external = readJson(holdFile, { active: false }); return policy.state.enabled !== true || policy.state.hold.active === true || external.active === true; }
function mutateState(stateDir, mutate) { const lock = path.join(stateDir, "state.lock"); const owner = { token: crypto.randomUUID() }; if (!acquireLock(lock, owner)) return null; try { const stateFile = path.join(stateDir, "state.json"); const state = readState(stateFile); const result = mutate(state); atomicWrite(stateFile, state); return result; } finally { releaseLock(lock, owner.token); } }

export function inspectController({ policy, nodeId, stateDir, now = iso(Date.now()), clock = "synchronized" }) {
  assertNodeId(nodeId); assertPolicy(policy); const nowMs = parseUtc(now, "now"); const state = readState(path.join(stateDir, "state.json")); const node = state.nodes[nodeId] ?? { attempts: 0, consecutive_failures: 0, status: "idle", first_deferred_at: null, missed_occurrences: 0 };
  const status = windowStatus(policy, nowMs); const retryAt = node.next_eligible_at ? Date.parse(node.next_eligible_at) : null;
  const deferralMs = node.first_deferred_at ? Math.max(0, nowMs - parseUtc(node.first_deferred_at, "first_deferred_at")) : 0;
  const temporal = decisionEffect(policy, { missedOccurrences: node.missed_occurrences ?? 0, deferralElapsedMs: deferralMs });
  let reason = status.reason;
  const occurrenceId = status.occurrence?.start ?? null;
  if (clock !== "synchronized") reason = "clock_uncertain"; else if (isHeld(path.join(stateDir, "hold.json"), policy)) reason = "held"; else if (node.status === "in_flight") reason = "in_flight_requires_operator_recovery"; else if (node.completed_occurrence === occurrenceId) reason = "already_completed_occurrence"; else if (node.retry_exhausted_occurrence === occurrenceId) reason = "retry_exhausted"; else if (retryAt && nowMs < retryAt) reason = "retry_backoff"; else if (status.eligible) reason = "eligible";
  return { kind: "brokkr-maintenance-controller-inspection", schema_version: "v1", node_id: nodeId, policy_id: policy.policy_id, policy_digest: policyDigest(policy), at: now, clock, timezone: policy.timezone, window: status, temporal: { missed_occurrences: node.missed_occurrences ?? 0, deferral_elapsed_ms: deferralMs, effect: temporal.effect, overdue: temporal.reason === "overdue_after_missed_windows" || temporal.reason === "maximum_deferral_reached" }, state: node, eligible: reason === "eligible" && temporal.effect !== "held" && temporal.effect !== "escalate_operator_gate", reason, digest: sha256({ policy: policyDigest(policy), nodeId, now, reason, node }) };
}
// State is made in_flight before the executor. A crash retains it and a restart
// refuses execution; no timeout lease can safely prove an old package manager died.
export function runController({ policy, nodeId, stateDir, now = iso(Date.now()), clock = "synchronized", beforeMutation = null, beforeFinalize = null, executor }) {
  if (typeof executor !== "function") throw new Error("executor function is required");
  assertNodeId(nodeId); assertPolicy(policy);
  const holdFile = path.join(stateDir, "hold.json"); const lockFile = path.join(stateDir, "locks", `${nodeId}.lock`); const owner = { node_id: nodeId, pid: process.pid, started_at: now, token: crypto.randomUUID() };
  if (!acquireLock(lockFile, owner)) return { ran: false, reason: "lock_contended" };
  try {
    const inspection = inspectController({ policy, nodeId, stateDir, now, clock }); if (!inspection.eligible) return { ran: false, reason: inspection.reason, inspection };
    const occurrenceId = inspection.window.occurrence.start;
    const started = mutateState(stateDir, (state) => { const previous = state.nodes[nodeId] ?? { attempts: 0, consecutive_failures: 0, first_deferred_at: null }; state.nodes[nodeId] = { ...previous, status: "in_flight", attempts: previous.attempts + 1, started_at: now, policy_digest: policyDigest(policy), occurrence_id: occurrenceId }; return state.nodes[nodeId]; });
    if (started === null) return { ran: false, reason: "state_lock_contended" };
    if (beforeMutation !== null) beforeMutation();
    if (isHeld(holdFile, policy)) { const held = mutateState(stateDir, (state) => { state.nodes[nodeId] = { ...state.nodes[nodeId], status: "held_before_mutation", completed_at: now }; return true; }); return held === null ? { ran: false, reason: "finalization_failed_operator_recovery" } : { ran: false, reason: "held_before_mutation" }; }
    try { const result = executor(); if (beforeFinalize !== null) beforeFinalize(); const finalized = mutateState(stateDir, (state) => { state.nodes[nodeId] = { ...state.nodes[nodeId], status: "succeeded", attempts: 0, consecutive_failures: 0, completed_at: now, completed_occurrence: occurrenceId, result: String(result ?? "ok").slice(0, 512) }; return true; }); return finalized === null ? { ran: true, reason: "finalization_failed_operator_recovery" } : { ran: true, reason: "succeeded" }; }
    catch (error) { if (beforeFinalize !== null) beforeFinalize(); const terminal = mutateState(stateDir, (state) => { const current = state.nodes[nodeId]; const failures = (current.consecutive_failures ?? 0) + 1; const exhausted = current.attempts >= policy.execution_limits.retry.max_attempts || failures >= policy.failure_limits.max_consecutive_failures; const nextMs = parseUtc(now, "now") + durationToMs(policy.execution_limits.retry.backoff); state.nodes[nodeId] = { ...current, status: exhausted ? "retry_exhausted" : "retry_pending", attempts: exhausted ? 0 : current.attempts, consecutive_failures: failures, next_eligible_at: iso(nextMs), completed_at: now, retry_exhausted_occurrence: exhausted ? occurrenceId : null, error: String(error.message ?? error).slice(0, 512) }; return exhausted; }); return terminal === null ? { ran: false, reason: "finalization_failed_operator_recovery" } : { ran: false, reason: terminal ? "retry_exhausted" : "retry_pending" }; }
  } finally { releaseLock(lockFile, owner.token); }
}
function args(argv) { const result = {}; for (let i = 0; i < argv.length; i += 2) { if (!argv[i].startsWith("--") || argv[i + 1] === undefined) throw new Error("arguments must be --name value pairs"); result[argv[i].slice(2)] = argv[i + 1]; } for (const key of ["policy", "node", "state-dir", "now", "clock"]) if (!result[key]) throw new Error(`--${key} is required`); return result; }
function main() { const options = args(process.argv.slice(2)); const policy = JSON.parse(fs.readFileSync(options.policy, "utf8")); process.stdout.write(`${JSON.stringify(inspectController({ policy, nodeId: options.node, stateDir: options["state-dir"], now: options.now, clock: options.clock }))}\n`); }
if (process.argv[1] === fileURLToPath(import.meta.url)) main();
