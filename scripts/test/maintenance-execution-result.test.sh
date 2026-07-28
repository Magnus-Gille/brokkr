#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ROOT="$ROOT" TMP="$TMP" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
const root = process.env.ROOT;
const { autonomyDigest } = await import(`${root}/scripts/lib/autonomy-authorization.mjs`);
const { schemaErrors } =
  await import(`${root}/scripts/lib/node-substrate-contract.mjs`);
const { projectMaintenanceExecutionResult, validateMaintenanceExecutionResult } =
  await import(`${root}/scripts/maintenance-execution-result.mjs`);
const resultSchema = JSON.parse(fs.readFileSync(
  `${root}/docs/maintenance-execution-result-v1.schema.json`, "utf8",
));
const digest = char => `sha256:${char.repeat(64)}`;
const binding = { mutation_id: "mutation-one", attempt_id: "attempt-one", recovery_disarm_id: "disarm-one", idempotency_key: "idem-one", writer_owner: "brokkr", owner_authority_ref: "ref:owner-authority", owner_authority_digest: digest("a"), configuration_owner: "brokkr", configuration_owner_authority_ref: "ref:config-authority", configuration_owner_authority_digest: digest("b"), target_scope_digest: digest("c"), admission_coverage_digest: digest("d"), admission_binding_state: "armed-canary", owner_identity: "owner-one", controller_identity: "controller-one", watchdog_identity: "watchdog-one", kill_switch_identity: "switch-one", recovery_worker_identity: "recovery-worker", risk_scope: "risk-one", candidate_digest: digest("e"), config_digest: digest("2"), evidence_digest: digest("f"), policy_digest: digest("0"), baseline_digest: digest("1"), postconditions_digest: digest("3"), deadline: "2026-07-28T11:08:00Z", canary: { scope_digest: digest("4"), target_count: 1 }, recovery: { class: "R-forward", worker_identity: "recovery-worker", descriptor_digest: digest("5"), disarms_after_action: true } };
function entry(phase, sequence, reason, actor, bindingDigest, previous) {
  const recoveryPhase = ["recover", "quarantine", "disarm", "terminally-blocked"].includes(phase);
  const value = {
    entry_id: `entry-${sequence}-${phase}`, sequence,
    recorded_at: phase === "commit" ?
      "2026-07-28T11:03:00Z" :
      `2026-07-28T10:0${sequence - 1}:00Z`, phase,
    outcome: {
      prepare: "prepared", apply: "applied", verify: "verified",
      watch: "watching", commit: "committed", unknown: "unknown",
      recover: "recovered", quarantine: "quarantined", disarm: "disarmed",
      "terminally-blocked": "terminally-blocked",
    }[phase],
    executor_identity: actor, binding_digest: bindingDigest,
    quarantine: {
      state: phase === "terminally-blocked" ? "active" : "not-applicable",
      reason_digest: digest("6"),
    },
    coverage_transition: ["disarm", "terminally-blocked"].includes(phase) ? {
      from_state: "armed-canary", to_state: "shadow",
      target_scope_digest: digest("c"), actor_identity: "recovery-worker",
    } : null,
    terminal_reason_digest:
      ["unknown", "disarm", "terminally-blocked"].includes(phase) ?
        (reason ?? digest("6")) : null,
    previous_receipt_digest: previous, receipt_digest: digest("4"),
    content_refs: ["ref:journal-tail"],
  };
  value.receipt_digest = autonomyDigest(value, "receipt_digest");
  return value;
}
function input({ phase = "commit", reconciliation = "reconciled",
  validUntil = "2026-07-28T12:00:00Z", observed = 2, expected = 2 } = {}) {
  const journalBinding = structuredClone(binding);
  journalBinding.mutation_id = "maintenance-journal";
  journalBinding.risk_scope = "no-reboot-security-bugfix-maintenance";
  journalBinding.canary.scope_digest = journalBinding.target_scope_digest;
  const bindingDigest = autonomyDigest(journalBinding);
  let phases;
  if (phase === "commit") phases = ["prepare", "apply", "verify", "watch", "commit"];
  else if (phase === "watch") phases = ["prepare", "apply", "verify", "watch"];
  else if (phase === "unknown") phases = ["prepare", "unknown"];
  else if (phase === "recover") phases = ["prepare", "unknown", "recover"];
  else if (phase === "quarantine") {
    phases = ["prepare", "unknown", "recover", "quarantine"];
  }
  else if (phase === "disarm") phases = ["prepare", "unknown", "recover", "quarantine", "disarm"];
  else phases = ["prepare", "unknown", "terminally-blocked"];
  let previous = null;
  const entries = phases.map((entryPhase, index) => {
    const recoveryPhase = ["recover", "quarantine", "disarm",
      "terminally-blocked"].includes(entryPhase);
    const value = entry(entryPhase, index + 1, null,
      recoveryPhase ? "recovery-worker" : "controller-one",
      bindingDigest, previous);
    previous = value.receipt_digest;
    return value;
  });
  const tail = entries.at(-1);
  const watch = entries.find(row => row.phase === "watch");
  const watchAnchor = watch ? {
    kind: "brokkr-durable-watch-anchor",
    schema_version: "v1",
    journal_id: "maintenance-journal",
    mutation_id: "maintenance-journal",
    attempt_id: journalBinding.attempt_id,
    target_scope_digest: journalBinding.target_scope_digest,
    candidate_digest: journalBinding.candidate_digest,
    binding_digest: bindingDigest,
    journal_tail_digest: watch.receipt_digest,
    anchored_at: watch.recorded_at,
    anchor_digest: digest("7"),
  } : null;
  if (watchAnchor) {
    watchAnchor.anchor_digest = autonomyDigest(
      watchAnchor, "anchor_digest",
    );
  }
  const terminalReceipt = {
    receipt_id: "maintenance-receipt", receipt_digest: digest("5"),
    journal_id: "maintenance-journal", binding_digest: bindingDigest,
    journal_tail_digest: tail.receipt_digest, reconciliation,
  };
  terminalReceipt.receipt_digest =
    autonomyDigest(terminalReceipt, "receipt_digest");
  return {
    journal: {
      kind: "autonomous-mutation-journal", schema_version: "v2",
      journal_id: "maintenance-journal",
      domain: "no-reboot-security-bugfix-maintenance",
      constitution_digest: digest("8"), binding: journalBinding,
      binding_digest: bindingDigest, entries, extensions: [],
    },
    watch_anchor: watchAnchor,
    terminal_receipt: terminalReceipt,
    source: {
      source_id: "brokkr-maintenance", source_revision_digest: digest("1"),
      configuration_digest: digest("2"),
    },
    freshness: {
      observed_at: "2026-07-28T10:00:00Z", valid_until: validUntil,
    },
    execution_epoch: 7,
    probe_coverage: { expected_count: expected, observed_count: observed },
  };
}

for (const name of ["clean", "unknown", "stale", "unreconciled", "failed", "recovered-by-worker", "disarmed", "terminally-blocked"]) {
  const fixture = JSON.parse(fs.readFileSync(
    `${root}/tests/fixtures/maintenance-execution-result/${name}.json`,
    "utf8",
  ));
  assert.deepEqual(schemaErrors(resultSchema, fixture), [], name);
  validateMaintenanceExecutionResult(fixture);
}
const cases = [
  ["clean", {}, "clean", true], ["unknown", { phase: "unknown" }, "unknown", false],
  ["stale", { validUntil: "2026-07-28T11:03:00Z" }, "stale", false],
  ["unreconciled", { reconciliation: "unreconciled" }, "unreconciled", false],
  ["failed", { reconciliation: "failed" }, "failed", false],
  ["recovered", { phase: "recover" }, "recovered-by-worker", false],
  ["disarmed", { phase: "disarm" }, "disarmed", false], ["terminal", { phase: "terminally-blocked" }, "terminally-blocked", false],
];
for (const [name, options, outcome, eligible] of cases) { const result = projectMaintenanceExecutionResult(input(options), { now: "2026-07-28T11:04:00Z" }); assert.equal(result.outcome, outcome, name); assert.equal(result.promotion_eligible, eligible, name); validateMaintenanceExecutionResult(result); }
const malicious = JSON.parse(fs.readFileSync(`${root}/tests/fixtures/maintenance-execution-result/clean.json`, "utf8"));
malicious.command = "apt-get upgrade"; assert.throws(() => validateMaintenanceExecutionResult(malicious), /result_shape/);
for (const forbidden of ["package_log", "credential", "policy", "path", "url", "private_locator"]) { const value = JSON.parse(fs.readFileSync(`${root}/tests/fixtures/maintenance-execution-result/clean.json`, "utf8")); value[forbidden] = "forbidden"; assert.throws(() => validateMaintenanceExecutionResult(value), /result_shape/, forbidden); }
const contradictory = JSON.parse(fs.readFileSync(`${root}/tests/fixtures/maintenance-execution-result/unknown.json`, "utf8"));
contradictory.health = "healthy"; contradictory.promotion_eligible = true;
contradictory.result_digest = autonomyDigest(contradictory, "result_digest");
assert.throws(() => validateMaintenanceExecutionResult(contradictory), /contradiction/);
const mismatch = input(); mismatch.terminal_receipt.journal_tail_digest = digest("9"); assert.throws(() => projectMaintenanceExecutionResult(mismatch), /receipt_binding/);
const forged = input(); forged.journal.entries[0].receipt_digest = digest("9"); assert.throws(() => projectMaintenanceExecutionResult(forged), /journal_entry/);
const skippedPhase = input();
skippedPhase.journal.entries.splice(1, 2);
for (let index = 0; index < skippedPhase.journal.entries.length; index += 1) {
  const row = skippedPhase.journal.entries[index];
  row.sequence = index + 1;
  row.previous_receipt_digest =
    skippedPhase.journal.entries[index - 1]?.receipt_digest ?? null;
  row.receipt_digest = autonomyDigest(row, "receipt_digest");
}
skippedPhase.terminal_receipt.journal_tail_digest =
  skippedPhase.journal.entries.at(-1).receipt_digest;
assert.throws(() => projectMaintenanceExecutionResult(skippedPhase),
  /journal_transition/);
assert.throws(() => projectMaintenanceExecutionResult(input(), {
  now: "2026-07-28T09:59:59Z",
}), /projection_time/);

// Exact-head review regressions: the projection must not manufacture clean
// evidence from a partial v2 validation, an unbound receipt, or a caller that
// omitted the trusted evaluation instant.
assert.throws(() => projectMaintenanceExecutionResult(
  input({ validUntil: "2026-07-28T10:01:00Z" }),
), /projection_time_required/);

const forgedReconciliation = input({ reconciliation: "failed" });
forgedReconciliation.terminal_receipt.reconciliation = "reconciled";
assert.throws(() => projectMaintenanceExecutionResult(
  forgedReconciliation, { now: "2026-07-28T10:30:00Z" },
), /receipt_binding/);

const malformedBinding = input();
malformedBinding.journal.binding.candidate_digest = "not-a-digest";
malformedBinding.journal.binding_digest =
  autonomyDigest(malformedBinding.journal.binding);
let reboundPrevious = null;
for (const row of malformedBinding.journal.entries) {
  row.binding_digest = malformedBinding.journal.binding_digest;
  row.previous_receipt_digest = reboundPrevious;
  row.receipt_digest = autonomyDigest(row, "receipt_digest");
  reboundPrevious = row.receipt_digest;
}
malformedBinding.terminal_receipt.binding_digest =
  malformedBinding.journal.binding_digest;
malformedBinding.terminal_receipt.journal_tail_digest =
  malformedBinding.journal.entries.at(-1).receipt_digest;
assert.throws(() => projectMaintenanceExecutionResult(
  malformedBinding, { now: "2026-07-28T10:30:00Z" },
), /journal_binding/);

const coercedAuthorityReference = input();
coercedAuthorityReference.journal.binding.owner_authority_ref =
  ["ref:owner-authority"];
coercedAuthorityReference.journal.binding_digest = autonomyDigest(
  coercedAuthorityReference.journal.binding,
);
let authorityPrevious = null;
for (const row of coercedAuthorityReference.journal.entries) {
  row.binding_digest = coercedAuthorityReference.journal.binding_digest;
  row.previous_receipt_digest = authorityPrevious;
  row.receipt_digest = autonomyDigest(row, "receipt_digest");
  authorityPrevious = row.receipt_digest;
}
const authorityWatch = coercedAuthorityReference.journal.entries.find(
  row => row.phase === "watch",
);
coercedAuthorityReference.watch_anchor.binding_digest =
  coercedAuthorityReference.journal.binding_digest;
coercedAuthorityReference.watch_anchor.journal_tail_digest =
  authorityWatch.receipt_digest;
coercedAuthorityReference.watch_anchor.anchor_digest = autonomyDigest(
  coercedAuthorityReference.watch_anchor, "anchor_digest",
);
coercedAuthorityReference.terminal_receipt.binding_digest =
  coercedAuthorityReference.journal.binding_digest;
coercedAuthorityReference.terminal_receipt.journal_tail_digest =
  coercedAuthorityReference.journal.entries.at(-1).receipt_digest;
coercedAuthorityReference.terminal_receipt.receipt_digest = autonomyDigest(
  coercedAuthorityReference.terminal_receipt, "receipt_digest",
);
assert.throws(() => projectMaintenanceExecutionResult(
  coercedAuthorityReference, { now: "2026-07-28T11:04:00Z" },
), /journal_binding/);

const aliasedActors = input();
aliasedActors.journal.binding.watchdog_identity =
  aliasedActors.journal.binding.controller_identity;
aliasedActors.journal.binding_digest =
  autonomyDigest(aliasedActors.journal.binding);
assert.throws(() => projectMaintenanceExecutionResult(
  aliasedActors, { now: "2026-07-28T11:04:00Z" },
), /journal_binding/);

const tooShortWatch = input();
tooShortWatch.journal.entries.at(-1).recorded_at =
  "2026-07-28T10:04:00Z";
tooShortWatch.journal.entries.at(-1).receipt_digest = autonomyDigest(
  tooShortWatch.journal.entries.at(-1), "receipt_digest",
);
tooShortWatch.terminal_receipt.journal_tail_digest =
  tooShortWatch.journal.entries.at(-1).receipt_digest;
tooShortWatch.terminal_receipt.receipt_digest = autonomyDigest(
  tooShortWatch.terminal_receipt, "receipt_digest",
);
assert.throws(() => projectMaintenanceExecutionResult(
  tooShortWatch, { now: "2026-07-28T10:30:00Z" },
), /journal_watch_incomplete/);

const lateDurableAnchor = input();
lateDurableAnchor.watch_anchor.anchored_at =
  "2026-07-28T10:10:00Z";
lateDurableAnchor.watch_anchor.anchor_digest = autonomyDigest(
  lateDurableAnchor.watch_anchor, "anchor_digest",
);
assert.throws(() => projectMaintenanceExecutionResult(
  lateDurableAnchor, { now: "2026-07-28T11:10:00Z" },
), /journal_apply_verify_budget_exceeded/);

const fractionalJournal = input({ phase: "unknown" });
fractionalJournal.journal.entries[0].recorded_at =
  "2026-07-28T10:00:00.123Z";
fractionalJournal.journal.entries[0].receipt_digest =
  autonomyDigest(fractionalJournal.journal.entries[0], "receipt_digest");
fractionalJournal.journal.entries[1].previous_receipt_digest =
  fractionalJournal.journal.entries[0].receipt_digest;
fractionalJournal.journal.entries[1].receipt_digest =
  autonomyDigest(fractionalJournal.journal.entries[1], "receipt_digest");
fractionalJournal.terminal_receipt.journal_tail_digest =
  fractionalJournal.journal.entries[1].receipt_digest;
fractionalJournal.terminal_receipt.receipt_digest = autonomyDigest(
  fractionalJournal.terminal_receipt, "receipt_digest",
);
assert.doesNotThrow(() => projectMaintenanceExecutionResult(
  fractionalJournal, { now: "2026-07-28T10:30:00Z" },
));

const semanticallyContradictory = JSON.parse(fs.readFileSync(
  `${root}/tests/fixtures/maintenance-execution-result/clean.json`,
  "utf8",
));
semanticallyContradictory.outcome = "unknown";
semanticallyContradictory.health = "unknown";
semanticallyContradictory.promotion_eligible = false;
semanticallyContradictory.recovery = {
  state: "unknown", reason_digest: digest("6"),
};
semanticallyContradictory.result_digest = autonomyDigest(
  semanticallyContradictory, "result_digest",
);
assert.throws(() => validateMaintenanceExecutionResult(
  semanticallyContradictory,
), /contradiction/);

const wrongResultIdentity = JSON.parse(fs.readFileSync(
  `${root}/tests/fixtures/maintenance-execution-result/clean.json`,
  "utf8",
));
wrongResultIdentity.result_id = "result-forged";
wrongResultIdentity.result_digest = autonomyDigest(
  wrongResultIdentity, "result_digest",
);
assert.throws(() => validateMaintenanceExecutionResult(
  wrongResultIdentity,
), /result_identity/);

const wrongConfiguration = JSON.parse(fs.readFileSync(
  `${root}/tests/fixtures/maintenance-execution-result/clean.json`,
  "utf8",
));
wrongConfiguration.source.configuration_digest = digest("9");
wrongConfiguration.result_digest = autonomyDigest(
  wrongConfiguration, "result_digest",
);
assert.throws(() => validateMaintenanceExecutionResult(
  wrongConfiguration,
), /result_journal/);

const wrongAnchorIdentity = JSON.parse(fs.readFileSync(
  `${root}/tests/fixtures/maintenance-execution-result/clean.json`,
  "utf8",
));
wrongAnchorIdentity.journal.watch_anchor.mutation_id = "other-mutation";
wrongAnchorIdentity.journal.watch_anchor.anchor_digest = autonomyDigest(
  wrongAnchorIdentity.journal.watch_anchor, "anchor_digest",
);
wrongAnchorIdentity.result_digest = autonomyDigest(
  wrongAnchorIdentity, "result_digest",
);
assert.throws(() => validateMaintenanceExecutionResult(
  wrongAnchorIdentity,
), /result_watch_anchor/);

const impossibleUnknownSequence = JSON.parse(fs.readFileSync(
  `${root}/tests/fixtures/maintenance-execution-result/unknown.json`,
  "utf8",
));
impossibleUnknownSequence.journal.tail_sequence = 5;
impossibleUnknownSequence.result_digest = autonomyDigest(
  impossibleUnknownSequence, "result_digest",
);
assert.throws(() => validateMaintenanceExecutionResult(
  impossibleUnknownSequence,
), /result_watch_anchor/);

const futureResultAnchor = JSON.parse(fs.readFileSync(
  `${root}/tests/fixtures/maintenance-execution-result/clean.json`,
  "utf8",
));
futureResultAnchor.journal.watch_anchor.anchored_at =
  "2026-07-28T11:05:00Z";
futureResultAnchor.journal.watch_anchor.anchor_digest = autonomyDigest(
  futureResultAnchor.journal.watch_anchor, "anchor_digest",
);
futureResultAnchor.result_digest = autonomyDigest(
  futureResultAnchor, "result_digest",
);
assert.throws(() => validateMaintenanceExecutionResult(
  futureResultAnchor,
), /result_watch_anchor/);
const noProbeEvidence = projectMaintenanceExecutionResult(
  input({ expected: 0, observed: 0 }),
  { now: "2026-07-28T11:04:00Z" },
);
assert.equal(noProbeEvidence.promotion_eligible, false);
assert.equal(noProbeEvidence.probe_coverage.state, "unknown");
assert.equal(noProbeEvidence.outcome, "unknown");
assert.equal(noProbeEvidence.health, "unknown");
validateMaintenanceExecutionResult(noProbeEvidence);

const staleFailed = projectMaintenanceExecutionResult(
  input({
    reconciliation: "failed",
    validUntil: "2026-07-28T11:03:00Z",
  }),
  { now: "2026-07-28T11:04:00Z" },
);
assert.equal(staleFailed.outcome, "failed");
assert.equal(staleFailed.health, "unhealthy");

for (const phase of ["recover", "quarantine"]) {
  const recoveredProjection = projectMaintenanceExecutionResult(
    input({ phase }),
    { now: "2026-07-28T10:30:00Z" },
  );
  assert.equal(recoveredProjection.recovery.state, "recovered-by-worker");
  assert.equal(recoveredProjection.recovery.reason_digest, digest("6"));
}

const expiresAtEvaluation = projectMaintenanceExecutionResult(
  input({ validUntil: "2026-07-28T11:04:00Z" }),
  { now: "2026-07-28T11:04:00Z" },
);
assert.equal(expiresAtEvaluation.outcome, "stale");
assert.equal(expiresAtEvaluation.promotion_eligible, false);

const impossibleFreshness = input({ phase: "unknown" });
impossibleFreshness.freshness.observed_at = "2026-02-31T10:00:00Z";
assert.throws(() => projectMaintenanceExecutionResult(
  impossibleFreshness, { now: "2026-07-28T11:04:00Z" },
), /freshness/);

const unsafeEpoch = input({ phase: "unknown" });
unsafeEpoch.execution_epoch = Number.MAX_SAFE_INTEGER + 1;
assert.throws(() => projectMaintenanceExecutionResult(
  unsafeEpoch, { now: "2026-07-28T11:04:00Z" },
), /epoch/);

const futureProjectionAnchor = input({ phase: "watch" });
futureProjectionAnchor.watch_anchor.anchored_at =
  "2026-07-28T10:04:00Z";
futureProjectionAnchor.watch_anchor.anchor_digest = autonomyDigest(
  futureProjectionAnchor.watch_anchor, "anchor_digest",
);
assert.throws(() => projectMaintenanceExecutionResult(
  futureProjectionAnchor, { now: "2026-07-28T10:03:30Z" },
), /projection_time/);

const tailBeforeAnchor = input();
const tailBeforeAnchorEntry = tailBeforeAnchor.journal.entries.at(-1);
tailBeforeAnchorEntry.phase = "unknown";
tailBeforeAnchorEntry.outcome = "unknown";
tailBeforeAnchorEntry.executor_identity =
  tailBeforeAnchor.journal.binding.watchdog_identity;
tailBeforeAnchorEntry.recorded_at = "2026-07-28T10:03:00Z";
tailBeforeAnchorEntry.terminal_reason_digest = digest("6");
tailBeforeAnchorEntry.receipt_digest = autonomyDigest(
  tailBeforeAnchorEntry, "receipt_digest",
);
tailBeforeAnchor.watch_anchor.anchored_at = "2026-07-28T10:04:00Z";
tailBeforeAnchor.watch_anchor.anchor_digest = autonomyDigest(
  tailBeforeAnchor.watch_anchor, "anchor_digest",
);
tailBeforeAnchor.terminal_receipt.journal_tail_digest =
  tailBeforeAnchorEntry.receipt_digest;
tailBeforeAnchor.terminal_receipt.receipt_digest = autonomyDigest(
  tailBeforeAnchor.terminal_receipt, "receipt_digest",
);
assert.throws(() => projectMaintenanceExecutionResult(
  tailBeforeAnchor, { now: "2026-07-28T10:30:00Z" },
), /journal_watch_anchor_timing/);

const negative = JSON.parse(fs.readFileSync(
  `${root}/tests/fixtures/maintenance-execution-result/negative.json`,
  "utf8",
));
const negativeBase = JSON.parse(fs.readFileSync(
  `${root}/tests/fixtures/maintenance-execution-result/${negative.base}`,
  "utf8",
));
for (const fixture of negative.cases) {
  const candidate = structuredClone(negativeBase);
  for (const [path, value] of Object.entries(fixture.mutations)) {
    const parts = path.split(".");
    let target = candidate;
    for (const part of parts.slice(0, -1)) target = target[part];
    target[parts.at(-1)] = value;
  }
  candidate.result_digest = autonomyDigest(candidate, "result_digest");
  assert.throws(() => validateMaintenanceExecutionResult(candidate),
    undefined, fixture.id);
}
console.log("ok - result fixtures, pure projection, and adversarial combinations fail closed");
NODE

node "$ROOT/scripts/maintenance-execution-result-delivery.mjs" --result "$ROOT/tests/fixtures/maintenance-execution-result/clean.json" >"$TMP/delivery.json"
node -e 'const x=require(process.argv[1]); if(x.delivered!==false||x.reason!=="delivery_disabled")process.exit(1)' "$TMP/delivery.json"
printf 'ok - delivery adapter is disabled and side-effect free\n'
