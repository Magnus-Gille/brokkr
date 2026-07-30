#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$ROOT" TMP="$TMP" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import { spawn } from "node:child_process";
const {
  canonicalJson, composeAttempt, digest, occurrenceIdentity,
  runDebianMaintenanceAttemptFactory,
} = await import(`${process.env.ROOT}/scripts/lib/debian-maintenance-attempt-factory.mjs`);
const releaseDigest = digest("release");
const policy = JSON.parse(fs.readFileSync(
  `${process.env.ROOT}/tests/fixtures/maintenance-policy/normal-window.json`,
)).records.find(row => row.kind === "maintenance-policy");
policy.timezone = "UTC";
policy.window.days_of_week = ["thu"];
policy.window.start_local_time = "18:00";
policy.window.duration = "PT2H";
policy.selector.node_ids = ["node-a"];
policy.reboot.policy = "never";
delete policy.policy_digest;
policy.policy_digest = digest(Object.fromEntries(
  Object.entries(policy).filter(([key]) => key !== "policy_digest"),
));
const plan = {
  kind: "brokkr-maintenance-plan", schema_version: "v1",
  plan_id: "window-plan", outcome: "planned", node_id: "node-a",
  policy_id: policy.policy_id, policy_digest: policy.policy_digest,
  inventory_evidence_id: "inventory-window", running_kernel: "6.1.0-test",
  decision: { effect: "on_schedule" }, blockers: [], hook_gaps: [],
  unmet_policy_classes: [], created_at: "2026-07-30T18:00:00Z",
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
plan.plan_digest = digest(plan);
const target = { node_id: "node-a", platform: "debian", non_pillar: true };
const before = {
  kernel: "6.1.0-test", packages: ["openssl=3.0.17-1~deb12u1"],
  reboot_required: false, dpkg_status: "clean",
};
const after = {
  kernel: "6.1.0-test", packages: ["openssl=3.0.17-1~deb12u2"],
  reboot_required: false, dpkg_status: "clean",
};
const actors = {
  owner: "maintenance-owner", controller: "maintenance-controller",
  watchdog: "maintenance-watchdog", kill_switch: "maintenance-kill-switch",
  recovery_worker: "maintenance-recovery-worker",
};
const config = {
  kind: "brokkr-debian-attempt-factory-configuration", schema_version: "v1",
  release_digest: releaseDigest, target, actors,
  authority: {
    writer_owner: "brokkr", owner_authority_ref: "ref:brokkr-owner-authority",
    owner_authority_digest: digest("owner"),
    configuration_owner: "brokkr",
    configuration_owner_authority_ref: "ref:brokkr-configuration-authority",
    configuration_owner_authority_digest: digest("configuration"),
    admission_coverage_digest: digest("coverage"),
    admission_binding_state: "armed-canary",
    constitution_digest: digest("constitution"),
  },
  recovery: {
    descriptor_id_prefix: "recovery",
    restart_units: ["brokkr-maintenance-safe.service"], budget_seconds: 240,
  },
  watch_seconds: 3600, deadline_seconds: 4200,
};
const fresh = {
  kind: "brokkr-debian-window-freshness", schema_version: "v1",
  observed_at: "2026-07-30T18:00:00Z",
  valid_until: "2026-07-30T18:05:00Z",
  liveness: { healthy: true }, eligibility: { eligible: true },
  kill_switch: { safe: true, identity: actors.kill_switch },
  hold: { active: false }, policy,
  window: {
    start: "2026-07-30T18:00:00Z", end: "2026-07-30T20:00:00Z",
    due: true,
  },
  target, plan, inventory: before, postconditions: after,
  apt_source_evidence: {
    kind: "brokkr-debian-apt-source-evidence", schema_version: "v1",
    plan_digest: plan.plan_digest, policy_digest: policy.policy_digest,
    trust_config_digest: digest("trust"),
    candidates: [{ name: "openssl", policy_output_digest: digest("policy") }],
  },
};
const targetScopeDigest = digest({ node_id: target.node_id, platform: "debian" });
const identities = {
  ...occurrenceIdentity({
    policyDigest: policy.policy_digest, targetScopeDigest,
    windowStart: fresh.window.start,
  }),
  target_scope_digest: targetScopeDigest,
};
const proposal = composeAttempt({
  config, freshness: fresh, identities, releaseDigest,
  at: "2026-07-30T18:00:00Z",
});
assert.equal(proposal.binding_digest, digest(proposal.binding));
assert.equal(
  proposal.binding.recovery.descriptor_digest,
  digest(proposal.request.recovery_descriptor),
);
assert.equal("binding_digest" in proposal.request.recovery_descriptor, false,
  "descriptor is upstream of the binding digest and cannot form a cycle");
assert.equal(proposal.request.binding_digest, proposal.binding_digest);
assert.deepEqual(proposal.request.binding, proposal.binding);
assert.equal(proposal.registration.binding_digest, proposal.binding_digest);
assert.equal(
  proposal.recovery_authorization.binding_digest, proposal.binding_digest,
);
assert.deepEqual(proposal.registration.actors, actors);

const stateRoot = `${process.env.TMP}/state`;
fs.mkdirSync(stateRoot, { mode: 0o700 });
let runs = 0;
const base = {
  stateRoot, releaseDigest, readConfiguration: () => structuredClone(config),
  readFreshness: () => structuredClone(fresh),
  now: () => "2026-07-30T18:00:01Z",
  runAttempt: input => {
    runs += 1;
    assert.equal(input.proposal.binding_digest, proposal.binding_digest);
    return { reason: "watching" };
  },
  buildRunOptions: (stored, freshness) => ({ proposal: stored, freshness }),
};
const first = runDebianMaintenanceAttemptFactory(base);
const retry = runDebianMaintenanceAttemptFactory(base);
assert.equal(first.attempt_id, retry.attempt_id);
assert.equal(first.mutation_id, retry.mutation_id);
assert.equal(runs, 2, "timer retry resumes the same W2 proposal");
assert.equal(fs.readdirSync(`${stateRoot}/occurrences`)
  .filter(name => name.endsWith(".json")).length, 1);

let crash = true;
assert.throws(() => runDebianMaintenanceAttemptFactory({
  ...base, stateRoot: `${process.env.TMP}/crash`,
  fault: point => {
    if (crash && point === "after-occurrence-persist") {
      crash = false;
      throw Error("injected-crash");
    }
  },
}), /injected-crash/);
const resumed = runDebianMaintenanceAttemptFactory({
  ...base, stateRoot: `${process.env.TMP}/crash`,
});
assert.equal(resumed.attempt_id, first.attempt_id);

const stale = structuredClone(fresh);
stale.valid_until = "2026-07-30T18:00:00Z";
const noAttempt = runDebianMaintenanceAttemptFactory({
  ...base, stateRoot: `${process.env.TMP}/stale`,
  readFreshness: () => structuredClone(stale),
});
assert.deepEqual(noAttempt, {
  outcome: "no-attempt", reason: "attempt_factory_freshness_ineligible",
});
assert.equal(fs.existsSync(`${process.env.TMP}/stale/occurrences`), false);

const oldButValid = structuredClone(fresh);
oldButValid.observed_at = "2026-07-30T17:50:00Z";
oldButValid.valid_until = "2026-07-30T18:15:00Z";
let oldSnapshotRuns = 0;
const oldSnapshotAttempt = runDebianMaintenanceAttemptFactory({
  ...base, stateRoot: `${process.env.TMP}/old-but-valid`,
  readFreshness: () => structuredClone(oldButValid),
  runAttempt: () => {
    oldSnapshotRuns += 1;
    return { reason: "unexpected" };
  },
});
assert.deepEqual(oldSnapshotAttempt, {
  outcome: "no-attempt", reason: "attempt_factory_freshness_ineligible",
});
assert.equal(oldSnapshotRuns, 0,
  "an old snapshot fails closed even while valid_until is in the future");

const notDue = structuredClone(fresh);
notDue.window.due = false;
const noWindowAttempt = runDebianMaintenanceAttemptFactory({
  ...base, stateRoot: `${process.env.TMP}/not-due`,
  readFreshness: () => structuredClone(notDue),
});
assert.deepEqual(noWindowAttempt, {
  outcome: "no-attempt", reason: "attempt_factory_freshness_ineligible",
});
assert.equal(fs.existsSync(`${process.env.TMP}/not-due/occurrences`), false);

let budgetClockReads = 0;
let budgetRuns = 0;
const refreshedAtEffect = structuredClone(fresh);
refreshedAtEffect.observed_at = "2026-07-30T18:05:00Z";
refreshedAtEffect.valid_until = "2026-07-30T18:10:00Z";
assert.throws(() => runDebianMaintenanceAttemptFactory({
  ...base, stateRoot: `${process.env.TMP}/spent-budget`,
  now: () => budgetClockReads++ === 0 ?
    "2026-07-30T18:00:00Z" : "2026-07-30T18:05:01Z",
  readFreshness: () => structuredClone(
    budgetClockReads <= 1 ? fresh : refreshedAtEffect,
  ),
  runAttempt: () => {
    budgetRuns += 1;
    return { reason: "unexpected" };
  },
}), /attempt_factory_watch_unreachable/);
assert.equal(budgetRuns, 0,
  "spent apply/verify budget fails closed before an effect");

let reads = 0;
const drifted = structuredClone(fresh);
drifted.hold.active = true;
assert.throws(() => runDebianMaintenanceAttemptFactory({
  ...base, stateRoot: `${process.env.TMP}/drift`,
  readFreshness: () => structuredClone(reads++ === 0 ? fresh : drifted),
}), /attempt_factory_freshness_ineligible/);

fs.mkdirSync(`${process.env.TMP}/contended`, { mode: 0o700 });
fs.mkdirSync(`${process.env.TMP}/contended/occurrences`, { mode: 0o700 });
const proposalName = identities.occurrence_digest.slice("sha256:".length);
fs.mkdirSync(
  `${process.env.TMP}/contended/occurrences/${proposalName}.json.lock`,
);
assert.throws(() => runDebianMaintenanceAttemptFactory({
  ...base, stateRoot: `${process.env.TMP}/contended`,
}), /attempt_factory_occurrence_contended/);

const crashedRoot = `${process.env.TMP}/crashed-lock`;
const crashedLock =
  `${crashedRoot}/occurrences/${proposalName}.json.lock`;
fs.mkdirSync(crashedLock, { recursive: true, mode: 0o700 });
fs.writeFileSync(`${crashedLock}/owner.json`, `${canonicalJson({
  kind: "brokkr-attempt-factory-lock", schema_version: "v1",
  pid: 2147483647, process_start_time: digest("departed-process"),
})}\n`, { mode: 0o600 });
const recoveredLock = runDebianMaintenanceAttemptFactory({
  ...base, stateRoot: crashedRoot,
});
assert.equal(recoveredLock.attempt_id, first.attempt_id);
assert.equal(fs.existsSync(crashedLock), false,
  "a crash residue owned by a departed process is recovered");

const reclaimRaceRoot = `${process.env.TMP}/reclaim-race`;
const reclaimRaceLock =
  `${reclaimRaceRoot}/occurrences/${proposalName}.json.lock`;
const reclaimReady = `${process.env.TMP}/reclaim-ready`;
const reclaimEffect = `${process.env.TMP}/reclaim-effect`;
fs.mkdirSync(reclaimRaceLock, { recursive: true, mode: 0o700 });
fs.writeFileSync(`${reclaimRaceLock}/owner.json`, `${canonicalJson({
  kind: "brokkr-attempt-factory-lock", schema_version: "v1",
  pid: 2147483647, process_start_time: digest("departed-race-owner"),
})}\n`, { mode: 0o600 });
const raceBundleFile = `${process.env.TMP}/reclaim-race-input.json`;
fs.writeFileSync(raceBundleFile, `${canonicalJson({
  stateRoot: reclaimRaceRoot, releaseDigest, config, fresh,
  readyDir: reclaimReady, effectFile: reclaimEffect,
})}\n`, { mode: 0o600 });
const raceWorker = String.raw`
  import fs from "node:fs";
  const [moduleFile, bundleFile] = process.argv.slice(1);
  const { runDebianMaintenanceAttemptFactory } = await import(moduleFile);
  const bundle = JSON.parse(fs.readFileSync(bundleFile));
  const wait = milliseconds => Atomics.wait(
    new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds,
  );
  fs.mkdirSync(bundle.readyDir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(bundle.readyDir + "/" + process.pid, "", {
    flag: "wx", mode: 0o600,
  });
  const readyDeadline = Date.now() + 5_000;
  while (fs.readdirSync(bundle.readyDir).length < 2) {
    if (Date.now() >= readyDeadline) throw Error("worker_barrier_timeout");
    wait(10);
  }
  try {
    const result = runDebianMaintenanceAttemptFactory({
      stateRoot: bundle.stateRoot,
      releaseDigest: bundle.releaseDigest,
      readConfiguration: () => structuredClone(bundle.config),
      readFreshness: () => structuredClone(bundle.fresh),
      now: () => "2026-07-30T18:00:01Z",
      runAttempt: () => {
        fs.writeFileSync(bundle.effectFile, String(process.pid), {
          flag: "wx", mode: 0o600,
        });
        wait(750);
        return { reason: "watching" };
      },
      buildRunOptions: (stored, freshness) => ({
        proposal: stored, freshness,
      }),
    });
    process.stdout.write(JSON.stringify({ outcome: result.outcome }));
  } catch (error) {
    process.stdout.write(JSON.stringify({
      error: String(error?.code ?? error?.message),
    }));
    process.exitCode = 2;
  }
`;
const runRaceWorker = () => new Promise((resolve, reject) => {
  const child = spawn(process.execPath, [
    "--input-type=module", "-e", raceWorker,
    `${process.env.ROOT}/scripts/lib/debian-maintenance-attempt-factory.mjs`,
    raceBundleFile,
  ], { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", chunk => { stdout += chunk; });
  child.stderr.on("data", chunk => { stderr += chunk; });
  child.on("error", reject);
  child.on("close", status => resolve({
    status, stdout, stderr,
  }));
});
const reclaimResults = await Promise.all([
  runRaceWorker(), runRaceWorker(),
]);
assert.deepEqual(reclaimResults.map(result => result.status).sort(), [0, 2],
  JSON.stringify(reclaimResults));
const reclaimOutputs = reclaimResults.map(result =>
  JSON.parse(result.stdout));
assert.equal(reclaimOutputs.filter(result =>
  result.outcome === "attempt-dispatched").length, 1);
assert.equal(reclaimOutputs.filter(result =>
  result.error === "attempt_factory_occurrence_contended").length, 1);
assert.equal(fs.readFileSync(reclaimEffect, "utf8").length > 0, true);

const tampered = structuredClone(proposal);
tampered.request.recovery_descriptor.packages = ["curl"];
assert.notEqual(
  tampered.binding.recovery.descriptor_digest,
  digest(tampered.request.recovery_descriptor),
);

// Full production bridge: fixed protected signed authority/key files feed the
// real runDebianMaintenance runner; the fixed host boundary is hermetically
// substituted at its single process invocation seam.
const fixture = name => JSON.parse(fs.readFileSync(
  `${process.env.ROOT}/tests/fixtures/autonomy-contract-v2/${name}`,
));
const digestWithout = (value, field) => {
  const copy = structuredClone(value);
  delete copy[field];
  return digest(copy);
};
const ownerKeys = crypto.generateKeyPairSync("ed25519");
const recoveryKeys = crypto.generateKeyPairSync("ed25519");
const pem = key => key.export({ type: "spki", format: "pem" });
const fingerprint = key => `sha256:${crypto.createHash("sha256").update(
  crypto.createPublicKey(key).export({ type: "spki", format: "der" }),
).digest("hex")}`;
const sign = (value, key) => crypto.sign(
  null, Buffer.from(canonicalJson(value)), key,
).toString("base64");
const constitution = fixture("constitution.json");
const coverage = fixture("coverage-armed-canary.json");
const ownerAttestations = fixture("owner-attestations.json");
const coverageRow = coverage.domains.find(row =>
  row.domain === "no-reboot-security-bugfix-maintenance");
const coverageBinding = coverageRow.bindings[0];
coverageBinding.target_scope_digest = targetScopeDigest;
const ownerAttestation = ownerAttestations.attestations.find(row =>
  row.domain === coverageRow.domain);
ownerAttestation.target_scope_digest = targetScopeDigest;
ownerAttestation.attestation_digest =
  digestWithout(ownerAttestation, "attestation_digest");
coverageBinding.configuration_owner_authority_digest =
  ownerAttestation.attestation_digest;
ownerAttestations.registry_digest =
  digestWithout(ownerAttestations, "registry_digest");
coverage.registry_digest = digestWithout(coverage, "registry_digest");
const recoveryPublic = pem(recoveryKeys.publicKey);
const recoveryRegistry = {
  kind: "autonomy-recovery-worker-registry", schema_version: "v1",
  registry_id: "maintenance-recovery-workers",
  entries: [{
    domain: coverageRow.domain, target_scope_digest: targetScopeDigest,
    recovery_worker_identity: coverageBinding.identities.recovery_worker,
    public_key_pem: recoveryPublic,
    public_key_fingerprint: fingerprint(recoveryPublic),
  }],
  registry_digest: digest("placeholder"), extensions: [],
};
recoveryRegistry.registry_digest =
  digestWithout(recoveryRegistry, "registry_digest");
const ownerPublic = pem(ownerKeys.publicKey);
const authorization = {
  kind: "autonomy-owner-authorization", schema_version: "v1",
  authorization_id: "maintenance-owner-authorization",
  authorization_sequence: 1, previous_authorization_digest: null,
  issued_at: "2026-07-30T17:55:00Z",
  authority: {
    key_id: "test-owner-ed25519", algorithm: "Ed25519",
    public_key_pem: ownerPublic,
    public_key_fingerprint: fingerprint(ownerPublic),
  },
  bindings: {
    constitution_digest: constitution.constitution_digest,
    coverage_intent_digest: coverage.registry_digest,
    owner_attestation_registry_digest: ownerAttestations.registry_digest,
    recovery_worker_registry_digest: recoveryRegistry.registry_digest,
  },
};
authorization.signature = {
  algorithm: "Ed25519",
  value_base64: sign(authorization, ownerKeys.privateKey),
};
const authorizationDigest = digest(authorization);
const integrationRoot = `${process.env.TMP}/integration`;
const authorityRoot = `${process.env.TMP}/authority`;
fs.mkdirSync(integrationRoot, { mode: 0o700 });
fs.mkdirSync(authorityRoot, { mode: 0o700 });
const protectedWrite = (file, value, raw = false) => {
  fs.writeFileSync(file, raw ? value : `${canonicalJson(value)}\n`,
    { mode: 0o600 });
  fs.chmodSync(file, 0o600);
};
for (const [name, value] of Object.entries({
  "authorization.json": authorization,
  "constitution.json": constitution,
  "coverage.json": coverage,
  "owner-attestations.json": ownerAttestations,
  "recovery-registry.json": recoveryRegistry,
  "authorization-checkpoint.json": {
    kind: "autonomy-owner-authorization-checkpoint", schema_version: "v1",
    authorization_digest: authorizationDigest, minimum_sequence: 1,
  },
})) protectedWrite(`${authorityRoot}/${name}`, value);
protectedWrite(`${authorityRoot}/owner-public-key.pem`, ownerPublic, true);
protectedWrite(
  `${authorityRoot}/recovery-worker-public-key.pem`, recoveryPublic, true,
);
protectedWrite(
  `${authorityRoot}/recovery-worker-private-key.pem`,
  recoveryKeys.privateKey.export({ type: "pkcs8", format: "pem" }), true,
);
protectedWrite(`${integrationRoot}/runtime-narrowing.json`, {
  kind: "autonomy-runtime-narrowing", schema_version: "v1",
  ledger_id: "maintenance-runtime-narrowing",
  owner_authorization_digest: authorizationDigest,
  entries: [], extensions: [],
});
protectedWrite(`${integrationRoot}/runtime-narrowing-checkpoint.json`, {
  kind: "autonomy-runtime-narrowing-checkpoint", schema_version: "v1",
  owner_authorization_digest: authorizationDigest,
  ledger_tail_digest: null, minimum_entries: 0,
});
const integrationConfig = structuredClone(config);
integrationConfig.actors = structuredClone(coverageBinding.identities);
integrationConfig.authority = {
  writer_owner: coverageBinding.writer_owner,
  owner_authority_ref: coverageBinding.owner_authority_ref,
  owner_authority_digest: coverageBinding.owner_authority_digest,
  configuration_owner: coverageBinding.configuration_owner,
  configuration_owner_authority_ref:
    coverageBinding.configuration_owner_authority_ref,
  configuration_owner_authority_digest:
    coverageBinding.configuration_owner_authority_digest,
  admission_coverage_digest: coverage.registry_digest,
  admission_binding_state: coverageBinding.state,
  constitution_digest: constitution.constitution_digest,
};
const integrationFresh = structuredClone(fresh);
integrationFresh.kill_switch.identity =
  integrationConfig.actors.kill_switch;
integrationFresh.valid_until = "2026-07-30T20:00:00Z";
let clockMs = Date.parse("2026-07-30T18:00:00Z");
const clock = () => new Date(clockMs += 1000)
  .toISOString().replace(".000Z", "Z");
let fixedHostCalls = 0;
const fixedHostMock = (_adapter, attempt) => {
  fixedHostCalls += 1;
  const requestPath = `${integrationRoot}/requests/${attempt}.json`;
  const registrationPath =
    `${integrationRoot}/registrations/${attempt}.json`;
  const fixedRequest = JSON.parse(fs.readFileSync(requestPath));
  const fixedRegistration = JSON.parse(fs.readFileSync(registrationPath));
  assert.equal(fixedRequest.schema_version, "v2");
  assert.equal(fixedRequest.binding_digest, digest(fixedRequest.binding));
  assert.equal(
    fixedRequest.recovery_descriptor_digest,
    digest(fixedRequest.recovery_descriptor),
  );
  assert.equal(
    fixedRegistration.lease_fence_digest,
    fixedRequest.lease_fence_digest,
  );
  fs.mkdirSync(`${integrationRoot}/journals`, { mode: 0o700 });
  protectedWrite(`${integrationRoot}/journals/${attempt}.json`, {
    entries: [{ phase: "verify" }],
  });
  return { elapsed_ms: 1 };
};
const watching = runDebianMaintenanceAttemptFactory({
  stateRoot: integrationRoot, authorityRoot, releaseDigest,
  readConfiguration: () => structuredClone(integrationConfig),
  readFreshness: () => structuredClone(integrationFresh),
  now: clock, hostApply: fixedHostMock,
});
assert.equal(watching.result.reason, "watching");
assert.equal(fixedHostCalls, 1);
clockMs = Date.parse("2026-07-30T19:01:10Z");
integrationFresh.observed_at = "2026-07-30T19:01:10Z";
const committed = runDebianMaintenanceAttemptFactory({
  stateRoot: integrationRoot, authorityRoot, releaseDigest,
  readConfiguration: () => structuredClone(integrationConfig),
  readFreshness: () => structuredClone(integrationFresh),
  now: clock, hostApply: fixedHostMock,
});
assert.equal(committed.result.reason, "committed");
assert.equal(fixedHostCalls, 1,
  "watch continuation never replays the fixed host effect");

console.log("debian maintenance attempt factory tests passed");
NODE

# The production entry point accepts no selection of any kind.
if node "$ROOT/scripts/debian-maintenance-attempt-factory.mjs" --target nope \
  >"$TMP/cli.out" 2>&1; then
  echo "attempt factory unexpectedly accepted argv" >&2
  exit 1
fi
grep -Fq "attempt_factory_cli_arguments_invalid" "$TMP/cli.out"
