#!/usr/bin/env node
// Revision-bound, owner-authorized transition from inert maintenance artifacts
// to one scheduled canary. Publication/installers stay inert; this separate
// ceremony consumes only protected, signed, exact bindings and arms last.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const DOMAIN = "no-reboot-security-bugfix-maintenance";
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const SHA = /^[a-f0-9]{40}$/;
const DIGEST = /^sha256:[a-f0-9]{64}$/;
const UTC = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const MAX_JSON_BYTES = 256 * 1024;
const CREDENTIAL_NAME = "brokkr-maintenance-result-delivery-v1";
const CEREMONY_PATH = "/etc/brokkr/maintenance-owner-ceremony";
const STATE_PATH = "/var/lib/brokkr/debian-maintenance";
const UNIT_PATH = "/etc/systemd/system";

const fail = code => {
  const error = new Error(code);
  error.code = code;
  throw error;
};
const plain = value =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const exact = (value, keys) =>
  plain(value) &&
  Object.keys(value).sort().join(",") === [...keys].sort().join(",");
const strictUtc = value => {
  if (typeof value !== "string" || !UTC.test(value)) return false;
  const parsed = new Date(value);
  return !Number.isNaN(parsed.getTime()) &&
    parsed.toISOString().replace(".000Z", "Z") === value;
};

export const canonicalJson = value =>
  value === null || typeof value !== "object" ? JSON.stringify(value) :
    Array.isArray(value) ?
      `[${value.map(canonicalJson).join(",")}]` :
      `{${Object.keys(value).sort().map(key =>
        `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
export const digestBytes = value =>
  `sha256:${crypto.createHash("sha256").update(value).digest("hex")}`;
export const digestValue = value =>
  digestBytes(Buffer.from(canonicalJson(value)));
const selfDigest = (value, field) => {
  const copy = structuredClone(value);
  delete copy[field];
  return digestValue(copy);
};

export function releaseTreeManifest(root) {
  const visit = (directory, relative = "") => {
    const entries = fs.readdirSync(directory).sort();
    return entries.flatMap(entry => {
      const childRelative = relative === "" ? entry :
        path.posix.join(relative, entry);
      const child = path.join(directory, entry);
      const stat = fs.lstatSync(child);
      if (stat.isSymbolicLink() ||
          (!stat.isDirectory() && !stat.isFile()) ||
          stat.uid !== process.geteuid() || (stat.mode & 0o022) !== 0) {
        fail("release_tree_unsafe");
      }
      const item = {
        path: childRelative,
        type: stat.isDirectory() ? "directory" : "file",
        mode: stat.mode & 0o7777,
        digest: stat.isFile() ? digestBytes(fs.readFileSync(child)) : null,
      };
      return stat.isDirectory() ?
        [item, ...visit(child, childRelative)] : [item];
    });
  };
  const stat = fs.lstatSync(root);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      stat.uid !== process.geteuid() || (stat.mode & 0o022) !== 0) {
    fail("release_tree_unsafe");
  }
  return visit(root);
}

const rooted = (rootPrefix, absolute) => {
  if (!path.isAbsolute(absolute)) fail("ceremony_internal_path_invalid");
  return rootPrefix === "" ? absolute :
    path.join(rootPrefix, absolute.slice(1));
};
const ensureProtectedDirectory = (directory, expectedUid, create = false) => {
  if (create) fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      stat.uid !== expectedUid || (stat.mode & 0o077) !== 0) {
    fail("ceremony_directory_unsafe");
  }
};
const readProtected = (file, expectedUid, asJson = true) => {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== expectedUid ||
        ![0o400, 0o600].includes(stat.mode & 0o7777) ||
        stat.size < 1 || stat.size > MAX_JSON_BYTES) {
      fail("ceremony_input_unsafe");
    }
    const bytes = fs.readFileSync(fd);
    if (!asJson) return bytes;
    try {
      return JSON.parse(bytes.toString("utf8"));
    } catch {
      fail("ceremony_input_invalid");
    }
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
};
const atomicWrite = (file, value, mode = 0o600) => {
  const directory = path.dirname(file);
  ensureProtectedDirectory(directory, process.geteuid());
  try {
    const existing = fs.lstatSync(file);
    if (!existing.isFile() || existing.isSymbolicLink() ||
        existing.uid !== process.geteuid() ||
        (existing.mode & 0o077) !== 0) {
      fail("ceremony_destination_unsafe");
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const temporary =
    `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  const bytes = Buffer.isBuffer(value) ? value :
    Buffer.from(`${canonicalJson(value)}\n`);
  let fd;
  try {
    fd = fs.openSync(temporary, "wx", mode);
    fs.writeFileSync(fd, bytes);
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    fs.renameSync(temporary, file);
    const directoryFd = fs.openSync(directory, "r");
    try {
      fs.fsyncSync(directoryFd);
    } finally {
      fs.closeSync(directoryFd);
    }
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    try {
      fs.unlinkSync(temporary);
    } catch {
      // Only the unique, unpublished temporary may be removed.
    }
  }
};
const appendAudit = (file, entry) => {
  const directory = path.dirname(file);
  ensureProtectedDirectory(directory, process.geteuid());
  const fd = fs.openSync(
    file,
    fs.constants.O_WRONLY | fs.constants.O_APPEND |
      fs.constants.O_CREAT | fs.constants.O_NOFOLLOW,
    0o600,
  );
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.geteuid() ||
        (stat.mode & 0o077) !== 0) fail("ceremony_audit_unsafe");
    fs.writeSync(fd, `${canonicalJson(entry)}\n`);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  const directoryFd = fs.openSync(directory, "r");
  try {
    fs.fsyncSync(directoryFd);
  } finally {
    fs.closeSync(directoryFd);
  }
};

function assertRecord(record) {
  if (!exact(record, [
    "kind", "schema_version", "ceremony_id", "decision", "approved_at",
    "release_sha", "canary_id", "target_scope_digest",
    "configuration_digest", "per_window_approval", "authority",
    "identities", "units", "bindings", "reversal", "signature",
  ]) ||
      record.kind !== "brokkr-maintenance-owner-ceremony" ||
      record.schema_version !== "v1" || !ID.test(record.ceremony_id) ||
      record.decision !== "approve" || !strictUtc(record.approved_at) ||
      !SHA.test(record.release_sha) || !ID.test(record.canary_id) ||
      !DIGEST.test(record.target_scope_digest) ||
      !DIGEST.test(record.configuration_digest) ||
      record.per_window_approval !== "forbidden") {
    fail("ceremony_record_invalid");
  }
  if (!exact(record.authority, ["key_id", "public_key_fingerprint"]) ||
      !ID.test(record.authority.key_id) ||
      !DIGEST.test(record.authority.public_key_fingerprint) ||
      !exact(record.identities, [
        "owner", "controller", "watchdog", "kill_switch", "recovery_worker",
      ]) ||
      Object.values(record.identities).some(value => !ID.test(value)) ||
      new Set(Object.values(record.identities)).size !== 5) {
    fail("ceremony_authority_invalid");
  }
  if (!exact(record.units, [
    "apply_service", "recovery_service", "delivery_service",
    "scheduler_timer", "watchdog_timer",
  ])) fail("ceremony_units_invalid");
  const expectedUnits = {
    apply_service:
      `brokkr-debian-maintenance-canary-${record.canary_id}.service`,
    recovery_service:
      `brokkr-debian-maintenance-recovery-${record.canary_id}.service`,
    delivery_service:
      "brokkr-maintenance-execution-result-delivery.service",
    scheduler_timer:
      `brokkr-debian-maintenance-scheduler-${record.canary_id}.timer`,
    watchdog_timer:
      `brokkr-debian-maintenance-watchdog-${record.canary_id}.timer`,
  };
  if (canonicalJson(record.units) !== canonicalJson(expectedUnits)) {
    fail("ceremony_units_invalid");
  }
  const bindingKeys = [
    "release_tree_digest", "authorization_digest",
    "constitution_digest", "coverage_registry_digest",
    "owner_attestation_registry_digest", "recovery_worker_registry_digest",
    "eligibility_digest", "kill_switch_digest",
    "delivery_adapter_revision", "delivery_adapter_digest",
    "delivery_credential_digest", "delivery_probe_digest",
    "apply_unit_digest", "recovery_unit_digest", "delivery_unit_digest",
    "scheduler_unit_digest", "watchdog_unit_digest",
  ];
  if (!exact(record.bindings, bindingKeys) ||
      !SHA.test(record.bindings.delivery_adapter_revision) ||
      Object.entries(record.bindings).some(([key, value]) =>
        key !== "delivery_adapter_revision" && !DIGEST.test(value))) {
    fail("ceremony_bindings_invalid");
  }
  if (!exact(record.reversal, [
    "kind", "action", "evidence_preserved",
  ]) ||
      record.reversal.kind !== "revision-bound-disarm" ||
      record.reversal.action !==
        "maintenance-owner-ceremony-transition disable" ||
      record.reversal.evidence_preserved !== true ||
      !exact(record.signature, ["algorithm", "value_base64"]) ||
      record.signature.algorithm !== "Ed25519" ||
      typeof record.signature.value_base64 !== "string") {
    fail("ceremony_record_invalid");
  }
}

function verifySignature(value, key, code) {
  const unsigned = structuredClone(value);
  const signature = unsigned.signature;
  delete unsigned.signature;
  if (!plain(signature) || signature.algorithm !== "Ed25519" ||
      typeof signature.value_base64 !== "string" ||
      !crypto.verify(
        null,
        Buffer.from(canonicalJson(unsigned)),
        key,
        Buffer.from(signature.value_base64, "base64"),
      )) fail(code);
}
const keyFingerprint = key =>
  digestBytes(key.export({ type: "spki", format: "der" }));

function verifyOwnerInputs({
  record, sourceDirectory, expectedUid, now,
}) {
  const pinnedKeyBytes = readProtected(
    path.join(sourceDirectory, "pinned-owner-public-key.pem"),
    expectedUid,
    false,
  );
  let pinnedKey;
  try {
    pinnedKey = crypto.createPublicKey(pinnedKeyBytes);
  } catch {
    fail("owner_key_invalid");
  }
  if (pinnedKey.asymmetricKeyType !== "ed25519" ||
      keyFingerprint(pinnedKey) !==
        record.authority.public_key_fingerprint) {
    fail("owner_key_invalid");
  }
  verifySignature(record, pinnedKey, "ceremony_signature_invalid");

  const read = name =>
    readProtected(path.join(sourceDirectory, `${name}.json`), expectedUid);
  const authorization = read("authorization");
  const constitution = read("constitution");
  const coverage = read("coverage");
  const ownerAttestations = read("ownerAttestations");
  const recoveryRegistry = read("recoveryRegistry");
  const eligibility = read("eligibility");
  const killSwitch = read("killSwitch");
  const deliveryCredential = read("deliveryCredential");
  const deliveryProbe = read("deliveryProbe");

  if (digestValue(authorization) !==
      record.bindings.authorization_digest ||
      !exact(authorization, [
        "kind", "schema_version", "authorization_id",
        "authorization_sequence", "previous_authorization_digest",
        "issued_at", "authority", "bindings", "signature",
      ]) ||
      authorization.kind !== "autonomy-owner-authorization" ||
      authorization.schema_version !== "v1" ||
      authorization.authority.public_key_fingerprint !==
        record.authority.public_key_fingerprint) {
    fail("authorization_binding_mismatch");
  }
  let authorizationKey;
  try {
    authorizationKey =
      crypto.createPublicKey(authorization.authority.public_key_pem);
  } catch {
    fail("authorization_invalid");
  }
  if (!authorizationKey.export({ type: "spki", format: "der" })
    .equals(pinnedKey.export({ type: "spki", format: "der" }))) {
    fail("authorization_invalid");
  }
  verifySignature(
    authorization,
    authorizationKey,
    "authorization_signature_invalid",
  );

  for (const [value, field, expected, code] of [
    [constitution, "constitution_digest",
      record.bindings.constitution_digest, "constitution_binding_mismatch"],
    [coverage, "registry_digest",
      record.bindings.coverage_registry_digest, "coverage_binding_mismatch"],
    [ownerAttestations, "registry_digest",
      record.bindings.owner_attestation_registry_digest,
      "attestation_binding_mismatch"],
    [recoveryRegistry, "registry_digest",
      record.bindings.recovery_worker_registry_digest,
      "recovery_registry_binding_mismatch"],
  ]) {
    if (value[field] !== expected ||
        selfDigest(value, field) !== expected) fail(code);
  }
  if (!plain(authorization.bindings) ||
      authorization.bindings.constitution_digest !==
        record.bindings.constitution_digest ||
      authorization.bindings.coverage_intent_digest !==
        record.bindings.coverage_registry_digest ||
      authorization.bindings.owner_attestation_registry_digest !==
        record.bindings.owner_attestation_registry_digest ||
      authorization.bindings.recovery_worker_registry_digest !==
        record.bindings.recovery_worker_registry_digest) {
    fail("authorization_binding_mismatch");
  }
  const policyRows = constitution.autonomous_classes?.filter(row =>
    row.class === DOMAIN) ?? [];
  if (policyRows.length !== 1 || policyRows[0].owner !== "brokkr" ||
      policyRows[0].recovery_class !== "R-forward" ||
      policyRows[0].bounds?.max_concurrent_targets !== 1 ||
      policyRows[0].bounds?.max_attempts !== 1 ||
      policyRows[0].bounds?.trusted_watchdog_time_required !== true) {
    fail("constitution_scope_invalid");
  }
  const domainRows = coverage.domains?.filter(row =>
    row.domain === DOMAIN) ?? [];
  const bindings = domainRows[0]?.bindings?.filter(binding =>
    binding.target_scope_digest === record.target_scope_digest) ?? [];
  if (coverage.global_state !== "armed" || domainRows.length !== 1 ||
      domainRows[0].owner !== "brokkr" ||
      domainRows[0].recovery_class !== "R-forward" ||
      domainRows[0].coverage !== "armed-canary" ||
      domainRows[0].target_state !== "armed-canary" ||
      bindings.length !== 1 ||
      bindings[0].state !== "armed-canary" ||
      bindings[0].writer_owner !== "brokkr" ||
      bindings[0].configuration_owner !== "brokkr" ||
      canonicalJson(bindings[0].identities) !==
        canonicalJson(record.identities)) {
    fail("coverage_scope_invalid");
  }
  const attestations = ownerAttestations.attestations?.filter(item =>
    item.domain === DOMAIN &&
    item.target_scope_digest === record.target_scope_digest &&
    item.configuration_owner === "brokkr") ?? [];
  if (attestations.length !== 1) fail("attestation_scope_invalid");
  const recoveryEntries = recoveryRegistry.entries?.filter(item =>
    item.domain === DOMAIN &&
    item.target_scope_digest === record.target_scope_digest &&
    item.recovery_worker_identity ===
      record.identities.recovery_worker) ?? [];
  if (recoveryEntries.length !== 1 ||
      recoveryEntries[0].public_key_fingerprint !==
        keyFingerprint(crypto.createPublicKey(
          recoveryEntries[0].public_key_pem,
        ))) fail("recovery_registry_scope_invalid");

  if (digestValue(eligibility) !== record.bindings.eligibility_digest) {
    fail("eligibility_binding_mismatch");
  }
  if (!exact(eligibility, [
    "kind", "schema_version", "canary_id", "target_scope_digest",
    "evaluated_at", "valid_until", "eligible", "non_pillar",
    "independently_reachable", "excluded_roles_verified",
    "no_reboot_scope", "evidence_digest",
  ]) ||
      eligibility.kind !== "brokkr-maintenance-canary-eligibility" ||
      eligibility.schema_version !== "v1" ||
      eligibility.canary_id !== record.canary_id ||
      eligibility.target_scope_digest !== record.target_scope_digest ||
      !strictUtc(eligibility.evaluated_at) ||
      !strictUtc(eligibility.valid_until) ||
      Date.parse(eligibility.evaluated_at) > Date.parse(now) ||
      Date.parse(now) >= Date.parse(eligibility.valid_until) ||
      eligibility.eligible !== true ||
      eligibility.non_pillar !== true ||
      eligibility.independently_reachable !== true ||
      eligibility.excluded_roles_verified !== true ||
      eligibility.no_reboot_scope !== true ||
      !DIGEST.test(eligibility.evidence_digest)) {
    fail("eligibility_stale");
  }
  if (digestValue(killSwitch) !== record.bindings.kill_switch_digest) {
    fail("kill_switch_binding_mismatch");
  }
  if (!exact(killSwitch, [
    "kind", "schema_version", "target_scope_digest", "identity",
    "safe", "observed_at", "valid_until", "state_digest",
  ]) ||
      killSwitch.kind !== "brokkr-maintenance-kill-switch" ||
      killSwitch.schema_version !== "v1" ||
      killSwitch.target_scope_digest !== record.target_scope_digest ||
      killSwitch.identity !== record.identities.kill_switch ||
      killSwitch.safe !== true ||
      !strictUtc(killSwitch.observed_at) ||
      !strictUtc(killSwitch.valid_until) ||
      Date.parse(killSwitch.observed_at) > Date.parse(now) ||
      Date.parse(now) >= Date.parse(killSwitch.valid_until) ||
      !DIGEST.test(killSwitch.state_digest)) {
    fail("kill_switch_unsafe");
  }
  if (digestValue(deliveryCredential) !==
      record.bindings.delivery_credential_digest ||
      deliveryCredential.kind !==
        "brokkr-maintenance-result-delivery-config" ||
      deliveryCredential.schema_version !== "v1" ||
      deliveryCredential.enabled !== true ||
      deliveryCredential.adapter_revision !==
        record.bindings.delivery_adapter_revision ||
      deliveryCredential.adapter_digest !==
        record.bindings.delivery_adapter_digest) {
    fail("delivery_configuration_invalid");
  }
  if (digestValue(deliveryProbe) !==
      record.bindings.delivery_probe_digest ||
      deliveryProbe.kind !== "maintenance-execution-result" ||
      deliveryProbe.schema_version !== "v1" ||
      deliveryProbe.source?.source_id !== "brokkr-maintenance" ||
      deliveryProbe.phase !== "disarm" ||
      deliveryProbe.outcome !== "disarmed" ||
      deliveryProbe.health !== "unhealthy" ||
      deliveryProbe.promotion_eligible !== false ||
      deliveryProbe.result_digest !==
        selfDigest(deliveryProbe, "result_digest")) {
    fail("delivery_probe_invalid");
  }
  return { deliveryCredential, deliveryProbe };
}

function verifyInstalledArtifacts({
  record, rootPrefix, expectedUid, systemd, requireDisabled = true,
}) {
  const release = rooted(
    rootPrefix,
    `/usr/local/lib/brokkr/releases/${record.release_sha}`,
  );
  if (digestValue(releaseTreeManifest(release)) !==
      record.bindings.release_tree_digest) fail("release_binding_mismatch");
  const roleToDigest = {
    apply_service: "apply_unit_digest",
    recovery_service: "recovery_unit_digest",
    delivery_service: "delivery_unit_digest",
    scheduler_timer: "scheduler_unit_digest",
    watchdog_timer: "watchdog_unit_digest",
  };
  for (const [role, digestField] of Object.entries(roleToDigest)) {
    const unit = record.units[role];
    const file = rooted(rootPrefix, `${UNIT_PATH}/${unit}`);
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() ||
        stat.uid !== expectedUid || (stat.mode & 0o7777) !== 0o644) {
      fail("unit_file_unsafe");
    }
    const bytes = fs.readFileSync(file);
    if (digestBytes(bytes) !== record.bindings[digestField]) {
      fail("unit_binding_mismatch");
    }
    const text = bytes.toString("utf8");
    if (role !== "delivery_service" &&
        !text.includes(
          `Environment=BROKKR_RELEASE_SHA=${record.release_sha}`,
        )) fail("unit_release_binding_mismatch");
    if (role === "delivery_service" &&
        (!text.includes(
          `Environment=BROKKR_ADAPTER_REVISION=${record.bindings.delivery_adapter_revision}`,
        ) ||
        !text.includes(
          `Environment=BROKKR_ADAPTER_DIGEST=${record.bindings.delivery_adapter_digest}`,
        ))) fail("delivery_adapter_binding_mismatch");
  }
  if (requireDisabled) {
    for (const role of [
      "apply_service", "recovery_service", "scheduler_timer", "watchdog_timer",
    ]) {
      const unit = record.units[role];
      if (systemd.isEnabled(unit) || systemd.isActive(unit)) {
        fail("unit_not_disabled");
      }
    }
    if (systemd.isActive(record.units.delivery_service)) {
      fail("delivery_unit_active");
    }
  }
}

const disarmValue = (record, at, reason) => ({
  kind: "brokkr-debian-maintenance-canary-disarm",
  schema_version: "v1",
  canary_id: record.canary_id,
  release_sha: record.release_sha,
  recorded_at: at,
  reason,
  evidence_preserved: true,
  state_preserved: true,
});
const durableBinding = (record, recordDigest, at, state) => ({
  kind: "brokkr-maintenance-owner-ceremony-state",
  schema_version: "v1",
  ceremony_id: record.ceremony_id,
  ceremony_digest: recordDigest,
  release_sha: record.release_sha,
  canary_id: record.canary_id,
  target_scope_digest: record.target_scope_digest,
  configuration_digest: record.configuration_digest,
  delivery_adapter_revision:
    record.bindings.delivery_adapter_revision,
  delivery_adapter_digest: record.bindings.delivery_adapter_digest,
  units: record.units,
  state,
  recorded_at: at,
  evidence_preserved: true,
  reversal: record.reversal,
});

function disableCredential(rootPrefix, record) {
  ensureProtectedDirectory(
    rooted(rootPrefix, "/etc/credstore"),
    process.geteuid(),
    true,
  );
  const destination = rooted(
    rootPrefix,
    `/etc/credstore/${CREDENTIAL_NAME}`,
  );
  atomicWrite(destination, {
    kind: "brokkr-maintenance-result-delivery-config",
    schema_version: "v1",
    enabled: false,
    adapter_revision: record.bindings.delivery_adapter_revision,
    adapter_digest: record.bindings.delivery_adapter_digest,
  });
}

function failSafeDisarm({
  rootPrefix, record, recordDigest, now, systemd, auditFile, reason,
}) {
  for (const relative of ["disarmed", "armed", "ceremony"]) {
    ensureProtectedDirectory(
      rooted(rootPrefix, `${STATE_PATH}/${relative}`),
      process.geteuid(),
    );
  }
  const disarmed = rooted(
    rootPrefix,
    `${STATE_PATH}/disarmed/${record.canary_id}.json`,
  );
  const armed = rooted(
    rootPrefix,
    `${STATE_PATH}/armed/${record.canary_id}.json`,
  );
  atomicWrite(disarmed, disarmValue(record, now, reason));
  try {
    fs.unlinkSync(armed);
    const directoryFd = fs.openSync(path.dirname(armed), "r");
    try {
      fs.fsyncSync(directoryFd);
    } finally {
      fs.closeSync(directoryFd);
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  let systemdFailed = false;
  for (const role of ["scheduler_timer", "watchdog_timer"]) {
    try {
      systemd.disableNow(record.units[role]);
    } catch {
      systemdFailed = true;
    }
  }
  for (const role of ["apply_service", "recovery_service"]) {
    try {
      systemd.stop(record.units[role]);
    } catch {
      systemdFailed = true;
    }
  }
  disableCredential(rootPrefix, record);
  appendAudit(auditFile, {
    kind: "brokkr-maintenance-owner-ceremony-transition",
    schema_version: "v1",
    ceremony_id: record.ceremony_id,
    ceremony_digest: recordDigest,
    release_sha: record.release_sha,
    canary_id: record.canary_id,
    target_scope_digest: record.target_scope_digest,
    transition: "canary-disarmed",
    state: systemdFailed ? "disarmed-unit-stop-failed" : "disarmed",
    reason_digest: digestBytes(Buffer.from(reason)),
    recorded_at: now,
    evidence_preserved: true,
    reversal: record.reversal,
  });
  if (systemdFailed) fail("disarm_persisted_systemd_failed");
}

function loadContext(options) {
  const rootPrefix = options.rootPrefix ?? "";
  if (rootPrefix !== "" &&
      (!path.isAbsolute(rootPrefix) || rootPrefix === "/")) {
    fail("test_root_invalid");
  }
  const expectedUid = options.expectedUid ?? process.geteuid();
  const now = options.now ?? new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  if (!strictUtc(now)) fail("trusted_time_invalid");
  const sourceDirectory = rooted(rootPrefix, CEREMONY_PATH);
  ensureProtectedDirectory(sourceDirectory, expectedUid);
  const record = readProtected(
    path.join(sourceDirectory, "record.json"),
    expectedUid,
  );
  assertRecord(record);
  const recordDigest = digestValue(record);
  return {
    rootPrefix, expectedUid, now, sourceDirectory, record, recordDigest,
    systemd: options.systemd,
    fault: options.fault ?? (() => {}),
    auditFile: rooted(
      rootPrefix,
      `${STATE_PATH}/ceremony/transitions.jsonl`,
    ),
  };
}

export function armMaintenanceCanary(options) {
  const context = loadContext(options);
  const {
    rootPrefix, expectedUid, now, sourceDirectory, record, recordDigest,
    systemd, fault, auditFile,
  } = context;
  if (!systemd) fail("systemd_adapter_missing");
  for (const relative of [
    "", "disarmed", "armed", "ceremony", "evidence",
  ]) {
    ensureProtectedDirectory(
      rooted(
        rootPrefix,
        relative === "" ? STATE_PATH : `${STATE_PATH}/${relative}`,
      ),
      expectedUid,
    );
  }
  const privateInputs = verifyOwnerInputs({
    record, sourceDirectory, expectedUid, now,
  });
  const armedPath = rooted(
    rootPrefix,
    `${STATE_PATH}/armed/${record.canary_id}.json`,
  );
  const disarmedPath = rooted(
    rootPrefix,
    `${STATE_PATH}/disarmed/${record.canary_id}.json`,
  );
  if (fs.existsSync(armedPath) && !fs.existsSync(disarmedPath)) {
    verifyInstalledArtifacts({
      record, rootPrefix, expectedUid, systemd, requireDisabled: false,
    });
    const active = readProtected(armedPath, expectedUid);
    if (active.ceremony_digest !== recordDigest ||
        active.release_sha !== record.release_sha ||
        active.target_scope_digest !== record.target_scope_digest ||
        active.state !== "armed-canary" ||
        !systemd.isEnabled(record.units.scheduler_timer) ||
        !systemd.isActive(record.units.scheduler_timer) ||
        !systemd.isEnabled(record.units.watchdog_timer) ||
        !systemd.isActive(record.units.watchdog_timer) ||
        systemd.result(record.units.delivery_service) !== "success") {
      fail("armed_readback_mismatch");
    }
    let armAuditPresent = false;
    try {
      armAuditPresent = fs.readFileSync(auditFile, "utf8")
        .trim().split("\n").filter(Boolean).map(JSON.parse).some(entry =>
          entry.ceremony_digest === recordDigest &&
          entry.transition === "canary-armed");
    } catch (error) {
      if (error.code !== "ENOENT") fail("ceremony_audit_invalid");
    }
    if (!armAuditPresent) {
      appendAudit(auditFile, {
        ...active,
        transition: "canary-armed",
        replay_repaired: true,
      });
    }
    return {
      kind: "brokkr-maintenance-owner-ceremony-result",
      schema_version: "v1",
      ceremony_id: record.ceremony_id,
      state: "armed-canary",
      idempotent: true,
    };
  }
  let publishedDeliveryEnabled = false;
  const publishedCredential = rooted(
    rootPrefix,
    `/etc/credstore/${CREDENTIAL_NAME}`,
  );
  try {
    const credential = readProtected(publishedCredential, expectedUid);
    publishedDeliveryEnabled = credential?.enabled === true;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const partialTransition = fs.existsSync(disarmedPath) && (
    publishedDeliveryEnabled ||
    systemd.isEnabled(record.units.scheduler_timer) ||
    systemd.isActive(record.units.scheduler_timer) ||
    systemd.isEnabled(record.units.watchdog_timer) ||
    systemd.isActive(record.units.watchdog_timer) ||
    systemd.isActive(record.units.apply_service) ||
    systemd.isActive(record.units.recovery_service)
  );
  if (partialTransition) {
    failSafeDisarm({
      rootPrefix, record, recordDigest, now, systemd, auditFile,
      reason: "partial-transition-recovered",
    });
    fail("partial_transition_recovered_disarmed");
  }
  verifyInstalledArtifacts({
    record, rootPrefix, expectedUid, systemd,
  });
  if (!fs.existsSync(disarmedPath) || fs.existsSync(armedPath)) {
    fail("initial_disarm_missing");
  }
  const existingDisarm = readProtected(disarmedPath, expectedUid);
  if (existingDisarm.canary_id !== record.canary_id ||
      existingDisarm.release_sha !== record.release_sha ||
      existingDisarm.evidence_preserved !== true ||
      existingDisarm.state_preserved !== true) {
    fail("initial_disarm_invalid");
  }
  let transitionStarted = false;
  try {
    transitionStarted = true;
    ensureProtectedDirectory(
      rooted(rootPrefix, "/etc/credstore"),
      expectedUid,
      true,
    );
    const credential = rooted(
      rootPrefix,
      `/etc/credstore/${CREDENTIAL_NAME}`,
    );
    atomicWrite(
      credential,
      Buffer.from(`${canonicalJson(privateInputs.deliveryCredential)}\n`),
    );
    appendAudit(auditFile, {
      ...durableBinding(record, recordDigest, now, "transitioning"),
      transition: "delivery-configured",
    });
    fault("after-delivery-configured");

    atomicWrite(
      rooted(
        rootPrefix,
        `${STATE_PATH}/evidence/maintenance-execution-result.json`,
      ),
      Buffer.from(`${canonicalJson(privateInputs.deliveryProbe)}\n`),
    );
    systemd.start(record.units.delivery_service);
    if (systemd.result(record.units.delivery_service) !== "success") {
      fail("delivery_readback_failed");
    }
    appendAudit(auditFile, {
      ...durableBinding(record, recordDigest, now, "transitioning"),
      transition: "delivery-readback-ready",
    });
    fault("after-delivery-readback");

    systemd.enableNow(record.units.watchdog_timer);
    if (!systemd.isEnabled(record.units.watchdog_timer) ||
        !systemd.isActive(record.units.watchdog_timer)) {
      fail("watchdog_readback_failed");
    }
    appendAudit(auditFile, {
      ...durableBinding(record, recordDigest, now, "transitioning"),
      transition: "watchdog-enabled",
    });
    fault("after-watchdog-enabled");

    systemd.enableNow(record.units.scheduler_timer);
    if (!systemd.isEnabled(record.units.scheduler_timer) ||
        !systemd.isActive(record.units.scheduler_timer)) {
      fail("scheduler_readback_failed");
    }
    appendAudit(auditFile, {
      ...durableBinding(record, recordDigest, now, "transitioning"),
      transition: "scheduler-enabled",
    });
    fault("after-scheduler-enabled");

    if (systemd.result(record.units.delivery_service) !== "success" ||
        !systemd.isEnabled(record.units.scheduler_timer) ||
        !systemd.isActive(record.units.scheduler_timer) ||
        !systemd.isEnabled(record.units.watchdog_timer) ||
        !systemd.isActive(record.units.watchdog_timer)) {
      fail("final_readback_failed");
    }
    const armed = durableBinding(
      record,
      recordDigest,
      now,
      "armed-canary",
    );
    atomicWrite(armedPath, armed);
    fs.unlinkSync(disarmedPath);
    const stateDirectory = fs.openSync(path.dirname(disarmedPath), "r");
    try {
      fs.fsyncSync(stateDirectory);
    } finally {
      fs.closeSync(stateDirectory);
    }
    appendAudit(auditFile, { ...armed, transition: "canary-armed" });
    fault("after-canary-armed");
    return {
      kind: "brokkr-maintenance-owner-ceremony-result",
      schema_version: "v1",
      ceremony_id: record.ceremony_id,
      state: "armed-canary",
      idempotent: false,
    };
  } catch (error) {
    if (transitionStarted) {
      failSafeDisarm({
        rootPrefix, record, recordDigest, now, systemd, auditFile,
        reason: String(error.code ?? error.message ?? "transition-failed"),
      });
    }
    throw error;
  }
}

export function disableMaintenanceCanary(options) {
  const context = loadContext(options);
  const {
    rootPrefix, expectedUid, now, record, recordDigest, systemd, auditFile,
  } = context;
  if (!systemd) fail("systemd_adapter_missing");
  const disarmedPath = rooted(
    rootPrefix,
    `${STATE_PATH}/disarmed/${record.canary_id}.json`,
  );
  const armedPath = rooted(
    rootPrefix,
    `${STATE_PATH}/armed/${record.canary_id}.json`,
  );
  const credentialPath = rooted(
    rootPrefix,
    `/etc/credstore/${CREDENTIAL_NAME}`,
  );
  let credentialDisabled = true;
  try {
    const credential = readProtected(credentialPath, expectedUid);
    credentialDisabled =
      credential?.kind ===
        "brokkr-maintenance-result-delivery-config" &&
      credential?.schema_version === "v1" &&
      credential?.enabled === false &&
      credential?.adapter_revision ===
        record.bindings.delivery_adapter_revision &&
      credential?.adapter_digest ===
        record.bindings.delivery_adapter_digest;
  } catch (error) {
    if (error.code !== "ENOENT") credentialDisabled = false;
  }
  const alreadyDisarmed = fs.existsSync(disarmedPath) &&
    !fs.existsSync(armedPath) &&
    !systemd.isActive(record.units.apply_service) &&
    !systemd.isActive(record.units.recovery_service) &&
    !systemd.isEnabled(record.units.scheduler_timer) &&
    !systemd.isActive(record.units.scheduler_timer) &&
    !systemd.isEnabled(record.units.watchdog_timer) &&
    !systemd.isActive(record.units.watchdog_timer) &&
    credentialDisabled;
  if (alreadyDisarmed) {
    const marker = readProtected(disarmedPath, expectedUid);
    if (marker.canary_id !== record.canary_id ||
        marker.release_sha !== record.release_sha ||
        marker.evidence_preserved !== true) {
      fail("disarm_marker_invalid");
    }
    return {
      kind: "brokkr-maintenance-owner-ceremony-result",
      schema_version: "v1",
      ceremony_id: record.ceremony_id,
      state: "disarmed",
      idempotent: true,
    };
  }
  failSafeDisarm({
    rootPrefix, record, recordDigest, now, systemd, auditFile,
    reason: "owner-ceremony-disable",
  });
  return {
    kind: "brokkr-maintenance-owner-ceremony-result",
    schema_version: "v1",
    ceremony_id: record.ceremony_id,
    state: "disarmed",
    idempotent: false,
  };
}

function productionSystemd() {
  const run = args => {
    const result = spawnSync("/usr/bin/systemctl", args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return {
      ok: result.status === 0,
      output: (result.stdout ?? "").trim(),
    };
  };
  return {
    isEnabled: unit => run(["is-enabled", "--quiet", unit]).ok,
    isActive: unit => run(["is-active", "--quiet", unit]).ok,
    result: unit => run([
      "show", "--property=Result", "--value", unit,
    ]).output,
    start: unit => {
      if (!run(["start", unit]).ok) fail("systemd_start_failed");
    },
    enableNow: unit => {
      if (!run(["enable", "--now", unit]).ok) {
        fail("systemd_enable_failed");
      }
    },
    disableNow: unit => {
      if (!run(["disable", "--now", unit]).ok) {
        fail("systemd_disable_failed");
      }
    },
    stop: unit => {
      if (!run(["stop", unit]).ok) fail("systemd_stop_failed");
    },
  };
}

function main() {
  if (process.geteuid() !== 0) fail("root_required");
  if (process.argv.length !== 3 ||
      !["arm", "disable"].includes(process.argv[2])) {
    process.stderr.write(
      "usage: maintenance-owner-ceremony-transition.mjs arm|disable\n",
    );
    process.exitCode = 64;
    return;
  }
  if (process.env.BROKKR_CEREMONY_TEST_ROOT ||
      process.env.BROKKR_CEREMONY_SYSTEMCTL) {
    fail("test_override_forbidden");
  }
  const action = process.argv[2];
  const result = action === "arm" ?
    armMaintenanceCanary({ systemd: productionSystemd() }) :
    disableMaintenanceCanary({ systemd: productionSystemd() });
  process.stdout.write(`${canonicalJson(result)}\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(
      `maintenance-owner-ceremony-transition: ${
        error.code ?? "internal_failure"}\n`,
    );
    process.exitCode = 1;
  }
}
