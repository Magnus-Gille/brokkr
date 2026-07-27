// Root-only, fixed-command host adapter for the bounded Debian maintenance lane.
// It is intentionally not wired to a timer or a live target.  The coordinator
// must first verify signed authority, then place an exact root-owned request and
// registration under the fixed state root.  This process has no shell execution
// path and never accepts a caller-selected command or filesystem path.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const STATE_ROOT = "/var/lib/brokkr/debian-maintenance";
const DIGEST = /^sha256:[a-f0-9]{64}$/;
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const PACKAGE = /^[a-z0-9][a-z0-9+.-]{0,127}$/;
const VERSION = /^[A-Za-z0-9:+.~-]{1,128}$/;
const UNIT = /^[a-zA-Z0-9@_.-]{1,128}\.service$/;
const KERNEL_OR_FIRMWARE = /(^|[-.])(linux|kernel|firmware|raspi-firmware)([-.]|$)/i;
const MAX_PACKAGES = 64;
const MIN_AVAILABLE_KIB = 1024 * 1024;
const RECOVERY_UNIT_ALLOWLIST = new Set(["brokkr-maintenance-safe.service"]);

export const canonicalJson = value => {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  return `{${Object.keys(value).sort().map(key => (
    `${JSON.stringify(key)}:${canonicalJson(value[key])}`
  )).join(",")}}`;
};
const digest = value => `sha256:${crypto.createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
const fail = code => { const error = new Error(code); error.code = code; throw error; };
const plain = value => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value, keys) => plain(value) && Object.keys(value).sort().join(",") === [...keys].sort().join(",");
const iso = value => typeof value === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(value) && Number.isFinite(Date.parse(value));
const command = (env, argv) => {
  if (!Array.isArray(argv) || argv.length < 1 || typeof argv[0] !== "string" || !argv[0].startsWith("/") || argv.some(arg => typeof arg !== "string" || arg.includes("\0"))) fail("host_command_invalid");
  const result = env.run(argv);
  if (!plain(result) || !Number.isInteger(result.status) || typeof result.stdout !== "string") fail("host_command_result_invalid");
  return result;
};
const ok = (env, argv, code) => { const result = command(env, argv); if (result.status !== 0) fail(code); return result.stdout; };
const clone = value => structuredClone(value);

function candidateSet(request) {
  const candidates = request.execution_request?.candidates;
  if (!Array.isArray(candidates) || candidates.length < 1 || candidates.length > MAX_PACKAGES) fail("host_candidates_invalid");
  const names = new Set();
  const ids = [];
  for (const candidate of candidates) {
    if (!exactKeys(candidate, ["id", "name", "class", "source", "current_version", "candidate_version", "eligible", "reasons"]) ||
      !PACKAGE.test(candidate.name) || KERNEL_OR_FIRMWARE.test(candidate.name) ||
      !VERSION.test(candidate.candidate_version) || (candidate.current_version !== null && !VERSION.test(candidate.current_version)) ||
      candidate.id !== `${candidate.name}@${candidate.candidate_version}` ||
      !["security", "bugfix"].includes(candidate.class) || candidate.source !== "distro_repository" ||
      candidate.eligible !== true || !Array.isArray(candidate.reasons) || candidate.reasons.length !== 0) {
      fail(KERNEL_OR_FIRMWARE.test(String(candidate.name)) ? "host_candidate_forbidden" : "host_candidate_invalid");
    }
    if (names.has(candidate.name)) fail("host_candidate_duplicate");
    names.add(candidate.name); ids.push(candidate.id);
  }
  if (canonicalJson(ids) !== canonicalJson([...ids].sort())) fail("host_candidates_not_canonical");
  return candidates;
}

function validateRequest(request, registration, action) {
  if (!plain(request) || request.action !== "apply" || !["apply", "recover"].includes(action)) fail("host_action_invalid");
  if (!exactKeys(request, [
    "kind", "schema_version", "action", "attempt_id", "binding_digest", "plan_digest",
    "constitution_digest", "release_digest", "execution_request", "execution_request_digest",
    "recovery_descriptor", "recovery_descriptor_digest", "lease_fence", "lease_fence_digest", "apt_source_evidence", "apt_source_evidence_digest",
  ]) || request.kind !== "brokkr-debian-host-adapter-request" || request.schema_version !== "v1" ||
    request.action !== "apply" || !ID.test(request.attempt_id) || ![
      request.binding_digest, request.plan_digest, request.constitution_digest, request.release_digest,
      request.execution_request_digest, request.recovery_descriptor_digest, request.lease_fence_digest, request.apt_source_evidence_digest,
    ].every(value => DIGEST.test(value)) || request.execution_request_digest !== digest(request.execution_request) ||
    request.recovery_descriptor_digest !== digest(request.recovery_descriptor) || request.lease_fence_digest !== digest(request.lease_fence) || request.apt_source_evidence_digest !== digest(request.apt_source_evidence)) fail("host_request_invalid");
  if (!exactKeys(registration, [
    "kind", "schema_version", "attempt_id", "binding_digest", "plan_digest", "constitution_digest",
    "release_digest", "execution_request_digest", "recovery_descriptor_digest", "lease_fence_digest", "apt_source_evidence_digest",
  ]) || registration.kind !== "brokkr-debian-host-adapter-registration" || registration.schema_version !== "v1" ||
    !Object.keys(registration).filter(key => key.endsWith("digest")).every(key => DIGEST.test(registration[key])) ||
    ["attempt_id", "binding_digest", "plan_digest", "constitution_digest", "release_digest", "execution_request_digest", "recovery_descriptor_digest", "lease_fence_digest", "apt_source_evidence_digest"].some(key => registration[key] !== request[key])) {
    fail("host_registration_mismatch");
  }
  const execution = request.execution_request;
  if (!exactKeys(execution, ["kind", "schema_version", "target", "candidates", "config", "pre_state", "expected_postconditions"]) ||
    execution.kind !== "brokkr-bounded-debian-maintenance-request" || execution.schema_version !== "v1" ||
    !exactKeys(execution.target, ["node_id", "platform", "non_pillar"]) || !ID.test(execution.target.node_id) ||
    execution.target.platform !== "debian" || execution.target.non_pillar !== true ||
    !exactKeys(execution.config, ["adapter_revision_digest", "plan_digest", "policy_digest", "no_reboot", "no_drain"]) ||
    !DIGEST.test(execution.config.adapter_revision_digest) || !DIGEST.test(execution.config.policy_digest) ||
    execution.config.plan_digest !== request.plan_digest || execution.config.adapter_revision_digest !== request.release_digest ||
    execution.config.no_reboot !== true || execution.config.no_drain !== true) fail("host_request_scope_invalid");
  if (request.lease_fence?.target_scope_digest !== digest({ node_id: execution.target.node_id, platform: execution.target.platform })) fail("host_fence_target_invalid");
  const candidates = candidateSet(request);
  if (!exactKeys(request.apt_source_evidence, ["kind", "schema_version", "plan_digest", "policy_digest", "trust_config_digest", "candidates"]) || request.apt_source_evidence.kind !== "brokkr-debian-apt-source-evidence" || request.apt_source_evidence.schema_version !== "v1" || request.apt_source_evidence.plan_digest !== request.plan_digest || request.apt_source_evidence.policy_digest !== execution.config.policy_digest || !DIGEST.test(request.apt_source_evidence.trust_config_digest) || !Array.isArray(request.apt_source_evidence.candidates) || request.apt_source_evidence.candidates.length !== candidates.length || canonicalJson(request.apt_source_evidence.candidates.map(item => item.name)) !== canonicalJson(candidates.map(item => item.name)) || !request.apt_source_evidence.candidates.every(item => exactKeys(item, ["name", "policy_output_digest"]) && DIGEST.test(item.policy_output_digest))) fail("host_apt_evidence_invalid");
  validateInventory(execution.pre_state, candidates, "host_pre_state_invalid");
  validateInventory(execution.expected_postconditions, candidates, "host_postconditions_invalid");
  const descriptor = request.recovery_descriptor;
  if (!exactKeys(descriptor, ["kind", "schema_version", "descriptor_id", "attempt_id", "binding_digest", "packages", "restart_units", "budget_seconds"]) ||
    descriptor.kind !== "brokkr-debian-recovery-descriptor" || descriptor.schema_version !== "v1" ||
    !ID.test(descriptor.descriptor_id) || descriptor.attempt_id !== request.attempt_id ||
    descriptor.binding_digest !== request.binding_digest || !Array.isArray(descriptor.packages) ||
    canonicalJson(descriptor.packages) !== canonicalJson(candidates.map(item => item.name)) ||
    !Array.isArray(descriptor.restart_units) || descriptor.restart_units.length > 16 ||
    new Set(descriptor.restart_units).size !== descriptor.restart_units.length ||
    !descriptor.restart_units.every(unit => UNIT.test(unit) && RECOVERY_UNIT_ALLOWLIST.has(unit)) || !Number.isInteger(descriptor.budget_seconds) ||
    descriptor.budget_seconds < 1 || descriptor.budget_seconds > 300) fail("host_recovery_descriptor_invalid");
  const assertFence = (fence, code) => {
  if (!exactKeys(fence, ["kind", "schema_version", "domain", "target_scope_digest", "attempt_id", "mutation_id", "binding_digest", "epoch", "holder_token", "activated_at", "expires_at"]) ||
    fence.kind !== "brokkr-effect-lease-fence" || fence.schema_version !== "v1" || fence.domain !== "no-reboot-security-bugfix-maintenance" ||
    !DIGEST.test(fence.target_scope_digest) || fence.attempt_id !== request.attempt_id || !ID.test(fence.mutation_id) ||
    fence.binding_digest !== request.binding_digest || !Number.isSafeInteger(fence.epoch) || fence.epoch < 1 ||
    typeof fence.holder_token !== "string" || fence.holder_token.length < 16 || !iso(fence.activated_at) || !iso(fence.expires_at) ||
    Date.parse(fence.activated_at) > Date.parse(fence.expires_at)) fail(code);
  };
  const fence = request.lease_fence; assertFence(fence, "host_fence_invalid");
  return { execution, candidates, descriptor, assertFence, aptEvidence: request.apt_source_evidence };
}

function validateInventory(inventory, candidates, code) {
  if (!exactKeys(inventory, ["kernel", "packages", "reboot_required", "dpkg_status"]) ||
    !VERSION.test(inventory.kernel) || inventory.reboot_required !== false || inventory.dpkg_status !== "clean" ||
    !Array.isArray(inventory.packages) || inventory.packages.length !== candidates.length ||
    canonicalJson(inventory.packages) !== canonicalJson([...inventory.packages].sort())) fail(code);
  const expectedNames = candidates.map(candidate => candidate.name).sort();
  const names = inventory.packages.map(value => value.split("=", 1)[0]).sort();
  if (canonicalJson(names) !== canonicalJson(expectedNames) || !inventory.packages.every(value => {
    const [name, version] = value.split("="); return PACKAGE.test(name) && VERSION.test(version) && value === `${name}=${version}`;
  })) fail(code);
}

function preflight(env) {
  if (ok(env, ["/usr/bin/timedatectl", "show", "--property=NTPSynchronized", "--value"], "host_clock_unverified").trim() !== "yes") fail("host_clock_unverified");
  ok(env, ["/usr/bin/on_ac_power"], "host_power_unverified");
  ok(env, ["/usr/bin/flock", "--nonblock", "/var/lib/dpkg/lock-frontend", "/usr/bin/true"], "host_package_lock_busy");
  const disk = ok(env, ["/bin/df", "-Pk", "/var"], "host_disk_unverified").trim().split("\n").at(-1).trim().split(/\s+/);
  if (!/^\d+$/.test(disk[3] ?? "") || Number(disk[3]) < MIN_AVAILABLE_KIB) fail("host_disk_exhausted");
  ok(env, ["/usr/bin/getent", "ahostsv4", "deb.debian.org"], "host_network_unreachable");
}
function withinRecoveryBudget(env, deadline) {
  const now = Date.parse(env.now());
  if (!Number.isFinite(now) || now >= deadline) fail("host_recovery_budget_exhausted");
  return Math.max(1, deadline - now);
}
function recoveryOk(env, deadline, argv, code) {
  const before = withinRecoveryBudget(env, deadline);
  const result = env.run(argv, { timeoutMs: before });
  if (!plain(result) || !Number.isInteger(result.status) || typeof result.stdout !== "string" || result.status !== 0) fail(code);
  withinRecoveryBudget(env, deadline);
  return result.stdout;
}

function hostInventory(env, candidates) {
  const kernel = ok(env, ["/usr/bin/uname", "-r"], "host_inventory_unavailable").trim();
  const packages = candidates.map(candidate => {
    const output = ok(env, ["/usr/bin/dpkg-query", "-W", "-f=${binary:Package}=${Version}\\n", candidate.name], "host_inventory_unavailable").trim();
    if (!new RegExp(`^${candidate.name.replace(/[.+-]/g, "\\$&")}=[A-Za-z0-9:+.~-]{1,128}$`).test(output)) fail("host_inventory_unavailable");
    return output;
  }).sort();
  const audit = ok(env, ["/usr/bin/dpkg", "--audit"], "host_dpkg_unhealthy").trim();
  const result = { kernel, packages, reboot_required: env.rebootRequired() === true, dpkg_status: audit === "" ? "clean" : "broken" };
  validateInventory(result, candidates, "host_inventory_unavailable");
  return result;
}

function exactSimulation(env, candidates) {
  const args = ["/usr/bin/apt-get", "--simulate", "--no-install-recommends", "--no-remove", "--only-upgrade", "install", ...candidates.map(item => `${item.name}=${item.candidate_version}`)];
  const output = ok(env, args, "host_exact_upgrade_unavailable");
  const installations = output.split("\n").filter(line => line.startsWith("Inst "));
  if (installations.length !== candidates.length) fail("host_exact_upgrade_widened");
  for (const candidate of candidates) {
    const expected = new RegExp(`^Inst ${candidate.name.replace(/[.+-]/g, "\\$&")} \\[.*\\] \\(${candidate.candidate_version.replace(/[.+~-]/g, "\\$&")} `);
    if (!installations.some(line => expected.test(line) && /\bDebian:/.test(line))) fail("host_exact_upgrade_widened");
  }
  if (output.split("\n").some(line => /^(Remv|Del) /.test(line))) fail("host_exact_upgrade_widened");
}
function verifyAptEvidence(env, candidates, evidence) {
  const trust = ok(env, ["/usr/bin/apt-config", "dump"], "host_apt_trust_unverifiable");
  if (digest(trust) !== evidence.trust_config_digest || /(?:AllowInsecureRepositories|AllowDowngradeToInsecureRepositories|Trusted)\s+"?true"?/i.test(trust)) fail("host_apt_trust_changed");
  for (const candidate of candidates) {
    const expected = evidence.candidates.find(item => item.name === candidate.name);
    const output = ok(env, ["/usr/bin/apt-cache", "policy", candidate.name], "host_apt_source_unverifiable");
    if (digest(output) !== expected.policy_output_digest || !new RegExp(`\\n\\s*${candidate.candidate_version.replace(/[.+~-]/g, "\\$&")} \\d+\\n\\s+\\d+ https?://[^\\s]*debian\\.org/debian(?:-security)?\\b`).test(output)) fail("host_apt_source_changed");
  }
}

const NEXT_PHASES = Object.freeze({
  null: new Set(["preflight"]), preflight: new Set(["inventory_before", "unknown"]),
  inventory_before: new Set(["apply", "unknown"]), apply: new Set(["inventory_after", "unknown", "recover"]),
  inventory_after: new Set(["verify", "unknown", "recover"]), verify: new Set(),
  unknown: new Set(["recover"]), recover: new Set(["quarantine"]),
  quarantine: new Set(["disarm"]), disarm: new Set(),
});
function journalEntry({ phase, at, bindingDigest, previousDigest, detail }) {
  const entry = {
    phase, at, binding_digest: bindingDigest, previous_digest: previousDigest,
    payload_digest: digest(detail),
  };
  return { ...entry, digest: digest(entry) };
}
function validJournal(state, bindingDigest) {
  if (!exactKeys(state, ["entries", "terminal"]) || !Array.isArray(state.entries)) return false;
  if (state.terminal !== null && (!exactKeys(state.terminal, ["kind", "schema_version", "state", "reason", "at", "binding_digest"]) ||
    state.terminal.kind !== "brokkr-debian-host-adapter-terminal" || state.terminal.schema_version !== "v1" ||
    !["terminally-blocked", "disarmed"].includes(state.terminal.state) || typeof state.terminal.reason !== "string" ||
    !iso(state.terminal.at) || state.terminal.binding_digest !== bindingDigest)) return false;
  let previous = null;
  for (let index = 0; index < state.entries.length; index += 1) {
    const entry = state.entries[index];
    if (!exactKeys(entry, ["phase", "at", "binding_digest", "previous_digest", "payload_digest", "digest"]) ||
      !iso(entry.at) || entry.binding_digest !== bindingDigest || entry.previous_digest !== previous ||
      !DIGEST.test(entry.payload_digest) || entry.digest !== digest({
        phase: entry.phase, at: entry.at, binding_digest: entry.binding_digest,
        previous_digest: entry.previous_digest, payload_digest: entry.payload_digest,
      })) return false;
    const priorPhase = index === 0 ? null : state.entries[index - 1].phase;
    if (!NEXT_PHASES[priorPhase]?.has(entry.phase)) return false;
    previous = entry.digest;
  }
  return true;
}
function append(state, phase, env, detail, bindingDigest) {
  const entry = journalEntry({ phase, at: env.now(), bindingDigest,
    previousDigest: state.entries.at(-1)?.digest ?? null, detail });
  if (!iso(entry.at)) fail("host_clock_unverified");
  state.entries.push(entry); env.writeJournal(clone(state)); return entry;
}
function terminal(state, env, reason, bindingDigest) {
  const record = { kind: "brokkr-debian-host-adapter-terminal", schema_version: "v1", state: "terminally-blocked", reason, at: env.now(), binding_digest: bindingDigest };
  state.terminal = record; env.writeJournal(clone(state)); env.writeTerminal(clone(record));
  return { outcome: "terminally-blocked", reason, journal: state };
}

export function runHostAdapter({ action, request, registration, env }) {
  const safeEnv = {
    uid: env?.uid, now: env?.now, run: env?.run, rebootRequired: env?.rebootRequired,
    readJournal: env?.readJournal, writeJournal: env?.writeJournal, writeTerminal: env?.writeTerminal,
  };
  if (safeEnv.uid !== 0) fail("host_root_required");
  if (typeof safeEnv.now !== "function" || typeof safeEnv.run !== "function" || typeof safeEnv.rebootRequired !== "function" ||
    typeof safeEnv.readJournal !== "function" || typeof safeEnv.writeJournal !== "function" || typeof safeEnv.writeTerminal !== "function" ||
    typeof env?.adapterReleaseDigest !== "function" || typeof env?.activateFence !== "function" || typeof env?.applyFenced !== "function" || typeof env?.readRecoveryActivation !== "function") fail("host_environment_invalid");
  const { execution, candidates, descriptor, assertFence, aptEvidence } = validateRequest(request, registration, action);
  if (env.adapterReleaseDigest() !== request.release_digest) fail("host_release_unbound");
  let state = safeEnv.readJournal();
  if (state !== null && !validJournal(state, request.binding_digest)) {
    return terminal({ entries: [], terminal: null }, safeEnv, "host_journal_corrupt", request.binding_digest);
  }
  state ??= { entries: [], terminal: null };
  if (state.terminal !== null) return { outcome: state.terminal.state, reason: state.terminal.reason, journal: state };
  if (action === "apply") {
    if (state.entries.length !== 0) return terminal(state, safeEnv, "host_apply_replay_forbidden");
    try {
      const fenceReceipt = env.activateFence(clone(request.lease_fence));
      if (!plain(fenceReceipt) || fenceReceipt.activated !== true || fenceReceipt.lease_fence_digest !== request.lease_fence_digest) fail("host_fence_activation_failed");
      preflight(safeEnv); append(state, "preflight", safeEnv, { binding_digest: request.binding_digest }, request.binding_digest);
      const before = hostInventory(safeEnv, candidates);
      if (canonicalJson(before) !== canonicalJson(execution.pre_state)) fail("host_baseline_drifted");
      append(state, "inventory_before", safeEnv, before, request.binding_digest);
      preflight(safeEnv); verifyAptEvidence(safeEnv, candidates, aptEvidence); exactSimulation(safeEnv, candidates);
      append(state, "apply", safeEnv, { execution_request_digest: request.execution_request_digest }, request.binding_digest);
      env.applyFenced({ fence: clone(request.lease_fence), lease_fence_digest: request.lease_fence_digest, apply: () => {
        const checkedAt = safeEnv.now();
        if (!iso(checkedAt) || Date.parse(checkedAt) < Date.parse(request.lease_fence.activated_at) || Date.parse(checkedAt) > Date.parse(request.lease_fence.expires_at)) fail("host_fence_expired");
        verifyAptEvidence(safeEnv, candidates, aptEvidence);
        return ok(safeEnv, ["/usr/bin/apt-get", "--assume-yes", "--no-install-recommends", "--no-remove", "--only-upgrade", "install", ...candidates.map(item => `${item.name}=${item.candidate_version}`)], "host_apply_failed");
      } });
      const after = hostInventory(safeEnv, candidates);
      append(state, "inventory_after", safeEnv, after, request.binding_digest);
      if (canonicalJson(after) !== canonicalJson(execution.expected_postconditions)) fail("host_postconditions_unverifiable");
      append(state, "verify", safeEnv, { postconditions_digest: digest(after) }, request.binding_digest);
      return { outcome: "applied", journal: state };
    } catch (error) {
      const reason = String(error?.code ?? error?.message ?? "host_apply_failed");
      if (["apply", "inventory_after"].includes(state.entries.at(-1)?.phase)) {
        try { append(state, "unknown", safeEnv, { reason }, request.binding_digest); }
        catch { return terminal(state, safeEnv, "host_journal_write_failed", request.binding_digest); }
        return { outcome: "unknown", reason, journal: state };
      }
      return terminal(state, safeEnv, reason, request.binding_digest);
    }
  }
  if (state.entries.length === 0 || !["apply", "inventory_after", "unknown"].includes(state.entries.at(-1)?.phase)) return terminal(state, safeEnv, "host_recovery_not_eligible", request.binding_digest);
  const started = Date.parse(safeEnv.now());
  try {
    const activation = env.readRecoveryActivation();
    if (!exactKeys(activation, ["kind", "schema_version", "attempt_id", "binding_digest", "recovery_descriptor_digest", "fence", "fence_digest"]) || activation.kind !== "brokkr-debian-recovery-activation" || activation.schema_version !== "v1" || activation.attempt_id !== request.attempt_id || activation.binding_digest !== request.binding_digest || activation.recovery_descriptor_digest !== request.recovery_descriptor_digest || activation.fence_digest !== digest(activation.fence)) fail("host_revalidation_fence_invalid");
    assertFence(activation.fence, "host_revalidation_fence_invalid");
    if (activation.fence.epoch <= request.lease_fence.epoch || activation.fence.domain !== request.lease_fence.domain ||
      activation.fence.target_scope_digest !== request.lease_fence.target_scope_digest ||
      activation.fence.attempt_id !== request.lease_fence.attempt_id || activation.fence.mutation_id !== request.lease_fence.mutation_id ||
      activation.fence.binding_digest !== request.lease_fence.binding_digest || activation.fence.holder_token === request.lease_fence.holder_token ||
      Date.parse(activation.fence.activated_at) < Date.parse(request.lease_fence.activated_at) || Date.parse(activation.fence.expires_at) <= Date.parse(activation.fence.activated_at)) fail("host_revalidation_fence_invalid");
    const recoveryFenceReceipt = env.activateFence(clone(activation.fence));
    if (!plain(recoveryFenceReceipt) || recoveryFenceReceipt.activated !== true || recoveryFenceReceipt.lease_fence_digest !== activation.fence_digest) fail("host_revalidation_activation_failed");
    append(state, "recover", safeEnv, { recovery_descriptor_digest: request.recovery_descriptor_digest }, request.binding_digest);
    const deadline = Math.min(started + descriptor.budget_seconds * 1000, Date.parse(activation.fence.expires_at));
    env.applyFenced({ fence: clone(activation.fence), lease_fence_digest: activation.fence_digest, apply: () => {
      const checkedAt = safeEnv.now(); if (!iso(checkedAt) || Date.parse(checkedAt) < Date.parse(activation.fence.activated_at) || Date.parse(checkedAt) > Date.parse(activation.fence.expires_at)) fail("host_revalidation_fence_expired");
      recoveryOk(safeEnv, deadline, ["/usr/bin/dpkg", "--configure", "-a"], "host_recovery_repair_failed");
      for (const unit of descriptor.restart_units) recoveryOk(safeEnv, deadline, ["/usr/bin/systemctl", "try-restart", unit], "host_recovery_restart_failed");
      for (const packageName of descriptor.packages) recoveryOk(safeEnv, deadline, ["/usr/bin/apt-mark", "hold", packageName], "host_recovery_hold_failed");
    }});
    withinRecoveryBudget(safeEnv, deadline);
    const after = hostInventory(safeEnv, candidates);
    if (canonicalJson(after) !== canonicalJson(execution.expected_postconditions)) fail("host_postconditions_unverifiable");
    append(state, "quarantine", safeEnv, { descriptor_id: descriptor.descriptor_id }, request.binding_digest);
    append(state, "disarm", safeEnv, { binding_digest: request.binding_digest }, request.binding_digest);
    state.terminal = { kind: "brokkr-debian-host-adapter-terminal", schema_version: "v1", state: "disarmed", reason: "forward_recovery_verified", at: safeEnv.now(), binding_digest: request.binding_digest };
    safeEnv.writeJournal(clone(state)); safeEnv.writeTerminal(clone(state.terminal));
    return { outcome: "disarmed", journal: state };
  } catch (error) { return terminal(state, safeEnv, String(error?.code ?? error?.message ?? "host_recovery_failed"), request.binding_digest); }
}

function regularRootOwned(file) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== 0 || (stat.mode & 0o077) !== 0) fail("host_input_file_unsafe");
}
function protectedDirectory(directory, create = false) {
  if (create && !fs.existsSync(directory)) fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== 0 || (stat.mode & 0o077) !== 0) fail("host_state_root_unsafe");
}
function readJson(file) { regularRootOwned(file); try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { fail("host_input_json_invalid"); } }
function atomicWrite(file, value) {
  protectedDirectory(STATE_ROOT);
  protectedDirectory(path.dirname(file), true);
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}`;
  const fd = fs.openSync(temporary, "wx", 0o600); try { fs.writeFileSync(fd, `${canonicalJson(value)}\n`); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(temporary, file); const directory = fs.openSync(path.dirname(file), "r"); try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
}
function cli() {
  const internal = process.argv[2] === "--effect-locked";
  const offset = internal ? 3 : 2;
  const [flag, action, attemptFlag, attempt] = process.argv.slice(offset);
  if (flag !== "--action" || !["apply", "recover"].includes(action) || attemptFlag !== "--attempt" || !ID.test(attempt) || process.argv.length !== offset + 4) fail("host_cli_arguments_invalid");
  if (process.getuid() !== 0) fail("host_root_required");
  protectedDirectory(STATE_ROOT);
  protectedDirectory(path.join(STATE_ROOT, "fences"), true);
  if (!internal) {
    const child = spawnSync("/usr/bin/flock", ["--nonblock", path.join(STATE_ROOT, "fences", `${attempt}.effect-lock`), process.execPath, fileURLToPath(import.meta.url), "--effect-locked", "--action", action, "--attempt", attempt], { encoding: "utf8" });
    process.stdout.write(child.stdout ?? ""); process.stderr.write(child.stderr ?? "");
    process.exitCode = child.status ?? 1; return;
  }
  protectedDirectory(path.join(STATE_ROOT, "requests"));
  protectedDirectory(path.join(STATE_ROOT, "registrations"));
  protectedDirectory(path.join(STATE_ROOT, "recovery-activations"));
  const request = readJson(path.join(STATE_ROOT, "requests", `${attempt}.json`));
  const registration = readJson(path.join(STATE_ROOT, "registrations", `${attempt}.json`));
  const journalFile = path.join(STATE_ROOT, "journals", `${attempt}.json`);
  const terminalFile = path.join(STATE_ROOT, "terminals", `${attempt}.json`);
  const fenceFile = path.join(STATE_ROOT, "fences", `${attempt}.json`);
  const rawDigest = `sha256:${crypto.createHash("sha256").update(fs.readFileSync(fileURLToPath(import.meta.url))).digest("hex")}`;
  const activateFence = fence => {
    protectedDirectory(path.dirname(fenceFile), true);
    const existing = fs.existsSync(fenceFile) ? readJson(fenceFile) : null;
    if (existing !== null) {
      if (!exactKeys(existing, ["fence", "lease_fence_digest"]) || existing.lease_fence_digest !== digest(existing.fence)) fail("host_fence_store_corrupt");
      if (existing.fence.epoch > fence.epoch || (existing.fence.epoch === fence.epoch && existing.lease_fence_digest !== digest(fence))) fail("host_fence_superseded");
    }
    atomicWrite(fenceFile, { fence: clone(fence), lease_fence_digest: digest(fence) });
    return { activated: true, lease_fence_digest: digest(fence) };
  };
  const applyFenced = ({ fence, lease_fence_digest, apply }) => {
    if (lease_fence_digest !== digest(fence)) fail("host_fence_digest_invalid");
    const current = readJson(fenceFile);
    if (canonicalJson(current) !== canonicalJson({ fence, lease_fence_digest })) fail("host_fence_superseded");
    return apply();
  };
  const result = runHostAdapter({ action, request, registration, env: {
    uid: process.getuid(), now: () => new Date().toISOString().replace(".000Z", "Z"),
    run: (argv, options = {}) => { const result = spawnSync(argv[0], argv.slice(1), { encoding: "utf8", timeout: options.timeoutMs ?? 120_000 }); return { status: result.status ?? 1, stdout: result.stdout ?? "" }; },
    rebootRequired: () => fs.existsSync("/var/run/reboot-required"),
    adapterReleaseDigest: () => rawDigest, activateFence, applyFenced,
    readRecoveryActivation: () => readJson(path.join(STATE_ROOT, "recovery-activations", `${attempt}.json`)),
    readJournal: () => fs.existsSync(journalFile) ? readJson(journalFile) : null,
    writeJournal: value => atomicWrite(journalFile, value), writeTerminal: value => atomicWrite(terminalFile, value),
  }});
  process.stdout.write(`${canonicalJson({ outcome: result.outcome, reason: result.reason ?? null })}\n`);
  process.exitCode = result.outcome === "applied" || result.outcome === "disarmed" ? 0 : 1;
}
if (process.argv[1] === fileURLToPath(import.meta.url)) cli();
