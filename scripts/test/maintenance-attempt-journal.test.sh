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
  deriveDebianAutonomyExecution, runDebianMaintenance,
} = await import(`${root}/scripts/debian-maintenance-executor.mjs`);
const {
  autonomyDigest, canonicalJson,
} = await import(`${root}/scripts/lib/autonomy-authorization.mjs`);
const {
  policyDigest,
} = await import(`${root}/scripts/lib/maintenance-policy-contract.mjs`);

const fixture = name => JSON.parse(fs.readFileSync(`${root}/tests/fixtures/autonomy-contract/${name}`, "utf8"));
const clone = value => structuredClone(value);
const loadOrCreateKeys = envName => {
  if (process.env[envName]) {
    const privateKey = crypto.createPrivateKey({
      key: Buffer.from(process.env[envName], "base64"), type: "pkcs8", format: "der",
    });
    return { privateKey, publicKey: crypto.createPublicKey(privateKey) };
  }
  const keys = crypto.generateKeyPairSync("ed25519");
  process.env[envName] = keys.privateKey.export({
    type: "pkcs8", format: "der",
  }).toString("base64");
  return keys;
};
const ownerKeys = loadOrCreateKeys("TEST_OWNER_PRIVATE_KEY");
const recoveryKeys = loadOrCreateKeys("TEST_RECOVERY_PRIVATE_KEY");
const publicPem = key => key.export({ type: "spki", format: "pem" });
const recoveryPublicPem = publicPem(recoveryKeys.publicKey);
const fingerprint = publicKey => `sha256:${crypto.createHash("sha256").update(crypto.createPublicKey(publicKey).export({ type: "spki", format: "der" })).digest("hex")}`;
const sign = (value, privateKey) => crypto.sign(null, Buffer.from(canonicalJson(value)), privateKey).toString("base64");

function bundle(targetScopeDigest = null) {
  const constitution = fixture("constitution.json");
  const coverage = fixture("coverage-armed-canary.json");
  const ownerAttestations = fixture("owner-attestations.json");
  if (targetScopeDigest !== null) {
    const row = coverage.domains.find(value => value.domain === "no-reboot-security-bugfix-maintenance");
    const owner = row.bindings[0];
    const attestation = ownerAttestations.attestations.find(value => value.domain === row.domain);
    owner.target_scope_digest = targetScopeDigest;
    attestation.target_scope_digest = targetScopeDigest;
    attestation.attestation_digest = autonomyDigest(attestation, "attestation_digest");
    owner.configuration_owner_authority_digest = attestation.attestation_digest;
    ownerAttestations.registry_digest = autonomyDigest(ownerAttestations, "registry_digest");
    coverage.registry_digest = autonomyDigest(coverage, "registry_digest");
  }
  const recoveryPublic = recoveryPublicPem;
  const recoveryRegistry = {
    kind: "autonomy-recovery-worker-registry", schema_version: "v1", registry_id: "maintenance-recovery-workers",
    entries: [{
      domain: "no-reboot-security-bugfix-maintenance",
      target_scope_digest: targetScopeDigest ?? "sha256:" + "5".repeat(64),
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
  const result = {
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
  result.read = () => result;
  return result;
}
function resignArtifacts(artifacts) {
  artifacts.constitution.constitution_digest = autonomyDigest(artifacts.constitution, "constitution_digest");
  artifacts.coverage.constitution_digest = artifacts.constitution.constitution_digest;
  artifacts.coverage.registry_digest = autonomyDigest(artifacts.coverage, "registry_digest");
  artifacts.ownerAttestations.registry_digest = autonomyDigest(artifacts.ownerAttestations, "registry_digest");
  artifacts.recoveryRegistry.registry_digest = autonomyDigest(artifacts.recoveryRegistry, "registry_digest");
  artifacts.authorization.bindings = {
    constitution_digest: artifacts.constitution.constitution_digest,
    coverage_intent_digest: artifacts.coverage.registry_digest,
    owner_attestation_registry_digest: artifacts.ownerAttestations.registry_digest,
    recovery_worker_registry_digest: artifacts.recoveryRegistry.registry_digest,
  };
  delete artifacts.authorization.signature;
  artifacts.authorization.signature = {
    algorithm: "Ed25519", value_base64: sign(artifacts.authorization, ownerKeys.privateKey),
  };
  const authorizationDigest = autonomyDigest(artifacts.authorization);
  artifacts.authorizationCheckpoint.authorization_digest = authorizationDigest;
  artifacts.runtimeNarrowing.owner_authorization_digest = authorizationDigest;
  artifacts.runtimeNarrowingCheckpoint.owner_authorization_digest = authorizationDigest;
  return artifacts;
}
function rotateOwnerAuthorization(artifacts = bundle()) {
  artifacts.authorization.authorization_id = "rotated-owner-authorization";
  delete artifacts.authorization.signature;
  artifacts.authorization.signature = {
    algorithm: "Ed25519",
    value_base64: sign(artifacts.authorization, ownerKeys.privateKey),
  };
  const authorizationDigest = autonomyDigest(artifacts.authorization);
  artifacts.authorizationCheckpoint.authorization_digest = authorizationDigest;
  artifacts.runtimeNarrowing.owner_authorization_digest = authorizationDigest;
  artifacts.runtimeNarrowing.entries = [];
  artifacts.runtimeNarrowingCheckpoint = {
    kind: "autonomy-runtime-narrowing-checkpoint", schema_version: "v1",
    owner_authorization_digest: authorizationDigest,
    ledger_tail_digest: null, minimum_entries: 0,
  };
  return artifacts;
}
function binding(id = "maintenance-attempt", coverage = fixture("coverage-armed-canary.json"), fields = {}) {
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
    ...fields,
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
function takeoverAdmission() {
  const result = admission([
    "2026-07-26T00:20:00Z", "2026-07-26T00:20:01Z", "2026-07-26T00:20:02Z",
    "2026-07-26T00:20:03Z", "2026-07-26T00:20:04Z", "2026-07-26T00:20:05Z",
  ]);
  result.liveness = () => ({ healthy: true, observed_at: "2026-07-26T00:19:59Z" });
  return result;
}
function recoveryTakeoverAdmission() {
  const result = admission([
    "2026-07-26T00:20:00Z", "2026-07-26T00:20:01Z",
    "2026-07-26T00:20:02Z", "2026-07-26T00:20:03Z",
  ]);
  result.liveness = () => ({ healthy: true, observed_at: "2026-07-26T00:19:59Z" });
  return result;
}
function phases(overrides = {}) {
  let activeFenceDigest = null;
  return {
    preflight: () => ({ execution_digest: autonomyDigest({
      baseline_digest: binding().baseline_digest, candidate_digest: binding().candidate_digest,
      config_digest: binding().config_digest, evidence_digest: binding().evidence_digest,
      policy_digest: binding().policy_digest, postconditions_digest: binding().postconditions_digest,
      target_scope_digest: binding().target_scope_digest,
    }) }),
    commitBinding: () => ({ execution_digest: autonomyDigest({
      baseline_digest: binding().baseline_digest, candidate_digest: binding().candidate_digest,
      config_digest: binding().config_digest, evidence_digest: binding().evidence_digest,
      policy_digest: binding().policy_digest, postconditions_digest: binding().postconditions_digest,
      target_scope_digest: binding().target_scope_digest,
    }) }),
    activateFence: fence => {
      activeFenceDigest = autonomyDigest(fence);
      return { activated: true, lease_fence_digest: activeFenceDigest };
    },
    applyFenced: invocation => {
      assert.equal(invocation.lease_fence_digest, activeFenceDigest);
      return { applied: true };
    },
    verify: () => ({ verified: true }), watch: () => {},
    safeStateReadback: () => ({ safe: true, postconditions_digest: "sha256:" + "f".repeat(64) }),
    ...overrides,
  };
}
function recovery(artifacts, overrides = {}) {
  const receipts = new Map();
  return {
    workerIdentity: "maintenance-recovery-worker",
    publicKeyFingerprint: fingerprint(recoveryPublicPem),
    readNarrowingHistory: ({ authorization_digest }) => {
      assert.equal(artifacts.runtimeNarrowing.owner_authorization_digest, authorization_digest);
      return {
        ledger: clone(artifacts.runtimeNarrowing),
        tailCheckpoint: clone(artifacts.runtimeNarrowingCheckpoint),
      };
    },
    recover: request => {
      if (!receipts.has(request.idempotency_key)) receipts.set(request.idempotency_key, {
        idempotency_key: request.idempotency_key, recovered: true,
        safe_state_verified: true, quarantine_active: true, reason_code: null,
      });
      return clone(receipts.get(request.idempotency_key));
    },
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
      return { ledger: clone(artifacts.runtimeNarrowing) };
    },
    advanceNarrowingCheckpoint: input => {
      artifacts.runtimeNarrowingCheckpoint = {
        kind: "autonomy-runtime-narrowing-checkpoint", schema_version: "v1",
        owner_authorization_digest: input.authorization_digest,
        ledger_tail_digest: input.ledger_tail_digest,
        minimum_entries: input.minimum_entries,
      };
    },
    ...overrides,
  };
}
const run = ({ dir, artifacts = bundle(), bind = binding(), admit = admission(), phase = phases(), recover = null, reconcile = null }) =>
  runMaintenanceAttempt({ journalDir: dir, binding: bind, artifacts, admission: admit, phases: phase, recovery: recover ?? recovery(artifacts), reconcile });

if (process.env.WORKER_MODE) {
  if (process.env.WORKER_MODE === "hold-lock") {
    const tickets = `${process.env.WORKER_DIR}/.autonomy-state/domain-state.lock.tickets`;
    fs.mkdirSync(tickets, { recursive: true });
    fs.writeFileSync(`${tickets}/00000001.json`, JSON.stringify({
      kind: "brokkr-lock-ticket", schema_version: "v1", pid: process.pid,
      token: "child-lock-owner", sequence: 1,
    }));
    fs.writeFileSync(process.env.READY, "ready");
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 60_000);
    process.exit(0);
  }
  while (process.env.BARRIER && !fs.existsSync(process.env.BARRIER)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
  const workerArtifacts = bundle();
  const workerRecoveryState = `${process.env.WORKER_DIR}/mock-recovery-state.json`;
  const readWorkerRecoveryState = () => fs.existsSync(workerRecoveryState) ?
    JSON.parse(fs.readFileSync(workerRecoveryState, "utf8")) : {
      ledger: clone(workerArtifacts.runtimeNarrowing),
      checkpoint: clone(workerArtifacts.runtimeNarrowingCheckpoint),
      receipts: {},
    };
  const writeWorkerRecoveryState = state => fs.writeFileSync(
    workerRecoveryState, JSON.stringify(state),
  );
  const workerRecovery = recovery(workerArtifacts, {
    readNarrowingHistory: () => {
      const state = readWorkerRecoveryState();
      return { ledger: clone(state.ledger), tailCheckpoint: clone(state.checkpoint) };
    },
    recover: request => {
      const state = readWorkerRecoveryState();
      if (!state.receipts[request.idempotency_key]) {
        if (process.env.RECOVERY_LOG) fs.appendFileSync(process.env.RECOVERY_LOG, "recover\n");
        state.receipts[request.idempotency_key] = {
          idempotency_key: request.idempotency_key, recovered: true,
          safe_state_verified: true, quarantine_active: true, reason_code: null,
        };
        writeWorkerRecoveryState(state);
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
      return clone(state.receipts[request.idempotency_key]);
    },
    appendSignedNarrowing: input => {
      const state = readWorkerRecoveryState();
      workerArtifacts.runtimeNarrowing = clone(state.ledger);
      const result = recovery(workerArtifacts).appendSignedNarrowing(input);
      state.ledger = clone(workerArtifacts.runtimeNarrowing);
      writeWorkerRecoveryState(state);
      return result;
    },
    advanceNarrowingCheckpoint: input => {
      const state = readWorkerRecoveryState();
      state.checkpoint = {
        kind: "autonomy-runtime-narrowing-checkpoint", schema_version: "v1",
        owner_authorization_digest: input.authorization_digest,
        ledger_tail_digest: input.ledger_tail_digest, minimum_entries: input.minimum_entries,
      };
      writeWorkerRecoveryState(state);
    },
    fault: point => {
      if (process.env.FAULT_POINT === point) process.exit(78);
    },
  });
  const resumedWorker = ["resume", "recover"].includes(process.env.WORKER_MODE);
  const workerAdmission = process.env.LATE_LEASE_TRANSFER ? admission([
    "2026-07-26T00:40:00Z", "2026-07-26T00:40:01Z", "2026-07-26T00:40:02Z",
    "2026-07-26T00:40:03Z", "2026-07-26T00:40:04Z",
  ]) : process.env.WORKER_MODE === "recover" ? admission([
    "2026-07-26T00:20:00Z", "2026-07-26T00:20:01Z", "2026-07-26T00:20:02Z",
    "2026-07-26T00:20:03Z", "2026-07-26T00:20:04Z",
  ]) : resumedWorker ? admission([
    "2026-07-26T00:16:00Z", "2026-07-26T00:16:01Z", "2026-07-26T00:16:02Z",
    "2026-07-26T00:16:03Z", "2026-07-26T00:16:04Z", "2026-07-26T00:16:05Z",
    "2026-07-26T00:16:06Z", "2026-07-26T00:16:07Z",
  ]) : admission();
  if (resumedWorker) workerAdmission.liveness = () => ({
    healthy: true, observed_at: process.env.LATE_LEASE_TRANSFER ?
      "2026-07-26T00:39:59Z" : process.env.WORKER_MODE === "recover" ?
      "2026-07-26T00:19:59Z" : "2026-07-26T00:15:59Z",
  });
  try {
    const effectFenceFile = `${process.env.WORKER_DIR}/mock-effect-fence.json`;
    const effectTransactionLock = `${effectFenceFile}.transaction`;
    const effectTransaction = operation => {
      while (true) {
        try {
          fs.mkdirSync(effectTransactionLock);
          break;
        } catch (error) {
          if (error.code !== "EEXIST") throw error;
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
        }
      }
      try {
        return operation();
      } finally {
        fs.rmdirSync(effectTransactionLock);
      }
    };
    run({
      dir: process.env.WORKER_DIR, artifacts: workerArtifacts,
      admit: workerAdmission,
      phase: phases({
        activateFence: fence => {
          if (process.env.FENCE_LOG) fs.appendFileSync(process.env.FENCE_LOG, "fence\n");
          assert.equal(
            fs.existsSync(`${process.env.WORKER_DIR}/${binding().idempotency_key}.json`),
            true, "the effect fence is not installed before durable prepare",
          );
          effectTransaction(() => {
            const temporary = `${effectFenceFile}.${process.pid}.tmp`;
            fs.writeFileSync(temporary, JSON.stringify(fence));
            fs.renameSync(temporary, effectFenceFile);
          });
          return {
            activated: true, lease_fence_digest: autonomyDigest(fence),
          };
        },
        applyFenced: invocation => {
          if (process.env.APPLY_LOG) fs.appendFileSync(process.env.APPLY_LOG, "apply\n");
          if (process.env.WORKER_MODE === "crash") process.exit(77);
          if (process.env.FORCE_RECOVERY) throw Error("force-recovery");
          while (process.env.HOLD_BEFORE_EFFECT &&
              !fs.existsSync(process.env.HOLD_BEFORE_EFFECT)) {
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
          }
          effectTransaction(() => {
            const activeFence = JSON.parse(fs.readFileSync(effectFenceFile, "utf8"));
            if (autonomyDigest(activeFence) !== invocation.lease_fence_digest) {
              throw Object.assign(new Error("effect-lease-fenced"), {
                code: "effect_lease_fenced",
              });
            }
            if (process.env.HOST_EFFECT_LOG) {
              fs.appendFileSync(process.env.HOST_EFFECT_LOG, "host-effect\n");
            }
          });
          while (process.env.HOLD_AFTER_APPLY && !fs.existsSync(process.env.HOLD_AFTER_APPLY)) {
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
          }
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
          return { applied: true };
        },
      }),
      recover: workerRecovery,
      reconcile: process.env.WORKER_MODE === "recover" ?
        () => ({ state: "applied" }) :
        process.env.WORKER_MODE === "resume" ?
          () => ({ state: "not-applied" }) : null,
    });
  } catch { process.exitCode = 79; }
  process.exit(process.exitCode ?? 0);
}

const happyArtifacts = bundle();
const happy = run({ dir: `${tmp}/happy`, artifacts: happyArtifacts });
assert.equal(happy.reason, "committed");
assert.deepEqual(happy.journal.entries.map(entry => entry.phase), ["prepare", "apply", "verify", "watch", "commit"]);
assert.equal(validateJournalConformance(happy.journal, {
  schema: happyArtifacts.journalSchema, constitution: happyArtifacts.constitution,
  coverage: happyArtifacts.coverage, ownerAttestations: happyArtifacts.ownerAttestations,
}), true);

const policyFixture = fixturePath => JSON.parse(fs.readFileSync(fixturePath, "utf8"));
const autonomousPolicy = policyFixture(`${root}/tests/fixtures/maintenance-policy/normal-window.json`)
  .records.find(record => record.kind === "maintenance-policy");
autonomousPolicy.timezone = "UTC";
autonomousPolicy.window.days_of_week = ["sun"];
autonomousPolicy.window.start_local_time = "00:00";
autonomousPolicy.window.duration = "PT2H";
autonomousPolicy.selector.node_ids = ["node-a"];
autonomousPolicy.reboot.policy = "never";
delete autonomousPolicy.policy_digest;
autonomousPolicy.policy_digest = policyDigest(autonomousPolicy);
const executionPlan = {
  kind: "brokkr-maintenance-plan", schema_version: "v1", plan_id: "autonomous-plan",
  outcome: "planned", node_id: "node-a", policy_id: autonomousPolicy.policy_id,
  policy_digest: autonomousPolicy.policy_digest, inventory_evidence_id: "observation-test",
  running_kernel: "kernel-old", decision: { effect: "on_schedule" }, blockers: [],
  hook_gaps: [], unmet_policy_classes: [], created_at: "2026-07-26T00:00:00Z",
  gates: {
    package_manager_lock: "unlocked", disk: "sufficient", power: "mains",
    clock: "synchronized", workload_hooks: "not_applicable", kernel_recovery: "not_applicable",
  },
  candidates: [{ eligible: true, source: "distro_repository", class: "security" }],
};
executionPlan.plan_digest = autonomyDigest(executionPlan);
const executionTarget = { node_id: "node-a", platform: "debian", non_pillar: true };
const executionBefore = { kernel: "kernel-old", packages: ["a"], reboot_required: false, dpkg_status: "clean" };
const executionAfter = { kernel: "kernel-new", packages: ["b"], reboot_required: false, dpkg_status: "clean" };
const adapterRevision = "sha256:" + "9".repeat(64);
const execution = deriveDebianAutonomyExecution({
  plan: executionPlan, policy: autonomousPolicy, target: executionTarget,
  inventory: executionBefore, adapterRevisionDigest: adapterRevision,
  postconditions: executionAfter,
});
const wrapperArtifacts = bundle(execution.target_scope_digest);
const wrapperBinding = binding("wrapper-integration", wrapperArtifacts.coverage, Object.fromEntries([
  "target_scope_digest", "candidate_digest", "config_digest", "evidence_digest",
  "policy_digest", "baseline_digest", "postconditions_digest",
].map(field => [field, execution[field]])));
const wrapperAdmission = admission();
wrapperAdmission.evidence = () => ({ fresh: true, eligible: true, digest: execution.evidence_digest });
const wrapperAdapters = overrides => {
  let applied = false;
  let activeFenceDigest = null;
  return {
    inventory: () => clone(applied ? executionAfter : executionBefore),
    activateFence: fence => {
      assert.equal(Object.isFrozen(fence), true);
      activeFenceDigest = autonomyDigest(fence);
      return { activated: true, lease_fence_digest: activeFenceDigest };
    },
    applyFenced: invocation => {
      assert.equal(Object.isFrozen(invocation), true);
      assert.equal(Object.isFrozen(invocation.execution_request), true);
      assert.equal(invocation.execution_request_digest, execution.execution_request_digest);
      assert.equal(invocation.lease_fence_digest, activeFenceDigest);
      assert.equal(
        autonomyDigest(invocation.lease_fence), invocation.lease_fence_digest,
      );
      assert.deepEqual(invocation.execution_request.target, executionTarget);
      assert.deepEqual(invocation.execution_request.candidates, executionPlan.candidates);
      assert.equal(invocation.execution_request.config.no_reboot, true);
      assert.equal(invocation.execution_request.config.no_drain, true);
      applied = true;
      const receipt = {
        ok: true, elapsed_ms: 1,
        execution_request_digest: invocation.execution_request_digest,
        lease_fence_digest: invocation.lease_fence_digest, reboot_required: false,
      };
      return { ...receipt, receipt_digest: autonomyDigest(receipt) };
    },
    afterInventory: () => clone(executionAfter),
    currentPolicy: () => clone(autonomousPolicy),
    clock: () => ({ synchronized: true, now: "2026-07-26T00:00:00Z" }),
    hold: () => ({ active: false }), substrateHealth: () => ({ ok: true }),
    revisionDigest: () => adapterRevision, targetMetadata: () => clone(executionTarget),
    ...overrides,
  };
};
const wrapperResult = runDebianMaintenance({
  binding: wrapperBinding, attemptJournalDir: `${tmp}/wrapper`, artifacts: wrapperArtifacts,
  admission: wrapperAdmission, recovery: recovery(wrapperArtifacts), watch: () => {},
  target: executionTarget, expectedPostconditions: executionAfter, plan: executionPlan,
  policy: autonomousPolicy, nodeId: "node-a", adapters: wrapperAdapters(),
});
assert.equal(wrapperResult.reason, "committed", "actual executor inputs compose through the authoritative journal");
let freshInventoryReads = 0, freshInventoryApplyCalls = 0;
const freshInventoryArtifacts = bundle(execution.target_scope_digest);
const freshInventoryBinding = binding(
  "wrapper-fresh-inventory", freshInventoryArtifacts.coverage,
  Object.fromEntries([
    "target_scope_digest", "candidate_digest", "config_digest", "evidence_digest",
    "policy_digest", "baseline_digest", "postconditions_digest",
  ].map(field => [field, execution[field]])),
);
const freshInventoryAdmission = admission();
freshInventoryAdmission.evidence = () => ({
  fresh: true, eligible: true, digest: execution.evidence_digest,
});
const freshInventoryResult = runDebianMaintenance({
  binding: freshInventoryBinding,
  attemptJournalDir: `${tmp}/wrapper-fresh-inventory`,
  artifacts: freshInventoryArtifacts, admission: freshInventoryAdmission,
  recovery: recovery(freshInventoryArtifacts), watch: () => {},
  target: executionTarget, expectedPostconditions: executionAfter,
  plan: executionPlan, policy: autonomousPolicy, nodeId: "node-a",
  adapters: wrapperAdapters({
    inventory: () => {
      freshInventoryReads += 1;
      return clone(freshInventoryReads === 1 ? executionBefore : {
        ...executionBefore, packages: ["drifted"],
      });
    },
    applyFenced: () => {
      freshInventoryApplyCalls += 1;
      throw Error("must-not-apply");
    },
  }),
});
assert.equal(freshInventoryResult.reason, "recovered-disarmed");
assert.equal(freshInventoryApplyCalls, 0,
  "fresh inventory drift immediately before mutation stops before applyFenced");
for (const [name, options] of [
  ["plan", { plan: { ...executionPlan, plan_id: "substituted-plan" } }],
  ["policy", { policy: { ...autonomousPolicy, policy_id: "substituted-policy" } }],
  ["target", { adapters: wrapperAdapters({ targetMetadata: () => ({ ...executionTarget, non_pillar: false }) }) }],
  ["inventory", { adapters: wrapperAdapters({ inventory: () => ({ ...executionBefore, packages: ["substituted"] }) }) }],
  ["adapter", { adapters: wrapperAdapters({ revisionDigest: () => "sha256:" + "8".repeat(64) }) }],
  ["postconditions", { expectedPostconditions: { ...executionAfter, packages: ["substituted"] } }],
]) assert.throws(() => runDebianMaintenance({
  binding: wrapperBinding, attemptJournalDir: `${tmp}/wrapper-substitute-${name}`,
  artifacts: wrapperArtifacts, admission: wrapperAdmission, recovery: recovery(wrapperArtifacts),
  watch: () => {}, target: executionTarget, expectedPostconditions: executionAfter,
  plan: executionPlan, policy: autonomousPolicy, nodeId: "node-a", adapters: wrapperAdapters(),
  ...options,
}), /execution_binding_substituted|autonomy_execution_out_of_scope|plan_digest_invalid|policy_invalid/, name);

const staleHostArtifacts = bundle(execution.target_scope_digest);
const staleHostBinding = binding("wrapper-stale-host", staleHostArtifacts.coverage, Object.fromEntries([
  "target_scope_digest", "candidate_digest", "config_digest", "evidence_digest",
  "policy_digest", "baseline_digest", "postconditions_digest",
].map(field => [field, execution[field]])));
const staleHostAdmission = admission();
staleHostAdmission.evidence = () => ({
  fresh: true, eligible: true, digest: execution.evidence_digest,
});
const staleHostResult = runDebianMaintenance({
  binding: staleHostBinding, attemptJournalDir: `${tmp}/wrapper-stale-host`,
  artifacts: staleHostArtifacts, admission: staleHostAdmission,
  recovery: recovery(staleHostArtifacts), watch: () => {}, target: executionTarget,
  expectedPostconditions: executionAfter, plan: executionPlan, policy: autonomousPolicy,
  nodeId: "node-a", adapters: wrapperAdapters({
    inventory: () => clone(executionBefore),
  }),
});
assert.equal(
  staleHostResult.reason, "recovered-disarmed",
  "post-watch success reads the host again instead of trusting cached post-apply inventory",
);

const unboundReceiptArtifacts = bundle(execution.target_scope_digest);
const unboundReceiptBinding = binding("wrapper-unbound-receipt", unboundReceiptArtifacts.coverage, Object.fromEntries([
  "target_scope_digest", "candidate_digest", "config_digest", "evidence_digest",
  "policy_digest", "baseline_digest", "postconditions_digest",
].map(field => [field, execution[field]])));
const unboundReceiptAdmission = admission();
unboundReceiptAdmission.evidence = () => ({
  fresh: true, eligible: true, digest: execution.evidence_digest,
});
const unboundReceipt = runDebianMaintenance({
  binding: unboundReceiptBinding, attemptJournalDir: `${tmp}/wrapper-unbound-receipt`,
  artifacts: unboundReceiptArtifacts, admission: unboundReceiptAdmission,
  recovery: recovery(unboundReceiptArtifacts), watch: () => {}, target: executionTarget,
  expectedPostconditions: executionAfter, plan: executionPlan, policy: autonomousPolicy,
  nodeId: "node-a", adapters: wrapperAdapters({
    applyFenced: invocation => ({
      ok: true, elapsed_ms: 1, execution_request_digest: "sha256:" + "0".repeat(64),
      lease_fence_digest: invocation.lease_fence_digest, reboot_required: false,
      receipt_digest: "sha256:" + "0".repeat(64),
    }),
  }),
});
assert.equal(
  unboundReceipt.reason, "recovered-disarmed",
  "an adapter receipt for any other immutable request is rejected",
);

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
const openCoverage = bundle();
openCoverage.coverage.unreviewed_field = true;
resignArtifacts(openCoverage);
assert.throws(() => run({
  dir: `${tmp}/open-coverage`, artifacts: openCoverage,
}), /w01_schema_invalid:coverage/, "W0.1 artifacts remain closed");
const duplicateRow = bundle();
duplicateRow.coverage.domains.push(clone(duplicateRow.coverage.domains.find(row => (
  row.domain === "no-reboot-security-bugfix-maintenance"
))));
resignArtifacts(duplicateRow);
assert.throws(() => run({
  dir: `${tmp}/duplicate-row`, artifacts: duplicateRow,
}), /w01_schema_invalid:coverage|target_owner_attestation_invalid/, "domain rows are unique");
const aliasedIdentities = bundle();
const aliasedOwner = aliasedIdentities.coverage.domains.find(row => (
  row.domain === "no-reboot-security-bugfix-maintenance"
)).bindings[0];
aliasedOwner.identities.controller = aliasedOwner.identities.owner;
resignArtifacts(aliasedIdentities);
assert.throws(() => run({
  dir: `${tmp}/aliased-identities`, artifacts: aliasedIdentities,
  bind: binding("aliased-identities", aliasedIdentities.coverage),
}), /coverage_identity_ambiguity/, "all five identities are distinct");
const wrongRecoveryKeyArtifacts = bundle();
const wrongRecoveryCapability = recovery(wrongRecoveryKeyArtifacts);
wrongRecoveryCapability.publicKeyFingerprint = "sha256:" + "0".repeat(64);
assert.throws(() => run({
  dir: `${tmp}/wrong-recovery-key`, artifacts: wrongRecoveryKeyArtifacts,
  recover: wrongRecoveryCapability,
}), /recovery_capability_unbound/, "the exact owner-bound recovery key is preflighted");

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
  admit: admission(baseTimes, () => ++killChecks < 4),
});
assert.equal(killed.reason, "recovered-disarmed");
assert.deepEqual(killed.journal.entries.map(entry => entry.phase), ["prepare", "apply", "unknown", "recover", "quarantine", "disarm"]);
const shortWatchArtifacts = bundle();
const shortWatch = run({
  dir: `${tmp}/short-watch`, artifacts: shortWatchArtifacts,
  admit: admission(["2026-07-26T00:00:00Z", "2026-07-26T00:00:01Z", "2026-07-26T00:00:02Z", "2026-07-26T00:00:03Z", "2026-07-26T00:00:04Z", "2026-07-26T00:09:59Z", "2026-07-26T00:10:00Z"]),
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
const staleLockDir = `${tmp}/stale-lock`, staleLockReady = `${tmp}/stale-lock-ready`;
const staleLockChild = spawn(process.execPath, [process.argv[1]], {
  env: {
    ...process.env, WORKER_MODE: "hold-lock", WORKER_DIR: staleLockDir,
    READY: staleLockReady,
  },
});
while (!fs.existsSync(staleLockReady)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
const staleLockExit = new Promise(resolve => staleLockChild.on("exit", resolve));
staleLockChild.kill("SIGKILL");
await staleLockExit;
assert.equal(run({ dir: staleLockDir }).reason, "committed",
  "dead lock owner is taken over without deleting a live successor lock");
assert.throws(() => run({
  dir: staleLockDir, bind: { ...binding(), candidate_digest: "sha256:" + "7".repeat(64) },
}), /attempt_conflicting_replay/, "terminal retry is idempotent only for the exact binding");

const resumeDir = `${tmp}/resume-race`, resumeApplyLog = `${tmp}/resume-apply.log`;
assert.equal(await runWorker({
  WORKER_MODE: "crash", WORKER_DIR: resumeDir, APPLY_LOG: `${tmp}/resume-crash-apply.log`,
}), 77);
assert.throws(() => run({
  dir: resumeDir, bind: binding("different-proposal"), artifacts: bundle(),
}), /domain_concurrency_exceeded/, "one active target blocks a distinct proposal");
const resumeBarrier = `${tmp}/resume-barrier`;
const resumeWorkers = [
  runWorker({ WORKER_MODE: "resume", WORKER_DIR: resumeDir, APPLY_LOG: resumeApplyLog, BARRIER: resumeBarrier }),
  runWorker({ WORKER_MODE: "resume", WORKER_DIR: resumeDir, APPLY_LOG: resumeApplyLog, BARRIER: resumeBarrier }),
];
fs.writeFileSync(resumeBarrier, "");
await Promise.all(resumeWorkers);
assert.equal(fs.readFileSync(resumeApplyLog, "utf8").trim().split("\n").length, 1,
  "two expired-lease contenders cannot both actuate");
assert.equal(bounded(`${resumeDir}/${binding().idempotency_key}.json`).entries.at(-1).phase, "disarm");

const conflictDir = `${tmp}/conflicting-replay`;
assert.equal(await runWorker({
  WORKER_MODE: "crash", WORKER_DIR: conflictDir, APPLY_LOG: `${tmp}/conflict-crash-apply.log`,
}), 77);
const conflictArtifacts = bundle();
const conflictResult = run({
  dir: conflictDir, artifacts: conflictArtifacts,
  bind: { ...binding(), candidate_digest: "sha256:" + "7".repeat(64) },
  admit: takeoverAdmission(),
  recover: recovery(conflictArtifacts),
});
assert.equal(conflictResult.journal.entries.at(-1).phase, "disarm",
  "a conflicting nonterminal replay is terminalized in the original envelope");

const staleWriterDir = `${tmp}/stale-writer`, staleWriterLog = `${tmp}/stale-writer-apply.log`;
const staleWriterHostEffects = `${tmp}/stale-writer-host-effects.log`;
const staleWriterRelease = `${tmp}/stale-writer-release`;
assert.equal(await runWorker({
  WORKER_MODE: "crash", WORKER_DIR: staleWriterDir, APPLY_LOG: `${tmp}/stale-writer-crash.log`,
}), 77);
const staleWriter = runWorker({
  WORKER_MODE: "resume", WORKER_DIR: staleWriterDir, APPLY_LOG: staleWriterLog,
  HOST_EFFECT_LOG: staleWriterHostEffects, HOLD_BEFORE_EFFECT: staleWriterRelease,
});
while (!fs.existsSync(staleWriterLog)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
await runWorker({
  WORKER_MODE: "recover", WORKER_DIR: staleWriterDir, LATE_LEASE_TRANSFER: "1",
});
fs.writeFileSync(staleWriterRelease, "");
await staleWriter;
const staleWriterJournal = bounded(`${staleWriterDir}/${binding().idempotency_key}.json`);
assert.equal(staleWriterJournal.entries.at(-1).phase, "disarm");
assert.equal(staleWriterJournal.entries.some(entry => entry.phase === "apply"), false,
  "an expired holder is fenced before it can journal over recovery");
assert.equal(fs.existsSync(staleWriterHostEffects), false,
  "the effect owner rejects the old token inside its mutation transaction");

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
  phase: phases({ applyFenced: () => { throw Object.assign(new Error("apply-failed"), { code: "apply-failed" }); } }),
  recover: recovery(failureArtifacts, { recover: request => ({
    idempotency_key: request.idempotency_key, recovered: false,
    safe_state_verified: false, quarantine_active: true, reason_code: "forward-repair-failed",
  }) }),
});
assert.equal(failed.reason, "terminally-blocked");
assert.equal(failed.recovery_error, "forward-repair-failed");
assert.equal(failed.journal.entries.at(-1).phase, "terminally-blocked");
assert.notEqual(failed.journal.entries.at(-1).terminal_reason_digest, failed.journal.entries.at(-2).terminal_reason_digest);
const failedReplay = run({
  dir: `${tmp}/recovery-failure`, artifacts: failureArtifacts,
  recover: recovery(failureArtifacts),
});
assert.equal(failedReplay.reason, "terminal-terminally-blocked",
  "exact terminal replay remains idempotent after signed demotion");

const wrongFromArtifacts = bundle();
const wrongFromBase = recovery(wrongFromArtifacts);
const wrongFromRecovery = recovery(wrongFromArtifacts, {
  appendSignedNarrowing: input => {
    const result = wrongFromBase.appendSignedNarrowing(input);
    const entry = wrongFromArtifacts.runtimeNarrowing.entries.at(-1);
    entry.from_state = "armed-fleet";
    const unsigned = structuredClone(entry);
    delete unsigned.entry_digest;
    delete unsigned.signature;
    entry.entry_digest = autonomyDigest(unsigned);
    delete entry.signature;
    entry.signature = {
      algorithm: "Ed25519", value_base64: sign(entry, recoveryKeys.privateKey),
    };
    return { ledger: clone(wrongFromArtifacts.runtimeNarrowing) };
  },
});
assert.throws(() => run({
  dir: `${tmp}/wrong-terminal-from-state`, artifacts: wrongFromArtifacts,
  phase: phases({ applyFenced: () => { throw Error("force-recovery"); } }),
  recover: wrongFromRecovery,
}), /runtime_narrowing_append_unverified/,
"signed terminal narrowing must match the exact authorized from-state");

for (const faultPoint of [
  "after-recovery-intent", "after-unknown-append", "after-unknown-journal",
  "after-target-transition", "after-target-unknown",
  "before-recover-invocation", "after-recover-return", "after-recovery-result",
  "after-ledger-return", "after-ledger-append",
  "after-checkpoint-return", "after-checkpoint-advance",
  "after-terminal-journal", "after-terminal-release-before-stage",
  "after-terminal-release", "after-outbox-complete",
]) {
  const faultDir = `${tmp}/outbox-${faultPoint}`;
  const faultRecoveryLog = `${faultDir}-recover.log`;
  assert.equal(await runWorker({
    WORKER_MODE: "fault", WORKER_DIR: faultDir, FORCE_RECOVERY: "1",
    FAULT_POINT: faultPoint, RECOVERY_LOG: faultRecoveryLog,
  }), 78, faultPoint);
  const faultResumeCode = await runWorker({
    WORKER_MODE: "recover", WORKER_DIR: faultDir, RECOVERY_LOG: faultRecoveryLog,
  });
  assert.equal(faultResumeCode, 0, `${faultPoint}: recovery resume exits cleanly`);
  assert.equal(
    bounded(`${faultDir}/${binding().idempotency_key}.json`).entries.at(-1).phase,
    "disarm", faultPoint,
  );
  assert.equal(
    fs.existsSync(faultRecoveryLog) ?
      fs.readFileSync(faultRecoveryLog, "utf8").trim().split("\n").filter(Boolean).length : 0,
    1, `${faultPoint}: idempotent recovery effect occurs exactly once`,
  );
}

for (const faultPoint of ["after-commit-journal", "after-commit-release"]) {
  const commitDir = `${tmp}/commit-${faultPoint}`;
  assert.equal(await runWorker({
    WORKER_MODE: "fault", WORKER_DIR: commitDir, FAULT_POINT: faultPoint,
  }), 78, faultPoint);
  const terminal = run({ dir: commitDir, artifacts: bundle() });
  assert.equal(terminal.journal.entries.at(-1).phase, "commit", faultPoint);
  const state = bounded(`${commitDir}/.autonomy-state/domain-state.json`);
  assert.equal(state.active_attempt_id, null, `${faultPoint}: terminal replay releases domain`);
  assert.equal(
    state.targets[binding().target_scope_digest.slice(7)].execution_lease,
    null, `${faultPoint}: terminal replay releases lease`,
  );
}

const leaseClaimDir = `${tmp}/lease-claim-crash`;
const leaseClaimFenceLog = `${tmp}/lease-claim-fence.log`;
assert.equal(await runWorker({
  WORKER_MODE: "fault", WORKER_DIR: leaseClaimDir, FAULT_POINT: "after-lease-claim",
  FENCE_LOG: leaseClaimFenceLog,
}), 78);
assert.equal(
  fs.existsSync(`${leaseClaimDir}/${binding().idempotency_key}.json.authority.json`),
  true, "historical authority is durable before the execution lease is claimed",
);
assert.equal(
  fs.existsSync(`${leaseClaimDir}/${binding().idempotency_key}.json`),
  false, "claim crash precedes prepare and actuation",
);
assert.equal(fs.existsSync(leaseClaimFenceLog), false,
  "a claim crash calls neither the effect fence nor apply before durable prepare");
assert.equal(await runWorker({
  WORKER_MODE: "resume", WORKER_DIR: leaseClaimDir,
  FAULT_POINT: "after-lease-transfer",
}), 78);
assert.equal(await runWorker({
  WORKER_MODE: "resume", WORKER_DIR: leaseClaimDir, LATE_LEASE_TRANSFER: "1",
}), 0, "an expired transferred epoch can be mechanically reclaimed");
assert.equal(
  bounded(`${leaseClaimDir}/${binding().idempotency_key}.json`).entries.at(-1).phase,
  "disarm",
);

const preparedRotationDir = `${tmp}/prepared-owner-rotation`;
const preparedRotationFenceLog = `${tmp}/prepared-owner-rotation-fence.log`;
assert.equal(await runWorker({
  WORKER_MODE: "fault", WORKER_DIR: preparedRotationDir,
  FAULT_POINT: "after-prepare-journal", FENCE_LOG: preparedRotationFenceLog,
}), 78);
assert.equal(fs.existsSync(preparedRotationFenceLog), false,
  "durable prepare precedes effect-fence installation");
const preparedHistoricalArtifacts = bundle();
const preparedRecovery = recovery(preparedHistoricalArtifacts);
preparedHistoricalArtifacts.read = () => rotateOwnerAuthorization();
const preparedRotationReplay = run({
  dir: preparedRotationDir, artifacts: preparedHistoricalArtifacts,
  admit: recoveryTakeoverAdmission(), recover: preparedRecovery,
});
assert.equal(preparedRotationReplay.reason, "recovered-disarmed",
  "a durable prepared attempt recovers under historical authority after current rotation");
assert.equal(
  bounded(`${preparedRotationDir}/${binding().idempotency_key}.json`).entries.at(-1).phase,
  "disarm",
);

const rotationDir = `${tmp}/outbox-owner-rotation`;
const rotationLog = `${tmp}/outbox-owner-rotation-recover.log`;
assert.equal(await runWorker({
  WORKER_MODE: "fault", WORKER_DIR: rotationDir, FORCE_RECOVERY: "1",
  FAULT_POINT: "after-checkpoint-advance", RECOVERY_LOG: rotationLog,
}), 78);
const rotationState = bounded(`${rotationDir}/mock-recovery-state.json`);
const rotationArtifacts = bundle();
rotationArtifacts.runtimeNarrowing = clone(rotationState.ledger);
rotationArtifacts.runtimeNarrowingCheckpoint = clone(rotationState.checkpoint);
const rotationRecovery = recovery(rotationArtifacts);
const rotatedCurrent = bundle();
rotatedCurrent.authorization.authorization_id = "rotated-owner-authorization";
delete rotatedCurrent.authorization.signature;
rotatedCurrent.authorization.signature = {
  algorithm: "Ed25519", value_base64: sign(rotatedCurrent.authorization, ownerKeys.privateKey),
};
const rotatedAuthorizationDigest = autonomyDigest(rotatedCurrent.authorization);
rotatedCurrent.authorizationCheckpoint.authorization_digest = rotatedAuthorizationDigest;
rotatedCurrent.runtimeNarrowing.owner_authorization_digest = rotatedAuthorizationDigest;
rotatedCurrent.runtimeNarrowing.entries = [];
rotatedCurrent.runtimeNarrowingCheckpoint = {
  kind: "autonomy-runtime-narrowing-checkpoint", schema_version: "v1",
  owner_authorization_digest: rotatedAuthorizationDigest, ledger_tail_digest: null, minimum_entries: 0,
};
rotationArtifacts.read = () => rotatedCurrent;
const rotatedReplay = run({
  dir: rotationDir, artifacts: rotationArtifacts, admit: recoveryTakeoverAdmission(),
  recover: rotationRecovery,
});
assert.equal(rotatedReplay.journal.entries.at(-1).phase, "disarm",
  "prepared historical authority survives current owner rotation");
assert.equal(fs.readFileSync(rotationLog, "utf8").trim().split("\n").length, 1);
assert.equal(run({
  dir: rotationDir, artifacts: rotationArtifacts,
  recover: rotationRecovery,
}).reason, "terminal-disarm", "completed recovery remains replayable through owner rotation");

const driftArtifacts = bundle();
const driftedCurrent = bundle();
driftedCurrent.authorizationCheckpoint.authorization_digest = "sha256:" + "0".repeat(64);
let artifactReads = 0, driftApplyCalls = 0;
driftArtifacts.read = () => (++artifactReads === 1 ? driftArtifacts : driftedCurrent);
const drifted = run({
  dir: `${tmp}/authorization-drift`, artifacts: driftArtifacts,
  phase: phases({ applyFenced: () => { driftApplyCalls += 1; return { applied: true }; } }),
  recover: recovery(driftArtifacts),
});
assert.equal(drifted.journal.entries.at(-1).phase, "disarm");
assert.equal(driftApplyCalls, 0, "checkpoint drift immediately before apply cannot actuate");

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
