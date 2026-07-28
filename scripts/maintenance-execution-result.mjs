// Metadata-only ADR-008 v2 maintenance result projection. This module has no
// filesystem, process, network, package, service, or host-effect capability.
import {
  autonomyDigest,
  strictUtc,
} from "./lib/autonomy-authorization.mjs";
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const DIGEST = /^sha256:[a-f0-9]{64}$/;
const UTC = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const REF = /^ref:[a-z][a-z0-9-]{2,120}$/;
const DOMAIN = "no-reboot-security-bugfix-maintenance";
const JOURNAL_PHASES = new Set(["prepare", "apply", "verify", "watch", "commit", "unknown", "recover", "quarantine", "disarm", "terminally-blocked"]);
const JOURNAL_OUTCOMES = { prepare: "prepared", apply: "applied", verify: "verified", watch: "watching", commit: "committed", unknown: "unknown", recover: "recovered", quarantine: "quarantined", disarm: "disarmed", "terminally-blocked": "terminally-blocked" };
const NEXT = {
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
};
const PHASE_SEQUENCE_BOUNDS = {
  prepare: [1, 1], apply: [2, 2], verify: [3, 3], watch: [4, 4],
  commit: [5, 5], unknown: [2, 5], recover: [3, 6],
  quarantine: [4, 7], disarm: [5, 8], "terminally-blocked": [3, 8],
};
const MAX_SEQUENCE_WITHOUT_WATCH = {
  prepare: 1, apply: 2, verify: 3, unknown: 4, recover: 5,
  quarantine: 6, disarm: 7, "terminally-blocked": 7,
};
const MIN_SEQUENCE_WITH_WATCH = {
  watch: 4, commit: 5, unknown: 5, recover: 6,
  quarantine: 7, disarm: 8, "terminally-blocked": 6,
};
const exact = (value, keys) => value && typeof value === "object" && !Array.isArray(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
const fail = code => { throw new Error(`maintenance_execution_result_${code}`); };
const validResultUtc = value => (
  typeof value === "string" && UTC.test(value) &&
  !Number.isNaN(Date.parse(value)) &&
  new Date(value).toISOString().replace(".000Z", "Z") === value
);
const validDigest = value => typeof value === "string" && DIGEST.test(value);
const validId = value => typeof value === "string" && ID.test(value);
const assert = (ok, code) => { if (!ok) fail(code); };

function validateWatchAnchor(anchor, journal, watch) {
  assert(exact(anchor, [
    "kind", "schema_version", "journal_id", "mutation_id", "attempt_id",
    "target_scope_digest", "candidate_digest", "binding_digest",
    "journal_tail_digest", "anchored_at", "anchor_digest",
  ]) &&
    anchor.kind === "brokkr-durable-watch-anchor" &&
    anchor.schema_version === "v1" &&
    anchor.journal_id === journal.journal_id &&
    anchor.mutation_id === journal.binding.mutation_id &&
    anchor.attempt_id === journal.binding.attempt_id &&
    anchor.target_scope_digest === journal.binding.target_scope_digest &&
    anchor.candidate_digest === journal.binding.candidate_digest &&
    anchor.binding_digest === journal.binding_digest &&
    anchor.journal_tail_digest === watch?.receipt_digest &&
    strictUtc(anchor.anchored_at) &&
    Date.parse(anchor.anchored_at) >= Date.parse(watch?.recorded_at) &&
    anchor.anchor_digest === autonomyDigest(anchor, "anchor_digest"),
  "journal_watch_anchor");
  return anchor;
}

function validateJournal(journal, watchAnchor) {
  assert(exact(journal, ["kind", "schema_version", "journal_id", "domain", "constitution_digest", "binding", "binding_digest", "entries", "extensions"]), "journal_shape");
  assert(journal.kind === "autonomous-mutation-journal" && journal.schema_version === "v2" &&
    validId(journal.journal_id) && journal.domain === DOMAIN &&
    validDigest(journal.constitution_digest), "journal_identity");
  const binding = journal.binding;
  assert(exact(binding, ["mutation_id", "attempt_id", "recovery_disarm_id", "idempotency_key", "writer_owner", "owner_authority_ref", "owner_authority_digest", "configuration_owner", "configuration_owner_authority_ref", "configuration_owner_authority_digest", "target_scope_digest", "admission_coverage_digest", "admission_binding_state", "owner_identity", "controller_identity", "watchdog_identity", "kill_switch_identity", "recovery_worker_identity", "risk_scope", "candidate_digest", "config_digest", "evidence_digest", "policy_digest", "baseline_digest", "postconditions_digest", "deadline", "canary", "recovery"]) &&
    [
      "mutation_id", "attempt_id", "recovery_disarm_id", "idempotency_key",
      "writer_owner", "configuration_owner", "owner_identity",
      "controller_identity", "watchdog_identity", "kill_switch_identity",
      "recovery_worker_identity",
    ].every(field => validId(binding[field])) &&
    [
      "owner_authority_ref", "configuration_owner_authority_ref",
    ].every(field => typeof binding[field] === "string" &&
      REF.test(binding[field])) &&
    [
      "owner_authority_digest", "configuration_owner_authority_digest",
      "target_scope_digest", "admission_coverage_digest",
      "candidate_digest", "config_digest", "evidence_digest",
      "policy_digest", "baseline_digest", "postconditions_digest",
    ].every(field => validDigest(binding[field])) &&
    ["armed-canary", "armed-fleet"].includes(binding.admission_binding_state) &&
    strictUtc(binding.deadline) &&
    binding.writer_owner === "brokkr" &&
    binding.configuration_owner === "brokkr" &&
    new Set([
      binding.mutation_id, binding.attempt_id, binding.recovery_disarm_id,
      binding.idempotency_key,
    ]).size === 4 &&
    new Set([
      binding.owner_identity, binding.controller_identity,
      binding.watchdog_identity, binding.kill_switch_identity,
      binding.recovery_worker_identity,
    ]).size === 5 &&
    journal.binding_digest === autonomyDigest(binding) &&
    journal.journal_id === binding.mutation_id &&
    binding.risk_scope === DOMAIN &&
    exact(binding.canary, ["scope_digest", "target_count"]) &&
    binding.canary.scope_digest === binding.target_scope_digest &&
    binding.canary.target_count === 1 &&
    exact(binding.recovery, ["class", "worker_identity", "descriptor_digest", "disarms_after_action"]) &&
    binding.recovery.class === "R-forward" &&
    binding.recovery.worker_identity === binding.recovery_worker_identity &&
    validDigest(binding.recovery.descriptor_digest) &&
    binding.recovery.disarms_after_action === true, "journal_binding");
  assert(Array.isArray(journal.entries) && journal.entries.length >= 2 &&
    Array.isArray(journal.extensions) && journal.extensions.length === 0,
  "journal_entries");
  const tail = journal.entries.at(-1);
  let previous = null;
  const entryIds = new Set();
  for (let index = 0; index < journal.entries.length; index += 1) {
    const entry = journal.entries[index];
    assert(exact(entry, ["entry_id", "sequence", "recorded_at", "phase", "outcome", "executor_identity", "binding_digest", "quarantine", "coverage_transition", "terminal_reason_digest", "previous_receipt_digest", "receipt_digest", "content_refs"]), "journal_entry_shape");
    const recoveryPhase = ["recover", "quarantine", "disarm", "terminally-blocked"].includes(entry.phase);
    const expectedActor = recoveryPhase ? binding.recovery_worker_identity :
      binding.controller_identity;
    assert(validId(entry.entry_id) && !entryIds.has(entry.entry_id) &&
      Number.isInteger(entry.sequence) && entry.sequence === index + 1 &&
      JOURNAL_PHASES.has(entry.phase) &&
      entry.outcome === JOURNAL_OUTCOMES[entry.phase] &&
      strictUtc(entry.recorded_at) &&
      entry.binding_digest === journal.binding_digest &&
      entry.previous_receipt_digest === previous &&
      entry.receipt_digest === autonomyDigest(entry, "receipt_digest") &&
      validId(entry.executor_identity) &&
      (entry.phase === "unknown" ?
        [binding.controller_identity, binding.watchdog_identity].includes(entry.executor_identity) :
        entry.executor_identity === expectedActor) &&
      exact(entry.quarantine, ["state", "reason_digest"]) &&
      ["not-applicable", "active"].includes(entry.quarantine.state) &&
      validDigest(entry.quarantine.reason_digest) &&
      (entry.terminal_reason_digest === null ||
        validDigest(entry.terminal_reason_digest)) &&
      Array.isArray(entry.content_refs) && entry.content_refs.length >= 1 &&
      new Set(entry.content_refs).size === entry.content_refs.length &&
      entry.content_refs.every(ref => typeof ref === "string" && REF.test(ref)),
    "journal_entry");
    if (index > 0) {
      assert(NEXT[journal.entries[index - 1].phase].has(entry.phase) &&
        Date.parse(entry.recorded_at) >=
          Date.parse(journal.entries[index - 1].recorded_at),
      "journal_transition");
    }
    if (["unknown", "disarm", "terminally-blocked"].includes(entry.phase)) {
      assert(validDigest(entry.terminal_reason_digest), "journal_reason");
    }
    if (entry.phase === "terminally-blocked") {
      assert(entry.quarantine.state === "active", "journal_quarantine");
    }
    if (["disarm", "terminally-blocked"].includes(entry.phase)) {
      assert(exact(entry.coverage_transition, [
        "from_state", "to_state", "target_scope_digest", "actor_identity",
      ]) &&
        entry.coverage_transition.from_state === binding.admission_binding_state &&
        entry.coverage_transition.to_state === "shadow" &&
        entry.coverage_transition.target_scope_digest ===
          binding.target_scope_digest &&
        entry.coverage_transition.actor_identity ===
          binding.recovery_worker_identity,
      "journal_coverage_transition");
    } else {
      assert(entry.coverage_transition === null,
        "journal_coverage_transition");
    }
    entryIds.add(entry.entry_id);
    previous = entry.receipt_digest;
  }
  assert(journal.entries[0].phase === "prepare", "journal_prepare");
  const preparedAt = Date.parse(journal.entries[0].recorded_at);
  const deadlineAt = Date.parse(binding.deadline);
  assert(deadlineAt >= preparedAt && deadlineAt - preparedAt <= 4_200_000,
    "journal_deadline_bound_invalid");
  for (const entry of journal.entries) {
    if (["prepare", "apply", "verify", "watch", "commit"].includes(entry.phase)) {
      assert(Date.parse(entry.recorded_at) <= deadlineAt &&
        Date.parse(entry.recorded_at) - preparedAt <= 4_200_000,
      "journal_deadline_exceeded");
    }
  }
  const watch = journal.entries.find(entry => entry.phase === "watch");
  if (watch) {
    const anchor = validateWatchAnchor(watchAnchor, journal, watch);
    assert(Date.parse(anchor.anchored_at) - preparedAt <= 300_000,
      "journal_apply_verify_budget_exceeded");
    if (tail.phase !== "watch") {
      assert(Date.parse(tail.recorded_at) >= Date.parse(anchor.anchored_at),
        "journal_watch_anchor_timing");
    }
  } else {
    assert(watchAnchor === null, "journal_watch_anchor");
  }
  if (tail.phase === "commit") {
    const watchedFor = Date.parse(tail.recorded_at) -
      Date.parse(watchAnchor?.anchored_at);
    assert(watch && watchedFor >= 3_600_000,
      "journal_watch_incomplete");
    assert(watchedFor <= 3_900_000, "journal_commit_grace_exceeded");
  }
  return tail;
}
function validateInput(input) {
  assert(exact(input, ["journal", "watch_anchor", "terminal_receipt", "source", "freshness", "execution_epoch", "probe_coverage"]), "input_shape");
  const tail = validateJournal(input.journal, input.watch_anchor);
  assert(exact(input.source, ["source_id", "source_revision_digest", "configuration_digest"]) && validId(input.source.source_id) && validDigest(input.source.source_revision_digest) && validDigest(input.source.configuration_digest) && input.source.configuration_digest === input.journal.binding.config_digest, "source_identity");
  assert(exact(input.freshness, ["observed_at", "valid_until"]) && validResultUtc(input.freshness.observed_at) && validResultUtc(input.freshness.valid_until) && Date.parse(input.freshness.valid_until) > Date.parse(input.freshness.observed_at), "freshness");
  assert(Number.isSafeInteger(input.execution_epoch) &&
    input.execution_epoch >= 1,
  "epoch");
  assert(exact(input.probe_coverage, ["expected_count", "observed_count"]) && Number.isInteger(input.probe_coverage.expected_count) && Number.isInteger(input.probe_coverage.observed_count) && input.probe_coverage.expected_count >= 0 && input.probe_coverage.expected_count <= 1024 && input.probe_coverage.observed_count >= 0 && input.probe_coverage.observed_count <= input.probe_coverage.expected_count, "probe_coverage");
  const receipt = input.terminal_receipt;
  assert(exact(receipt, ["receipt_id", "receipt_digest", "journal_id", "binding_digest", "journal_tail_digest", "reconciliation"]), "receipt_shape");
  assert(validId(receipt.receipt_id) &&
    receipt.receipt_digest === autonomyDigest(receipt, "receipt_digest") &&
    receipt.journal_id === input.journal.journal_id &&
    receipt.binding_digest === input.journal.binding_digest &&
    receipt.journal_tail_digest === tail.receipt_digest &&
    ["reconciled", "unreconciled", "failed"].includes(receipt.reconciliation),
  "receipt_binding");
  return tail;
}
function statusFor(input, tail, now) {
  if (input.terminal_receipt.reconciliation === "unreconciled") return "unreconciled";
  if (input.terminal_receipt.reconciliation === "failed") return "failed";
  if (tail.phase === "unknown") return "unknown";
  if (tail.phase === "terminally-blocked") return "terminally-blocked";
  if (tail.phase === "disarm") return "disarmed";
  if (tail.phase === "recover" || input.journal.entries.some(entry => entry?.phase === "recover")) return "recovered-by-worker";
  if (tail.phase === "commit") {
    return Date.parse(now) >= Date.parse(input.freshness.valid_until) ?
      "stale" : "clean";
  }
  return "failed";
}
function recoveryStateFor(outcome) {
  if (outcome === "clean") return "not-required";
  if (["unknown", "stale", "unreconciled"].includes(outcome)) return "unknown";
  return outcome;
}
function expectedOutcome(result) {
  if (result.reconciliation === "unreconciled") return "unreconciled";
  if (result.reconciliation === "failed") return "failed";
  if (result.phase === "unknown") return "unknown";
  if (result.phase === "terminally-blocked") return "terminally-blocked";
  if (result.phase === "disarm") return "disarmed";
  if (result.phase === "recover" || result.phase === "quarantine") {
    return "recovered-by-worker";
  }
  if (result.phase === "commit") {
    if (Date.parse(result.freshness.evaluated_at) >=
      Date.parse(result.freshness.valid_until)) return "stale";
    return result.probe_coverage.expected_count > 0 &&
      result.probe_coverage.state === "complete" ? "clean" : "unknown";
  }
  return "failed";
}
export function projectMaintenanceExecutionResult(input, options = {}) {
  const tail = validateInput(input);
  assert(exact(options, ["now"]), "projection_time_required");
  const { now } = options;
  assert(validResultUtc(now) &&
    Date.parse(now) >= Date.parse(input.freshness.observed_at),
  "projection_time");
  assert(Date.parse(now) >= Date.parse(tail.recorded_at),
    "projection_time");
  if (input.watch_anchor !== null) {
    assert(Date.parse(now) >= Date.parse(input.watch_anchor.anchored_at),
      "projection_time");
  }
  const baseOutcome = statusFor(input, tail, now);
  const probeState = input.probe_coverage.expected_count === 0 ? "unknown" :
    input.probe_coverage.observed_count === input.probe_coverage.expected_count ?
      "complete" : "incomplete";
  const outcome = baseOutcome === "clean" && probeState !== "complete" ?
    "unknown" : baseOutcome;
  const clean = outcome === "clean" && probeState === "complete";
  const health = clean ? "healthy" : (outcome === "unknown" || outcome === "stale" || outcome === "unreconciled" ? "unknown" : "unhealthy");
  const recoveryState = recoveryStateFor(outcome);
  const triggeringUnknown = outcome === "recovered-by-worker" ?
    input.journal.entries.findLast(entry => entry.phase === "unknown") : null;
  const recoveryReasonDigest = outcome === "clean" ? null :
    tail.terminal_reason_digest ??
    triggeringUnknown?.terminal_reason_digest ??
    input.terminal_receipt.receipt_digest;
  const result = {
    kind: "maintenance-execution-result", schema_version: "v1",
    result_id: `result-${input.journal.binding_digest.slice(7, 39)}`,
    source: structuredClone(input.source),
    freshness: {
      ...structuredClone(input.freshness),
      evaluated_at: now,
    },
    execution_epoch: input.execution_epoch,
    journal: {
      journal_id: input.journal.journal_id,
      binding_digest: input.journal.binding_digest,
      config_digest: input.journal.binding.config_digest,
      tail_sequence: tail.sequence,
      tail_recorded_at: tail.recorded_at,
      tail_receipt_digest: tail.receipt_digest,
      watch_anchor: structuredClone(input.watch_anchor),
    },
    receipt: structuredClone(input.terminal_receipt),
    probe_coverage: { expected_count: input.probe_coverage.expected_count, observed_count: input.probe_coverage.observed_count, state: probeState },
    reconciliation: input.terminal_receipt.reconciliation, phase: tail.phase, outcome, health, promotion_eligible: clean,
    recovery: { state: recoveryState, reason_digest: recoveryReasonDigest },
    result_digest: "sha256:".padEnd(71, "0"),
    extensions: [],
  };
  result.result_digest = autonomyDigest(result, "result_digest");
  return result;
}
export function validateMaintenanceExecutionResult(result) {
  assert(exact(result, ["kind", "schema_version", "result_id", "source", "freshness", "execution_epoch", "journal", "receipt", "probe_coverage", "reconciliation", "phase", "outcome", "health", "promotion_eligible", "recovery", "result_digest", "extensions"]), "result_shape");
  assert(result.kind === "maintenance-execution-result" &&
    result.schema_version === "v1" &&
    result.result_id === `result-${result.journal?.binding_digest?.slice(7, 39)}` &&
    validId(result.result_id) &&
    result.result_digest === autonomyDigest(result, "result_digest") &&
    Array.isArray(result.extensions) && result.extensions.length === 0,
  "result_identity");
  assert(exact(result.source, ["source_id", "source_revision_digest", "configuration_digest"]) && validId(result.source.source_id) && validDigest(result.source.source_revision_digest) && validDigest(result.source.configuration_digest), "result_source");
  assert(exact(result.freshness, ["observed_at", "valid_until", "evaluated_at"]) && validResultUtc(result.freshness.observed_at) && validResultUtc(result.freshness.valid_until) && validResultUtc(result.freshness.evaluated_at) && Date.parse(result.freshness.valid_until) > Date.parse(result.freshness.observed_at) && Date.parse(result.freshness.evaluated_at) >= Date.parse(result.freshness.observed_at), "result_freshness");
  assert(Number.isSafeInteger(result.execution_epoch) &&
    result.execution_epoch >= 1 &&
    exact(result.journal, [
      "journal_id", "binding_digest", "config_digest", "tail_sequence",
      "tail_recorded_at", "tail_receipt_digest", "watch_anchor",
    ]) &&
    validId(result.journal.journal_id) &&
    validDigest(result.journal.binding_digest) &&
    result.journal.config_digest === result.source.configuration_digest &&
    Number.isInteger(result.journal.tail_sequence) &&
    result.journal.tail_sequence >= 1 &&
    strictUtc(result.journal.tail_recorded_at) &&
    Date.parse(result.freshness.evaluated_at) >=
      Date.parse(result.journal.tail_recorded_at) &&
    validDigest(result.journal.tail_receipt_digest),
  "result_journal");
  const resultAnchor = result.journal.watch_anchor;
  const sequenceBounds = PHASE_SEQUENCE_BOUNDS[result.phase];
  assert(sequenceBounds !== undefined &&
    result.journal.tail_sequence >= sequenceBounds[0] &&
    result.journal.tail_sequence <= sequenceBounds[1],
  "result_journal");
  const maxWithoutWatch = MAX_SEQUENCE_WITHOUT_WATCH[result.phase];
  const anchorRequired = result.phase === "watch" ||
    result.phase === "commit" ||
    (maxWithoutWatch !== undefined &&
      result.journal.tail_sequence > maxWithoutWatch);
  const minWithWatch = MIN_SEQUENCE_WITH_WATCH[result.phase];
  assert(resultAnchor === null ?
    !anchorRequired :
    minWithWatch !== undefined &&
      result.journal.tail_sequence >= minWithWatch,
  "result_watch_anchor");
  if (resultAnchor !== null) {
    assert(exact(resultAnchor, [
      "kind", "schema_version", "journal_id", "mutation_id", "attempt_id",
      "target_scope_digest", "candidate_digest", "binding_digest",
      "journal_tail_digest", "anchored_at", "anchor_digest",
    ]) &&
      resultAnchor.kind === "brokkr-durable-watch-anchor" &&
      resultAnchor.schema_version === "v1" &&
      resultAnchor.journal_id === result.journal.journal_id &&
      resultAnchor.mutation_id === result.journal.journal_id &&
      resultAnchor.binding_digest === result.journal.binding_digest &&
      validId(resultAnchor.mutation_id) &&
      validId(resultAnchor.attempt_id) &&
      validDigest(resultAnchor.target_scope_digest) &&
      validDigest(resultAnchor.candidate_digest) &&
      validDigest(resultAnchor.journal_tail_digest) &&
      strictUtc(resultAnchor.anchored_at) &&
      Date.parse(result.freshness.evaluated_at) >=
        Date.parse(resultAnchor.anchored_at) &&
      (result.phase === "watch" ||
        Date.parse(result.journal.tail_recorded_at) >=
          Date.parse(resultAnchor.anchored_at)) &&
      resultAnchor.anchor_digest ===
        autonomyDigest(resultAnchor, "anchor_digest"),
    "result_watch_anchor");
  }
  if (result.phase === "commit") {
    const watchedFor = Date.parse(result.journal.tail_recorded_at) -
      Date.parse(resultAnchor?.anchored_at);
    assert(resultAnchor !== null && watchedFor >= 3_600_000 &&
      watchedFor <= 3_900_000,
    "result_watch_anchor");
  }
  assert(exact(result.receipt, ["receipt_id", "receipt_digest", "journal_id", "binding_digest", "journal_tail_digest", "reconciliation"]) &&
    validId(result.receipt.receipt_id) &&
    result.receipt.receipt_digest ===
      autonomyDigest(result.receipt, "receipt_digest") &&
    result.receipt.journal_id === result.journal.journal_id &&
    result.receipt.binding_digest === result.journal.binding_digest &&
    result.receipt.journal_tail_digest === result.journal.tail_receipt_digest &&
    result.receipt.reconciliation === result.reconciliation,
  "result_receipt");
  assert(exact(result.probe_coverage, ["expected_count", "observed_count", "state"]) &&
    Number.isInteger(result.probe_coverage.expected_count) &&
    result.probe_coverage.expected_count >= 0 &&
    result.probe_coverage.expected_count <= 1024 &&
    Number.isInteger(result.probe_coverage.observed_count) &&
    result.probe_coverage.observed_count >= 0 &&
    result.probe_coverage.observed_count <=
      result.probe_coverage.expected_count &&
    result.probe_coverage.state ===
      (result.probe_coverage.expected_count === 0 ? "unknown" :
        result.probe_coverage.observed_count ===
          result.probe_coverage.expected_count ? "complete" : "incomplete"),
  "result_probes");
  assert(["reconciled", "unreconciled", "failed"].includes(result.reconciliation) && JOURNAL_PHASES.has(result.phase) && ["clean", "unknown", "stale", "unreconciled", "failed", "recovered-by-worker", "disarmed", "terminally-blocked"].includes(result.outcome) && ["healthy", "unknown", "unhealthy"].includes(result.health) && typeof result.promotion_eligible === "boolean", "result_enums");
  assert(exact(result.recovery, ["state", "reason_digest"]) && ["not-required", "unknown", "failed", "recovered-by-worker", "disarmed", "terminally-blocked"].includes(result.recovery.state) && (result.recovery.reason_digest === null || validDigest(result.recovery.reason_digest)), "result_recovery");
  const outcome = expectedOutcome(result);
  const clean = outcome === "clean" &&
    result.probe_coverage.expected_count > 0 &&
    result.probe_coverage.state === "complete" &&
    result.probe_coverage.observed_count ===
      result.probe_coverage.expected_count;
  const expectedHealth = clean ? "healthy" :
    ["unknown", "stale", "unreconciled"].includes(outcome) ?
      "unknown" : "unhealthy";
  assert(result.outcome === outcome &&
    result.health === expectedHealth &&
    result.promotion_eligible === clean &&
    result.recovery.state === recoveryStateFor(outcome) &&
    (clean ? result.recovery.reason_digest === null :
      validDigest(result.recovery.reason_digest)),
  "result_health_contradiction");
  return true;
}
