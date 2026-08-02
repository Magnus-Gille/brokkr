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
import { pathToFileURL } from "node:url";
const root = process.env.ROOT, tmp = process.env.TMP;
const {
  loadPinnedJournalSchema, validateJournalConformance,
} = await import(`${root}/scripts/maintenance-attempt-journal.mjs`);
const {
  deriveDebianAutonomyExecution, runDebianMaintenance,
} = await import(`${root}/scripts/debian-maintenance-executor.mjs`);
const {
  __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS,
  __BROKKR_TEST_ONLY__currentLockOwnerIdentity,
  __BROKKR_TEST_ONLY__probeExclusiveDirectory,
} = await import(`${root}/scripts/debian-maintenance-autonomy.mjs`);
const {
  autonomyDigest, canonicalJson,
} = await import(`${root}/scripts/lib/autonomy-authorization.mjs`);
const {
  policyDigest,
} = await import(`${root}/scripts/lib/maintenance-policy-contract.mjs`);

const fixture = name => JSON.parse(fs.readFileSync(`${root}/tests/fixtures/autonomy-contract-v2/${name}`, "utf8"));
const legacyFixture = name => JSON.parse(fs.readFileSync(
  `${root}/tests/fixtures/autonomy-contract/${name}`, "utf8",
));
const clone = value => structuredClone(value);
function resignJournal(journal) {
  journal.binding_digest = autonomyDigest(journal.binding);
  let previous = null;
  for (const entry of journal.entries) {
    entry.binding_digest = journal.binding_digest;
    entry.previous_receipt_digest = previous;
    entry.receipt_digest = autonomyDigest(entry, "receipt_digest");
    previous = entry.receipt_digest;
  }
  return journal;
}
const autonomousPolicy = JSON.parse(fs.readFileSync(
  `${root}/tests/fixtures/maintenance-policy/normal-window.json`, "utf8",
)).records.find(record => record.kind === "maintenance-policy");
autonomousPolicy.timezone = "UTC";
autonomousPolicy.window.days_of_week = ["sun"];
autonomousPolicy.window.start_local_time = "00:00";
autonomousPolicy.window.duration = "PT2H";
autonomousPolicy.selector.node_ids = ["node-a"];
autonomousPolicy.reboot.policy = "never";
delete autonomousPolicy.policy_digest;
autonomousPolicy.policy_digest = policyDigest(autonomousPolicy);
const executionPlan = {
  kind: "brokkr-maintenance-plan", schema_version: "v1",
  plan_id: "autonomous-plan", outcome: "planned", node_id: "node-a",
  policy_id: autonomousPolicy.policy_id,
  policy_digest: autonomousPolicy.policy_digest,
  inventory_evidence_id: "observation-test", running_kernel: "kernel-old",
  decision: { effect: "on_schedule" }, blockers: [], hook_gaps: [],
  unmet_policy_classes: [], created_at: "2026-07-26T00:00:00Z",
  gates: {
    package_manager_lock: "unlocked", disk: "sufficient", power: "mains",
    clock: "synchronized", workload_hooks: "not_applicable",
    kernel_recovery: "not_applicable",
  },
  candidates: [{
    id: "openssl@3.0.17-1~deb12u2", name: "openssl", class: "security",
    source: "distro_repository", current_version: "3.0.17-1~deb12u1",
    candidate_version: "3.0.17-1~deb12u2", eligible: true, reasons: [],
  }],
};
executionPlan.plan_digest = autonomyDigest(executionPlan);
const executionTarget = {
  node_id: "node-a", platform: "debian", non_pillar: true,
};
const executionBefore = {
  kernel: "kernel-old", packages: ["a"], reboot_required: false,
  dpkg_status: "clean",
};
const executionAfter = {
  kernel: "kernel-new", packages: ["b"], reboot_required: false,
  dpkg_status: "clean",
};
const adapterRevision = "sha256:" + "9".repeat(64);
const execution = deriveDebianAutonomyExecution({
  plan: executionPlan, policy: autonomousPolicy, target: executionTarget,
  inventory: executionBefore, adapterRevisionDigest: adapterRevision,
  postconditions: executionAfter,
});
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

function bundle(targetScopeDigest = execution.target_scope_digest) {
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
      target_scope_digest: targetScopeDigest,
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
    journalSchema: loadPinnedJournalSchema(`${root}/docs/autonomous-mutation-journal-v2.schema.json`),
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
function binding(
  id = "maintenance-attempt",
  coverage = bundle(execution.target_scope_digest).coverage,
  fields = {},
) {
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
    candidate_digest: execution.candidate_digest,
    config_digest: execution.config_digest,
    evidence_digest: execution.evidence_digest,
    policy_digest: execution.policy_digest,
    baseline_digest: execution.baseline_digest,
    postconditions_digest: execution.postconditions_digest,
    deadline: "2026-07-26T01:10:00Z",
    canary: { scope_digest: owner.target_scope_digest, target_count: 1 },
    recovery: { class: "R-forward", worker_identity: owner.identities.recovery_worker, descriptor_digest: "sha256:" + "2".repeat(64), disarms_after_action: true },
    ...fields,
  };
}
const baseTimes = [
  "2026-07-26T00:00:00Z", "2026-07-26T00:00:01Z",
  "2026-07-26T00:00:02Z", "2026-07-26T00:00:03Z",
  "2026-07-26T00:04:00Z", "2026-07-26T00:05:00Z",
  "2026-07-26T01:05:00Z",
];
function admission(times = baseTimes, kill = () => true) {
  let index = 0;
  let latest = times[0];
  return {
    trustedClock: () => {
      latest = times[Math.min(index++, times.length - 1)];
      return { trusted: true, now: latest };
    },
    killSwitch: () => ({ safe: kill(), identity: "maintenance-kill-switch" }),
    evidence: () => ({
      fresh: true, eligible: true, digest: execution.evidence_digest,
    }),
    liveness: () => ({ healthy: true, observed_at: latest }),
    maintenance: () => ({
      window: { start: "2026-07-26T00:00:00Z", end: "2026-07-26T01:10:01Z" },
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
    safeStateReadback: () => ({
      safe: true, postconditions_digest: execution.postconditions_digest,
    }),
    ...overrides,
  };
}
function recovery(artifacts, overrides = {}) {
  const {
    resourceNow = null,
    ...capabilityOverrides
  } = overrides;
  const receipts = new Map();
  let activeFence = null;
  const api = {
    workerIdentity: "maintenance-recovery-worker",
    publicKeyFingerprint: fingerprint(recoveryPublicPem),
    activateFence: fence => {
      if (activeFence) {
        assert.ok(fence.epoch >= activeFence.epoch);
        if (fence.epoch === activeFence.epoch) {
          assert.equal(autonomyDigest(fence), autonomyDigest(activeFence));
        }
      }
      activeFence = clone(fence);
      return {
        activated: true, lease_fence_digest: autonomyDigest(fence),
      };
    },
    readNarrowingHistory: ({ authorization_digest }) => {
      assert.equal(artifacts.runtimeNarrowing.owner_authorization_digest, authorization_digest);
      return {
        ledger: clone(artifacts.runtimeNarrowing),
        tailCheckpoint: clone(artifacts.runtimeNarrowingCheckpoint),
      };
    },
    recover: request => {
      assert.equal(
        request.revalidation_fence_digest, autonomyDigest(activeFence),
        "recovery effect validates the current resource fence",
      );
      assert.equal(
        autonomyDigest(request.revalidation_fence), request.revalidation_fence_digest,
        "recovery revalidation carries the current immutable resource fence",
      );
      const revalidatedAt = resourceNow?.() ?? activeFence.activated_at;
      if (Date.parse(revalidatedAt) < Date.parse(activeFence.activated_at) ||
          Date.parse(revalidatedAt) > Date.parse(activeFence.expires_at)) {
        throw Object.assign(new Error("recovery-fence-expired"), {
          code: "recovery_fence_expired",
        });
      }
      if (!receipts.has(request.idempotency_key)) {
        receipts.set(request.idempotency_key, {
          idempotency_key: request.idempotency_key,
          effect_lease_fence_digest: request.lease_fence_digest,
          recovered: true,
          safe_state_verified: true, quarantine_active: true, reason_code: null,
        });
      }
      return {
        ...clone(receipts.get(request.idempotency_key)),
        revalidated_lease_fence_digest: request.revalidation_fence_digest,
        revalidated_at: revalidatedAt,
      };
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
    ...capabilityOverrides,
  };
  const activations = new Map();
  globalThis.__BROKKR_TEST_FIXED_RECOVERY_HOST__ = {
    persistActivation: activation => {
      const activationDigest = autonomyDigest(activation);
      const existing = activations.get(activation.attempt_id);
      if (existing && autonomyDigest(existing) !== activationDigest) {
        throw Object.assign(new Error("activation-conflict"), { code: "activation_conflict" });
      }
      activations.set(activation.attempt_id, clone(activation));
      return { activation_digest: activationDigest, idempotent: existing !== undefined };
    },
    runFixedAdapter: input => api.recover(input.recovery_request),
  };
  return api;
}
function exactAdapters(phase = phases(), overrides = {}) {
  const {
    resourceNow = null,
    ...adapterOverrides
  } = overrides;
  const state = { applied: false, activeFence: null };
  return {
    inventory: () => {
      const safe = phase.safeStateReadback?.();
      return clone(state.applied && safe?.safe !== false ?
        executionAfter : executionBefore);
    },
    activateFence: fence => {
      if (state.activeFence) {
        assert.ok(fence.epoch >= state.activeFence.epoch);
        if (fence.epoch === state.activeFence.epoch) {
          assert.equal(autonomyDigest(fence), autonomyDigest(state.activeFence));
        }
      }
      state.activeFence = clone(fence);
      phase.activateFence?.(fence);
      return {
        activated: true, lease_fence_digest: autonomyDigest(fence),
      };
    },
    applyFenced: invocation => {
      assert.equal(
        invocation.lease_fence_digest, autonomyDigest(state.activeFence),
      );
      const fenceCheckedAt =
        resourceNow?.() ?? state.activeFence.activated_at;
      if (Date.parse(fenceCheckedAt) < Date.parse(state.activeFence.activated_at) ||
          Date.parse(fenceCheckedAt) >
          Date.parse(state.activeFence.expires_at)) {
        throw Object.assign(new Error("effect-lease-expired"), {
          code: "effect_lease_expired",
        });
      }
      const result = phase.applyFenced?.({
        lease_fence: invocation.lease_fence,
        lease_fence_digest: invocation.lease_fence_digest,
      }) ?? { applied: true };
      if (result.applied !== true) throw Error("phase-apply-failed");
      state.applied = true;
      const receipt = {
        ok: true, elapsed_ms: 1,
        execution_request_digest: invocation.execution_request_digest,
        lease_fence_digest: invocation.lease_fence_digest,
        fence_checked_at: fenceCheckedAt,
        reboot_required: false,
      };
      return { ...receipt, receipt_digest: autonomyDigest(receipt) };
    },
    afterInventory: () => clone(executionAfter),
    currentPolicy: () => clone(autonomousPolicy),
    clock: () => ({
      synchronized: true, now: "2026-07-26T00:00:00Z",
    }),
    hold: () => ({ active: false }),
    substrateHealth: () => ({
      ok: phase.verify?.().verified === true,
    }),
    revisionDigest: () => adapterRevision,
    targetMetadata: () => clone(executionTarget),
    ...adapterOverrides,
  };
}
const run = ({
  dir, artifacts = bundle(), bind = binding(), admit = admission(),
  phase = phases(), recover = null, reconcile = null, adapters = null,
  autoResume = true, publicOptions = {},
}) => {
  const selectedRecovery = recover ?? recovery(artifacts);
  const selectedAdapters = adapters ?? exactAdapters(phase);
  const input = {
    ...publicOptions,
    binding: bind, attemptJournalDir: dir, artifacts, admission: admit,
    recovery: selectedRecovery, reconcile, target: executionTarget,
    expectedPostconditions: executionAfter, plan: executionPlan,
    policy: autonomousPolicy, nodeId: "node-a", adapters: selectedAdapters,
  };
  let result = runDebianMaintenance(input);
  if (autoResume && result.reason === "watching") {
    result = runDebianMaintenance(input);
  }
  return result;
};
const currentLockOwnerIdentity = () => __BROKKR_TEST_ONLY__currentLockOwnerIdentity();
function writeLockTicketRecord(ticketsDir, {
  sequence,
  token = `completed-${String(sequence).padStart(8, "0")}`,
  pid = process.pid,
  boot_id = currentLockOwnerIdentity().boot_id,
  boot_id_authoritative = currentLockOwnerIdentity().boot_id_authoritative,
  process_start_time = currentLockOwnerIdentity().process_start_time,
  process_start_time_authoritative = currentLockOwnerIdentity().process_start_time_authoritative,
} = {}) {
  const prefix = String(sequence).padStart(8, "0");
  fs.mkdirSync(ticketsDir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(`${ticketsDir}/${prefix}.json`, `${canonicalJson({
    kind: "brokkr-lock-ticket",
    schema_version: "v1",
    pid,
    boot_id,
    boot_id_authoritative,
    process_start_time,
    process_start_time_authoritative,
    token,
    sequence,
  })}\n`);
  return { prefix, token };
}
function writeCompletedLockTicket(ticketsDir, sequence) {
  const { prefix, token } = writeLockTicketRecord(ticketsDir, { sequence });
  fs.writeFileSync(`${ticketsDir}/${prefix}.done`, `${canonicalJson({
    kind: "brokkr-lock-ticket-completion",
    schema_version: "v1",
    token,
    sequence,
  })}\n`);
}
function writeRetiredLockTicket(ticketsDir, {
  sequence,
  token = `completed-${String(sequence).padStart(8, "0")}`,
  reason = "owner-dead",
} = {}) {
  const prefix = String(sequence).padStart(8, "0");
  fs.mkdirSync(ticketsDir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(`${ticketsDir}/${prefix}.done`, `${canonicalJson({
    kind: "brokkr-lock-ticket-retirement",
    schema_version: "v1",
    token,
    sequence,
    reason,
  })}\n`);
}
const lockTicketArtifacts = ticketsDir => (
  fs.existsSync(ticketsDir) ? fs.readdirSync(ticketsDir).sort() : []
);
const lockCheckpointArtifacts = ticketsDir => lockTicketArtifacts(ticketsDir)
  .filter(name => name === "checkpoint.json" || /^checkpoint\.\d+\.json$/.test(name));
const lockTicketSequences = ticketsDir => lockTicketArtifacts(ticketsDir)
  .flatMap(name => {
    const match = /^(\d+)\.json$/.exec(name);
    return match ? [Number.parseInt(match[1], 10)] : [];
  })
  .sort((left, right) => left - right);
const lockTicketFinalArtifacts = ticketsDir => lockTicketArtifacts(ticketsDir)
  .filter(name =>
    /^(\d+)\.(done|json)$/.test(name) ||
    name === "checkpoint.json" ||
    /^checkpoint\.\d+\.json$/.test(name),
  );
const lockTicketTemps = ticketsDir => lockTicketArtifacts(ticketsDir)
  .filter(name => name.endsWith(".tmp"));
function readHighestLockCheckpoint(ticketsDir) {
  let selected = null;
  for (const name of lockCheckpointArtifacts(ticketsDir)) {
    const record = bounded(`${ticketsDir}/${name}`);
    if (selected === null || record.last_completed_sequence > selected.last_completed_sequence) {
      selected = record;
      continue;
    }
    if (record.last_completed_sequence === selected.last_completed_sequence) {
      assert.equal(record.last_completed_token, selected.last_completed_token);
    }
  }
  return selected;
}
function withEnv(name, value, fn) {
  const previous = process.env[name];
  if (value === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = value;
  }
  try {
    return fn();
  } finally {
    if (previous === undefined) {
      delete process.env[name];
    } else {
      process.env[name] = previous;
    }
  }
}
function withLockOwnerProbe(probe, fn) {
  const previousProbe = globalThis.__BROKKR_TEST_LOCK_OWNER_PROBE__;
  globalThis.__BROKKR_TEST_LOCK_OWNER_PROBE__ = probe;
  try {
    return withEnv("BROKKR_ENABLE_TEST_LOCK_OWNER_PROBE", "1", fn);
  } finally {
    if (previousProbe === undefined) {
      delete globalThis.__BROKKR_TEST_LOCK_OWNER_PROBE__;
    } else {
      globalThis.__BROKKR_TEST_LOCK_OWNER_PROBE__ = previousProbe;
    }
  }
}
async function importFreshAutonomyModuleWithBootIdFailure(code) {
  const originalReadFileSync = fs.readFileSync;
  fs.readFileSync = ((file, ...args) => {
    if (file === "/proc/sys/kernel/random/boot_id") {
      throw Object.assign(new Error(`synthetic-boot-id-${code}`), { code });
    }
    return originalReadFileSync.call(fs, file, ...args);
  });
  const autonomyUrl = pathToFileURL(`${root}/scripts/debian-maintenance-autonomy.mjs`);
  autonomyUrl.searchParams.set("test", crypto.randomUUID());
  try {
    return await import(autonomyUrl.href);
  } finally {
    fs.readFileSync = originalReadFileSync;
  }
}
function waitForFile(file, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (!fs.existsSync(file)) {
    if (Date.now() >= deadline) {
      throw new Error(`timed out waiting for ${file}`);
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
  }
}
function withLockTicketFaults(fn) {
  const previousEnabled = process.env.BROKKR_ENABLE_TEST_LOCK_TICKET_FAULTS;
  process.env.BROKKR_ENABLE_TEST_LOCK_TICKET_FAULTS = "1";
  try {
    return fn();
  } finally {
    if (previousEnabled === undefined) {
      delete process.env.BROKKR_ENABLE_TEST_LOCK_TICKET_FAULTS;
    } else {
      process.env.BROKKR_ENABLE_TEST_LOCK_TICKET_FAULTS = previousEnabled;
    }
    delete globalThis.__BROKKR_TEST_LOCK_TICKET_FAULT__;
  }
}
const fallbackOwnerProbeEnv = ({
  bootId,
  selfProcessStart,
  otherProcessStart = "__NULL__",
} = {}) => ({
  BROKKR_ENABLE_TEST_LOCK_OWNER_PROBE: "1",
  TEST_OWNER_PROBE_BOOT_ID: bootId,
  TEST_OWNER_PROBE_BOOT_ID_AUTHORITATIVE: "0",
  TEST_OWNER_PROBE_SELF_PROCESS_START: selfProcessStart,
  TEST_OWNER_PROBE_SELF_PROCESS_START_AUTHORITATIVE: "0",
  TEST_OWNER_PROBE_OTHER_PROCESS_START: otherProcessStart,
  TEST_OWNER_PROBE_OTHER_PROCESS_START_AUTHORITATIVE: "0",
});

if (process.env.WORKER_MODE) {
  process.env.BROKKR_ENABLE_TEST_LOCK_TICKET_FAULTS = "1";
  const holdDeadlineMs = Number.parseInt(process.env.CHILD_HOLD_TIMEOUT_MS ?? "15000", 10);
  const waitBriefly = (timeoutMs = 1) =>
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, timeoutMs);
  const waitForReleaseFile = (file, label) => {
    const deadline = Date.now() + holdDeadlineMs;
    while (!file || !fs.existsSync(file)) {
      if (Date.now() >= deadline) {
        throw Object.assign(new Error(`${label}-timeout`), {
          code: "worker_hold_timeout",
        });
      }
      waitBriefly();
    }
  };
  const envProbeValue = (name, authoritativeName) => {
    const value = process.env[name];
    if (value === undefined) return undefined;
    if (value === "__NULL__") return null;
    return {
      value,
      authoritative: process.env[authoritativeName] === "1",
    };
  };
  const bootProbe = envProbeValue(
    "TEST_OWNER_PROBE_BOOT_ID",
    "TEST_OWNER_PROBE_BOOT_ID_AUTHORITATIVE",
  );
  const selfStartProbe = envProbeValue(
    "TEST_OWNER_PROBE_SELF_PROCESS_START",
    "TEST_OWNER_PROBE_SELF_PROCESS_START_AUTHORITATIVE",
  );
  const otherStartProbe = envProbeValue(
    "TEST_OWNER_PROBE_OTHER_PROCESS_START",
    "TEST_OWNER_PROBE_OTHER_PROCESS_START_AUTHORITATIVE",
  );
  if ([bootProbe, selfStartProbe, otherStartProbe].some(value => value !== undefined)) {
    process.env.BROKKR_ENABLE_TEST_LOCK_OWNER_PROBE = "1";
    globalThis.__BROKKR_TEST_LOCK_OWNER_PROBE__ = {
      currentBootId: () => bootProbe,
      processStartTime: pid => (pid === process.pid ? selfStartProbe : otherStartProbe),
    };
  }
  globalThis.__BROKKR_TEST_LOCK_TICKET_FAULT__ = point => {
    if (process.env.HOLD_POINT === point) {
      if (process.env.HOLD_READY) fs.writeFileSync(process.env.HOLD_READY, `${point}\n`);
      waitForReleaseFile(process.env.HOLD_RELEASE, process.env.HOLD_POINT);
    }
    if (process.env.FAULT_POINT === point) process.exit(78);
  };
  if (process.env.WORKER_MODE === "lock-probe") {
    __BROKKR_TEST_ONLY__probeExclusiveDirectory(process.env.LOCK_DIR);
    process.exit(0);
  }
  if (process.env.WORKER_MODE === "lock-probe-status") {
    try {
      __BROKKR_TEST_ONLY__probeExclusiveDirectory(process.env.LOCK_DIR);
      process.exit(0);
    } catch (error) {
      if (process.env.ERROR_LOG) {
        fs.writeFileSync(process.env.ERROR_LOG, `${error?.code ?? error?.message ?? error}\n`);
      }
      process.exit(error?.code === "lock_probe_contended" ? 73 : 74);
    }
  }
  if (process.env.WORKER_MODE === "lock-hold") {
    __BROKKR_TEST_ONLY__probeExclusiveDirectory(process.env.LOCK_DIR, () => {
      if (process.env.OP_READY) fs.writeFileSync(process.env.OP_READY, "ready\n");
      waitForReleaseFile(process.env.OP_RELEASE, "lock-hold-release");
      return true;
    });
    process.exit(0);
  }
  if (process.env.WORKER_MODE === "hold-lock") {
    const tickets = `${process.env.WORKER_DIR}/.autonomy-state/domain-state.lock.tickets`;
    fs.mkdirSync(tickets, { recursive: true });
    const owner = currentLockOwnerIdentity();
    fs.writeFileSync(`${tickets}/00000001.json`, JSON.stringify({
      kind: "brokkr-lock-ticket", schema_version: "v1", pid: process.pid,
      boot_id: owner.boot_id, boot_id_authoritative: owner.boot_id_authoritative,
      process_start_time: owner.process_start_time,
      process_start_time_authoritative: owner.process_start_time_authoritative,
      token: "child-lock-owner", sequence: 1,
    }));
    fs.writeFileSync(process.env.READY, "ready");
    waitBriefly(holdDeadlineMs);
    process.exit(0);
  }
  if (process.env.BARRIER) waitForReleaseFile(process.env.BARRIER, "worker-barrier");
  const workerArtifacts = bundle();
  const overBudgetWorkerTimes = process.env.OVER_BUDGET_WATCH_ANCHOR ?
    Array(12).fill("2026-07-26T00:00:00Z") : null;
  const workerRecoveryState = `${process.env.WORKER_DIR}/mock-recovery-state.json`;
  const withWorkerLock = (lock, operation) => {
    while (true) {
      try { fs.mkdirSync(lock); break; }
      catch (error) {
        if (error.code !== "EEXIST") throw error;
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
      }
    }
    try { return operation(); } finally { fs.rmdirSync(lock); }
  };
  const recoveryTransactionLock = `${workerRecoveryState}.transaction`;
  const workerResourceNow = () => process.env.VERY_LATE_LEASE_TRANSFER ?
    "2026-07-26T00:56:10Z" : process.env.LATE_LEASE_TRANSFER ?
    "2026-07-26T00:40:10Z" : process.env.WORKER_MODE === "recover" ?
    "2026-07-26T00:20:10Z" : ["resume", "race"].includes(process.env.WORKER_MODE) ?
    "2026-07-26T00:16:10Z" : "2026-07-26T00:00:10Z";
  const readWorkerRecoveryState = () => fs.existsSync(workerRecoveryState) ?
    JSON.parse(fs.readFileSync(workerRecoveryState, "utf8")) : {
      ledger: clone(workerArtifacts.runtimeNarrowing),
      checkpoint: clone(workerArtifacts.runtimeNarrowingCheckpoint),
      receipts: {}, active_fence: null,
    };
  const writeWorkerRecoveryState = state => {
    const temporary = `${workerRecoveryState}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(state));
    fs.renameSync(temporary, workerRecoveryState);
  };
  const workerRecovery = recovery(workerArtifacts, {
    activateFence: fence => withWorkerLock(recoveryTransactionLock, () => {
      const state = readWorkerRecoveryState();
      if (state.active_fence) {
        assert.ok(fence.epoch >= state.active_fence.epoch,
          "recovery resource rejects a lower epoch");
        if (fence.epoch === state.active_fence.epoch) {
          assert.equal(autonomyDigest(fence), autonomyDigest(state.active_fence));
        }
      }
      state.active_fence = clone(fence);
      writeWorkerRecoveryState(state);
      return {
        activated: true, lease_fence_digest: autonomyDigest(fence),
      };
    }),
    readNarrowingHistory: () => {
      const state = readWorkerRecoveryState();
      return { ledger: clone(state.ledger), tailCheckpoint: clone(state.checkpoint) };
    },
    recover: request => {
      if (process.env.RECOVERY_CALL_LOG) {
        fs.appendFileSync(process.env.RECOVERY_CALL_LOG, "recovery-call\n");
      }
      if (process.env.HOLD_BEFORE_RECOVERY_EFFECT) {
        waitForReleaseFile(
          process.env.HOLD_BEFORE_RECOVERY_EFFECT,
          "hold-before-recovery-effect",
        );
      }
      return withWorkerLock(recoveryTransactionLock, () => {
        const state = readWorkerRecoveryState();
        if (request.revalidation_fence_digest !==
            autonomyDigest(state.active_fence)) {
          throw Object.assign(new Error("recovery-lease-fenced"), {
            code: "recovery_lease_fenced",
          });
        }
        // Recovery revalidates at the installed successor fence's trusted
        // activation instant. Effect-side stale-writer cases below retain their
        // independent host-clock probes.
        const revalidatedAt = state.active_fence.activated_at;
        if (Date.parse(revalidatedAt) <
              Date.parse(state.active_fence.activated_at) ||
            Date.parse(revalidatedAt) >
            Date.parse(state.active_fence.expires_at)) {
          throw Object.assign(new Error("recovery-fence-expired"), {
            code: "recovery_fence_expired",
          });
        }
        if (!state.receipts[request.idempotency_key]) {
          if (process.env.RECOVERY_LOG) {
            fs.appendFileSync(process.env.RECOVERY_LOG, "recover\n");
          }
          state.receipts[request.idempotency_key] = {
            idempotency_key: request.idempotency_key,
            effect_lease_fence_digest: request.lease_fence_digest,
            recovered: true,
            safe_state_verified: true, quarantine_active: true,
            reason_code: null,
          };
          writeWorkerRecoveryState(state);
        }
        return {
          ...clone(state.receipts[request.idempotency_key]),
          revalidated_lease_fence_digest: request.revalidation_fence_digest,
          revalidated_at: revalidatedAt,
        };
      });
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
      if (point === "after-watch-journal-readback" &&
          overBudgetWorkerTimes) {
        overBudgetWorkerTimes.fill("2026-07-26T00:05:01Z");
      }
      if (process.env.FAULT_POINT === point) process.exit(78);
    },
  });
  const resumedWorker = ["resume", "recover"].includes(process.env.WORKER_MODE);
  const workerAdmission = process.env.VERY_LATE_LEASE_TRANSFER ? admission([
    "2026-07-26T00:56:00Z", "2026-07-26T00:56:01Z",
    "2026-07-26T00:56:02Z", "2026-07-26T00:56:03Z",
    "2026-07-26T00:56:04Z",
  ]) : process.env.LATE_LEASE_TRANSFER ? admission([
    "2026-07-26T00:40:00Z", "2026-07-26T00:40:01Z", "2026-07-26T00:40:02Z",
    "2026-07-26T00:40:03Z", "2026-07-26T00:40:04Z",
  ]) : process.env.WORKER_MODE === "recover" ? admission([
    "2026-07-26T00:20:00Z", "2026-07-26T00:20:01Z", "2026-07-26T00:20:02Z",
    "2026-07-26T00:20:03Z", "2026-07-26T00:20:04Z",
  ]) : resumedWorker ? admission([
    "2026-07-26T00:16:00Z", "2026-07-26T00:16:01Z", "2026-07-26T00:16:02Z",
    "2026-07-26T00:16:03Z", "2026-07-26T00:16:04Z", "2026-07-26T00:16:05Z",
    "2026-07-26T00:16:06Z", "2026-07-26T00:16:07Z",
  ]) : admission(overBudgetWorkerTimes ?? baseTimes);
  if (resumedWorker) workerAdmission.liveness = () => ({
    healthy: true, observed_at: process.env.VERY_LATE_LEASE_TRANSFER ?
      "2026-07-26T00:55:59Z" : process.env.LATE_LEASE_TRANSFER ?
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
    const workerResult = run({
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
          if (process.env.HOLD_BEFORE_EFFECT) {
            waitForReleaseFile(process.env.HOLD_BEFORE_EFFECT, "hold-before-effect");
          }
          try {
            effectTransaction(() => {
              const activeFence = JSON.parse(fs.readFileSync(effectFenceFile, "utf8"));
              if (autonomyDigest(activeFence) !== invocation.lease_fence_digest) {
                throw Object.assign(new Error("effect-lease-fenced"), {
                  code: "effect_lease_fenced",
                });
              }
              const checkedAt = workerResourceNow();
              if (Date.parse(checkedAt) <
                    Date.parse(activeFence.activated_at) ||
                  Date.parse(checkedAt) > Date.parse(activeFence.expires_at)) {
                throw Object.assign(new Error("effect-lease-expired"), {
                  code: "effect_lease_expired",
                });
              }
              if (process.env.HOST_EFFECT_LOG) {
                fs.appendFileSync(process.env.HOST_EFFECT_LOG, "host-effect\n");
              }
            });
          } catch (error) {
            if (process.env.WORKER_ERROR_LOG &&
                process.env.HOLD_AFTER_APPLY_READY) {
              fs.appendFileSync(
                process.env.WORKER_ERROR_LOG,
                `${String(error?.code ?? error?.message ?? "unknown-error")}\n`,
              );
            }
            throw error;
          }
          if (process.env.HOLD_AFTER_APPLY_READY) {
            fs.writeFileSync(process.env.HOLD_AFTER_APPLY_READY, "ready\n");
          }
          if (process.env.HOLD_AFTER_APPLY) {
            waitForReleaseFile(process.env.HOLD_AFTER_APPLY, "hold-after-apply");
          }
          waitBriefly(100);
          return { applied: true };
        },
      }),
      recover: workerRecovery,
      reconcile: process.env.WORKER_MODE === "recover" ?
        () => ({ state: "applied" }) :
        process.env.WORKER_MODE === "resume" ?
          () => ({ state: "not-applied" }) : null,
    });
    if (process.env.WORKER_RESULT) {
      fs.writeFileSync(process.env.WORKER_RESULT, JSON.stringify({
        ran: workerResult.ran, reason: workerResult.reason,
      }));
    }
  } catch (error) {
    if (process.env.WORKER_ERROR_LOG) {
      fs.appendFileSync(
        process.env.WORKER_ERROR_LOG,
        `${String(error?.code ?? error?.message ?? "unknown-error")}\n`,
      );
    }
    process.exitCode = 79;
  }
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
const happyPrepareAt = Date.parse(happy.journal.entries[0].recorded_at);
const happyWatchAt = Date.parse(
  happy.journal.entries.find(entry => entry.phase === "watch").recorded_at,
);
const happyWatchAnchor = bounded(
  `${tmp}/happy/${happy.journal.binding.idempotency_key}.json.watch-anchor.json`,
);
const happyAnchorAt = Date.parse(happyWatchAnchor.anchored_at);
const happyCommitAt = Date.parse(happy.journal.entries.at(-1).recorded_at);
assert.ok(happyWatchAt <= happyAnchorAt,
  "the journal watch entry cannot postdate its post-fsync anchor");
assert.equal(happyAnchorAt - happyPrepareAt, 300_000,
  "the v2 happy path anchors the durable watch receipt at the exact 300-second budget");
assert.equal(happyCommitAt - happyAnchorAt, 3_600_000,
  "the v2 happy path commits at the exact 3600-second post-receipt watch floor");
assert.equal(
  happyWatchAnchor.journal_tail_digest,
  happy.journal.entries.find(entry => entry.phase === "watch").receipt_digest,
  "the durable anchor binds the exact authenticated watch journal tail",
);
assert.equal(happyWatchAnchor.attempt_id, happy.journal.binding.attempt_id);
assert.equal(
  happyWatchAnchor.target_scope_digest,
  happy.journal.binding.target_scope_digest,
);
assert.equal(
  happyWatchAnchor.candidate_digest,
  happy.journal.binding.candidate_digest,
);
assert.equal(Object.hasOwn(happy.journal.binding.canary, "watch_deadline"), false,
  "v2 derives watch completion from the durable receipt");
assert.throws(() => loadPinnedJournalSchema(
  `${root}/docs/autonomous-mutation-journal-v1.schema.json`,
), /journal_schema_pin_mismatch/,
"the retained v1 journal is provenance only and cannot authorize new admission");
const mixedEpochArtifacts = bundle();
mixedEpochArtifacts.constitution = legacyFixture("constitution.json");
mixedEpochArtifacts.coverage = legacyFixture("coverage-armed-canary.json");
mixedEpochArtifacts.ownerAttestations =
  legacyFixture("owner-attestations.json");
assert.throws(() => run({
  dir: `${tmp}/mixed-v1-v2`,
  artifacts: mixedEpochArtifacts,
  bind: binding("mixed-v1-v2", mixedEpochArtifacts.coverage),
}), /w01_schema_invalid/,
"mixed v1 authority and v2 journal admission fails closed");
for (const [name, mutate, expected] of [
  ["late durable watch receipt", journal => {
    journal.entries.find(entry => entry.phase === "watch").recorded_at =
      "2026-07-26T00:05:00.001Z";
  }, /journal_apply_verify_budget_exceeded/],
  ["short post-receipt watch", journal => {
    journal.entries.at(-1).recorded_at = "2026-07-26T01:04:59.999Z";
  }, /journal_watch_incomplete/],
  ["excess commit grace", journal => {
    journal.entries.find(entry => entry.phase === "verify").recorded_at =
      "2026-07-26T00:04:59.999Z";
    journal.entries.find(entry => entry.phase === "watch").recorded_at =
      "2026-07-26T00:04:59.999Z";
    journal.entries.at(-1).recorded_at = "2026-07-26T01:10:00Z";
  }, /journal_commit_grace_exceeded/],
  ["total deadline overflow", journal => {
    journal.binding.deadline = "2026-07-26T01:10:00.001Z";
  }, /journal_deadline_bound_invalid/],
]) {
  const candidate = clone(happy.journal);
  mutate(candidate);
  resignJournal(candidate);
  assert.throws(() => validateJournalConformance(candidate, {
    schema: happyArtifacts.journalSchema,
    constitution: happyArtifacts.constitution,
    coverage: happyArtifacts.coverage,
    ownerAttestations: happyArtifacts.ownerAttestations,
  }, name === "short post-receipt watch" ?
    { watchAnchor: happyWatchAnchor } : {}), expected, name);
}
const preboundWatchDeadline = clone(happy.journal);
preboundWatchDeadline.binding.canary.watch_deadline =
  "2026-07-26T01:05:00Z";
resignJournal(preboundWatchDeadline);
assert.throws(() => validateJournalConformance(preboundWatchDeadline, {
  schema: happyArtifacts.journalSchema,
  constitution: happyArtifacts.constitution,
  coverage: happyArtifacts.coverage,
  ownerAttestations: happyArtifacts.ownerAttestations,
}), /journal_schema_invalid/, "v2 rejects caller-prebound watch deadlines");
const noncanonicalZeroMilliseconds = clone(happy.journal);
noncanonicalZeroMilliseconds.binding.deadline =
  "2026-07-26T01:10:00.000Z";
resignJournal(noncanonicalZeroMilliseconds);
assert.throws(() => validateJournalConformance(
  noncanonicalZeroMilliseconds,
  {
    schema: happyArtifacts.journalSchema,
    constitution: happyArtifacts.constitution,
    coverage: happyArtifacts.coverage,
    ownerAttestations: happyArtifacts.ownerAttestations,
  },
), /journal_schema_invalid:.*date-time/,
"v2 rejects noncanonical .000Z timestamps exactly like Grimnir");
const terminalAnchorArtifacts = bundle();
const terminalAnchorBinding = binding(
  "terminal-anchor", terminalAnchorArtifacts.coverage,
);
const terminalAnchorDir = `${tmp}/terminal-anchor`;
assert.equal(run({
  dir: terminalAnchorDir, artifacts: terminalAnchorArtifacts,
  bind: terminalAnchorBinding,
}).reason, "committed");
fs.unlinkSync(
  `${terminalAnchorDir}/${terminalAnchorBinding.idempotency_key}` +
  ".json.watch-anchor.json",
);
assert.throws(() => run({
  dir: terminalAnchorDir, artifacts: terminalAnchorArtifacts,
  bind: terminalAnchorBinding,
}), /watch_anchor_ENOENT/,
"an exact terminal commit retry still requires its durable anchor");
const wrongJournalIdentity = clone(happy.journal);
wrongJournalIdentity.journal_id = "different-mutation";
assert.throws(() => validateJournalConformance(wrongJournalIdentity, {
  schema: happyArtifacts.journalSchema, constitution: happyArtifacts.constitution,
  coverage: happyArtifacts.coverage, ownerAttestations: happyArtifacts.ownerAttestations,
}), /journal_mutation_identity_mismatch/);
const aliasedEnvelopeIdentities = clone(happy.journal);
aliasedEnvelopeIdentities.binding.attempt_id =
  aliasedEnvelopeIdentities.binding.mutation_id;
resignJournal(aliasedEnvelopeIdentities);
assert.throws(() => validateJournalConformance(aliasedEnvelopeIdentities, {
  schema: happyArtifacts.journalSchema, constitution: happyArtifacts.constitution,
  coverage: happyArtifacts.coverage, ownerAttestations: happyArtifacts.ownerAttestations,
}), /journal_envelope_identity_aliased/);
const rForwardRevert = clone(happy.journal);
rForwardRevert.entries[1].phase = "revert";
rForwardRevert.entries[1].outcome = "reverted";
resignJournal(rForwardRevert);
assert.throws(() => validateJournalConformance(rForwardRevert, {
  schema: happyArtifacts.journalSchema, constitution: happyArtifacts.constitution,
  coverage: happyArtifacts.coverage, ownerAttestations: happyArtifacts.ownerAttestations,
}), /journal_r_forward_revert_forbidden/);
const aliasedTerminalIdentity = resignJournal(clone(happy.journal));
aliasedTerminalIdentity.binding.recovery_disarm_id =
  aliasedTerminalIdentity.binding.attempt_id;
resignJournal(aliasedTerminalIdentity);
assert.throws(() => validateJournalConformance(aliasedTerminalIdentity, {
  schema: happyArtifacts.journalSchema, constitution: happyArtifacts.constitution,
  coverage: happyArtifacts.coverage,
  ownerAttestations: happyArtifacts.ownerAttestations,
}), /journal_envelope_identity_aliased/);
const duplicateEntryIdentity = clone(happy.journal);
duplicateEntryIdentity.entries[1].entry_id =
  duplicateEntryIdentity.entries[0].entry_id;
resignJournal(duplicateEntryIdentity);
assert.throws(() => validateJournalConformance(duplicateEntryIdentity, {
  schema: happyArtifacts.journalSchema, constitution: happyArtifacts.constitution,
  coverage: happyArtifacts.coverage,
  ownerAttestations: happyArtifacts.ownerAttestations,
}), /journal_entry_identity_replayed/);

const wrapperArtifacts = bundle(execution.target_scope_digest);
const wrapperBinding = binding("wrapper-integration", wrapperArtifacts.coverage, Object.fromEntries([
  "target_scope_digest", "candidate_digest", "config_digest", "evidence_digest",
  "policy_digest", "baseline_digest", "postconditions_digest",
].map(field => [field, execution[field]])));
const wrapperAdmission = admission();
wrapperAdmission.evidence = () => ({ fresh: true, eligible: true, digest: execution.evidence_digest });
const completeDebian = input => {
  let result = runDebianMaintenance(input);
  if (result.reason === "watching") result = runDebianMaintenance(input);
  return result;
};
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
        lease_fence_digest: invocation.lease_fence_digest,
        fence_checked_at: "2026-07-26T00:00:01Z",
        reboot_required: false,
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
const wrapperResult = completeDebian({
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
const staleHostResult = completeDebian({
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
const unboundReceipt = completeDebian({
  binding: unboundReceiptBinding, attemptJournalDir: `${tmp}/wrapper-unbound-receipt`,
  artifacts: unboundReceiptArtifacts, admission: unboundReceiptAdmission,
  recovery: recovery(unboundReceiptArtifacts), watch: () => {}, target: executionTarget,
  expectedPostconditions: executionAfter, plan: executionPlan, policy: autonomousPolicy,
  nodeId: "node-a", adapters: wrapperAdapters({
    applyFenced: invocation => ({
      ok: true, elapsed_ms: 1, execution_request_digest: "sha256:" + "0".repeat(64),
      lease_fence_digest: invocation.lease_fence_digest,
      fence_checked_at: "2026-07-26T00:00:01Z", reboot_required: false,
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
}), /w01_schema_invalid:coverage/, "W0.2 constitution/coverage remain closed");
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
let expiredEffectCalls = 0;
const expiredEffectArtifacts = bundle();
const expiredEffectPhase = phases({
  applyFenced: () => {
    expiredEffectCalls += 1;
    return { applied: true };
  },
});
const expiredEffect = run({
  dir: `${tmp}/expired-effect`, artifacts: expiredEffectArtifacts,
  phase: expiredEffectPhase,
  adapters: exactAdapters(expiredEffectPhase, {
    resourceNow: () => "2026-07-26T00:16:00Z",
  }),
});
assert.equal(expiredEffect.reason, "recovered-disarmed");
assert.equal(expiredEffectCalls, 0,
  "the effect resource rejects an expired fence before host actuation even without a successor");
let prematureEffectCalls = 0;
const prematureEffectArtifacts = bundle();
const prematureEffectPhase = phases({
  applyFenced: () => {
    prematureEffectCalls += 1;
    return { applied: true };
  },
});
const prematureEffect = run({
  dir: `${tmp}/premature-effect`, artifacts: prematureEffectArtifacts,
  phase: prematureEffectPhase,
  adapters: exactAdapters(prematureEffectPhase, {
    resourceNow: () => "2026-07-25T23:59:59Z",
  }),
});
assert.equal(prematureEffect.reason, "recovered-disarmed");
assert.equal(prematureEffectCalls, 0,
  "the effect resource rejects a fence before activation even without a successor");
const expiredRecoveryArtifacts = bundle();
let recoveryResourceNow = null;
const expiredRecoveryCapability = recovery(expiredRecoveryArtifacts, {
  resourceNow: () => recoveryResourceNow,
});
const recoveredWithSuccessor = run({
  dir: `${tmp}/expired-recovery`, artifacts: expiredRecoveryArtifacts,
  phase: phases({ applyFenced: () => { throw Error("force-recovery"); } }),
  recover: expiredRecoveryCapability, autoResume: false,
});
assert.equal(recoveredWithSuccessor.reason, "recovered-disarmed",
  "forward recovery transfers to a fresh successor fence before host actuation");
const expiredRecoveryOutbox = bounded(
  `${tmp}/expired-recovery/${binding().idempotency_key}.json.recovery-outbox.json`,
);
assert.equal(expiredRecoveryOutbox.authorized_recovery_fence_digests.length, 2);
assert.equal(
  expiredRecoveryOutbox.recovery_result.effect_lease_fence_digest,
  expiredRecoveryOutbox.recovery_request.lease_fence_digest,
  "the terminal receipt preserves the original effect-lease identity",
);
assert.notEqual(
  expiredRecoveryOutbox.recovery_result.effect_lease_fence_digest,
  expiredRecoveryOutbox.recovery_result.revalidated_lease_fence_digest,
  "the successor revalidation fence remains a distinct durable authority",
);
const callerMintedHost = {
  persistActivation: () => { throw Error("caller host must never run"); },
  runFixedAdapter: () => { throw Error("caller adapter must never run"); },
};
const publicBoundary = run({
  dir: `${tmp}/public-boundary`, artifacts: bundle(),
  phase: phases({ applyFenced: () => { throw Error("force-recovery"); } }),
  autoResume: false,
  publicOptions: { host: callerMintedHost, recoveryHostFactory: () => callerMintedHost },
});
assert.equal(publicBoundary.reason, "recovered-disarmed",
  "public look-alikes and factories cannot replace the fixed recovery host");
const shortWatchArtifacts = bundle();
const shortWatch = run({
  dir: `${tmp}/short-watch`, artifacts: shortWatchArtifacts,
  admit: admission([
    "2026-07-26T00:00:00Z", "2026-07-26T00:00:01Z",
    "2026-07-26T00:00:02Z", "2026-07-26T00:00:03Z",
    "2026-07-26T00:00:04Z", "2026-07-26T00:00:05Z",
    "2026-07-26T00:09:59Z", "2026-07-26T00:10:00Z",
  ]),
});
assert.equal(shortWatch.reason, "watching",
  "an early continuation stays nonterminal instead of recovering healthy work");
assert.equal(shortWatch.journal.entries.at(-1).phase, "watch");
const longWatchArtifacts = bundle();
const longWatchBinding = binding(
  "long-watch", longWatchArtifacts.coverage,
);
const longWatchAdapters = exactAdapters();
const longWatchRecovery = recovery(longWatchArtifacts);
const longWatchInitial = run({
  dir: `${tmp}/long-watch`, artifacts: longWatchArtifacts,
  bind: longWatchBinding,
  admit: admission([
    "2026-07-26T00:00:00Z", "2026-07-26T00:00:01Z",
    "2026-07-26T00:00:02Z", "2026-07-26T00:00:03Z",
    "2026-07-26T00:00:04Z", "2026-07-26T00:00:05Z",
  ]),
  recover: longWatchRecovery, adapters: longWatchAdapters,
  autoResume: false,
});
assert.equal(longWatchInitial.reason, "watching");
const longWatchStateAfterInitial = bounded(
  `${tmp}/long-watch/.autonomy-state/domain-state.json`,
);
const longWatchTargetKey = Object.keys(
  longWatchStateAfterInitial.targets,
)[0];
assert.equal(
  longWatchStateAfterInitial.targets[longWatchTargetKey].lease_epoch, 1,
);
const overlapAdmission = admission([
  "2026-07-26T00:16:00Z", "2026-07-26T00:16:01Z",
  "2026-07-26T00:16:02Z", "2026-07-26T00:16:03Z",
]);
overlapAdmission.liveness = () => ({
  healthy: true, observed_at: "2026-07-26T00:15:59Z",
});
const longWatchOverlap = run({
  dir: `${tmp}/long-watch`, artifacts: longWatchArtifacts,
  bind: longWatchBinding, admit: overlapAdmission,
  recover: longWatchRecovery, adapters: longWatchAdapters,
  autoResume: false,
});
assert.equal(longWatchOverlap.reason, "watching",
  "an invocation after the 900-second lease but before watch completion does not recover");
assert.equal(longWatchOverlap.journal.entries.at(-1).phase, "watch");
assert.equal(longWatchArtifacts.runtimeNarrowing.entries.length, 0);
const longWatchStateAfterOverlap = bounded(
  `${tmp}/long-watch/.autonomy-state/domain-state.json`,
);
assert.equal(
  longWatchStateAfterOverlap.targets[longWatchTargetKey].lease_epoch, 2,
  "a watch continuation acquires a fresh monotonically advanced fence",
);
assert.equal(
  longWatchStateAfterOverlap.targets[longWatchTargetKey].execution_lease,
  null,
  "the persisted watch releases its short execution lease",
);
const dueAdmission = admission([
  "2026-07-26T01:00:05Z", "2026-07-26T01:00:06Z",
  "2026-07-26T01:00:07Z", "2026-07-26T01:00:08Z",
  "2026-07-26T01:00:09Z",
]);
dueAdmission.liveness = () => ({
  healthy: true, observed_at: "2026-07-26T01:00:04Z",
});
const longWatchCommit = run({
  dir: `${tmp}/long-watch`, artifacts: longWatchArtifacts,
  bind: longWatchBinding, admit: dueAdmission,
  recover: longWatchRecovery, adapters: longWatchAdapters,
  autoResume: false,
});
assert.equal(longWatchCommit.reason, "committed");
const fullWatchArtifacts = bundle();
const fullWatchBinding = binding(
  "full-watch", fullWatchArtifacts.coverage, {
    deadline: "2026-07-26T01:10:00Z",
    canary: {
      scope_digest: execution.target_scope_digest, target_count: 1,
    },
  },
);
const fullWatchAdapters = exactAdapters();
const fullWatchRecovery = recovery(fullWatchArtifacts);
const watchAdmissionAt = (now, end = "2026-07-26T01:10:01Z") => {
  const result = admission([now]);
  result.liveness = () => ({ healthy: true, observed_at: now });
  result.maintenance = () => ({
    window: { start: "2026-07-26T00:00:00Z", end },
    target: { platform: "debian", non_pillar: true },
    plan: {
      classes: ["security", "bugfix"], reboot_policy: "never",
      source: "distro_repository", workload_hooks: "not_applicable",
    },
  });
  return result;
};
const delayedWatchArtifacts = bundle();
const delayedWatchBinding = binding(
  "delayed-watch", delayedWatchArtifacts.coverage,
);
const delayedWatchTimes = Array(12).fill("2026-07-26T00:00:00Z");
const delayedWatchRecovery = recovery(delayedWatchArtifacts, {
  fault: point => {
    if (point === "after-watch-journal-readback") {
      delayedWatchTimes.fill("2026-07-26T00:05:00Z");
    }
  },
});
const delayedWatchAdapters = exactAdapters();
let delayedWatchResult = run({
  dir: `${tmp}/delayed-watch`, artifacts: delayedWatchArtifacts,
  bind: delayedWatchBinding, admit: admission(delayedWatchTimes),
  recover: delayedWatchRecovery, adapters: delayedWatchAdapters,
  autoResume: false,
});
assert.equal(delayedWatchResult.reason, "watching");
const delayedWatchEntry = delayedWatchResult.journal.entries.find(
  entry => entry.phase === "watch",
);
const delayedWatchAnchorFile =
  `${tmp}/delayed-watch/${delayedWatchBinding.idempotency_key}` +
  ".json.watch-anchor.json";
const delayedWatchAnchor = bounded(delayedWatchAnchorFile);
assert.equal(delayedWatchEntry.recorded_at, "2026-07-26T00:00:00Z",
  "the injected durable-write delay occurs after the journal timestamp");
assert.equal(delayedWatchAnchor.anchored_at, "2026-07-26T00:05:00Z",
  "the authoritative watch clock starts only after durable journal readback");
const overBudgetWatchArtifacts = bundle();
const overBudgetWatchTimes = Array(12).fill("2026-07-26T00:00:00Z");
const overBudgetWatchResult = run({
  dir: `${tmp}/over-budget-watch`, artifacts: overBudgetWatchArtifacts,
  admit: admission(overBudgetWatchTimes),
  recover: recovery(overBudgetWatchArtifacts, {
    fault: point => {
      if (point === "after-watch-journal-readback") {
        overBudgetWatchTimes.fill("2026-07-26T00:05:01Z");
      }
    },
  }),
  autoResume: false,
});
assert.equal(overBudgetWatchResult.journal.entries.at(-1).phase, "disarm",
  "a post-durability anchor 301 seconds after prepare fails closed");
assert.equal(overBudgetWatchResult.journal.entries.find(
  entry => entry.phase === "unknown",
).terminal_reason_digest, autonomyDigest({
  code: "maintenance_apply_verify_budget_exceeded",
}), "the 300-second prepare-to-anchor budget is enforced on the runtime path");
delayedWatchResult = run({
  dir: `${tmp}/delayed-watch`, artifacts: delayedWatchArtifacts,
  bind: delayedWatchBinding,
  admit: watchAdmissionAt("2026-07-26T01:04:59Z"),
  recover: delayedWatchRecovery, adapters: delayedWatchAdapters,
  autoResume: false,
});
assert.equal(delayedWatchResult.reason, "watching",
  "pre-durability time does not count toward the 3600-second watch");
assert.deepEqual(bounded(delayedWatchAnchorFile), delayedWatchAnchor,
  "watch continuation preserves the exact durable anchor");
delayedWatchResult = run({
  dir: `${tmp}/delayed-watch`, artifacts: delayedWatchArtifacts,
  bind: delayedWatchBinding,
  admit: watchAdmissionAt("2026-07-26T01:05:00Z"),
  recover: delayedWatchRecovery, adapters: delayedWatchAdapters,
  autoResume: false,
});
assert.equal(delayedWatchResult.reason, "committed",
  "commit becomes eligible exactly 3600 seconds after the durable anchor");
let fullWatchResult = run({
  dir: `${tmp}/full-watch`, artifacts: fullWatchArtifacts,
  bind: fullWatchBinding, admit: watchAdmissionAt("2026-07-26T00:00:00Z"),
  recover: fullWatchRecovery, adapters: fullWatchAdapters, autoResume: false,
});
assert.equal(fullWatchResult.reason, "watching");
for (const now of [
  "2026-07-26T00:16:00Z", "2026-07-26T00:32:00Z",
  "2026-07-26T00:48:00Z",
]) {
  fullWatchResult = run({
    dir: `${tmp}/full-watch`, artifacts: fullWatchArtifacts,
    bind: fullWatchBinding, admit: watchAdmissionAt(now),
    recover: fullWatchRecovery, adapters: fullWatchAdapters, autoResume: false,
  });
  assert.equal(fullWatchResult.reason, "watching", now);
}
fullWatchResult = run({
  dir: `${tmp}/full-watch`, artifacts: fullWatchArtifacts,
  bind: fullWatchBinding, admit: watchAdmissionAt("2026-07-26T01:00:00Z"),
  recover: fullWatchRecovery, adapters: fullWatchAdapters, autoResume: false,
});
assert.equal(fullWatchResult.reason, "committed",
  "the exact 3600-second post-receipt watch survives repeated lease release/reacquisition");
const fullWatchState = bounded(
  `${tmp}/full-watch/.autonomy-state/domain-state.json`,
);
assert.equal(
  fullWatchState.targets[fullWatchBinding.target_scope_digest.slice(7)]
    .lease_epoch,
  5, "the full watch advances one monotonic epoch per restart",
);
const killedWatchArtifacts = bundle();
const killedWatchRecovery = recovery(killedWatchArtifacts);
const killedWatchAdapters = exactAdapters();
const killedWatchInitial = run({
  dir: `${tmp}/killed-watch`, artifacts: killedWatchArtifacts,
  admit: admission(), recover: killedWatchRecovery,
  adapters: killedWatchAdapters, autoResume: false,
});
assert.equal(killedWatchInitial.reason, "watching");
const killedWatchContinuation = run({
  dir: `${tmp}/killed-watch`, artifacts: killedWatchArtifacts,
  admit: admission([
    "2026-07-26T00:10:01Z", "2026-07-26T00:10:02Z",
    "2026-07-26T00:10:03Z", "2026-07-26T00:10:04Z",
  ], () => false),
  recover: killedWatchRecovery, adapters: killedWatchAdapters,
  autoResume: false,
});
assert.equal(killedWatchContinuation.reason, "recovered-disarmed",
  "a killed continuation recovers instead of waiting or committing");
const unsafeReadbackArtifacts = bundle();
const unsafeReadback = run({
  dir: `${tmp}/unsafe-readback`, artifacts: unsafeReadbackArtifacts,
  phase: phases({ safeStateReadback: () => ({ safe: false, postconditions_digest: "sha256:" + "f".repeat(64) }) }),
});
assert.equal(unsafeReadback.reason, "recovered-disarmed", "maintenance-safe-state readback gates commit");

const deadlineAdmission = admission(["2026-07-26T01:10:00Z"]);
deadlineAdmission.liveness = () => ({ healthy: true, observed_at: "2026-07-26T01:09:59Z" });
deadlineAdmission.maintenance = () => ({
  window: { start: "2026-07-26T00:00:00Z", end: "2026-07-26T01:10:01Z" },
  target: { platform: "debian", non_pillar: true },
  plan: { classes: ["security"], reboot_policy: "never", source: "distro_repository", workload_hooks: "not_applicable" },
});
assert.throws(() => run({ dir: `${tmp}/deadline`, admit: deadlineAdmission }), /attempt_deadline_closed/);
assert.throws(() => run({
  dir: `${tmp}/backdate`, admit: admission(["2026-07-26T00:00:00Z", "2026-07-25T23:59:59Z"]),
}), /trusted_clock_backdated/);

const crashDir = `${tmp}/crash`;
const runWorker = (env, timeoutMs = 15_000) => new Promise((resolve, reject) => {
  const child = spawn(process.execPath, [...process.execArgv, process.argv[1]], {
    env: { ...process.env, ...env },
  });
  let settled = false;
  const finish = callback => value => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    callback(value);
  };
  const timer = setTimeout(() => {
    if (!settled) child.kill("SIGKILL");
    finish(reject)(new Error(`worker timeout: ${JSON.stringify(env)}`));
  }, timeoutMs);
  child.on("error", finish(reject));
  child.on("exit", finish(resolve));
});
const productionProbeIdentity = (() => {
  const previousProbe = globalThis.__BROKKR_TEST_LOCK_OWNER_PROBE__;
  globalThis.__BROKKR_TEST_LOCK_OWNER_PROBE__ = {
    currentBootId: () => ({
      value: "probe-boot-id",
      authoritative: true,
    }),
    processStartTime: () => ({
      value: "probe-process-start",
      authoritative: true,
    }),
  };
  try {
    return withEnv("BROKKR_ENABLE_TEST_LOCK_OWNER_PROBE", undefined, () =>
      currentLockOwnerIdentity());
  } finally {
    if (previousProbe === undefined) {
      delete globalThis.__BROKKR_TEST_LOCK_OWNER_PROBE__;
    } else {
      globalThis.__BROKKR_TEST_LOCK_OWNER_PROBE__ = previousProbe;
    }
  }
})();
assert.notEqual(productionProbeIdentity.boot_id, "probe-boot-id",
  "production owner identity ignores injected test probes without the explicit env gate");
assert.notEqual(productionProbeIdentity.process_start_time, "probe-process-start",
  "production owner identity ignores injected process-start probes without the explicit env gate");
for (const bootIdErrorCode of ["ENOTDIR", "EACCES", "EPERM"]) {
  const freshAutonomyModule = await importFreshAutonomyModuleWithBootIdFailure(bootIdErrorCode);
  const fallbackBootOwner = freshAutonomyModule.__BROKKR_TEST_ONLY__currentLockOwnerIdentity();
  assert.equal(fallbackBootOwner.boot_id_authoritative, false,
    `${bootIdErrorCode}: boot-id probe falls back non-authoritatively`);
  assert.equal(typeof fallbackBootOwner.boot_id, "string",
    `${bootIdErrorCode}: boot-id fallback remains populated`);
  assert.equal(fallbackBootOwner.boot_id.length >= 1, true,
    `${bootIdErrorCode}: boot-id fallback stays non-empty`);
}
const fallbackContentionDir = `${tmp}/fallback-contention.lock`;
const fallbackContentionTickets = `${fallbackContentionDir}.tickets`;
const fallbackContentionReady = `${tmp}/fallback-contention.ready`;
const fallbackContentionRelease = `${tmp}/fallback-contention.release`;
const fallbackHolder = runWorker({
  WORKER_MODE: "lock-hold",
  LOCK_DIR: fallbackContentionDir,
  OP_READY: fallbackContentionReady,
  OP_RELEASE: fallbackContentionRelease,
  CHILD_HOLD_TIMEOUT_MS: "5000",
  ...fallbackOwnerProbeEnv({
    bootId: "boot-estimate:holder-a",
    selfProcessStart: "time-origin:holder-a",
  }),
});
waitForFile(fallbackContentionReady);
assert.equal(await runWorker({
  WORKER_MODE: "lock-probe-status",
  LOCK_DIR: fallbackContentionDir,
  CHILD_HOLD_TIMEOUT_MS: "5000",
  ...fallbackOwnerProbeEnv({
    bootId: "boot-estimate:holder-b",
    selfProcessStart: "time-origin:holder-b",
  }),
}), 73,
  "fallback boot/process estimates stay fail-closed across processes while the holder is live");
assert.deepEqual(
  lockTicketArtifacts(fallbackContentionTickets).filter(name => /^\d+\.json$/.test(name)),
  ["00000001.json"],
  "an ambiguous live fallback tail does not grow a successor ticket",
);
fs.writeFileSync(fallbackContentionRelease, "");
assert.equal(await fallbackHolder, 0);
assert.equal(await runWorker({
  WORKER_MODE: "lock-probe",
  LOCK_DIR: fallbackContentionDir,
  ...fallbackOwnerProbeEnv({
    bootId: "boot-estimate:holder-c",
    selfProcessStart: "time-origin:holder-c",
  }),
}), 0,
  "the fallback-path holder still releases cleanly once the live owner exits");
const reclaimAfterCrashDir = `${tmp}/lock-reclaim-after-crash.lock`;
const reclaimAfterCrashTickets = `${reclaimAfterCrashDir}.tickets`;
assert.equal(await runWorker({
  WORKER_MODE: "lock-probe",
  LOCK_DIR: reclaimAfterCrashDir,
  FAULT_POINT: "after-lock-owner-operation",
}), 78, "the synthetic crash lands after publishing the owner ticket");
assert.deepEqual(
  lockTicketArtifacts(reclaimAfterCrashTickets).filter(name => /^\d+\.json$/.test(name)),
  ["00000001.json"],
  "the crash leaves exactly one unresolved owner ticket",
);
assert.equal(await runWorker({
  WORKER_MODE: "lock-probe",
  LOCK_DIR: reclaimAfterCrashDir,
}), 0, "restart can reclaim a single provably dead crashed ticket");
assert.deepEqual(
  lockTicketArtifacts(reclaimAfterCrashTickets).filter(name => /^(\d+)\.(done|json)$/.test(name)),
  ["00000001.done", "00000001.json", "00000002.done", "00000002.json"],
  "restart retires the dead ticket and advances with a fresh sequence",
);
const reclaimerRaceDir = `${tmp}/lock-reclaimer-race.lock`;
const reclaimerRaceTickets = `${reclaimerRaceDir}.tickets`;
writeLockTicketRecord(reclaimerRaceTickets, {
  sequence: 1,
  pid: 999999,
  boot_id: "11111111-1111-1111-1111-111111111111",
  boot_id_authoritative: true,
  process_start_time: "linux-start:111",
  process_start_time_authoritative: true,
  token: "dead-race-owner",
});
const reclaimerRaceReady = `${tmp}/lock-reclaimer-race.ready`;
const reclaimerRaceRelease = `${tmp}/lock-reclaimer-race.release`;
const reclaimerRaceHeld = `${tmp}/lock-reclaimer-race-held`;
const reclaimerRaceDone = `${tmp}/lock-reclaimer-race.done`;
const delayedReclaimer = runWorker({
  WORKER_MODE: "lock-probe-status",
  LOCK_DIR: reclaimerRaceDir,
  HOLD_POINT: "before-lock-ticket-retire-claim",
  HOLD_READY: reclaimerRaceReady,
  HOLD_RELEASE: reclaimerRaceRelease,
  CHILD_HOLD_TIMEOUT_MS: "5000",
});
waitForFile(reclaimerRaceReady);
const liveSuccessor = runWorker({
  WORKER_MODE: "lock-hold",
  LOCK_DIR: reclaimerRaceDir,
  OP_READY: reclaimerRaceHeld,
  OP_RELEASE: reclaimerRaceDone,
  CHILD_HOLD_TIMEOUT_MS: "5000",
});
waitForFile(reclaimerRaceHeld);
assert.deepEqual(
  lockTicketArtifacts(reclaimerRaceTickets).filter(name => /^(\d+)\.(done|json)$/.test(name)),
  ["00000001.done", "00000001.json", "00000002.json"],
  "the first live successor publishes a fresh sequence after retiring the dead ticket",
);
fs.writeFileSync(reclaimerRaceRelease, "");
assert.equal(await delayedReclaimer, 73,
  "a delayed second reclaimer cannot retire or replace the fresh live successor");
assert.deepEqual(lockTicketSequences(reclaimerRaceTickets), [2],
  "the stale reclaimer leaves the fresh successor sequence intact");
assert.equal(fs.existsSync(`${reclaimerRaceTickets}/00000002.json`), true,
  "the stale reclaimer does not delete the fresh successor path");
fs.writeFileSync(reclaimerRaceDone, "");
assert.equal(await liveSuccessor, 0);
const conflictingRetirementDir = `${tmp}/lock-retirement-conflicting-done.lock`;
const conflictingRetirementTickets = `${conflictingRetirementDir}.tickets`;
writeLockTicketRecord(conflictingRetirementTickets, {
  sequence: 1,
  pid: 999999,
  boot_id: "11111111-1111-1111-1111-111111111111",
  boot_id_authoritative: true,
  process_start_time: "linux-start:111",
  process_start_time_authoritative: true,
  token: "dead-conflicting-owner",
});
withLockTicketFaults(() => {
  let retireClaims = 0;
  globalThis.__BROKKR_TEST_LOCK_TICKET_FAULT__ = point => {
    if (point !== "before-lock-ticket-retire-claim") return;
    retireClaims += 1;
    if (retireClaims === 1) {
      writeRetiredLockTicket(conflictingRetirementTickets, {
        sequence: 1,
        token: "some-other-owner",
        reason: "owner-dead",
      });
      return;
    }
    throw Object.assign(new Error("unexpected-retirement-retry-loop"), {
      code: "unexpected_retirement_retry_loop",
    });
  };
  assert.throws(
    () => __BROKKR_TEST_ONLY__probeExclusiveDirectory(conflictingRetirementDir),
    /lock_completion_conflict/,
    "a conflicting completion at retirement EEXIST fails closed instead of retrying forever",
  );
});
const malformedRetirementDir = `${tmp}/lock-retirement-malformed-done.lock`;
const malformedRetirementTickets = `${malformedRetirementDir}.tickets`;
writeLockTicketRecord(malformedRetirementTickets, {
  sequence: 1,
  pid: 999998,
  boot_id: "11111111-1111-1111-1111-111111111111",
  boot_id_authoritative: true,
  process_start_time: "linux-start:112",
  process_start_time_authoritative: true,
  token: "dead-malformed-owner",
});
withLockTicketFaults(() => {
  let retireClaims = 0;
  globalThis.__BROKKR_TEST_LOCK_TICKET_FAULT__ = point => {
    if (point !== "before-lock-ticket-retire-claim") return;
    retireClaims += 1;
    if (retireClaims === 1) {
      fs.writeFileSync(`${malformedRetirementTickets}/00000001.done`, "{not-json}\n");
      return;
    }
    throw Object.assign(new Error("unexpected-retirement-retry-loop"), {
      code: "unexpected_retirement_retry_loop",
    });
  };
  assert.throws(
    () => __BROKKR_TEST_ONLY__probeExclusiveDirectory(malformedRetirementDir),
    /lock_completion_invalid/,
    "a malformed completion at retirement EEXIST fails closed instead of retrying forever",
  );
});
const staleLockDir = `${tmp}/stale-lock`, staleLockReady = `${tmp}/stale-lock-ready`;
const staleLockChild = spawn(process.execPath, [...process.execArgv, process.argv[1]], {
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
const directCompactionDir = `${tmp}/direct-lock-compaction.lock`;
const directCompactionTickets = `${directCompactionDir}.tickets`;
for (let sequence = 1;
  sequence < __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold;
  sequence += 1) {
  writeCompletedLockTicket(directCompactionTickets, sequence);
}
withLockTicketFaults(() => {
  globalThis.__BROKKR_TEST_LOCK_TICKET_FAULT__ = point => {
    if (point === "after-lock-release-visible-before-prune") {
      throw Object.assign(new Error("synthetic-lock-compaction-failure"), {
        code: "synthetic_lock_compaction_failure",
      });
    }
  };
  assert.equal(__BROKKR_TEST_ONLY__probeExclusiveDirectory(directCompactionDir), true,
    "post-release compaction faults do not mask the successful primary operation");
});
assert.equal(
  readHighestLockCheckpoint(directCompactionTickets).last_completed_sequence,
  __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold,
  "compaction durability survives best-effort prune failure after visible completion",
);
const directAmbiguousDir = `${tmp}/direct-lock-ambiguous.lock`;
const directAmbiguousTickets = `${directAmbiguousDir}.tickets`;
for (let sequence = 1;
  sequence < __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold;
  sequence += 1) {
  writeCompletedLockTicket(directAmbiguousTickets, sequence);
}
withLockTicketFaults(() => {
  globalThis.__BROKKR_TEST_LOCK_TICKET_FAULT__ = point => {
    if (point === "after-lock-checkpoint-fsync") {
      throw Object.assign(new Error("synthetic-lock-checkpoint-fsync"), {
        code: "synthetic_lock_checkpoint_fsync",
      });
    }
  };
  assert.throws(
    () => __BROKKR_TEST_ONLY__probeExclusiveDirectory(directAmbiguousDir),
    /lock_completion_ambiguous/,
    "a successful operation is not reported as safely retryable when checkpoint completion is ambiguous",
  );
});
assert.equal(lockTicketTemps(directAmbiguousTickets).length, 1,
  "an ambiguous checkpoint boundary leaves exactly one orphaned staging file");
const epermDir = `${tmp}/lock-liveness-eperm.lock`;
const epermTickets = `${epermDir}.tickets`;
fs.mkdirSync(epermTickets, { recursive: true, mode: 0o700 });
const epermOwner = currentLockOwnerIdentity();
fs.writeFileSync(`${epermTickets}/00000001.json`, `${canonicalJson({
  kind: "brokkr-lock-ticket",
  schema_version: "v1",
  pid: 424242,
  boot_id: epermOwner.boot_id,
  process_start_time: epermOwner.process_start_time,
  token: "eperm-owner",
  sequence: 1,
})}\n`);
const originalKill = process.kill;
process.kill = ((pid, signal) => {
  if (pid === 424242 && signal === 0) {
    throw Object.assign(new Error("eperm-owner"), { code: "EPERM" });
  }
  return originalKill(pid, signal);
});
try {
  assert.throws(
    () => __BROKKR_TEST_ONLY__probeExclusiveDirectory(epermDir),
    /lock_probe_contended/,
    "EPERM is treated as evidence that the recorded owner is still alive",
  );
} finally {
  process.kill = originalKill;
}
const reusedPidDir = `${tmp}/lock-liveness-reused-pid.lock`;
const reusedPidTickets = `${reusedPidDir}.tickets`;
const reusedPidBootId = "22222222-2222-2222-2222-222222222222";
const reusedPidOldStart = "linux-start:222";
const reusedPidNewStart = "linux-start:333";
writeLockTicketRecord(reusedPidTickets, {
  sequence: 1,
  pid: 424243,
  boot_id: reusedPidBootId,
  boot_id_authoritative: true,
  process_start_time: reusedPidOldStart,
  process_start_time_authoritative: true,
  token: "reused-owner",
});
process.kill = ((pid, signal) => {
  if (pid === 424243 && signal === 0) {
    throw Object.assign(new Error("eperm-reused-owner"), { code: "EPERM" });
  }
  return originalKill(pid, signal);
});
try {
  withLockOwnerProbe({
    currentBootId: () => ({
      value: reusedPidBootId,
      authoritative: true,
    }),
    processStartTime: pid => (
      pid === 424243 ? {
        value: reusedPidNewStart,
        authoritative: true,
      } : {
        value: "linux-start:444",
        authoritative: true,
      }
    ),
  }, () => {
    assert.equal(__BROKKR_TEST_ONLY__probeExclusiveDirectory(reusedPidDir), true,
      "EPERM does not pin a stale owner when the process start identity changed");
  });
} finally {
  process.kill = originalKill;
}
const malformedBootIdDir = `${tmp}/lock-liveness-malformed-boot-id.lock`;
const malformedBootIdTickets = `${malformedBootIdDir}.tickets`;
writeLockTicketRecord(malformedBootIdTickets, {
  sequence: 1,
  pid: 424246,
  boot_id: "not-a-linux-boot-id",
  boot_id_authoritative: true,
  process_start_time: "linux-start:500",
  process_start_time_authoritative: true,
  token: "malformed-boot-id-owner",
});
process.kill = ((pid, signal) => {
  if (pid === 424246 && signal === 0) {
    throw Object.assign(new Error("eperm-malformed-boot-id"), { code: "EPERM" });
  }
  return originalKill(pid, signal);
});
try {
  withLockOwnerProbe({
    currentBootId: () => ({
      value: reusedPidBootId,
      authoritative: true,
    }),
    processStartTime: pid => (
      pid === 424246 ? {
        value: "linux-start:500",
        authoritative: true,
      } : {
        value: "linux-start:444",
        authoritative: true,
      }
    ),
  }, () => {
    assert.throws(
      () => __BROKKR_TEST_ONLY__probeExclusiveDirectory(malformedBootIdDir),
      /lock_probe_contended/,
      "a malformed authoritative boot ID stays ambiguous and fail-closed while the owner is live",
    );
  });
} finally {
  process.kill = originalKill;
}
const malformedProcessStartDir = `${tmp}/lock-liveness-malformed-process-start.lock`;
const malformedProcessStartTickets = `${malformedProcessStartDir}.tickets`;
writeLockTicketRecord(malformedProcessStartTickets, {
  sequence: 1,
  pid: 424247,
  boot_id: reusedPidBootId,
  boot_id_authoritative: true,
  process_start_time: "linux-start:not-a-positive-integer",
  process_start_time_authoritative: true,
  token: "malformed-process-start-owner",
});
process.kill = ((pid, signal) => {
  if (pid === 424247 && signal === 0) {
    throw Object.assign(new Error("eperm-malformed-process-start"), { code: "EPERM" });
  }
  return originalKill(pid, signal);
});
try {
  withLockOwnerProbe({
    currentBootId: () => ({
      value: reusedPidBootId,
      authoritative: true,
    }),
    processStartTime: pid => (
      pid === 424247 ? {
        value: "linux-start:600",
        authoritative: true,
      } : {
        value: "linux-start:444",
        authoritative: true,
      }
    ),
  }, () => {
    assert.throws(
      () => __BROKKR_TEST_ONLY__probeExclusiveDirectory(malformedProcessStartDir),
      /lock_probe_contended/,
      "a malformed authoritative process-start stamp stays ambiguous and fail-closed while the owner is live",
    );
  });
} finally {
  process.kill = originalKill;
}
const legacyReusedPidDir = `${tmp}/lock-liveness-legacy-reused-pid.lock`;
const legacyReusedPidTickets = `${legacyReusedPidDir}.tickets`;
fs.mkdirSync(legacyReusedPidTickets, { recursive: true, mode: 0o700 });
const legacyReusedPidTicket = `${legacyReusedPidTickets}/00000001.json`;
fs.writeFileSync(legacyReusedPidTicket, `${canonicalJson({
  kind: "brokkr-lock-ticket",
  schema_version: "v1",
  pid: 424244,
  token: "legacy-reused-owner",
  sequence: 1,
})}\n`);
process.kill = ((pid, signal) => {
  if (pid === 424244 && signal === 0) {
    throw Object.assign(new Error("eperm-legacy-reused-owner"), { code: "EPERM" });
  }
  return originalKill(pid, signal);
});
try {
  withLockOwnerProbe({
    processStartedAfterLegacyTicket: (pid, ticketMtimeMs) => {
      assert.equal(pid, 424244);
      assert.equal(Number.isFinite(ticketMtimeMs), true);
      return true;
    },
  }, () => {
    assert.throws(
      () => __BROKKR_TEST_ONLY__probeExclusiveDirectory(legacyReusedPidDir),
      /lock_probe_contended/,
      "a legacy five-field ticket remains fail-closed even when PID reuse looks newer",
    );
  });
} finally {
  process.kill = originalKill;
}
writeRetiredLockTicket(legacyReusedPidTickets, {
  sequence: 1,
  token: "legacy-reused-owner",
  reason: "legacy-owner-identity-ambiguous",
});
assert.equal(__BROKKR_TEST_ONLY__probeExclusiveDirectory(legacyReusedPidDir), true,
  "an operator can non-destructively retire an ambiguous legacy ticket");
assert.deepEqual(
  lockTicketArtifacts(legacyReusedPidTickets).filter(name => /^(\d+)\.(done|json)$/.test(name)),
  [
    "00000001.done",
    "00000001.json",
    "00000002.done",
    "00000002.json",
  ],
  "manual retirement advances above the legacy ticket without deleting it",
);
const legacyAmbiguousPidDir = `${tmp}/lock-liveness-legacy-ambiguous-pid.lock`;
const legacyAmbiguousPidTickets = `${legacyAmbiguousPidDir}.tickets`;
fs.mkdirSync(legacyAmbiguousPidTickets, { recursive: true, mode: 0o700 });
fs.writeFileSync(`${legacyAmbiguousPidTickets}/00000001.json`, `${canonicalJson({
  kind: "brokkr-lock-ticket",
  schema_version: "v1",
  pid: 424245,
  token: "legacy-ambiguous-owner",
  sequence: 1,
})}\n`);
process.kill = ((pid, signal) => {
  if (pid === 424245 && signal === 0) {
    throw Object.assign(new Error("eperm-legacy-ambiguous-owner"), { code: "EPERM" });
  }
  return originalKill(pid, signal);
});
try {
  withLockOwnerProbe({
    processStartedAfterLegacyTicket: () => false,
  }, () => {
    assert.throws(
      () => __BROKKR_TEST_ONLY__probeExclusiveDirectory(legacyAmbiguousPidDir),
      /lock_probe_contended/,
      "a legacy ticket remains fail-closed when PID reuse cannot be proven",
    );
  });
} finally {
  process.kill = originalKill;
}
const invalidPidDir = `${tmp}/lock-invalid-pid.lock`;
const invalidPidTickets = `${invalidPidDir}.tickets`;
fs.mkdirSync(invalidPidTickets, { recursive: true, mode: 0o700 });
fs.writeFileSync(`${invalidPidTickets}/00000001.json`, `${canonicalJson({
  kind: "brokkr-lock-ticket",
  schema_version: "v1",
  pid: 0,
  boot_id: reusedPidBootId,
  process_start_time: reusedPidOldStart,
  token: "invalid-pid",
  sequence: 1,
})}\n`);
assert.throws(
  () => __BROKKR_TEST_ONLY__probeExclusiveDirectory(invalidPidDir),
  /lock_owner_invalid/,
  "non-positive owner PIDs are rejected",
);
const strayNamesDir = `${tmp}/lock-stray-names.lock`;
const strayNamesTickets = `${strayNamesDir}.tickets`;
fs.mkdirSync(strayNamesTickets, { recursive: true, mode: 0o700 });
fs.writeFileSync(`${strayNamesTickets}/nonsense.tmp`, "{}\n");
fs.writeFileSync(`${strayNamesTickets}/checkpoint.bad.tmp`, "{}\n");
fs.writeFileSync(`${strayNamesTickets}/00000000.json`, "{}\n");
assert.equal(__BROKKR_TEST_ONLY__probeExclusiveDirectory(strayNamesDir), true,
  "stray temp and invalid ticket names do not wedge acquisition");
assert.deepEqual(lockTicketTemps(strayNamesTickets), [],
  "stray temp names are reclaimed on the next acquisition");
assert.equal(fs.existsSync(`${strayNamesTickets}/00000000.json`), false,
  "non-positive stray ticket artifacts are reclaimed when acquisition succeeds");
const delayedCompactorDir = `${tmp}/delayed-compactor.lock`;
const delayedCompactorTickets = `${delayedCompactorDir}.tickets`;
for (let sequence = 1;
  sequence < __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold;
  sequence += 1) {
  writeCompletedLockTicket(delayedCompactorTickets, sequence);
}
const delayedCompactorReady = `${tmp}/delayed-compactor.ready`;
const delayedCompactorRelease = `${tmp}/delayed-compactor.release`;
const delayedCompactor = runWorker({
  WORKER_MODE: "lock-probe",
  LOCK_DIR: delayedCompactorDir,
  HOLD_POINT: "after-lock-release-visible-before-prune",
  HOLD_READY: delayedCompactorReady,
  HOLD_RELEASE: delayedCompactorRelease,
});
waitForFile(delayedCompactorReady);
assert.equal(await runWorker({
  WORKER_MODE: "lock-probe",
  LOCK_DIR: delayedCompactorDir,
}), 0, "a successor can enter after the visible release boundary");
fs.writeFileSync(delayedCompactorRelease, "");
assert.equal(await delayedCompactor, 0);
assert.equal(await runWorker({
  WORKER_MODE: "lock-probe",
  LOCK_DIR: delayedCompactorDir,
}), 0);
assert.equal(
  readHighestLockCheckpoint(delayedCompactorTickets).last_completed_sequence,
  __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold,
  "the delayed compactor leaves its monotonic completion checkpoint in place",
);
assert.deepEqual(
  lockTicketSequences(delayedCompactorTickets),
  [
    __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold + 1,
    __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold + 2,
  ],
  "a delayed compactor cannot regress the checkpoint or reuse a sequence",
);
const delayedAcquirerDir = `${tmp}/delayed-acquirer.lock`;
const delayedAcquirerTickets = `${delayedAcquirerDir}.tickets`;
for (let sequence = 1;
  sequence < __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold;
  sequence += 1) {
  writeCompletedLockTicket(delayedAcquirerTickets, sequence);
}
const delayedAcquirerReady = `${tmp}/delayed-acquirer.ready`;
const delayedAcquirerRelease = `${tmp}/delayed-acquirer.release`;
const delayedAcquirerHeld = `${tmp}/delayed-acquirer-held`;
const delayedAcquirerDone = `${tmp}/delayed-acquirer.done`;
const delayedAcquirer = runWorker({
  WORKER_MODE: "lock-hold",
  LOCK_DIR: delayedAcquirerDir,
  HOLD_POINT: "after-lock-ticket-fsync",
  HOLD_READY: delayedAcquirerReady,
  HOLD_RELEASE: delayedAcquirerRelease,
  OP_READY: delayedAcquirerHeld,
  OP_RELEASE: delayedAcquirerDone,
});
waitForFile(delayedAcquirerReady);
assert.equal(await runWorker({
  WORKER_MODE: "lock-probe",
  LOCK_DIR: delayedAcquirerDir,
}), 0, "a successor can compact the completed prefix while another acquirer is still delayed");
fs.writeFileSync(delayedAcquirerRelease, "");
waitForFile(delayedAcquirerHeld);
assert.equal(await runWorker({
  WORKER_MODE: "lock-probe-status",
  LOCK_DIR: delayedAcquirerDir,
}), 73, "a delayed acquirer retries above the advanced floor and still blocks concurrent entry");
fs.writeFileSync(delayedAcquirerDone, "");
assert.equal(await delayedAcquirer, 0);
assert.equal(
  readHighestLockCheckpoint(delayedAcquirerTickets).last_completed_sequence,
  __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold,
  "the delayed acquirer does not let a stale post-compaction ticket advance the floor",
);
assert.deepEqual(
  lockTicketSequences(delayedAcquirerTickets),
  [__BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold + 1],
  "the delayed acquirer retries with a visible sequence above the compacted floor",
);
const staleCheckpointSelectionDir = `${tmp}/stale-checkpoint-selection.lock`;
const staleCheckpointSelectionTickets = `${staleCheckpointSelectionDir}.tickets`;
fs.mkdirSync(staleCheckpointSelectionTickets, { recursive: true, mode: 0o700 });
fs.writeFileSync(`${staleCheckpointSelectionTickets}/checkpoint.00000003.json`, `${canonicalJson({
  kind: "brokkr-lock-ticket-checkpoint",
  schema_version: "v1",
  last_completed_sequence: 3,
  last_completed_token: "completed-00000003",
  next_sequence: 4,
})}\n`);
fs.writeFileSync(`${staleCheckpointSelectionTickets}/checkpoint.00000002.json`, `${canonicalJson({
  kind: "brokkr-lock-ticket-checkpoint",
  schema_version: "v1",
  last_completed_sequence: 2,
  last_completed_token: "completed-00000002",
  next_sequence: 3,
})}\n`);
assert.equal(__BROKKR_TEST_ONLY__probeExclusiveDirectory(staleCheckpointSelectionDir), true,
  "the highest immutable checkpoint selects the next sequence");
assert.equal(readHighestLockCheckpoint(staleCheckpointSelectionTickets).last_completed_sequence, 3);
assert.deepEqual(
  lockCheckpointArtifacts(staleCheckpointSelectionTickets),
  ["checkpoint.00000003.json"],
  "lower immutable checkpoints are pruned once a higher floor exists",
);
assert.deepEqual(lockTicketSequences(staleCheckpointSelectionTickets), [4]);
const pruneRaceDir = `${tmp}/lock-prune-race.lock`;
const pruneRaceTickets = `${pruneRaceDir}.tickets`;
fs.mkdirSync(pruneRaceTickets, { recursive: true, mode: 0o700 });
fs.writeFileSync(`${pruneRaceTickets}/checkpoint.json`, `${canonicalJson({
  kind: "brokkr-lock-ticket-checkpoint",
  schema_version: "v1",
  last_completed_sequence: 2,
  last_completed_token: "completed-00000002",
  next_sequence: 3,
})}\n`);
writeCompletedLockTicket(pruneRaceTickets, 1);
writeCompletedLockTicket(pruneRaceTickets, 2);
const pruneRaceReady = `${tmp}/lock-prune-race.ready`;
const pruneRaceRelease = `${tmp}/lock-prune-race.release`;
const pruneRace = runWorker({
  WORKER_MODE: "lock-probe",
  LOCK_DIR: pruneRaceDir,
  HOLD_POINT: "before-lock-prune-unlink",
  HOLD_READY: pruneRaceReady,
  HOLD_RELEASE: pruneRaceRelease,
});
waitForFile(pruneRaceReady);
for (const name of [
  "00000001.json", "00000001.done", "00000002.json", "00000002.done",
]) {
  fs.unlinkSync(`${pruneRaceTickets}/${name}`);
}
fs.writeFileSync(pruneRaceRelease, "");
assert.equal(await pruneRace, 0,
  "pruning tolerates ENOENT when another pruner wins the unlink race");
assert.deepEqual(lockTicketSequences(pruneRaceTickets), [3]);
const readRaceDir = `${tmp}/lock-read-race.lock`;
const readRaceTickets = `${readRaceDir}.tickets`;
fs.mkdirSync(readRaceTickets, { recursive: true, mode: 0o700 });
fs.writeFileSync(`${readRaceTickets}/checkpoint.json`, `${canonicalJson({
  kind: "brokkr-lock-ticket-checkpoint",
  schema_version: "v1",
  last_completed_sequence: 255,
  last_completed_token: "completed-00000255",
  next_sequence: 256,
})}\n`);
writeCompletedLockTicket(readRaceTickets, 256);
const readRaceReady = `${tmp}/lock-read-race.ready`;
const readRaceRelease = `${tmp}/lock-read-race.release`;
const readRace = runWorker({
  WORKER_MODE: "lock-probe",
  LOCK_DIR: readRaceDir,
  HOLD_POINT: "before-lock-ticket-read",
  HOLD_READY: readRaceReady,
  HOLD_RELEASE: readRaceRelease,
});
waitForFile(readRaceReady);
fs.writeFileSync(`${readRaceTickets}/checkpoint.00000256.json`, `${canonicalJson({
  kind: "brokkr-lock-ticket-checkpoint",
  schema_version: "v1",
  last_completed_sequence: 256,
  last_completed_token: "completed-00000256",
  next_sequence: 257,
})}\n`);
for (const name of lockTicketArtifacts(readRaceTickets)) {
  if (name === "checkpoint.json" || /^checkpoint\.\d+\.json$/.test(name)) continue;
  fs.unlinkSync(`${readRaceTickets}/${name}`);
}
fs.writeFileSync(readRaceRelease, "");
assert.equal(await readRace, 0,
  "bounded retry survives a prune-vs-read race on the latest completed ticket");
assert.equal(
  readHighestLockCheckpoint(readRaceTickets).last_completed_sequence,
  256,
);
assert.deepEqual(lockTicketSequences(readRaceTickets), [257]);
for (const faultPoint of [
  "after-lock-ticket-open",
  "after-lock-ticket-write",
  "after-lock-ticket-fsync",
]) {
  const faultDir = `${tmp}/${faultPoint}`;
  const faultTickets = `${faultDir}/.autonomy-state/domain-state.lock.tickets`;
  assert.equal(await runWorker({
    WORKER_MODE: "fault", WORKER_DIR: faultDir, FAULT_POINT: faultPoint,
  }), 78, `${faultPoint}: crash is injected before ticket publication`);
  assert.deepEqual(
    fs.existsSync(faultTickets) ?
      fs.readdirSync(faultTickets).filter(name => /^\d+\.json$/.test(name)) : [],
    [],
    `${faultPoint}: no torn final ticket is published before durability`,
  );
  assert.equal(run({ dir: faultDir }).reason, "committed",
    `${faultPoint}: restart recovers without delete races`);
}
for (const faultPoint of [
  "after-lock-owner-operation",
  "after-lock-completion-open",
  "after-lock-completion-write",
  "after-lock-completion-fsync",
]) {
  const faultDir = `${tmp}/${faultPoint}`;
  const faultTickets = `${faultDir}/.autonomy-state/domain-state.lock.tickets`;
  assert.equal(await runWorker({
    WORKER_MODE: "fault", WORKER_DIR: faultDir, FAULT_POINT: faultPoint,
  }), 78, `${faultPoint}: crash is injected before completion publication`);
  const latestTicket = fs.readdirSync(faultTickets)
    .filter(name => /^\d+\.json$/.test(name))
    .sort()
    .at(-1);
  assert.equal(typeof latestTicket, "string", `${faultPoint}: owner ticket is durable`);
  assert.equal(
    fs.existsSync(
      `${faultTickets}/${latestTicket.slice(0, latestTicket.length - ".json".length)}.done`,
    ),
    false,
    `${faultPoint}: no completion marker is published before durability`,
  );
  assert.equal(run({
    dir: faultDir,
    admit: takeoverAdmission(),
  }).reason, "recovered-disarmed",
    `${faultPoint}: a dead predecessor is recoverable without unlink races`);
}
for (const faultPoint of [
  "after-lock-ticket-link",
  "after-lock-checkpoint-open",
  "after-lock-checkpoint-write",
  "after-lock-checkpoint-fsync",
]) {
  const faultDir = `${tmp}/lock-probe-${faultPoint}`;
  const faultTickets = `${faultDir}.tickets`;
  for (let sequence = 1;
    sequence < __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold;
    sequence += 1) {
    writeCompletedLockTicket(faultTickets, sequence);
  }
  assert.equal(await runWorker({
    WORKER_MODE: "lock-probe",
    LOCK_DIR: faultDir,
    FAULT_POINT: faultPoint,
  }), 78, faultPoint);
  assert.equal(lockTicketTemps(faultTickets).length >= 1, true,
    `${faultPoint}: the crash boundary leaves a reclaimable staging file`);
  assert.equal(await runWorker({
    WORKER_MODE: "lock-probe",
    LOCK_DIR: faultDir,
  }), 0, `${faultPoint}: restart reclaims orphan staging and finishes`);
  assert.deepEqual(lockTicketTemps(faultTickets), [],
    `${faultPoint}: restart removes orphan staging files`);
  const recoveredLockCheckpoint = readHighestLockCheckpoint(faultTickets);
  assert.equal(
    recoveredLockCheckpoint !== null &&
      recoveredLockCheckpoint.last_completed_sequence >=
      __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.compaction_threshold - 1,
    true,
    `${faultPoint}: recovery leaves the highest safe durable checkpoint`,
  );
}
for (const faultPoint of ["after-lock-completion-link"]) {
  const faultDir = `${tmp}/lock-probe-${faultPoint}`;
  const faultTickets = `${faultDir}.tickets`;
  assert.equal(await runWorker({
    WORKER_MODE: "lock-probe",
    LOCK_DIR: faultDir,
    FAULT_POINT: faultPoint,
  }), 78, faultPoint);
  assert.equal(lockTicketTemps(faultTickets).length, 1,
    `${faultPoint}: the crash boundary leaves exactly one orphaned staging file`);
  assert.equal(await runWorker({
    WORKER_MODE: "lock-probe",
    LOCK_DIR: faultDir,
  }), 0, `${faultPoint}: restart cleans the orphaned completion staging file`);
  assert.deepEqual(lockTicketTemps(faultTickets), [],
    `${faultPoint}: restart removes the orphaned completion staging file`);
}
const repeatedTmpDir = `${tmp}/repeated-lock-tmp.lock`;
const repeatedTmpTickets = `${repeatedTmpDir}.tickets`;
for (let attempt = 1; attempt <= 8; attempt += 1) {
  assert.equal(await runWorker({
    WORKER_MODE: "lock-probe",
    LOCK_DIR: repeatedTmpDir,
    FAULT_POINT: "after-lock-ticket-write",
  }), 78, `repeated tmp crash ${attempt}`);
  assert.equal(lockTicketTemps(repeatedTmpTickets).length <= 1, true,
    "repeated fault injection stays bounded by reclaiming the prior orphan before the next attempt");
}
assert.equal(await runWorker({
  WORKER_MODE: "lock-probe",
  LOCK_DIR: repeatedTmpDir,
}), 0);
assert.deepEqual(lockTicketTemps(repeatedTmpTickets), [],
  "a subsequent successful run clears the last orphaned staging file");
assert.deepEqual(
  lockTicketArtifacts(repeatedTmpTickets).filter(
    name => /^(\d+)\.(done|json)$/.test(name),
  ),
  ["00000001.done", "00000001.json"],
  "repeated crash-only growth leaves an exact bounded final artifact set",
);
const dualFailureDir = `${tmp}/lock-dual-failure.lock`;
withLockTicketFaults(() => {
  globalThis.__BROKKR_TEST_LOCK_TICKET_FAULT__ = point => {
    if (point === "after-lock-owner-operation") {
      throw Object.assign(new Error("synthetic-release-failure"), {
        code: "synthetic_release_failure",
      });
    }
  };
  assert.throws(
    () => __BROKKR_TEST_ONLY__probeExclusiveDirectory(dualFailureDir, () => {
      throw Object.assign(new Error("synthetic-operation-failure"), {
        code: "synthetic_operation_failure",
      });
    }),
    error => error?.code === "synthetic_operation_failure" &&
      error.lock_release_error?.code === "lock_completion_ambiguous" &&
      error.lock_release_error.cause?.code === "synthetic_release_failure",
    "operation failures retain the release fault context when unlock also fails",
  );
});
const liveLimitDir = `${tmp}/lock-live-limit.lock`;
const liveLimitTickets = `${liveLimitDir}.tickets`;
for (let attempt = 1; attempt <= 8; attempt += 1) {
  assert.equal(await runWorker({
    WORKER_MODE: "lock-probe",
    LOCK_DIR: liveLimitDir,
    FAULT_POINT: "after-lock-ticket-link",
  }), 78, `post-link crash remains reproducible at attempt ${attempt}`);
  assert.equal(lockTicketSequences(liveLimitTickets).at(-1), attempt,
    "restart retires the prior dead tail before another post-link crash advances the sequence");
}
assert.equal(lockTicketTemps(liveLimitTickets).length, 1,
  "repeated post-link crashes leave exactly one reclaimable staging file");
assert.equal(await runWorker({
  WORKER_MODE: "lock-probe",
  LOCK_DIR: liveLimitDir,
}), 0, "a later successful run can recover after the retired dead-tail chain");
assert.deepEqual(lockTicketTemps(liveLimitTickets), [],
  "the successful post-link recovery clears the last staging orphan");
const liveLimitSequences = lockTicketSequences(liveLimitTickets);
assert.equal(liveLimitSequences.at(-1), 9,
  "repeated post-link crashes keep advancing to fresh sequences");
assert.equal(liveLimitSequences.length <= 2, true,
  "repeated post-link crashes stay bounded after prefix compaction prunes retired tickets");
const tmpCeilingDir = `${tmp}/lock-tmp-ceiling.lock`;
const tmpCeilingTickets = `${tmpCeilingDir}.tickets`;
fs.mkdirSync(tmpCeilingTickets, { recursive: true, mode: 0o700 });
for (let count = 0;
  count <= __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS.tmp_hard_limit;
  count += 1) {
  fs.writeFileSync(
    `${tmpCeilingTickets}/00000001.json.${process.pid}.${crypto.randomUUID()}.tmp`,
    "{}\n",
  );
}
assert.throws(
  () => __BROKKR_TEST_ONLY__probeExclusiveDirectory(tmpCeilingDir),
  /lock_ticket_tmp_limit/,
  "live staging growth above the hard ceiling fails closed",
);
const exhaustedLockDir = `${tmp}/bounded-lock-tickets`;
const exhaustedTickets =
  `${exhaustedLockDir}/.autonomy-state/domain-state.lock.tickets`;
for (let sequence = 1; sequence <= 10_000; sequence += 1) {
  writeCompletedLockTicket(exhaustedTickets, sequence);
}
assert.equal(run({ dir: exhaustedLockDir }).reason, "committed",
  "a completed 10,000-ticket prefix compacts instead of failing closed forever");
const compactedArtifacts = fs.readdirSync(exhaustedTickets)
  .filter(name =>
    name === "checkpoint.json" ||
    /^checkpoint\.\d+\.json$/.test(name) ||
    /^\d+\.(json|done)$/.test(name),
  );
assert.equal(compactedArtifacts.length <= 64, true,
  "lock-ticket compaction leaves bounded final artifacts after >10,000 acquisitions");
assert.equal(readHighestLockCheckpoint(exhaustedTickets) !== null, true,
  "bounded lock compaction records a durable checkpoint");
const checkpointCrashDir = `${tmp}/lock-checkpoint-rename`;
const checkpointCrashTickets =
  `${checkpointCrashDir}/.autonomy-state/domain-state.lock.tickets`;
for (let sequence = 1; sequence <= 10_000; sequence += 1) {
  writeCompletedLockTicket(checkpointCrashTickets, sequence);
}
assert.equal(await runWorker({
  WORKER_MODE: "fault",
  WORKER_DIR: checkpointCrashDir,
  FAULT_POINT: "after-lock-checkpoint-link",
}), 78, "checkpoint publication can crash after the exclusive link boundary");
assert.equal(
  lockCheckpointArtifacts(checkpointCrashTickets).length >= 1,
  true,
  "the checkpoint link boundary leaves a durable checkpoint artifact",
);
assert.equal(run({
  dir: checkpointCrashDir,
  admit: takeoverAdmission(),
}).reason, "recovered-disarmed",
  "checkpoint replay prunes the already-checkpointed prefix and proceeds");
assert.equal(
  lockTicketFinalArtifacts(checkpointCrashTickets).length <= 64,
  true,
  "checkpoint replay re-bounds storage after a crash between link and prune",
);

const sigkillDir = `${tmp}/controller-sigkill`;
const sigkillApplyLog = `${tmp}/controller-sigkill-apply.log`;
const sigkillErrorLog = `${tmp}/controller-sigkill-error.log`;
const sigkillRelease = `${tmp}/controller-sigkill-release`;
const sigkillReady = `${tmp}/controller-sigkill-ready`;
const sigkillStartedAtMs = Date.now();
const sigkillChild = spawn(
  process.execPath,
  [...process.execArgv, process.argv[1]],
  {
    env: {
      ...process.env,
      WORKER_MODE: "sigkill",
      WORKER_DIR: sigkillDir,
      APPLY_LOG: sigkillApplyLog,
      WORKER_ERROR_LOG: sigkillErrorLog,
      HOLD_AFTER_APPLY: sigkillRelease,
      HOLD_AFTER_APPLY_READY: sigkillReady,
    },
  },
);
const sigkillExit = new Promise(resolve =>
  sigkillChild.on("exit", (code, signal) => resolve({ code, signal })));
await new Promise((resolve, reject) => {
  const deadline = Date.now() + 10_000;
  const poll = setInterval(() => {
    if (fs.existsSync(sigkillReady)) {
      clearInterval(poll);
      sigkillChild.off("exit", onEarlyExit);
      resolve();
    } else if (Date.now() >= deadline) {
      clearInterval(poll);
      sigkillChild.off("exit", onEarlyExit);
      reject(new Error("SIGKILL worker readiness timed out after 10 seconds"));
    }
  }, 5);
  const onEarlyExit = (code, signal) => {
    clearInterval(poll);
    const detail = fs.existsSync(sigkillErrorLog) ?
      fs.readFileSync(sigkillErrorLog, "utf8").trim() : "no worker error receipt";
    reject(new Error(
      `SIGKILL worker exited before readiness: code=${code} signal=${signal} (${detail})`,
    ));
  };
  sigkillChild.once("exit", onEarlyExit);
});
sigkillChild.kill("SIGKILL");
assert.deepEqual(await sigkillExit, { code: null, signal: "SIGKILL" },
  "the supervised controller is actually killed with SIGKILL");
assert.equal(await runWorker({
  WORKER_MODE: "recover", WORKER_DIR: sigkillDir,
  RECOVERY_LOG: `${tmp}/controller-sigkill-recovery.log`,
}), 0);
assert.equal(
  bounded(`${sigkillDir}/${binding().idempotency_key}.json`)
    .entries.at(-1).phase,
  "disarm",
  "the exact durable recovery path disarms after controller SIGKILL",
);
const sigkillElapsedSeconds = Math.ceil(
  (Date.now() - sigkillStartedAtMs) / 1000,
);
assert.equal(sigkillElapsedSeconds <= 300, true,
  "SIGKILL recovery completes inside the declared recovery budget");
const sigkillApplyCount = fs.readFileSync(sigkillApplyLog, "utf8")
  .trim().split("\n").filter(Boolean).length;
assert.equal(sigkillApplyCount, 1,
  "recovery after SIGKILL cannot apply a new plan");

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
assert.equal(fs.existsSync(resumeApplyLog), false,
  "an ambiguous private executor journal prevents resumed re-actuation");
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
const staleWriterErrors = `${tmp}/stale-writer-errors.log`;
const staleWriter = runWorker({
  WORKER_MODE: "race", WORKER_DIR: staleWriterDir, APPLY_LOG: staleWriterLog,
  HOST_EFFECT_LOG: staleWriterHostEffects, HOLD_BEFORE_EFFECT: staleWriterRelease,
  WORKER_ERROR_LOG: staleWriterErrors,
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
assert.match(fs.readFileSync(staleWriterErrors, "utf8").trim(),
  /^(effect|execution)_lease_fenced$/,
  "the stale writer fails at or before the resource fence");
const staleWriterRecoveryStart = staleWriterJournal.entries.find(
  entry => entry.phase === "recover",
)?.recorded_at;
const staleWriterTerminalAt =
  staleWriterJournal.entries.at(-1).recorded_at;
assert.equal(typeof staleWriterRecoveryStart, "string");
const progressWedgeElapsedSeconds =
  (Date.parse(staleWriterTerminalAt) -
    Date.parse(staleWriterRecoveryStart)) / 1000;
assert.equal(Number.isSafeInteger(progressWedgeElapsedSeconds), true);
assert.equal(progressWedgeElapsedSeconds <= 300, true,
  "progress-loop wedge recovery completes inside its bound");
const staleWriterNewPlanMutations = fs.existsSync(staleWriterHostEffects) ?
  fs.readFileSync(staleWriterHostEffects, "utf8")
    .trim().split("\n").filter(Boolean).length : 0;
assert.equal(staleWriterNewPlanMutations, 0);

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

const staleRecoveryDir = `${tmp}/stale-recovery`;
const staleRecoveryCalls = `${tmp}/stale-recovery-calls.log`;
const staleRecoveryEffects = `${tmp}/stale-recovery-effects.log`;
const staleRecoveryRelease = `${tmp}/stale-recovery-release`;
const staleRecoveryErrors = `${tmp}/stale-recovery-errors.log`;
const staleRecovery = runWorker({
  WORKER_MODE: "fault", WORKER_DIR: staleRecoveryDir,
  FORCE_RECOVERY: "1", RECOVERY_CALL_LOG: staleRecoveryCalls,
  RECOVERY_LOG: staleRecoveryEffects,
  HOLD_BEFORE_RECOVERY_EFFECT: staleRecoveryRelease,
  WORKER_ERROR_LOG: staleRecoveryErrors,
});
while (!fs.existsSync(staleRecoveryCalls)) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
}
assert.equal(await runWorker({
  WORKER_MODE: "recover", WORKER_DIR: staleRecoveryDir,
  LATE_LEASE_TRANSFER: "1",
}), 79, "the successor advances the resource fence while the old outbox lock is live");
fs.writeFileSync(staleRecoveryRelease, "");
assert.equal(await staleRecovery, 79,
  "the old recovery writer is rejected after the resource fence advances");
assert.equal(fs.readFileSync(staleRecoveryErrors, "utf8").trim(),
  "recovery_lease_fenced",
  "the stale recovery writer fails for the expected resource fence");
assert.equal(await runWorker({
  WORKER_MODE: "recover", WORKER_DIR: staleRecoveryDir,
  VERY_LATE_LEASE_TRANSFER: "1", RECOVERY_CALL_LOG: staleRecoveryCalls,
  RECOVERY_LOG: staleRecoveryEffects,
}), 0);
assert.equal(
  fs.readFileSync(staleRecoveryEffects, "utf8").trim().split("\n").length,
  1, "only the current recovery fence can produce the recovery effect",
);
assert.equal(
  bounded(`${staleRecoveryDir}/${binding().idempotency_key}.json`)
    .entries.at(-1).phase,
  "disarm",
);
const recoveryCrashJournal = bounded(
  `${staleRecoveryDir}/${binding().idempotency_key}.json`,
);
const recoveryCrashStartedAt = recoveryCrashJournal.entries.find(
  entry => entry.phase === "recover",
)?.recorded_at;
const recoveryCrashTerminalAt =
  recoveryCrashJournal.entries.at(-1).recorded_at;
assert.equal(typeof recoveryCrashStartedAt, "string");
const recoveryCrashElapsedSeconds =
  (Date.parse(recoveryCrashTerminalAt) -
    Date.parse(recoveryCrashStartedAt)) / 1000;
assert.equal(Number.isSafeInteger(recoveryCrashElapsedSeconds), true);
assert.equal(recoveryCrashElapsedSeconds <= 300, true,
  "recovery crash-loop exhaustion completes inside its bound");
const recoveryCrashNewPlanMutations = recoveryCrashJournal.entries.filter(
  entry => entry.phase === "apply",
).length;
assert.equal(recoveryCrashNewPlanMutations, 0,
  "recovery crash-loop handling cannot create a new apply phase");

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
    idempotency_key: request.idempotency_key,
    effect_lease_fence_digest: request.lease_fence_digest,
    revalidated_lease_fence_digest: request.revalidation_fence_digest,
    revalidated_at: request.revalidation_fence.activated_at, recovered: false,
    safe_state_verified: false, quarantine_active: true, reason_code: "forward-repair-failed",
  }) }),
});
assert.equal(failed.reason, "terminally-blocked");
assert.equal(failed.recovery_error, "forward-repair-failed");
assert.equal(failed.journal.entries.at(-1).phase, "terminally-blocked");
const inactiveBlocked = clone(failed.journal);
inactiveBlocked.entries.at(-1).quarantine.state = "not-applicable";
resignJournal(inactiveBlocked);
assert.throws(() => validateJournalConformance(inactiveBlocked, {
  schema: failureArtifacts.journalSchema,
  constitution: failureArtifacts.constitution,
  coverage: failureArtifacts.coverage,
  ownerAttestations: failureArtifacts.ownerAttestations,
}), /journal_terminally_blocked_not_quarantined/);
assert.notEqual(failed.journal.entries.at(-1).terminal_reason_digest, failed.journal.entries.at(-2).terminal_reason_digest);
const failedReplay = run({
  dir: `${tmp}/recovery-failure`, artifacts: failureArtifacts,
  recover: recovery(failureArtifacts),
});
assert.equal(failedReplay.reason, "terminal-terminally-blocked",
  "exact terminal replay remains idempotent after signed demotion");

const unknownReachabilityArtifacts = bundle();
let unknownReachabilityCalls = 0;
const unknownReachabilityRecovery = recovery(
  unknownReachabilityArtifacts,
  {
    recover: request => {
      unknownReachabilityCalls += 1;
      return {
        idempotency_key: request.idempotency_key,
        effect_lease_fence_digest: request.lease_fence_digest,
        revalidated_lease_fence_digest:
          request.revalidation_fence_digest,
        revalidated_at: request.revalidation_fence.activated_at,
        recovered: false,
        safe_state_verified: false,
        quarantine_active: true,
        reason_code: "unknown-reachability",
      };
    },
  },
);
const unknownReachability = run({
  dir: `${tmp}/unknown-reachability`,
  artifacts: unknownReachabilityArtifacts,
  phase: phases({
    applyFenced: () => {
      throw Object.assign(new Error("effect-reachability-unknown"), {
        code: "effect_reachability_unknown",
      });
    },
  }),
  recover: unknownReachabilityRecovery,
});
assert.equal(unknownReachability.reason, "terminally-blocked");
assert.equal(unknownReachability.recovery_error, "unknown-reachability");
assert.equal(
  unknownReachability.journal.entries.at(-1).phase,
  "terminally-blocked",
);
assert.equal(unknownReachabilityCalls, 1);
assert.equal(run({
  dir: `${tmp}/unknown-reachability`,
  artifacts: unknownReachabilityArtifacts,
  recover: unknownReachabilityRecovery,
}).reason, "terminal-terminally-blocked");
assert.equal(unknownReachabilityCalls, 1,
  "unknown reachability terminalizes without an optimistic retry");
const unknownStartedAt = unknownReachability.journal.entries.find(
  entry => entry.phase === "unknown",
)?.recorded_at;
const unknownTerminalAt =
  unknownReachability.journal.entries.at(-1).recorded_at;
assert.equal(typeof unknownStartedAt, "string");
const unknownReachabilityElapsedSeconds =
  (Date.parse(unknownTerminalAt) - Date.parse(unknownStartedAt)) / 1000;
assert.equal(Number.isSafeInteger(unknownReachabilityElapsedSeconds), true);
assert.equal(unknownReachabilityElapsedSeconds <= 300, true);
const unknownReachabilityNewPlanMutations =
  unknownReachability.journal.entries.filter(
    entry => entry.phase === "apply",
  ).length;
assert.equal(unknownReachabilityNewPlanMutations, 0);

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

const rebaseArtifacts = bundle();
const unrelatedTargetScope = "sha256:" + "4".repeat(64);
const unrelatedRecoveryKeys = crypto.generateKeyPairSync("ed25519");
const unrelatedRecoveryPublic = publicPem(unrelatedRecoveryKeys.publicKey);
rebaseArtifacts.recoveryRegistry.entries.push({
  ...clone(rebaseArtifacts.recoveryRegistry.entries[0]),
  target_scope_digest: unrelatedTargetScope,
  recovery_worker_identity: "unrelated-recovery-worker",
  public_key_pem: unrelatedRecoveryPublic,
  public_key_fingerprint: fingerprint(unrelatedRecoveryPublic),
});
resignArtifacts(rebaseArtifacts);
const rebaseBaseRecovery = recovery(rebaseArtifacts);
let unrelatedInjected = false;
const rebaseRecovery = {
  ...rebaseBaseRecovery,
  readNarrowingHistory: input => {
    if (!unrelatedInjected) {
      unrelatedInjected = true;
      const unsigned = {
        sequence: 1, recorded_at: "2026-07-26T00:00:03Z",
        domain: "no-reboot-security-bugfix-maintenance",
        target_scope_digest: unrelatedTargetScope,
        from_state: "armed-canary", to_state: "shadow",
        recovery_worker_identity: "unrelated-recovery-worker",
        journal_receipt_digest: "sha256:" + "3".repeat(64),
        previous_entry_digest: null,
      };
      const entry = {
        ...unsigned, entry_digest: autonomyDigest(unsigned),
      };
      entry.signature = {
        algorithm: "Ed25519",
        value_base64: sign(entry, unrelatedRecoveryKeys.privateKey),
      };
      rebaseArtifacts.runtimeNarrowing.entries.push(entry);
    }
    return rebaseBaseRecovery.readNarrowingHistory(input);
  },
};
const rebased = run({
  dir: `${tmp}/narrowing-rebase`, artifacts: rebaseArtifacts,
  phase: phases({ applyFenced: () => { throw Error("force-recovery"); } }),
  recover: rebaseRecovery,
});
assert.equal(rebased.reason, "recovered-disarmed");
assert.equal(rebaseArtifacts.runtimeNarrowing.entries.length, 2);
assert.equal(
  rebaseArtifacts.runtimeNarrowing.entries[1].previous_entry_digest,
  rebaseArtifacts.runtimeNarrowing.entries[0].entry_digest,
  "recovery rebases onto the freshly verified historical-epoch tail",
);

const pendingPostureArtifacts = bundle();
let pendingPostureFaulted = false;
const pendingPostureRecovery = recovery(pendingPostureArtifacts, {
  fault: point => {
    if (point === "after-recovery-intent" && !pendingPostureFaulted) {
      pendingPostureFaulted = true;
      throw Error("crash-after-recovery-intent");
    }
  },
});
assert.throws(() => run({
  dir: `${tmp}/pending-posture`, artifacts: pendingPostureArtifacts,
  phase: phases({ applyFenced: () => { throw Error("force-recovery"); } }),
  recover: pendingPostureRecovery, autoResume: false,
}), /crash-after-recovery-intent/);
let pendingKillReads = 0;
const pendingAdmission = recoveryTakeoverAdmission();
const originalPendingKill = pendingAdmission.killSwitch;
pendingAdmission.killSwitch = () => {
  pendingKillReads += 1;
  return originalPendingKill();
};
const pendingReplay = run({
  dir: `${tmp}/pending-posture`, artifacts: pendingPostureArtifacts,
  admit: pendingAdmission, recover: pendingPostureRecovery,
});
assert.equal(pendingReplay.reason, "recovered-disarmed");
assert.ok(pendingKillReads >= 1,
  "pending outbox replay consults the current protected kill posture");

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
  if (faultPoint === "after-recover-return") {
    const replayedOutbox = bounded(
      `${faultDir}/${binding().idempotency_key}.json.recovery-outbox.json`,
    );
    assert.equal(replayedOutbox.authorized_recovery_fence_digests.length, 3,
      "the crash replay records the original fence and both monotonic successors");
    const originalRecoveryFenceDigest =
      replayedOutbox.authorized_recovery_fence_digests[0];
    assert.equal(
      replayedOutbox.recovery_request.lease_fence_digest,
      originalRecoveryFenceDigest,
      "the original recovery request remains immutable after successor takeover",
    );
    assert.ok(
      replayedOutbox.authorized_recovery_fence_digests.includes(
        replayedOutbox.recovery_result.effect_lease_fence_digest,
      ),
      "the recovery receipt remains bound to a recorded, authorized effect fence",
    );
    assert.equal(
      replayedOutbox.recovery_result.effect_lease_fence_digest,
      originalRecoveryFenceDigest,
      "the recovery terminal receipt preserves the immutable original effect lease",
    );
    assert.notEqual(
      replayedOutbox.recovery_result.effect_lease_fence_digest,
      replayedOutbox.recovery_result.revalidated_lease_fence_digest,
      "a successor revalidates the immutable original effect receipt under its current fence",
    );
  }
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

const watchAnchorCrashDir = `${tmp}/watch-anchor-crash`;
assert.equal(await runWorker({
  WORKER_MODE: "fault", WORKER_DIR: watchAnchorCrashDir,
  FAULT_POINT: "after-watch-anchor",
}), 78, "the process can crash after the durable anchor but before lease release");
const watchAnchorCrashFile =
  `${watchAnchorCrashDir}/${binding().idempotency_key}` +
  ".json.watch-anchor.json";
const watchAnchorBeforeReplay = bounded(watchAnchorCrashFile);
assert.equal(
  bounded(`${watchAnchorCrashDir}/${binding().idempotency_key}.json`)
    .entries.at(-1).phase,
  "watch", "the watch journal is durable before the anchor crash point",
);
assert.equal(await runWorker({
  WORKER_MODE: "resume", WORKER_DIR: watchAnchorCrashDir,
}), 0, "restart reconstructs the watch clock from the durable anchor");
assert.deepEqual(
  bounded(watchAnchorCrashFile), watchAnchorBeforeReplay,
  "crash replay neither backdates nor replaces the durable watch anchor",
);

const preAnchorCrashDir = `${tmp}/pre-anchor-crash`;
assert.equal(await runWorker({
  WORKER_MODE: "fault", WORKER_DIR: preAnchorCrashDir,
  FAULT_POINT: "after-watch-journal-readback",
}), 78, "the process can crash after journal durability but before anchor issue");
const preAnchorCrashJournal =
  `${preAnchorCrashDir}/${binding().idempotency_key}.json`;
const preAnchorCrashFile = `${preAnchorCrashJournal}.watch-anchor.json`;
assert.equal(bounded(preAnchorCrashJournal).entries.at(-1).phase, "watch",
  "the pre-anchor crash leaves the durable watch journal tail");
assert.equal(fs.existsSync(preAnchorCrashFile), false,
  "the pre-anchor crash cannot leave an invented or backdated anchor");
assert.equal(await runWorker({
  WORKER_MODE: "resume", WORKER_DIR: preAnchorCrashDir,
}), 0, "restart recovers rather than reconstructing an absent watch anchor");
assert.equal(fs.existsSync(preAnchorCrashFile), false,
  "recovery never recreates a missing anchor from the earlier journal time");
assert.equal(bounded(preAnchorCrashJournal).entries.at(-1).phase, "disarm",
  "an unanchored watch is fail-closed through forward recovery");

const overBudgetAnchorCrashDir = `${tmp}/over-budget-anchor-crash`;
assert.equal(await runWorker({
  WORKER_MODE: "fault", WORKER_DIR: overBudgetAnchorCrashDir,
  OVER_BUDGET_WATCH_ANCHOR: "1", FAULT_POINT: "after-watch-anchor",
}), 78, "the process can crash after persisting a 301-second anchor");
const overBudgetAnchorCrashJournal =
  `${overBudgetAnchorCrashDir}/${binding().idempotency_key}.json`;
const overBudgetAnchorCrashFile =
  `${overBudgetAnchorCrashJournal}.watch-anchor.json`;
assert.equal(bounded(overBudgetAnchorCrashFile).anchored_at,
  "2026-07-26T00:05:01Z",
  "the crash fixture durably records the authenticated over-budget anchor");
assert.equal(bounded(overBudgetAnchorCrashJournal).entries.at(-1).phase,
  "watch", "the crash precedes the initial runtime budget assertion");
assert.equal(await runWorker({
  WORKER_MODE: "resume", WORKER_DIR: overBudgetAnchorCrashDir,
}), 0, "restart routes the authenticated over-budget anchor into recovery");
assert.equal(bounded(overBudgetAnchorCrashJournal).entries.at(-1).phase,
  "disarm", "the over-budget anchor can never resume watch or commit");
const overBudgetTerminalJournal =
  bounded(overBudgetAnchorCrashJournal);
const overBudgetTerminalResult =
  `${tmp}/over-budget-anchor-terminal-result.json`;
const overBudgetTerminalRecoveryLog =
  `${tmp}/over-budget-anchor-terminal-recovery.log`;
assert.equal(await runWorker({
  WORKER_MODE: "resume", WORKER_DIR: overBudgetAnchorCrashDir,
  WORKER_RESULT: overBudgetTerminalResult,
  RECOVERY_CALL_LOG: overBudgetTerminalRecoveryLog,
}), 0, "an exact terminal retry accepts the authenticated recovery history");
assert.deepEqual(bounded(overBudgetTerminalResult), {
  ran: false, reason: "terminal-disarm",
}, "the exact post-recovery retry is read-only");
assert.deepEqual(
  bounded(overBudgetAnchorCrashJournal), overBudgetTerminalJournal,
  "the exact terminal retry does not append another recovery receipt",
);
assert.equal(fs.existsSync(overBudgetTerminalRecoveryLog), false,
  "the exact terminal retry causes no new recovery effect");

for (const anchorDamage of ["malformed", "torn"]) {
  const damagedAnchorDir = `${tmp}/${anchorDamage}-anchor`;
  assert.equal(await runWorker({
    WORKER_MODE: "fault", WORKER_DIR: damagedAnchorDir,
    FAULT_POINT: "after-watch-anchor",
  }), 78, `the ${anchorDamage} anchor fixture starts from a durable anchor`);
  const damagedAnchorJournal =
    `${damagedAnchorDir}/${binding().idempotency_key}.json`;
  const damagedAnchorFile = `${damagedAnchorJournal}.watch-anchor.json`;
  if (anchorDamage === "torn") {
    fs.writeFileSync(damagedAnchorFile, '{"kind":');
  } else {
    const malformedAnchor = bounded(damagedAnchorFile);
    malformedAnchor.journal_tail_digest = autonomyDigest("wrong-watch-tail");
    fs.writeFileSync(damagedAnchorFile, JSON.stringify(malformedAnchor));
  }
  assert.equal(await runWorker({
    WORKER_MODE: "resume", WORKER_DIR: damagedAnchorDir,
  }), 0, `${anchorDamage} anchor restart enters fail-closed recovery`);
  assert.equal(bounded(damagedAnchorJournal).entries.at(-1).phase, "disarm",
    `${anchorDamage} anchor state cannot continue or commit`);
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
const corruptCurrentDir = `${tmp}/prepared-corrupt-current`;
assert.equal(await runWorker({
  WORKER_MODE: "fault", WORKER_DIR: corruptCurrentDir,
  FAULT_POINT: "after-prepare-journal",
}), 78);
const corruptHistoricalArtifacts = bundle();
corruptHistoricalArtifacts.read = () => {
  throw Error("current-authority-unavailable");
};
const corruptCurrentReplay = run({
  dir: corruptCurrentDir, artifacts: corruptHistoricalArtifacts,
  admit: recoveryTakeoverAdmission(),
  recover: recovery(corruptHistoricalArtifacts),
});
assert.equal(corruptCurrentReplay.reason, "recovered-disarmed",
  "current bundle corruption cannot strand authenticated historical recovery");

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

if (process.env.BROKKR_FI_CONTROLLER_RECEIPT) {
  const fileDigest = relative =>
    `sha256:${crypto.createHash("sha256")
      .update(fs.readFileSync(`${root}/${relative}`)).digest("hex")}`;
  const cleanElapsedSeconds = (happyCommitAt - happyPrepareAt) / 1000;
  assert.equal(cleanElapsedSeconds, 3900);
  const happyNewPlanMutations =
    happy.journal.entries.filter(entry => entry.phase === "apply").length - 1;
  assert.equal(happyNewPlanMutations, 0);
  const fragment = {
    kind: "brokkr-supervised-debian-fi-fragment",
    schema_version: "v1",
    path_id: "w2a-w2b-production-v1",
    production_path: {
      controller: fileDigest("scripts/debian-maintenance-autonomy.mjs"),
      bounded_recovery_dispatcher: fileDigest(
        "scripts/lib/bounded-recovery-dispatch.mjs",
      ),
    },
    scenarios: [
      {
        id: "clean-run", outcome: "committed",
        quarantine_active: false,
        new_plan_mutations: happyNewPlanMutations,
        budget_seconds: 3900,
        observed_elapsed_seconds: cleanElapsedSeconds,
        terminal_at: happy.journal.entries.at(-1).recorded_at,
      },
      {
        id: "controller-kill-9", outcome: "disarmed",
        quarantine_active: true,
        new_plan_mutations: sigkillApplyCount - 1,
        budget_seconds: 300,
        observed_elapsed_seconds: sigkillElapsedSeconds,
        terminal_at: bounded(
          `${sigkillDir}/${binding().idempotency_key}.json`,
        ).entries.at(-1).recorded_at,
      },
      {
        id: "progress-loop-wedge", outcome: "disarmed",
        quarantine_active: true,
        new_plan_mutations: staleWriterNewPlanMutations,
        budget_seconds: 300,
        observed_elapsed_seconds: progressWedgeElapsedSeconds,
        terminal_at: staleWriterTerminalAt,
      },
      {
        id: "recovery-crash-loop", outcome: "disarmed",
        quarantine_active: true,
        new_plan_mutations: recoveryCrashNewPlanMutations,
        budget_seconds: 300,
        observed_elapsed_seconds: recoveryCrashElapsedSeconds,
        terminal_at: recoveryCrashTerminalAt,
      },
      {
        id: "unknown-reachability", outcome: "terminally-blocked",
        quarantine_active: true,
        new_plan_mutations: unknownReachabilityNewPlanMutations,
        budget_seconds: 300,
        observed_elapsed_seconds: unknownReachabilityElapsedSeconds,
        terminal_at: unknownTerminalAt,
      },
    ].map(value => ({
      ...value,
      path_id: "w2a-w2b-production-v1",
      passed:
        value.new_plan_mutations === 0 &&
        value.observed_elapsed_seconds <= value.budget_seconds,
    })),
  };
  assert.equal(fragment.scenarios.every(value => value.passed), true);
  fs.writeFileSync(
    process.env.BROKKR_FI_CONTROLLER_RECEIPT,
    `${JSON.stringify(fragment)}\n`,
    { mode: 0o600 },
  );
}

console.log("maintenance attempt journal: W0.2 authorization, admission, v2 timing, recovery, demotion and rate gates OK");
NODE

env ROOT="$ROOT" TMP="$TMP" node --experimental-loader "$ROOT/scripts/test/fixtures/fixed-recovery-host/loader.mjs" "$TMP/test.mjs"
