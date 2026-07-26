#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/test.mjs" <<'NODE'
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import { spawn } from "node:child_process";
const root = process.env.ROOT, tmp = process.env.TMP;
const {
  loadPinnedJournalSchema, runMaintenanceAttempt, validateJournalConformance,
} = await import(`${root}/scripts/maintenance-attempt-journal.mjs`);
const {
  autonomyDigest, canonicalJson,
} = await import(`${root}/scripts/lib/autonomy-authorization.mjs`);

const fixture = name => JSON.parse(fs.readFileSync(`${root}/tests/fixtures/autonomy-contract/${name}`, "utf8"));
const clone = value => structuredClone(value);
const ownerKeys = crypto.generateKeyPairSync("ed25519");
const recoveryKeys = crypto.generateKeyPairSync("ed25519");
const publicPem = key => key.export({ type: "spki", format: "pem" });
const fingerprint = publicKey => `sha256:${crypto.createHash("sha256").update(crypto.createPublicKey(publicKey).export({ type: "spki", format: "der" })).digest("hex")}`;
const sign = (value, privateKey) => crypto.sign(null, Buffer.from(canonicalJson(value)), privateKey).toString("base64");

function bundle() {
  const constitution = fixture("constitution.json");
  const coverage = fixture("coverage-armed-canary.json");
  const ownerAttestations = fixture("owner-attestations.json");
  const recoveryPublic = publicPem(recoveryKeys.publicKey);
  const recoveryRegistry = {
    kind: "autonomy-recovery-worker-registry", schema_version: "v1", registry_id: "maintenance-recovery-workers",
    entries: [{
      domain: "no-reboot-security-bugfix-maintenance",
      target_scope_digest: "sha256:" + "5".repeat(64),
      recovery_worker_identity: "maintenance-recovery-worker",
      public_key_pem: recoveryPublic,
      public_key_fingerprint: fingerprint(recoveryPublic),
    }],
    registry_digest: "sha256:" + "0".repeat(64), extensions: [],
  };
  recoveryRegistry.registry_digest = autonomyDigest(recoveryRegistry, "registry_digest");
  const ownerPublic = publicPem(ownerKeys.publicKey);
  const authorization = {
    kind: "autonomy-owner-authorization", schema_version: "v1", authorization_id: "maintenance-owner-authorization",
    authorization_sequence: 1, previous_authorization_digest: null, issued_at: "2026-07-26T00:00:00Z",
    authority: { key_id: "test-owner-ed25519", algorithm: "Ed25519", public_key_pem: ownerPublic, public_key_fingerprint: fingerprint(ownerPublic) },
    bindings: {
      constitution_digest: autonomyDigest(constitution, "constitution_digest"),
      coverage_intent_digest: autonomyDigest(coverage, "registry_digest"),
      owner_attestation_registry_digest: autonomyDigest(ownerAttestations, "registry_digest"),
      recovery_worker_registry_digest: autonomyDigest(recoveryRegistry, "registry_digest"),
    },
  };
  authorization.signature = { algorithm: "Ed25519", value_base64: sign(authorization, ownerKeys.privateKey) };
  const authorizationDigest = autonomyDigest(authorization);
  return {
    journalSchema: loadPinnedJournalSchema(`${root}/docs/autonomous-mutation-journal-v1.schema.json`),
    authorization, constitution, coverage, ownerAttestations, recoveryRegistry,
    pinnedOwnerPublicKeyPem: ownerPublic,
    authorizationCheckpoint: {
      kind: "autonomy-owner-authorization-checkpoint", schema_version: "v1",
      authorization_digest: authorizationDigest, minimum_sequence: 1,
    },
    runtimeNarrowing: {
      kind: "autonomy-runtime-narrowing", schema_version: "v1", ledger_id: "maintenance-runtime-narrowing",
      owner_authorization_digest: authorizationDigest, entries: [], extensions: [],
    },
    runtimeNarrowingCheckpoint: {
      kind: "autonomy-runtime-narrowing-checkpoint", schema_version: "v1",
      owner_authorization_digest: authorizationDigest, ledger_tail_digest: null, minimum_entries: 0,
    },
  };
}
function binding(id = "maintenance-attempt") {
  const coverage = fixture("coverage-armed-canary.json");
  const owner = coverage.domains.find(row => row.domain === "no-reboot-security-bugfix-maintenance").bindings[0];
  return {
    mutation_id: `${id}-mutation`, attempt_id: id, recovery_disarm_id: `${id}-disarm`, idempotency_key: `${id}-idem`,
    writer_owner: owner.writer_owner, owner_authority_ref: owner.owner_authority_ref, owner_authority_digest: owner.owner_authority_digest,
    configuration_owner: owner.configuration_owner, configuration_owner_authority_ref: owner.configuration_owner_authority_ref,
    configuration_owner_authority_digest: owner.configuration_owner_authority_digest, target_scope_digest: owner.target_scope_digest,
    admission_coverage_digest: coverage.registry_digest, admission_binding_state: owner.state,
    owner_identity: owner.identities.owner, controller_identity: owner.identities.controller,
    watchdog_identity: owner.identities.watchdog, kill_switch_identity: owner.identities.kill_switch,
    recovery_worker_identity: owner.identities.recovery_worker, risk_scope: "no-reboot-security-bugfix-maintenance",
    candidate_digest: "sha256:" + "a".repeat(64), config_digest: "sha256:" + "b".repeat(64),
    evidence_digest: "sha256:" + "c".repeat(64), policy_digest: "sha256:" + "d".repeat(64),
    baseline_digest: "sha256:" + "e".repeat(64), postconditions_digest: "sha256:" + "f".repeat(64),
    deadline: "2026-07-26T01:00:00Z",
    canary: { scope_digest: owner.target_scope_digest, target_count: 1, watch_deadline: "2026-07-26T00:10:00Z" },
    recovery: { class: "R-forward", worker_identity: owner.identities.recovery_worker, descriptor_digest: "sha256:" + "2".repeat(64), disarms_after_action: true },
  };
}
const baseTimes = ["2026-07-26T00:00:00Z", "2026-07-26T00:00:01Z", "2026-07-26T00:00:02Z", "2026-07-26T00:00:03Z", "2026-07-26T00:10:00Z", "2026-07-26T00:10:01Z"];
function admission(times = baseTimes, kill = () => true) {
  let index = 0;
  return {
    trustedClock: () => ({ trusted: true, now: times[Math.min(index++, times.length - 1)] }),
    killSwitch: () => ({ safe: kill(), identity: "maintenance-kill-switch" }),
    evidence: () => ({ fresh: true, eligible: true, digest: "sha256:" + "c".repeat(64) }),
    liveness: () => ({ healthy: true, observed_at: "2026-07-26T00:00:00Z" }),
    maintenance: () => ({
      window: { start: "2026-07-26T00:00:00Z", end: "2026-07-26T00:59:59Z" },
      target: { platform: "debian", non_pillar: true },
      plan: { classes: ["security", "bugfix"], reboot_policy: "never", source: "distro_repository", workload_hooks: "not_applicable" },
    }),
  };
}
function phases(overrides = {}) {
  return {
    apply: () => ({ applied: true }), verify: () => ({ verified: true }), watch: () => {},
    safeStateReadback: () => ({ safe: true, postconditions_digest: "sha256:" + "f".repeat(64) }),
    ...overrides,
  };
}
function recovery(artifacts, overrides = {}) {
  return {
    recover: () => ({ recovered: true, safe_state_verified: true, quarantine_active: true }),
    appendSignedNarrowing: input => {
      const entryWithoutSignature = {
        sequence: input.sequence, recorded_at: input.recorded_at, domain: "no-reboot-security-bugfix-maintenance",
        target_scope_digest: input.binding.target_scope_digest, from_state: input.binding.admission_binding_state, to_state: "shadow",
        recovery_worker_identity: input.binding.recovery_worker_identity, journal_receipt_digest: input.journal_receipt_digest,
        previous_entry_digest: input.previous_entry_digest,
      };
      const entry = { ...entryWithoutSignature, entry_digest: autonomyDigest(entryWithoutSignature) };
      entry.signature = { algorithm: "Ed25519", value_base64: sign(entry, recoveryKeys.privateKey) };
      artifacts.runtimeNarrowing.entries.push(entry);
      artifacts.runtimeNarrowingCheckpoint = {
        kind: "autonomy-runtime-narrowing-checkpoint", schema_version: "v1",
        owner_authorization_digest: input.authorization_digest, ledger_tail_digest: entry.entry_digest,
        minimum_entries: artifacts.runtimeNarrowing.entries.length,
      };
      return { ledger: clone(artifacts.runtimeNarrowing), tailCheckpoint: clone(artifacts.runtimeNarrowingCheckpoint) };
    },
    ...overrides,
  };
}
const run = ({ dir, artifacts = bundle(), bind = binding(), admit = admission(), phase = phases(), recover = null, reconcile = null }) =>
  runMaintenanceAttempt({ journalDir: dir, binding: bind, artifacts, admission: admit, phases: phase, recovery: recover ?? recovery(artifacts), reconcile });

if (process.env.WORKER_MODE) {
  while (process.env.BARRIER && !fs.existsSync(process.env.BARRIER)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
  const workerArtifacts = bundle();
  try {
    run({
      dir: process.env.WORKER_DIR, artifacts: workerArtifacts,
      phase: phases({
        apply: () => {
          if (process.env.APPLY_LOG) fs.appendFileSync(process.env.APPLY_LOG, "apply\n");
          if (process.env.WORKER_MODE === "crash") process.exit(77);
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
          return { applied: true };
        },
      }),
      recover: recovery(workerArtifacts, {
        recover: () => {
          if (process.env.RECOVERY_LOG) fs.appendFileSync(process.env.RECOVERY_LOG, "recover\n");
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
          return { recovered: true, safe_state_verified: true, quarantine_active: true };
        },
      }),
      reconcile: process.env.WORKER_MODE === "recover" ? () => ({ state: "applied" }) : null,
    });
  } catch {}
  process.exit(0);
}

const happyArtifacts = bundle();
const happy = run({ dir: `${tmp}/happy`, artifacts: happyArtifacts });
assert.equal(happy.reason, "committed");
assert.deepEqual(happy.journal.entries.map(entry => entry.phase), ["prepare", "apply", "verify", "watch", "commit"]);
assert.equal(validateJournalConformance(happy.journal, {
  schema: happyArtifacts.journalSchema, constitution: happyArtifacts.constitution,
  coverage: happyArtifacts.coverage, ownerAttestations: happyArtifacts.ownerAttestations,
}), true);

const redigested = bundle();
redigested.coverage.domains.find(row => row.domain === "no-reboot-security-bugfix-maintenance").target_state = "armed-fleet";
redigested.coverage.registry_digest = autonomyDigest(redigested.coverage, "registry_digest");
assert.throws(() => run({ dir: `${tmp}/redigested`, artifacts: redigested }), /owner_authorization_binding_mismatch/);
const falseOwner = bundle();
falseOwner.ownerAttestations.attestations.find(entry => entry.domain === "no-reboot-security-bugfix-maintenance").configuration_owner = "hugin";
falseOwner.ownerAttestations.attestations.find(entry => entry.domain === "no-reboot-security-bugfix-maintenance").attestation_digest =
  autonomyDigest(falseOwner.ownerAttestations.attestations.find(entry => entry.domain === "no-reboot-security-bugfix-maintenance"), "attestation_digest");
falseOwner.ownerAttestations.registry_digest = autonomyDigest(falseOwner.ownerAttestations, "registry_digest");
assert.throws(() => run({ dir: `${tmp}/false-owner`, artifacts: falseOwner }), /owner_authorization_binding_mismatch/);

const staleAdmission = admission();
staleAdmission.liveness = () => ({ healthy: true, observed_at: "2026-07-25T23:44:59Z" });
assert.throws(() => run({ dir: `${tmp}/stale-liveness`, admit: staleAdmission }), /maintenance_liveness_stale/);
const futureAdmission = admission();
futureAdmission.liveness = () => ({ healthy: true, observed_at: "2026-07-26T00:00:01Z" });
assert.throws(() => run({ dir: `${tmp}/future-liveness`, admit: futureAdmission }), /maintenance_liveness_stale/);
for (const [name, mutate] of [
  ["pillar", value => { value.target.non_pillar = false; }],
  ["reboot", value => { value.plan.reboot_policy = "if-required"; }],
  ["kernel", value => { value.plan.classes = ["kernel"]; }],
  ["duplicate-class", value => { value.plan.classes = ["security", "security"]; }],
  ["source", value => { value.plan.source = "third_party"; }],
]) {
  const scoped = admission();
  const original = scoped.maintenance;
  scoped.maintenance = () => { const value = original(); mutate(value); return value; };
  assert.throws(() => run({ dir: `${tmp}/scope-${name}`, admit: scoped }), /maintenance_target_ineligible|maintenance_plan_out_of_scope/);
}

let killChecks = 0;
const killArtifacts = bundle();
const killed = run({
  dir: `${tmp}/kill`, artifacts: killArtifacts,
  admit: admission(baseTimes, () => ++killChecks < 3),
});
assert.equal(killed.reason, "recovered-disarmed");
assert.deepEqual(killed.journal.entries.map(entry => entry.phase), ["prepare", "apply", "unknown", "recover", "quarantine", "disarm"]);
const shortWatchArtifacts = bundle();
const shortWatch = run({
  dir: `${tmp}/short-watch`, artifacts: shortWatchArtifacts,
  admit: admission(["2026-07-26T00:00:00Z", "2026-07-26T00:00:01Z", "2026-07-26T00:00:02Z", "2026-07-26T00:00:03Z", "2026-07-26T00:09:59Z", "2026-07-26T00:10:00Z"]),
});
assert.equal(shortWatch.reason, "recovered-disarmed", "watch must actually reach its bound before commit");
const unsafeReadbackArtifacts = bundle();
const unsafeReadback = run({
  dir: `${tmp}/unsafe-readback`, artifacts: unsafeReadbackArtifacts,
  phase: phases({ safeStateReadback: () => ({ safe: false, postconditions_digest: "sha256:" + "f".repeat(64) }) }),
});
assert.equal(unsafeReadback.reason, "recovered-disarmed", "maintenance-safe-state readback gates commit");

const deadlineAdmission = admission(["2026-07-26T01:00:00Z"]);
deadlineAdmission.liveness = () => ({ healthy: true, observed_at: "2026-07-26T00:59:59Z" });
deadlineAdmission.maintenance = () => ({
  window: { start: "2026-07-26T00:00:00Z", end: "2026-07-26T01:00:01Z" },
  target: { platform: "debian", non_pillar: true },
  plan: { classes: ["security"], reboot_policy: "never", source: "distro_repository", workload_hooks: "not_applicable" },
});
assert.throws(() => run({ dir: `${tmp}/deadline`, admit: deadlineAdmission }), /attempt_deadline_closed/);
assert.throws(() => run({
  dir: `${tmp}/backdate`, admit: admission(["2026-07-26T00:00:00Z", "2026-07-25T23:59:59Z"]),
}), /trusted_clock_backdated/);

const crashDir = `${tmp}/crash`;
const runWorker = env => new Promise(resolve => {
  const child = spawn(process.execPath, [process.argv[1]], { env: { ...process.env, ...env } });
  child.on("exit", code => resolve(code));
});
const crashApplyLog = `${tmp}/crash-apply.log`;
assert.equal(await runWorker({ WORKER_MODE: "crash", WORKER_DIR: crashDir, APPLY_LOG: crashApplyLog }), 77);
assert.equal(fs.readFileSync(crashApplyLog, "utf8").trim(), "apply");
const crashJournal = bounded(`${crashDir}/${binding().idempotency_key}.json`);
function bounded(file) { return JSON.parse(fs.readFileSync(file, "utf8")); }
assert.equal(crashJournal.entries[0].phase, "prepare");
assert.equal(crashJournal.entries.length, 1, "crash after actuation leaves an ambiguous prepared receipt");
const recoveryLog = `${tmp}/crash-recovery.log`, recoveryBarrier = `${tmp}/recovery-barrier`;
const recoveryWorkers = [
  runWorker({ WORKER_MODE: "recover", WORKER_DIR: crashDir, RECOVERY_LOG: recoveryLog, BARRIER: recoveryBarrier }),
  runWorker({ WORKER_MODE: "recover", WORKER_DIR: crashDir, RECOVERY_LOG: recoveryLog, BARRIER: recoveryBarrier }),
];
fs.writeFileSync(recoveryBarrier, "");
await Promise.all(recoveryWorkers);
assert.equal(fs.readFileSync(recoveryLog, "utf8").trim().split("\n").length, 1, "recovery claim is process-safe and one-shot");
assert.equal(bounded(`${crashDir}/${binding().idempotency_key}.json`).entries.at(-1).phase, "disarm");

const raceDir = `${tmp}/prepare-race`, applyLog = `${tmp}/race-apply.log`, prepareBarrier = `${tmp}/prepare-barrier`;
const prepareWorkers = [
  runWorker({ WORKER_MODE: "race", WORKER_DIR: raceDir, APPLY_LOG: applyLog, BARRIER: prepareBarrier }),
  runWorker({ WORKER_MODE: "race", WORKER_DIR: raceDir, APPLY_LOG: applyLog, BARRIER: prepareBarrier }),
];
fs.writeFileSync(prepareBarrier, "");
await Promise.all(prepareWorkers);
assert.equal(fs.readFileSync(applyLog, "utf8").trim().split("\n").length, 1, "exclusive prepare permits at most one process to actuate");

const failureArtifacts = bundle();
const failed = run({
  dir: `${tmp}/recovery-failure`, artifacts: failureArtifacts,
  phase: phases({ apply: () => { throw Object.assign(new Error("apply-failed"), { code: "apply-failed" }); } }),
  recover: recovery(failureArtifacts, { recover: () => { throw Object.assign(new Error("forward-repair-failed"), { code: "forward-repair-failed" }); } }),
});
assert.equal(failed.reason, "terminally-blocked");
assert.equal(failed.recovery_error, "forward-repair-failed");
assert.equal(failed.journal.entries.at(-1).phase, "terminally-blocked");
assert.notEqual(failed.journal.entries.at(-1).terminal_reason_digest, failed.journal.entries.at(-2).terminal_reason_digest);

const demotedBinding = binding("maintenance-after-demotion");
assert.throws(() => run({
  dir: `${tmp}/demotion-consumed`, artifacts: failureArtifacts, bind: demotedBinding,
}), /runtime_demotion_consumed/);

const rateArtifacts = bundle();
run({ dir: `${tmp}/rate`, artifacts: rateArtifacts, bind: binding("maintenance-rate-one") });
const rateAdmission = admission(["2026-07-26T00:20:00Z"]);
rateAdmission.liveness = () => ({ healthy: true, observed_at: "2026-07-26T00:19:59Z" });
assert.throws(() => run({
  dir: `${tmp}/rate`, artifacts: rateArtifacts, bind: binding("maintenance-rate-two"),
  admit: rateAdmission,
}), /attempt_interval_exceeded|attempt_window_exceeded/);

console.log("maintenance attempt journal: W0.1 authorization, admission, phases, recovery, demotion and rate gates OK");
NODE

env ROOT="$ROOT" TMP="$TMP" node "$TMP/test.mjs"
