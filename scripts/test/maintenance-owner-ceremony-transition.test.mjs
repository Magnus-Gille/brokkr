import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  armMaintenanceCanary,
  disableMaintenanceCanary,
  canonicalJson,
  digestBytes,
  digestValue,
} from "../maintenance-owner-ceremony-transition.mjs";

const sha = character => `sha256:${character.repeat(64)}`;
const revision = "1".repeat(40);
const adapterRevision = "2".repeat(40);
const canary = "canary-one";
const targetScopeDigest = sha("5");
const utc = "2026-07-30T15:00:00Z";
const later = "2026-07-31T15:00:00Z";
const root = fs.mkdtempSync(path.join(os.tmpdir(), "brokkr-ceremony-"));
process.on("exit", () => fs.rmSync(root, { recursive: true, force: true }));

const rooted = absolute => path.join(root, absolute.slice(1));
const write = (absolute, value, mode = 0o600) => {
  const file = rooted(absolute);
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, typeof value === "string" ? value : `${JSON.stringify(value)}\n`, { mode });
  fs.chmodSync(file, mode);
  return file;
};
const writeUnit = (name, contents) =>
  write(`/etc/systemd/system/${name}`, contents, 0o644);
for (const absolute of [
  "/var/lib/brokkr/debian-maintenance",
  "/var/lib/brokkr/debian-maintenance/disarmed",
  "/var/lib/brokkr/debian-maintenance/armed",
  "/var/lib/brokkr/debian-maintenance/ceremony",
  "/var/lib/brokkr/debian-maintenance/evidence",
]) {
  fs.mkdirSync(rooted(absolute), { recursive: true, mode: 0o700 });
  fs.chmodSync(rooted(absolute), 0o700);
}

const owner = crypto.generateKeyPairSync("ed25519");
const recovery = crypto.generateKeyPairSync("ed25519");
const ownerPublic = owner.publicKey.export({ type: "spki", format: "pem" });
const recoveryPublic = recovery.publicKey.export({ type: "spki", format: "pem" });
const fingerprint = key => digestBytes(
  crypto.createPublicKey(key).export({ type: "spki", format: "der" }),
);
const sign = (value, key = owner.privateKey) =>
  crypto.sign(null, Buffer.from(canonicalJson(value)), key).toString("base64");
const selfDigest = (value, field) => {
  const copy = structuredClone(value);
  delete copy[field];
  return digestValue(copy);
};

const identities = {
  owner: "maintenance-owner",
  controller: "maintenance-controller",
  watchdog: "maintenance-watchdog",
  kill_switch: "maintenance-kill-switch",
  recovery_worker: "maintenance-recovery-worker",
};
const constitution = {
  kind: "autonomy-constitution",
  schema_version: "v2",
  constitution_id: "ceremony-constitution",
  autonomous_classes: [{
    class: "no-reboot-security-bugfix-maintenance",
    owner: "brokkr",
    recovery_class: "R-forward",
    bounds: {
      max_concurrent_targets: 1,
      max_attempts: 1,
      trusted_watchdog_time_required: true,
    },
  }],
  constitution_digest: null,
};
constitution.constitution_digest = selfDigest(constitution, "constitution_digest");

const ownerAttestations = {
  kind: "autonomy-owner-attestation-registry",
  schema_version: "v1",
  registry_id: "ceremony-owner-attestations",
  attestations: [{
    attestation_id: "maintenance-config-attestation",
    domain: "no-reboot-security-bugfix-maintenance",
    target_scope_digest: targetScopeDigest,
    configuration_owner: "brokkr",
    attestation_digest: sha("6"),
  }],
  registry_digest: null,
};
ownerAttestations.registry_digest =
  selfDigest(ownerAttestations, "registry_digest");

const recoveryRegistry = {
  kind: "autonomy-recovery-worker-registry",
  schema_version: "v1",
  registry_id: "ceremony-recovery-registry",
  entries: [{
    domain: "no-reboot-security-bugfix-maintenance",
    target_scope_digest: targetScopeDigest,
    recovery_worker_identity: identities.recovery_worker,
    public_key_pem: recoveryPublic,
    public_key_fingerprint: fingerprint(recoveryPublic),
  }],
  registry_digest: null,
};
recoveryRegistry.registry_digest =
  selfDigest(recoveryRegistry, "registry_digest");

const coverage = {
  kind: "autonomy-coverage-registry",
  schema_version: "v2",
  registry_id: "ceremony-coverage",
  global_state: "armed",
  domains: [{
    domain: "no-reboot-security-bugfix-maintenance",
    owner: "brokkr",
    recovery_class: "R-forward",
    coverage: "armed-canary",
    target_state: "armed-canary",
    bindings: [{
      writer_owner: "brokkr",
      configuration_owner: "brokkr",
      target_scope_digest: targetScopeDigest,
      state: "armed-canary",
      identities,
    }],
  }],
  registry_digest: null,
};
coverage.registry_digest = selfDigest(coverage, "registry_digest");

const unsignedAuthorization = {
  kind: "autonomy-owner-authorization",
  schema_version: "v1",
  authorization_id: "ceremony-authorization",
  authorization_sequence: 1,
  previous_authorization_digest: null,
  issued_at: utc,
  authority: {
    key_id: "maintenance-owner-key",
    algorithm: "Ed25519",
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
const authorization = {
  ...unsignedAuthorization,
  signature: { algorithm: "Ed25519", value_base64: sign(unsignedAuthorization) },
};

const unitNames = {
  apply_service: `brokkr-debian-maintenance-canary-${canary}.service`,
  recovery_service: `brokkr-debian-maintenance-recovery-${canary}.service`,
  delivery_service: "brokkr-maintenance-execution-result-delivery.service",
  scheduler_timer: `brokkr-debian-maintenance-scheduler-${canary}.timer`,
  watchdog_timer: `brokkr-debian-maintenance-watchdog-${canary}.timer`,
};
const unitFiles = {};
for (const [role, name] of Object.entries(unitNames)) {
  unitFiles[role] = writeUnit(name, [
    `[Unit]`,
    `Description=${role}`,
    `Environment=BROKKR_RELEASE_SHA=${revision}`,
    role === "delivery_service" ?
      `Environment=BROKKR_ADAPTER_REVISION=${adapterRevision}\nEnvironment=BROKKR_ADAPTER_DIGEST=${sha("a")}` :
      "",
    "",
  ].join("\n"));
}

const release = rooted(`/usr/local/lib/brokkr/releases/${revision}`);
fs.mkdirSync(path.join(release, "scripts/lib"), { recursive: true, mode: 0o755 });
write(`/usr/local/lib/brokkr/releases/${revision}/scripts/debian-maintenance-host-adapter.mjs`, "host\n", 0o755);
write(`/usr/local/lib/brokkr/releases/${revision}/scripts/lib/fixed-debian-maintenance-host-operation.mjs`, "fixed\n", 0o644);
write(`/usr/local/lib/brokkr/releases/${revision}/scripts/lib/bounded-recovery-dispatch.mjs`, "recover\n", 0o644);

const deliveryCredential = {
  kind: "brokkr-maintenance-result-delivery-config",
  schema_version: "v1",
  enabled: true,
  adapter_revision: adapterRevision,
  adapter_digest: sha("a"),
  endpoint: "https://heimdall.example.invalid/api/maintenance-execution-results",
  bearer_token: "ceremony-test-token-0001",
};
const deliveryProbe = {
  kind: "maintenance-execution-result",
  schema_version: "v1",
  result_id: "result-ceremony-probe",
  source: {
    source_id: "brokkr-maintenance",
    source_revision_digest: sha("b"),
    configuration_digest: sha("c"),
  },
  freshness: { observed_at: utc, valid_until: later, evaluated_at: utc },
  execution_epoch: 1,
  journal: {
    journal_id: "ceremony-probe-journal",
    binding_digest: sha("d"),
    tail_sequence: 1,
    tail_receipt_digest: sha("e"),
    config_digest: sha("c"),
    tail_recorded_at: utc,
    watch_anchor: null,
  },
  receipt: {
    receipt_id: "ceremony-probe-receipt",
    receipt_digest: sha("f"),
    journal_tail_digest: sha("e"),
    journal_id: "ceremony-probe-journal",
    binding_digest: sha("d"),
    reconciliation: "reconciled",
  },
  probe_coverage: { expected_count: 1, observed_count: 1, state: "complete" },
  reconciliation: "reconciled",
  phase: "disarm",
  outcome: "disarmed",
  health: "unhealthy",
  promotion_eligible: false,
  recovery: { state: "disarmed", reason_digest: sha("0") },
  extensions: [],
  result_digest: null,
};
deliveryProbe.result_digest = selfDigest(deliveryProbe, "result_digest");

const eligibility = {
  kind: "brokkr-maintenance-canary-eligibility",
  schema_version: "v1",
  canary_id: canary,
  target_scope_digest: targetScopeDigest,
  evaluated_at: utc,
  valid_until: later,
  eligible: true,
  non_pillar: true,
  independently_reachable: true,
  excluded_roles_verified: true,
  no_reboot_scope: true,
  evidence_digest: sha("9"),
};
const killSwitch = {
  kind: "brokkr-maintenance-kill-switch",
  schema_version: "v1",
  target_scope_digest: targetScopeDigest,
  identity: identities.kill_switch,
  safe: true,
  observed_at: utc,
  valid_until: later,
  state_digest: sha("8"),
};

const privateFiles = {
  authorization,
  constitution,
  coverage,
  ownerAttestations,
  recoveryRegistry,
  eligibility,
  killSwitch,
  deliveryCredential,
  deliveryProbe,
};
for (const [name, value] of Object.entries(privateFiles)) {
  write(`/etc/brokkr/maintenance-owner-ceremony/${name}.json`, value);
}
write(
  "/etc/brokkr/maintenance-owner-ceremony/pinned-owner-public-key.pem",
  ownerPublic,
);

const unsignedRecord = {
  kind: "brokkr-maintenance-owner-ceremony",
  schema_version: "v1",
  ceremony_id: "ceremony-one",
  decision: "approve",
  approved_at: utc,
  release_sha: revision,
  canary_id: canary,
  target_scope_digest: targetScopeDigest,
  configuration_digest: sha("7"),
  per_window_approval: "forbidden",
  authority: {
    key_id: "maintenance-owner-key",
    public_key_fingerprint: fingerprint(ownerPublic),
  },
  identities,
  units: unitNames,
  bindings: {
    release_tree_digest: null,
    authorization_digest: digestValue(authorization),
    constitution_digest: constitution.constitution_digest,
    coverage_registry_digest: coverage.registry_digest,
    owner_attestation_registry_digest: ownerAttestations.registry_digest,
    recovery_worker_registry_digest: recoveryRegistry.registry_digest,
    eligibility_digest: digestValue(eligibility),
    kill_switch_digest: digestValue(killSwitch),
    delivery_adapter_revision: adapterRevision,
    delivery_adapter_digest: sha("a"),
    delivery_credential_digest: digestValue(deliveryCredential),
    delivery_probe_digest: digestValue(deliveryProbe),
    apply_unit_digest: digestBytes(fs.readFileSync(unitFiles.apply_service)),
    recovery_unit_digest: digestBytes(fs.readFileSync(unitFiles.recovery_service)),
    delivery_unit_digest: digestBytes(fs.readFileSync(unitFiles.delivery_service)),
    scheduler_unit_digest: digestBytes(fs.readFileSync(unitFiles.scheduler_timer)),
    watchdog_unit_digest: digestBytes(fs.readFileSync(unitFiles.watchdog_timer)),
  },
  reversal: {
    kind: "revision-bound-disarm",
    action: "maintenance-owner-ceremony-transition disable",
    evidence_preserved: true,
  },
};

const systemdStates = new Map(Object.values(unitNames).map(name => [
  name, { enabled: false, active: false, result: "success" },
]));
const systemdLog = [];
const systemd = {
  isEnabled(name) { return systemdStates.get(name)?.enabled === true; },
  isActive(name) { return systemdStates.get(name)?.active === true; },
  result(name) { return systemdStates.get(name)?.result ?? "unknown"; },
  start(name) {
    systemdLog.push(`start ${name}`);
    assert.equal(name, unitNames.delivery_service);
    systemdStates.get(name).result = "success";
  },
  enableNow(name) {
    systemdLog.push(`enable-now ${name}`);
    const state = systemdStates.get(name);
    state.enabled = true;
    state.active = true;
  },
  disableNow(name) {
    const disarm = rooted(
      `/var/lib/brokkr/debian-maintenance/disarmed/${canary}.json`,
    );
    assert.equal(fs.existsSync(disarm), true,
      "disarm must be durable before any unit is stopped");
    systemdLog.push(`disable-now ${name}`);
    const state = systemdStates.get(name);
    state.enabled = false;
    state.active = false;
  },
  stop(name) {
    const disarm = rooted(
      `/var/lib/brokkr/debian-maintenance/disarmed/${canary}.json`,
    );
    assert.equal(fs.existsSync(disarm), true,
      "disarm must be durable before any unit is stopped");
    systemdLog.push(`stop ${name}`);
    systemdStates.get(name).active = false;
  },
};

unsignedRecord.bindings.release_tree_digest =
  digestValue((await import("../maintenance-owner-ceremony-transition.mjs"))
    .releaseTreeManifest(release));
const record = {
  ...unsignedRecord,
  signature: { algorithm: "Ed25519", value_base64: sign(unsignedRecord) },
};
write("/etc/brokkr/maintenance-owner-ceremony/record.json", record);
write(`/var/lib/brokkr/debian-maintenance/disarmed/${canary}.json`, {
  kind: "brokkr-debian-maintenance-canary-disarm",
  schema_version: "v1",
  canary_id: canary,
  release_sha: revision,
  recorded_at: utc,
  evidence_preserved: true,
  state_preserved: true,
});

const options = {
  rootPrefix: root,
  expectedUid: process.getuid(),
  now: utc,
  systemd,
};
const armed = armMaintenanceCanary(options);
assert.equal(armed.state, "armed-canary");
assert.deepEqual(systemdLog, [
  `start ${unitNames.delivery_service}`,
  `enable-now ${unitNames.watchdog_timer}`,
  `enable-now ${unitNames.scheduler_timer}`,
]);
assert.equal(
  fs.existsSync(rooted(`/var/lib/brokkr/debian-maintenance/disarmed/${canary}.json`)),
  false,
);
assert.equal(
  fs.existsSync(rooted(`/var/lib/brokkr/debian-maintenance/armed/${canary}.json`)),
  true,
);
const audit = fs.readFileSync(rooted(
  "/var/lib/brokkr/debian-maintenance/ceremony/transitions.jsonl",
), "utf8").trim().split("\n").map(JSON.parse);
assert.deepEqual(audit.map(entry => entry.transition), [
  "delivery-configured",
  "delivery-readback-ready",
  "watchdog-enabled",
  "scheduler-enabled",
  "canary-armed",
]);
assert.equal(audit.every(entry =>
  entry.reversal.action ===
    "maintenance-owner-ceremony-transition disable"), true);

const callsAfterArm = systemdLog.length;
assert.equal(armMaintenanceCanary(options).idempotent, true);
assert.equal(systemdLog.length, callsAfterArm,
  "exact replay must not repeat delivery or enablement");

const disabled = disableMaintenanceCanary(options);
assert.equal(disabled.state, "disarmed");
assert.equal(
  fs.existsSync(rooted(`/var/lib/brokkr/debian-maintenance/disarmed/${canary}.json`)),
  true,
);
assert.equal(
  fs.existsSync(rooted(`/var/lib/brokkr/debian-maintenance/armed/${canary}.json`)),
  false,
);
assert.equal(disableMaintenanceCanary(options).idempotent, true);

const cloneRoot = () => {
  const next = fs.mkdtempSync(path.join(os.tmpdir(), "brokkr-ceremony-fault-"));
  fs.cpSync(root, next, { recursive: true });
  fs.chmodSync(path.join(
    next, "/etc/brokkr/maintenance-owner-ceremony".slice(1),
  ), 0o700);
  fs.chmodSync(path.join(next, "/etc/credstore".slice(1)), 0o700);
  for (const absolute of [
    "/var/lib/brokkr/debian-maintenance",
    "/var/lib/brokkr/debian-maintenance/disarmed",
    "/var/lib/brokkr/debian-maintenance/armed",
    "/var/lib/brokkr/debian-maintenance/ceremony",
    "/var/lib/brokkr/debian-maintenance/evidence",
  ]) {
    fs.chmodSync(path.join(next, absolute.slice(1)), 0o700);
  }
  fs.rmSync(path.join(next,
    `/var/lib/brokkr/debian-maintenance/ceremony`.slice(1)),
  { recursive: true, force: true });
  fs.rmSync(path.join(next,
    `/var/lib/brokkr/debian-maintenance/armed`.slice(1)),
  { recursive: true, force: true });
  for (const absolute of [
    "/var/lib/brokkr/debian-maintenance/armed",
    "/var/lib/brokkr/debian-maintenance/ceremony",
  ]) {
    fs.mkdirSync(path.join(next, absolute.slice(1)), {
      recursive: true,
      mode: 0o700,
    });
    fs.chmodSync(path.join(next, absolute.slice(1)), 0o700);
  }
  writeAt(next, `/var/lib/brokkr/debian-maintenance/disarmed/${canary}.json`, {
    kind: "brokkr-debian-maintenance-canary-disarm",
    schema_version: "v1",
    canary_id: canary,
    release_sha: revision,
    recorded_at: utc,
    evidence_preserved: true,
    state_preserved: true,
  });
  return next;
};
function writeAt(base, absolute, value, mode = 0o600) {
  const file = path.join(base, absolute.slice(1));
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, `${JSON.stringify(value)}\n`, { mode });
  fs.chmodSync(file, mode);
}

for (const boundary of [
  "after-delivery-configured",
  "after-delivery-readback",
  "after-watchdog-enabled",
  "after-scheduler-enabled",
  "after-canary-armed",
]) {
  const faultRoot = cloneRoot();
  const states = new Map(Object.values(unitNames).map(name => [
    name, { enabled: false, active: false, result: "success" },
  ]));
  const mock = {
    isEnabled: name => states.get(name).enabled,
    isActive: name => states.get(name).active,
    result: name => states.get(name).result,
    start: () => {},
    enableNow: name => Object.assign(
      states.get(name), { enabled: true, active: true }),
    disableNow: name => Object.assign(
      states.get(name), { enabled: false, active: false }),
    stop: name => Object.assign(states.get(name), { active: false }),
  };
  assert.throws(() => armMaintenanceCanary({
    ...options,
    rootPrefix: faultRoot,
    systemd: mock,
    fault: step => {
      if (step === boundary) throw new Error(`fault:${boundary}`);
    },
  }), /fault:/);
  assert.equal(fs.existsSync(path.join(
    faultRoot,
    `/var/lib/brokkr/debian-maintenance/disarmed/${canary}.json`.slice(1),
  )), true, `${boundary} must leave durable disarm`);
  assert.equal(states.get(unitNames.scheduler_timer).enabled, false);
  assert.equal(states.get(unitNames.watchdog_timer).enabled, false);
  fs.rmSync(faultRoot, { recursive: true, force: true });
}

const tampered = structuredClone(record);
tampered.release_sha = "3".repeat(40);
write("/etc/brokkr/maintenance-owner-ceremony/record.json", tampered);
assert.throws(() => armMaintenanceCanary(options),
  /ceremony_signature_invalid/);
write("/etc/brokkr/maintenance-owner-ceremony/record.json", record);

const stale = structuredClone(eligibility);
stale.valid_until = utc;
write("/etc/brokkr/maintenance-owner-ceremony/eligibility.json", stale);
assert.throws(() => armMaintenanceCanary(options),
  /eligibility_binding_mismatch|eligibility_stale/);
write("/etc/brokkr/maintenance-owner-ceremony/eligibility.json", eligibility);

function isolatedStates() {
  return new Map(Object.values(unitNames).map(name => [
    name, { enabled: false, active: false, result: "success" },
  ]));
}
function isolatedSystemd(states, overrides = {}) {
  return {
    isEnabled: name => states.get(name).enabled,
    isActive: name => states.get(name).active,
    result: name => states.get(name).result,
    start: () => {},
    enableNow: name => Object.assign(
      states.get(name), { enabled: true, active: true }),
    disableNow: name => Object.assign(
      states.get(name), { enabled: false, active: false }),
    stop: name => Object.assign(states.get(name), { active: false }),
    ...overrides,
  };
}

{
  const unsafeRoot = cloneRoot();
  fs.appendFileSync(path.join(
    unsafeRoot,
    `/etc/systemd/system/${unitNames.scheduler_timer}`.slice(1),
  ), "# drift\n");
  assert.throws(() => armMaintenanceCanary({
    ...options,
    rootPrefix: unsafeRoot,
    systemd: isolatedSystemd(isolatedStates()),
  }), /unit_binding_mismatch/);
  fs.rmSync(unsafeRoot, { recursive: true, force: true });
}

{
  const wrongAuthorityRoot = cloneRoot();
  const file = path.join(
    wrongAuthorityRoot,
    "/etc/brokkr/maintenance-owner-ceremony/authorization.json".slice(1),
  );
  const wrong = JSON.parse(fs.readFileSync(file, "utf8"));
  wrong.authorization_id = "wrong-authorization";
  fs.writeFileSync(file, `${JSON.stringify(wrong)}\n`, { mode: 0o600 });
  assert.throws(() => armMaintenanceCanary({
    ...options,
    rootPrefix: wrongAuthorityRoot,
    systemd: isolatedSystemd(isolatedStates()),
  }), /authorization_binding_mismatch/);
  fs.rmSync(wrongAuthorityRoot, { recursive: true, force: true });
}

{
  const unsafeStateRoot = cloneRoot();
  const states = isolatedStates();
  states.get(unitNames.scheduler_timer).enabled = true;
  assert.throws(() => armMaintenanceCanary({
    ...options,
    rootPrefix: unsafeStateRoot,
    systemd: isolatedSystemd(states),
  }), /partial_transition_recovered_disarmed/);
  assert.equal(states.get(unitNames.scheduler_timer).enabled, false);
  fs.rmSync(unsafeStateRoot, { recursive: true, force: true });
}

for (const failure of ["delivery", "watchdog", "scheduler"]) {
  const failedRoot = cloneRoot();
  const states = isolatedStates();
  const base = isolatedSystemd(states);
  const mock = isolatedSystemd(states, failure === "delivery" ? {
    start: name => { states.get(name).result = "failed"; },
  } : {
    enableNow: name => {
      if ((failure === "watchdog" &&
          name === unitNames.watchdog_timer) ||
          (failure === "scheduler" &&
          name === unitNames.scheduler_timer)) return;
      base.enableNow(name);
    },
  });
  assert.throws(() => armMaintenanceCanary({
    ...options,
    rootPrefix: failedRoot,
    systemd: mock,
  }), failure === "delivery" ?
    /delivery_readback_failed/ :
    new RegExp(`${failure}_readback_failed`));
  assert.equal(fs.existsSync(path.join(
    failedRoot,
    `/var/lib/brokkr/debian-maintenance/disarmed/${canary}.json`.slice(1),
  )), true);
  assert.equal(states.get(unitNames.scheduler_timer).enabled, false);
  assert.equal(states.get(unitNames.watchdog_timer).enabled, false);
  fs.rmSync(failedRoot, { recursive: true, force: true });
}

console.log("ok - exact owner ceremony arms last, replays idempotently, and fails closed");
