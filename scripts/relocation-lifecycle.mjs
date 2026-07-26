#!/usr/bin/env node
// Bounded, local relocation executor (brokkr#10).  It never discovers hosts or
// commands: every mutation is an explicit, attributed hook in an operation file.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { canonicalJson, checkSchema, schemaErrors, strictUtc } from "./lib/node-substrate-contract.mjs";

const ID = /^[a-z][a-z0-9-]{2,62}$/;
const DIGEST = /^sha256:[a-f0-9]{64}$/;
const HOOKS = ["preflight", "drain", "apply", "verify", "representative_data", "rollback"];
const hash = value => `sha256:${crypto.createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
const die = message => { process.stderr.write(`relocation-lifecycle: ${message}\n`); process.exit(3); };
const args = (() => {
  const out = {}; const raw = process.argv.slice(2);
  for (let i = 0; i < raw.length; i += 1) {
    if (raw[i] === "--resume") { out.resume = true; continue; }
    if (!["--plan", "--operation", "--journal", "--now", "--operator-confirm"].includes(raw[i]) || i + 1 === raw.length) die("usage: relocation-lifecycle.mjs --plan FILE --operation FILE --journal FILE --now UTC [--resume] [--operator-confirm physical-move]");
    out[raw[i].slice(2).replaceAll("-", "_")] = raw[++i];
  }
  for (const key of ["plan", "operation", "journal", "now"]) if (typeof out[key] !== "string") die("all required arguments are required");
  if (!strictUtc(out.now)) die("--now must be an exact UTC instant");
  return out;
})();
const read = (file, name) => {
  let stat; try { stat = fs.lstatSync(file); } catch { die(`${name} is unavailable`); }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1_000_000) die(`${name} must be a bounded regular file`);
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { die(`${name} is not valid JSON`); }
};
const writeJournal = journal => {
  const destination = path.resolve(args.journal); const parent = path.dirname(destination);
  if (!fs.existsSync(parent) || !fs.statSync(parent).isDirectory()) die("journal parent is unavailable");
  if (fs.existsSync(destination) && fs.lstatSync(destination).isSymbolicLink()) die("journal may not be a symlink");
  const tmp = `${destination}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${canonicalJson(journal)}\n`, { mode: 0o600 }); fs.renameSync(tmp, destination);
};
const plan = read(args.plan, "plan");
if (plan.kind !== "brokkr-relocation-plan" || plan.schema_version !== "v1" || plan.outcome !== "promoted" || !DIGEST.test(plan.plan_digest) || !plan.lifecycle_result) die("plan is not a promoted, digest-bound relocation plan");
const schema = read(path.resolve(path.dirname(new URL(import.meta.url).pathname), "../docs/node-substrate-contract-v1.schema.json"), "pinned contract");
checkSchema(schema);
if (schemaErrors(schema, plan.lifecycle_result).length || plan.lifecycle_result.outcome !== "promoted" || plan.lifecycle_result.deadline <= args.now || plan.plan_id !== plan.lifecycle_result.plan_id || plan.plan_digest !== plan.lifecycle_result.plan_digest) die("plan lifecycle result is invalid, blocked, stale, or not bound to its top-level plan");
if (!plan.rollback?.available || typeof plan.rollback.hook !== "string") die("plan has no explicit reversal recipe");
const operation = read(args.operation, "operation");
const operationKeys = ["hooks", "id", "irreversible", "kind", "monitoring", "physical_move_required", "platform_fault_refs", "reversal_recipe", "schema_version"];
if (canonicalJson(Object.keys(operation).sort()) !== canonicalJson(operationKeys.sort()) || operation.kind !== "brokkr-relocation-operation" || operation.schema_version !== "v1" || !ID.test(operation.id) || typeof operation.reversal_recipe !== "string" || !operation.reversal_recipe.trim() || !operation.irreversible || operation.irreversible.allowed !== false || typeof operation.physical_move_required !== "boolean") die("operation is not a closed, reversible v1 record");
if (!operation.monitoring || operation.monitoring.contract !== "heimdall-monitoring-agent-capability/v1" || !Array.isArray(operation.monitoring.required_capabilities) || canonicalJson([...operation.monitoring.required_capabilities].sort()) !== canonicalJson(["lifecycle-result", "node-capability-freshness"])) die("operation does not negotiate the exact Heimdall v1 capabilities");
if (!Array.isArray(operation.platform_fault_refs) || new Set(operation.platform_fault_refs).size !== operation.platform_fault_refs.length || !operation.platform_fault_refs.every(value => typeof value === "string" && /^fault-[a-z0-9-]+-[0-9]+$/.test(value))) die("operation platform-fault references are invalid");
if (!Array.isArray(operation.hooks) || operation.hooks.length !== HOOKS.length) die("operation must allowlist every lifecycle hook exactly once");
const hookMap = new Map();
for (const hook of operation.hooks) {
  if (!hook || !HOOKS.includes(hook.name) || hookMap.has(hook.name) || !Array.isArray(hook.command) || !hook.command.length || !hook.command.every(item => typeof item === "string" && item.length > 0) || !Number.isInteger(hook.timeout_seconds) || hook.timeout_seconds < 1 || hook.timeout_seconds > 300 || hook.idempotency_required !== true || typeof hook.required_output !== "string" || !hook.required_output || !hook.attribution || !ID.test(hook.attribution.owner_repo) || !ID.test(hook.attribution.actor)) die("operation hook allowlist is invalid");
  const stat = (() => { try { return fs.statSync(hook.command[0]); } catch { return null; } })();
  if (!stat?.isFile() || (stat.mode & 0o111) === 0) die(`allowlisted hook executable is unavailable: ${hook.name}`);
  hookMap.set(hook.name, hook);
}
const planHooks = new Map((plan.hooks ?? []).map(hook => [hook.name, hook]));
for (const name of ["preflight", "drain", "verify"]) if (planHooks.get(name)?.idempotency_required !== true) die(`plan lacks an idempotent ${name} hook`);
if (plan.rollback.hook !== "rollback") die("only explicit rollback hook is supported by this v1 executor");
const operationDigest = hash(operation);
const initial = { kind: "brokkr-relocation-journal", schema_version: "v1", plan_id: plan.plan_id, plan_digest: plan.plan_digest, operation_id: operation.id, operation_digest: operationDigest, reversal_recipe: operation.reversal_recipe, phase: "preflight", outcome: "running", old_placement_retained: true, events: [] };
const journalId = `journal-${hash({ plan_id: plan.plan_id, plan_digest: plan.plan_digest, operation_id: operation.id, operation_digest: operationDigest }).slice(7, 47)}`;
let journal;
if (fs.existsSync(args.journal)) {
  if (!args.resume) die("journal exists; use --resume to continue or roll back the same operation");
  journal = read(args.journal, "journal");
  if (journal.plan_digest !== plan.plan_digest || journal.operation_digest !== operationDigest || journal.outcome === "promoted") die("journal does not describe a resumable identical operation");
} else { if (args.resume) die("no journal exists to resume"); journal = initial; writeJournal(journal); }
const event = (phase, outcome, detail) => { journal.phase = phase; journal.events.push({ at: args.now, phase, outcome, detail, platform_fault_refs: operation.platform_fault_refs, capability_contract: { version: 1, required: operation.monitoring.required_capabilities, evidence: { "node-capability-freshness": { observed_at: args.now, status: "fresh" }, "lifecycle-result": { observed_at: args.now, result: outcome } } } }); writeJournal(journal); };
const terminalHookOutcome = outcome => ({ succeeded: "success", failed: "failed", interrupted: "partial" }[outcome]);
const terminalLifecycle = ({ phase, outcome, substrateOutcome, rollback }) => {
  const hookResults = ["preflight", "drain", "verify", "rollback", "compensate"].flatMap(name => {
    const events = journal.events.filter(item => item.phase === name && terminalHookOutcome(item.outcome));
    if (!events.length) return [];
    const latest = events.at(-1);
    return [{
      result_id: `hook-${name}-${hash({ name, outcome: latest.outcome, plan_id: plan.lifecycle_result.plan_id, attempt_id: plan.lifecycle_result.attempt_id, idempotency_key: plan.lifecycle_result.idempotency_key }).slice(7, 31)}`,
      hook: name,
      attempt_id: plan.lifecycle_result.attempt_id,
      plan_id: plan.lifecycle_result.plan_id,
      plan_digest: plan.lifecycle_result.plan_digest,
      desired_revision: plan.lifecycle_result.desired_revision,
      observation_evidence_id: plan.lifecycle_result.observation_evidence_id,
      action: "relocate",
      deadline: plan.lifecycle_result.deadline,
      idempotency_key: plan.lifecycle_result.idempotency_key,
      outcome: terminalHookOutcome(latest.outcome)
    }];
  });
  const result = { ...plan.lifecycle_result, action: "relocate", phase, outcome, hook_results: hookResults, substrate: { outcome: substrateOutcome, rollback, pre_state_evidence_id: plan.lifecycle_result.observation_evidence_id }, created_at: args.now };
  if (schemaErrors(schema, result).length) die("derived terminal lifecycle result violates the pinned contract");
  return result;
};
const recordRollbackTerminal = state => {
  const details = {
    verified: { substrateOutcome: "failed", rollback: "verified" },
    failed: { substrateOutcome: "failed", rollback: "failed" },
    interrupted: { substrateOutcome: "partial", rollback: "failed" }
  }[state];
  journal.lifecycle_result = terminalLifecycle({ phase: "substrate_rollback", outcome: "blocked", ...details });
  journal.rollback_status = state;
  writeJournal(journal);
};
const run = name => {
  const hook = hookMap.get(name); event(name, "started", hook.attribution);
  const result = spawnSync(hook.command[0], hook.command.slice(1), { encoding: "utf8", timeout: hook.timeout_seconds * 1000, maxBuffer: 64_000, env: { ...process.env, BROKKR_LIFECYCLE_IDEMPOTENCY_KEY: plan.lifecycle_result.idempotency_key, BROKKR_RELOCATION_OPERATION_ID: operation.id, BROKKR_RELOCATION_HOOK: name } });
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
  // Exit 75 is the sole retryable hook outcome.  It records an interruption
  // without claiming either hook success or rollback; an identical --resume
  // invocation may safely rerun this idempotent allowlisted hook.
  if (result.status === 75) { event(name, "interrupted", hook.attribution); return "interrupted"; }
  if (result.error || result.status !== 0 || !output.includes(hook.required_output)) {
    event(name, "failed", { ...hook.attribution, reason: result.error ? "execution-error" : result.signal ? "timeout" : "nonzero-or-missing-required-output" }); return false;
  }
  event(name, "succeeded", hook.attribution); return true;
};
const rollback = reason => { event("rollback", "started", { reason }); const outcome = run("rollback"); if (outcome === "interrupted") { journal.outcome = "interrupted"; journal.phase = "rollback"; recordRollbackTerminal("interrupted"); process.exit(4); } if (!outcome) { journal.outcome = "blocked"; journal.phase = "rollback"; recordRollbackTerminal("failed"); die("rollback hook failed; old placement remains retained"); } journal.outcome = "blocked"; journal.phase = "rollback"; recordRollbackTerminal("verified"); process.exit(3); };
const order = ["preflight", "drain", "apply", "verify", "representative_data"];
let start = order.indexOf(journal.phase);
if (journal.phase === "awaiting_operator") start = order.indexOf("apply");
else if (journal.phase === "rollback") {
  if (journal.outcome === "interrupted" && journal.events.at(-1)?.phase === "rollback" && journal.events.at(-1)?.outcome === "interrupted") rollback("resume-rollback");
  die("journal is already rolled back; create a new operation for another attempt");
}
else if (journal.events.some(item => item.phase === journal.phase && item.outcome === "succeeded")) start += 1;
for (let i = Math.max(0, start); i < order.length; i += 1) {
  const phase = order[i];
  if (phase === "apply" && operation.physical_move_required && journal.phase !== "awaiting_operator") { journal.phase = "awaiting_operator"; event("awaiting_operator", "blocked", { reason: "physical-move-required" }); process.exit(4); }
  if (phase === "apply" && operation.physical_move_required && args.operator_confirm !== "physical-move") die("physical move requires --operator-confirm physical-move");
  const outcome = run(phase);
  if (outcome === "interrupted") { journal.outcome = "interrupted"; writeJournal(journal); process.exit(4); }
  if (!outcome) rollback(`${phase}-failed`);
}
journal.phase = "promoted"; journal.outcome = "promoted"; journal.old_placement_retained = false; event("promoted", "succeeded", { representative_data: "verified", irreversible: "not-performed" });
journal.lifecycle_result = terminalLifecycle({ phase: "verify", outcome: "promoted", substrateOutcome: "success", rollback: "not_needed" }); writeJournal(journal);
process.stdout.write(`${canonicalJson({ kind: "brokkr-relocation-result", schema_version: "v1", outcome: "promoted", journal: { id: journalId, digest: hash(journal) }, lifecycle_result: journal.lifecycle_result, monitoring: { contract: operation.monitoring.contract, capability_contract: { version: 1, required: operation.monitoring.required_capabilities, evidence: { "node-capability-freshness": { observed_at: args.now, status: "fresh" }, "lifecycle-result": { observed_at: args.now, result: "promoted" } } }, platform_fault_refs: operation.platform_fault_refs } })}\n`);
