// Hermetic Debian maintenance execution seam (brokkr#35). It contains no
// subprocess, package-manager, reboot, deployment, or remote-host effects.
// Those effects are narrowly injected by a separately reviewed host adapter.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { canonicalJson, durationToMs, policyDigest, strictUtc } from "./lib/maintenance-policy-contract.mjs";
import { windowStatus } from "./maintenance-controller.mjs";
import { runMaintenanceAttempt } from "./maintenance-attempt-journal.mjs";

const MAX_PLAN_AGE_MS = 5 * 60 * 1000;
const MAX_EVENTS = 32;
const MAX_INVENTORY_BYTES = 16_384;
const hash = value => `sha256:${crypto.createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
const fail = (code, cause) => { const error = new Error(code); error.code = code; error.cause = cause; throw error; };
const parseUtc = value => strictUtc(value) ? Date.parse(value) : fail("invalid_timestamp");
const read = file => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (error) { if (error.code === "ENOENT") return null; throw error; } };
function write(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 }); const temp = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  const fd = fs.openSync(temp, "wx", 0o600); try { fs.writeFileSync(fd, `${canonicalJson(value)}\n`); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(temp, file); const directory = fs.openSync(path.dirname(file), "r"); try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
}
function safeDetail(value) { // Never journal arbitrary adapter output.
  const text = value && typeof value === "object" ? canonicalJson(value) : String(value ?? "");
  return { digest: `sha256:${crypto.createHash("sha256").update(text).digest("hex")}`, bytes: Buffer.byteLength(text), summary: typeof value?.code === "string" ? value.code.slice(0, 96) : typeof value?.ok === "boolean" ? `ok=${value.ok}` : "adapter-evidence" };
}
function inventory(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("inventory_invalid");
  const allowed = new Set(["kernel", "packages", "reboot_required", "dpkg_status"]); const output = {};
  for (const [key, item] of Object.entries(value)) {
    if (!allowed.has(key)) fail("inventory_field_not_allowed");
    if (typeof item === "string" && item.length <= 256) output[key] = item;
    else if (typeof item === "boolean") output[key] = item;
    else if (Array.isArray(item) && item.length <= 256 && item.every(x => typeof x === "string" && x.length <= 256)) output[key] = [...item].sort();
    else fail("inventory_invalid");
  }
  if (Buffer.byteLength(canonicalJson(output)) > MAX_INVENTORY_BYTES) fail("inventory_too_large");
  return output;
}
function assertPolicy(policy) {
  if (!policy || policy.kind !== "maintenance-policy" || policy.schema_version !== "v1" || typeof policy.policy_id !== "string" || policy.policy_digest !== policyDigest(policy)) fail("policy_invalid");
  return policy;
}
function verifyPlan({ plan, policy, nowMs, nodeId }) {
  if (!plan || plan.kind !== "brokkr-maintenance-plan" || plan.schema_version !== "v1" || plan.outcome !== "planned") fail("plan_not_planned");
  const copy = structuredClone(plan); const supplied = copy.plan_digest; delete copy.plan_digest; if (supplied !== hash(copy)) fail("plan_digest_invalid");
  if (!plan.decision || !["on_schedule", "run_deferred"].includes(plan.decision.effect) || !Array.isArray(plan.blockers) || plan.blockers.length !== 0 || !Array.isArray(plan.hook_gaps) || !Array.isArray(plan.unmet_policy_classes) || typeof plan.inventory_evidence_id !== "string" || typeof plan.running_kernel !== "string") fail("plan_not_authorized");
  if (typeof plan.plan_id !== "string" || typeof plan.node_id !== "string" || !Array.isArray(plan.candidates) || plan.plan_id.length > 128 || plan.node_id.length > 128 || plan.candidates.length > 512 || plan.hook_gaps.length > 64 || plan.unmet_policy_classes.length > 64) fail("plan_bounds_invalid");
  if (plan.node_id !== nodeId || !policy.selector.node_ids.includes(nodeId)) fail("plan_node_not_selected");
  if (plan.policy_digest !== policy.policy_digest || plan.policy_id !== policy.policy_id) fail("policy_changed");
  const age = nowMs - parseUtc(plan.created_at); if (age < 0 || age > MAX_PLAN_AGE_MS) fail("plan_stale");
  const gates = plan.gates;
  if (!gates || gates.package_manager_lock !== "unlocked" || gates.disk !== "sufficient" || !["mains", "not_applicable"].includes(gates.power) || gates.clock !== "synchronized" || !["ready", "not_applicable"].includes(gates.workload_hooks)) fail("plan_gates_not_safe");
  const kernels = plan.candidates?.filter(item => item.class === "kernel") ?? [];
  if (kernels.length && gates.kernel_recovery !== "eligible") fail("kernel_recovery_not_safe");
  if ((gates.workload_hooks === "ready" && plan.hook_gaps.length !== 0) || (gates.workload_hooks === "not_applicable" && plan.hook_gaps.length !== 0)) fail("hook_gaps_inconsistent");
  if (!Array.isArray(plan.candidates) || !plan.candidates.every(item => item.eligible === true && policy.updates.allowed_sources.includes(item.source) && policy.updates.allowed_classes.includes(item.class))) fail("candidate_not_allowlisted");
}
function currentAdmission({ plan, policy, nodeId, adapters }) {
  const clock = adapters.clock(); if (!clock || clock.synchronized !== true || !strictUtc(clock.now)) fail("clock_uncertain");
  const current = assertPolicy(adapters.currentPolicy()); assertPolicy(policy);
  if (current.policy_id !== policy.policy_id || current.policy_digest !== policy.policy_digest) fail("policy_changed_before_mutation");
  if (current.state?.enabled !== true || current.state?.hold?.active === true || adapters.hold().active === true) fail("held");
  if (!windowStatus(current, parseUtc(clock.now)).eligible) fail("window_closed_before_mutation");
  verifyPlan({ plan, policy: current, nowMs: parseUtc(clock.now), nodeId });
  const status = windowStatus(current, parseUtc(clock.now));
  return { policy: current, now: clock.now, remaining_window_ms: Date.parse(status.occurrence.end) - parseUtc(clock.now) };
}
// All effects are injected, synchronous and individually bounded by the host
// adapter. This layer never retries: #34's finite controller retry budget owns
// retries. `currentPolicy` and `clock` are read once per admission boundary.
export function executeDebianMaintenance({ plan, policy, nodeId = plan?.node_id, journalFile, adapters }) {
  for (const name of ["inventory", "apply", "afterInventory", "currentPolicy", "clock", "hold"]) if (typeof adapters?.[name] !== "function") fail("adapter_contract_invalid");
  assertPolicy(policy); if (read(journalFile) !== null) fail("journal_already_exists");
  if (policy.reboot?.policy === "always_after_window") fail("always_after_window_unsupported");
  // This first boundary is before inventory/drain: no workload mutation happens
  // until plan, current policy, clock and window are all freshly accepted.
  const initial = currentAdmission({ plan, policy, nodeId, adapters });
  const workload = plan.gates.workload_hooks;
  if (workload === "ready") for (const name of ["drain", "verifyDrain", "restoreDrain"]) if (typeof adapters[name] !== "function") fail("drain_adapter_missing");
  if (initial.policy.reboot?.policy !== "never") for (const name of ["reboot", "healthAfterReboot"]) if (typeof adapters[name] !== "function") fail("reboot_adapter_missing_preflight");
  if (typeof adapters.substrateHealth !== "function" || (workload === "ready" && typeof adapters.workloadHealth !== "function")) fail("health_adapter_missing_preflight");
  const journal = { kind: "brokkr-debian-mutation-journal", schema_version: "v1", plan_id: plan.plan_id, plan_digest: plan.plan_digest, policy_digest: initial.policy.policy_digest, node_id: nodeId, unmet_policy_classes: plan.unmet_policy_classes.map(item => ({ class: String(item.class ?? "unknown").slice(0, 64), reason: String(item.reason ?? "unspecified").slice(0, 96) })), outcome: "running", events: [], before_inventory: null, after_inventory: null, reversal: null, failure: null };
  let eventAt = initial.now;
  const event = (phase, outcome, detail) => { if (journal.events.length >= MAX_EVENTS) fail("journal_event_limit"); journal.events.push({ at: eventAt, phase, outcome, detail: safeDetail(detail) }); write(journalFile, journal); };
  let mutationBoundary = false; let drainBoundary = false; let rebootAttempted = false;
  const terminal = (code, error) => {
    journal.failure = { code: String(code).slice(0, 96), diagnostic: safeDetail({ message: String(error?.message ?? code).slice(0, 256) }) };
    journal.outcome = mutationBoundary ? "operator_recovery_required" : drainBoundary ? "drain_recovery_required" : "failed_before_mutation"; write(journalFile, journal);
    if (drainBoundary && !mutationBoundary) {
      event("restore_drain_started", "started", { code });
      try { const restored = adapters.restoreDrain(); event("restore_drain", restored?.ok ? "succeeded" : "failed", restored); if (!restored?.ok) fail("restore_drain_failed"); journal.outcome = "failed_after_drain_restored"; write(journalFile, journal); return { outcome: journal.outcome, reason: code, journal }; }
      catch (restoreError) { journal.outcome = "operator_recovery_required"; journal.reversal = { mode: "operator_restore_required", result: safeDetail({ message: String(restoreError.message ?? restoreError).slice(0, 256) }) }; event("restore_drain", "failed", restoreError); write(journalFile, journal); return { outcome: journal.outcome, reason: code, journal }; }
    }
    if (!mutationBoundary) return { outcome: journal.outcome, reason: code, journal };
    // A recovery attempt is explicitly one-shot, journaled before invocation.
    event("recovery_started", "started", { code });
    try {
      const kernelEligible = rebootAttempted && ["reboot_timeout", "health_recovery_failed", "substrate_health_failed"].includes(code) && typeof adapters.previousKernelRecovery === "function";
      const result = kernelEligible ? adapters.previousKernelRecovery() : null;
      if (kernelEligible && result?.recovered === true && canonicalJson(result.recipe) === canonicalJson({ kind: "previous-kernel", boot_entry: "saved" })) { journal.reversal = { mode: "previous_kernel", boot_entry: "saved", result: safeDetail(result) }; journal.outcome = "recovered_previous_kernel"; event("recovery", "succeeded", result); }
      else { const reprovision = adapters.boundedReprovisionEvidence ? adapters.boundedReprovisionEvidence() : null; journal.reversal = { mode: "forward_recovery_or_reprovision", result: safeDetail(reprovision) }; event("recovery", "recorded", reprovision); }
    } catch (recoveryError) { journal.reversal = { mode: "operator_recovery_required", result: safeDetail({ message: String(recoveryError.message ?? recoveryError).slice(0, 256) }) }; event("recovery", "failed", recoveryError); }
    write(journalFile, journal); return { outcome: journal.outcome, reason: code, journal };
  };
  try {
    journal.before_inventory = inventory(adapters.inventory()); event("inventory_before", "succeeded", journal.before_inventory);
    if (workload === "ready") { event("drain_started", "started", {}); drainBoundary = true; const drained = adapters.drain(); event("drain", drained?.ok ? "succeeded" : "failed", drained); if (!drained?.ok) fail("drain_failed"); const verified = adapters.verifyDrain(); event("drain_verify", verified?.ok ? "succeeded" : "failed", verified); if (!verified?.ok) fail("drain_verify_failed"); }
    // The exact second boundary closes any race while drain was running.
    eventAt = currentAdmission({ plan, policy, nodeId, adapters }).now; event("admission_revalidated", "succeeded", {});
    const applyLimit = { timeout_ms: durationToMs(initial.policy.execution_limits.timeout), remaining_window_ms: eventAt ? currentAdmission({ plan, policy, nodeId, adapters }).remaining_window_ms : 0 };
    event("apply_started", "started", applyLimit); mutationBoundary = true; const applied = adapters.apply(applyLimit); event("apply", applied?.ok ? "succeeded" : "failed", applied); if (!applied?.ok || !Number.isFinite(applied.elapsed_ms) || applied.elapsed_ms < 0 || applied.elapsed_ms > Math.min(applyLimit.timeout_ms, applyLimit.remaining_window_ms)) fail(applied?.interrupted ? "dpkg_interrupted" : "apply_failed");
    if (applied.reboot_required) {
      eventAt = currentAdmission({ plan, policy, nodeId, adapters }).now;
      if (initial.policy.reboot?.policy === "never") fail("reboot_forbidden_by_policy");
      const rebootLimit = { max_reboot_wait_ms: durationToMs(initial.policy.reboot.max_reboot_wait) }; event("reboot_started", "started", rebootLimit); rebootAttempted = true; const rebooted = adapters.reboot(rebootLimit); event("reboot", rebooted?.ok ? "succeeded" : "failed", rebooted); if (!rebooted?.ok || !Number.isFinite(rebooted.elapsed_ms) || rebooted.elapsed_ms < 0 || rebooted.elapsed_ms > rebootLimit.max_reboot_wait_ms) fail("reboot_timeout");
      const health = adapters.healthAfterReboot(rebootLimit); event("health", health?.ok ? "succeeded" : "failed", health); if (!health?.ok || !Number.isFinite(health.elapsed_ms) || health.elapsed_ms < 0 || health.elapsed_ms > rebootLimit.max_reboot_wait_ms) fail("health_recovery_failed");
    }
    const substrate = adapters.substrateHealth(); event("substrate_health", substrate?.ok ? "succeeded" : "failed", substrate); if (!substrate?.ok) fail("substrate_health_failed");
    if (workload === "ready") { event("restore_drain_started", "started", {}); const restored = adapters.restoreDrain(); event("restore_drain", restored?.ok ? "succeeded" : "failed", restored); if (!restored?.ok) fail("restore_drain_failed_after_apply"); const workloadHealth = adapters.workloadHealth(); event("workload_health", workloadHealth?.ok ? "succeeded" : "failed", workloadHealth); if (!workloadHealth?.ok) fail("workload_health_failed"); }
    journal.after_inventory = inventory(adapters.afterInventory()); event("inventory_after", "succeeded", journal.after_inventory); journal.outcome = "succeeded"; write(journalFile, journal); return { outcome: "succeeded", journal };
  } catch (error) { return terminal(error.code ?? "executor_failed", error); }
}
export function runDebianMaintenance(options) {
  const {
    binding, attemptJournalDir, artifacts, admission, recovery, reconcile = null,
    watch, safeStateReadback, ...executor
  } = options ?? {};
  if (!binding || typeof attemptJournalDir !== "string" || !artifacts || !admission || !recovery ||
      typeof watch !== "function" || typeof safeStateReadback !== "function") fail("attempt_journal_contract_invalid");
  const journalFile = path.join(attemptJournalDir, "mutation", `${binding.attempt_id}.json`);
  let executionResult = null;
  return runMaintenanceAttempt({
    journalDir: attemptJournalDir, binding, artifacts, admission, recovery, reconcile,
    phases: {
      apply: () => {
        executionResult = executeDebianMaintenance({ ...executor, journalFile });
        if (executionResult.outcome !== "succeeded") fail("executor_postconditions_unmet");
        return { applied: true };
      },
      verify: () => ({ verified: executionResult?.outcome === "succeeded" }),
      watch,
      safeStateReadback,
    },
  });
}
