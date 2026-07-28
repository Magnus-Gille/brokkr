// The single production capability boundary for Debian host maintenance.
// Every command, path, state write, fence operation, and systemd unit is
// lexical-private and fixed here. The sole export accepts only closed,
// untrusted action/request/registration values and revalidates them against
// root-owned fixed-path authority before any host effect.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const STATE_ROOT = "/var/lib/brokkr/debian-maintenance";
const OPERATION_FILE = fileURLToPath(import.meta.url);
const DIGEST = /^sha256:[a-f0-9]{64}$/;
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const PACKAGE = /^[a-z0-9][a-z0-9+.-]{0,127}$/;
const VERSION = /^[A-Za-z0-9:+.~-]{1,128}$/;
const UNIT = /^[a-zA-Z0-9@_.-]{1,128}\.service$/;
const PROTECTED_PACKAGE_FAMILIES = Object.freeze([
  /^(?:linux-(?:base|headers|image|kbuild|libc-dev|modules|source|tools)|kernel)(?:[-.]|$)/,
  /(?:^|[-.])(?:kernel|firmware|microcode|eeprom)(?:[-.]|$)/,
  /^(?:raspi|rpi)(?:[-.]|$)/,
  /^(?:grub|shim|u-boot|uboot|initramfs|dracut|dkms|kmod|fwupd|flashrom)(?:[-.]|$)/,
  /^(?:systemd-boot)(?:[-.]|$)/,
]);
const APPROVED_DEBIAN_ORIGINS = new Map([
  ["deb.debian.org", new Set(["/debian", "/debian-security"])],
  ["security.debian.org", new Set(["/debian-security"])],
]);
const MAX_PACKAGES = 64;
const MIN_AVAILABLE_KIB = 1024 * 1024;
const RECOVERY_UNIT_ALLOWLIST = new Set(["brokkr-maintenance-safe.service"]);
const fixedSpawnSync = (...args) => spawnSync(...args);

const canonicalJson = value => {
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
const iso = value => {
  if (typeof value !== "string" ||
      !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(value)) return false;
  const instant = new Date(value);
  return !Number.isNaN(instant.getTime()) &&
    instant.toISOString().replace(".000Z", "Z") === value;
};
const protectedPackage = value => (
  typeof value === "string" &&
  PROTECTED_PACKAGE_FAMILIES.some(pattern => pattern.test(value))
);
const command = (env, argv) => {
  if (!Array.isArray(argv) || argv.length < 1 || typeof argv[0] !== "string" || !argv[0].startsWith("/") || argv.some(arg => typeof arg !== "string" || arg.includes("\0"))) fail("host_command_invalid");
  const result = env.run(argv);
  if (!plain(result) || !Number.isInteger(result.status) || typeof result.stdout !== "string") fail("host_command_result_invalid");
  return result;
};
const ok = (env, argv, code) => { const result = command(env, argv); if (result.status !== 0) fail(code); return result.stdout; };
const clone = value => structuredClone(value);

function assertAttempt(attempt) {
  if (!ID.test(attempt)) fail("host_attempt_invalid");
}
function protectedDirectory(directory, { create = false } = {}) {
  if (create && !fs.existsSync(directory)) {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  }
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== 0 ||
      (stat.mode & 0o077) !== 0) fail("host_state_root_unsafe");
}
function readRootOwnedJson(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== 0 || (stat.mode & 0o077) !== 0) {
      fail("host_input_file_unsafe");
    }
    try { return JSON.parse(fs.readFileSync(fd, "utf8")); }
    catch { fail("host_input_json_invalid"); }
  } finally {
    fs.closeSync(fd);
  }
}
function fixedFile(directory, attempt) {
  assertAttempt(attempt);
  return path.join(STATE_ROOT, directory, `${attempt}.json`);
}
function readFixed(directory, attempt) {
  protectedDirectory(STATE_ROOT);
  protectedDirectory(path.join(STATE_ROOT, directory));
  return readRootOwnedJson(fixedFile(directory, attempt));
}
function atomicWriteFixed(directory, attempt, value) {
  protectedDirectory(STATE_ROOT);
  const targetDirectory = path.join(STATE_ROOT, directory);
  protectedDirectory(targetDirectory, { create: true });
  const file = fixedFile(directory, attempt);
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}`;
  const fd = fs.openSync(
    temporary,
    fs.constants.O_WRONLY | fs.constants.O_CREAT |
      fs.constants.O_EXCL | fs.constants.O_NOFOLLOW,
    0o600,
  );
  try {
    fs.writeFileSync(fd, `${canonicalJson(value)}\n`);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temporary, file);
  const directoryFd = fs.openSync(targetDirectory, "r");
  try { fs.fsyncSync(directoryFd); } finally { fs.closeSync(directoryFd); }
}
function fixedRun(argv, options = {}) {
  const result = fixedSpawnSync(argv[0], argv.slice(1), {
    encoding: "utf8", timeout: options.timeoutMs ?? 120_000,
  });
  return { status: result.status ?? 1, stdout: result.stdout ?? "" };
}
function fixedFiles(attempt) {
  assertAttempt(attempt);
  return {
    journal: fixedFile("journals", attempt),
    terminal: fixedFile("terminals", attempt),
    fence: fixedFile("fences", attempt),
    activation: fixedFile("recovery-activations", attempt),
    authorization: fixedFile("recovery-authorizations", attempt),
    request: fixedFile("requests", attempt),
    registration: fixedFile("registrations", attempt),
  };
}
function fixedReadOptional(directory, attempt) {
  protectedDirectory(STATE_ROOT);
  const targetDirectory = path.join(STATE_ROOT, directory);
  protectedDirectory(targetDirectory);
  const file = fixedFile(directory, attempt);
  return fs.existsSync(file) ? readRootOwnedJson(file) : null;
}
function assertFixedInputBinding(attempt, request, registration) {
  const fixedRequest = readFixed("requests", attempt);
  const fixedRegistration = readFixed("registrations", attempt);
  if (canonicalJson(fixedRequest) !== canonicalJson(request) ||
      canonicalJson(fixedRegistration) !== canonicalJson(registration)) {
    fail("host_fixed_authorization_unverified");
  }
}
function assertRecoveryAuthorization(attempt, activation, recoveryRequest = null) {
  const authorization = readFixed("recovery-authorizations", attempt);
  if (!exactKeys(authorization, [
    "kind", "schema_version", "attempt_id", "activation", "recovery_request",
  ]) || authorization.kind !== "brokkr-debian-recovery-authorization" ||
      authorization.schema_version !== "v1" ||
      authorization.attempt_id !== attempt ||
      canonicalJson(authorization.activation) !== canonicalJson(activation) ||
      (recoveryRequest !== null &&
        canonicalJson(authorization.recovery_request) !==
          canonicalJson(recoveryRequest))) {
    fail("bounded_recovery_authorization_unverified");
  }
  return authorization;
}
function assertEffectLock(attempt) {
  const lockFile = fixedFiles(attempt).fence.replace(/\.json$/, ".effect-lock");
  protectedDirectory(path.join(STATE_ROOT, "fences"));
  const lockFd = fs.openSync(
    lockFile, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW,
  );
  let lock;
  try { lock = fs.fstatSync(lockFd); } finally { fs.closeSync(lockFd); }
  if (!lock.isFile() || lock.uid !== 0 || (lock.mode & 0o077) !== 0) {
    fail("host_effect_lock_unverified");
  }
  const ownedKernelLock = fs.readdirSync("/proc/self/fd").some(name => {
    if (!/^\d+$/.test(name) || Number(name) <= 2) return false;
    try {
      const descriptor = fs.fstatSync(Number(name));
      if (!descriptor.isFile() || descriptor.dev !== lock.dev ||
          descriptor.ino !== lock.ino) return false;
      return fs.readFileSync(`/proc/self/fdinfo/${name}`, "utf8")
        .split("\n")
        .filter(line => line.startsWith("lock:"))
        .some(line => {
          const fields = line.trim().split(/\s+/);
          return fields[2] === "FLOCK" && fields[3] === "ADVISORY" &&
            fields[4] === "WRITE" && fields[5] === String(process.pid) &&
            fields[6]?.endsWith(`:${lock.ino}`);
        });
    } catch {
      return false;
    }
  });
  if (!ownedKernelLock) fail("host_effect_lock_unverified");
  const contender = fixedSpawnSync(
    "/usr/bin/flock",
    ["--nonblock", lockFile, "/usr/bin/true"],
    { encoding: "utf8" },
  );
  if (contender.status !== 1) fail("host_effect_lock_unverified");
}
function fixedActivateFence(attempt, fence) {
  const existing = fixedReadOptional("fences", attempt);
  if (existing !== null) {
    if (!exactKeys(existing, ["fence", "lease_fence_digest"]) ||
        existing.lease_fence_digest !== digest(existing.fence)) {
      fail("host_fence_store_corrupt");
    }
    if (existing.fence.epoch > fence.epoch ||
        (existing.fence.epoch === fence.epoch &&
          existing.lease_fence_digest !== digest(fence))) {
      fail("host_fence_superseded");
    }
  }
  atomicWriteFixed("fences", attempt, {
    fence: clone(fence), lease_fence_digest: digest(fence),
  });
  return { activated: true, lease_fence_digest: digest(fence) };
}
function fixedAssertFenceCurrent(attempt, fence, leaseFenceDigest) {
  if (leaseFenceDigest !== digest(fence)) fail("host_fence_digest_invalid");
  const current = readFixed("fences", attempt);
  if (canonicalJson(current) !== canonicalJson({
    fence, lease_fence_digest: leaseFenceDigest,
  })) fail("host_fence_superseded");
}
const fixedNow = () => new Date(Math.floor(Date.now() / 1000) * 1000)
  .toISOString().replace(".000Z", "Z");
const fixedRebootRequired = () => fs.existsSync("/var/run/reboot-required");
const fixedReleaseDigest = () => `sha256:${crypto.createHash("sha256")
  .update(fs.readFileSync(OPERATION_FILE)).digest("hex")}`;

function candidateSet(request) {
  const candidates = request.execution_request?.candidates;
  if (!Array.isArray(candidates) || candidates.length < 1 || candidates.length > MAX_PACKAGES) fail("host_candidates_invalid");
  const names = new Set();
  const ids = [];
  for (const candidate of candidates) {
    if (!exactKeys(candidate, ["id", "name", "class", "source", "current_version", "candidate_version", "eligible", "reasons"]) ||
      !PACKAGE.test(candidate.name) || protectedPackage(candidate.name) ||
      !VERSION.test(candidate.candidate_version) || (candidate.current_version !== null && !VERSION.test(candidate.current_version)) ||
      candidate.id !== `${candidate.name}@${candidate.candidate_version}` ||
      !["security", "bugfix"].includes(candidate.class) || candidate.source !== "distro_repository" ||
      candidate.eligible !== true || !Array.isArray(candidate.reasons) || candidate.reasons.length !== 0) {
      fail(protectedPackage(candidate.name) ? "host_candidate_forbidden" : "host_candidate_invalid");
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
  const at = env.now();
  if (!iso(at)) fail("host_clock_unverified");
  const now = Date.parse(at);
  if (now >= deadline) fail("host_recovery_budget_exhausted");
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
function approvedDebianOrigin(value, archiveComponent) {
  let origin;
  try { origin = new URL(value); } catch { return false; }
  return ["http:", "https:"].includes(origin.protocol) &&
    origin.username === "" && origin.password === "" && origin.port === "" &&
    origin.search === "" && origin.hash === "" &&
    APPROVED_DEBIAN_ORIGINS.get(origin.hostname)?.has(origin.pathname) === true &&
    /^[a-z0-9][a-z0-9+.-]*\/main$/.test(archiveComponent);
}
function policyBindsApprovedCandidate(output, version) {
  const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const exactVersion = new RegExp(
    `^\\s*(?:\\*\\*\\*\\s+)?${escaped}\\s+\\d+\\s*$`,
  );
  const anyVersion = /^\s*(?:\*\*\*\s+)?\S+\s+\d+\s*$/;
  const lines = output.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    if (!exactVersion.test(lines[index])) continue;
    for (let originIndex = index + 1;
      originIndex < lines.length &&
      !anyVersion.test(lines[originIndex]);
      originIndex += 1) {
      const match = /^\s+\d+\s+(\S+)\s+(\S+)\s+\S+\s+Packages\s*$/
        .exec(lines[originIndex]);
      if (match && approvedDebianOrigin(match[1], match[2])) return true;
    }
  }
  return false;
}
function verifyAptEvidence(env, candidates, evidence) {
  const trust = ok(env, ["/usr/bin/apt-config", "dump"], "host_apt_trust_unverifiable");
  if (digest(trust) !== evidence.trust_config_digest || /(?:AllowInsecureRepositories|AllowDowngradeToInsecureRepositories|Trusted)\s+"?true"?/i.test(trust)) fail("host_apt_trust_changed");
  for (const candidate of candidates) {
    const expected = evidence.candidates.find(item => item.name === candidate.name);
    const output = ok(env, ["/usr/bin/apt-cache", "policy", candidate.name], "host_apt_source_unverifiable");
    if (digest(output) !== expected.policy_output_digest ||
        !policyBindsApprovedCandidate(output, candidate.candidate_version)) {
      fail("host_apt_source_changed");
    }
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
  if (state.terminal !== null) {
    const terminal = state.terminal;
    const legacy = exactKeys(terminal, ["kind", "schema_version", "state", "reason", "at", "binding_digest"]);
    const bound = exactKeys(terminal, ["kind", "schema_version", "state", "reason", "at", "binding_digest", "activation_digest", "revalidation_fence_digest"]);
    if ((!legacy && !bound) || terminal.kind !== "brokkr-debian-host-adapter-terminal" ||
      terminal.schema_version !== "v1" || !["terminally-blocked", "disarmed"].includes(terminal.state) ||
      typeof terminal.reason !== "string" || !iso(terminal.at) || terminal.binding_digest !== bindingDigest ||
      (terminal.state === "disarmed" && !bound) ||
      (bound && (!DIGEST.test(terminal.activation_digest) ||
        !DIGEST.test(terminal.revalidation_fence_digest)))) return false;
  }
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
function terminal(state, env, reason, bindingDigest, activation = null) {
  const at = env.now();
  if (!iso(at)) fail("host_clock_unverified");
  const record = { kind: "brokkr-debian-host-adapter-terminal", schema_version: "v1", state: "terminally-blocked", reason, at, binding_digest: bindingDigest };
  if (activation !== null) {
    record.activation_digest = digest(activation);
    record.revalidation_fence_digest = activation.fence_digest;
  }
  state.terminal = record; env.writeJournal(clone(state)); env.writeTerminal(clone(record));
  return { outcome: "terminally-blocked", reason, journal: state };
}
function disarmedTerminal(env, state, request, activation) {
  const at = env.now();
  if (!iso(at)) fail("host_clock_unverified");
  const record = {
    kind: "brokkr-debian-host-adapter-terminal", schema_version: "v1",
    state: "disarmed", reason: "forward_recovery_verified", at,
    binding_digest: request.binding_digest,
    activation_digest: digest(activation),
    revalidation_fence_digest: activation.fence_digest,
  };
  state.terminal = record;
  env.writeJournal(clone(state));
  env.writeTerminal(clone(record));
  return { outcome: "disarmed", journal: state };
}
function reconcileTerminal(state, env) {
  if (state.terminal === null) return;
  const sidecar = env.readTerminal();
  if (sidecar === null) {
    env.writeTerminal(clone(state.terminal));
  } else if (canonicalJson(sidecar) !== canonicalJson(state.terminal)) {
    fail("host_terminal_conflict");
  }
}
function validateHostRecoveryActivation(request, activation, assertFence) {
  if (!exactKeys(activation, [
    "kind", "schema_version", "attempt_id", "binding_digest",
    "recovery_descriptor_digest", "fence", "fence_digest",
  ]) || activation.kind !== "brokkr-debian-recovery-activation" ||
      activation.schema_version !== "v1" ||
      activation.attempt_id !== request.attempt_id ||
      activation.binding_digest !== request.binding_digest ||
      activation.recovery_descriptor_digest !==
        request.recovery_descriptor_digest ||
      activation.fence_digest !== digest(activation.fence)) {
    fail("host_revalidation_fence_invalid");
  }
  assertFence(activation.fence, "host_revalidation_fence_invalid");
  if (activation.fence.epoch <= request.lease_fence.epoch ||
      activation.fence.domain !== request.lease_fence.domain ||
      activation.fence.target_scope_digest !==
        request.lease_fence.target_scope_digest ||
      activation.fence.attempt_id !== request.lease_fence.attempt_id ||
      activation.fence.mutation_id !== request.lease_fence.mutation_id ||
      activation.fence.binding_digest !== request.lease_fence.binding_digest ||
      activation.fence.holder_token === request.lease_fence.holder_token ||
      Date.parse(activation.fence.activated_at) <
        Date.parse(request.lease_fence.activated_at) ||
      Date.parse(activation.fence.expires_at) <=
        Date.parse(activation.fence.activated_at)) {
    fail("host_revalidation_fence_invalid");
  }
}
function activateHostRecoveryFence(env, activation) {
  const receipt = env.activateFence(clone(activation.fence));
  if (!plain(receipt) || receipt.activated !== true ||
      receipt.lease_fence_digest !== activation.fence_digest) {
    fail("host_revalidation_activation_failed");
  }
  env.assertFenceCurrent(clone(activation.fence), activation.fence_digest);
  const checkedAt = env.now();
  if (!iso(checkedAt) ||
      Date.parse(checkedAt) < Date.parse(activation.fence.activated_at) ||
      Date.parse(checkedAt) > Date.parse(activation.fence.expires_at)) {
    fail("host_revalidation_fence_expired");
  }
}

function runHostAdapterCore({ action, request, registration, env }) {
  const safeEnv = {
    uid: env?.uid, now: env?.now, run: env?.run, rebootRequired: env?.rebootRequired,
    readJournal: env?.readJournal, readTerminal: env?.readTerminal,
    writeJournal: env?.writeJournal, writeTerminal: env?.writeTerminal,
  };
  if (safeEnv.uid !== 0) fail("host_root_required");
  if (typeof safeEnv.now !== "function" || typeof safeEnv.run !== "function" || typeof safeEnv.rebootRequired !== "function" ||
    typeof safeEnv.readJournal !== "function" ||
    typeof safeEnv.readTerminal !== "function" ||
    typeof safeEnv.writeJournal !== "function" ||
    typeof safeEnv.writeTerminal !== "function" ||
    typeof env?.adapterReleaseDigest !== "function" || typeof env?.activateFence !== "function" || typeof env?.assertFenceCurrent !== "function" || typeof env?.readRecoveryActivation !== "function") fail("host_environment_invalid");
  const { execution, candidates, descriptor, assertFence, aptEvidence } = validateRequest(request, registration, action);
  if (env.adapterReleaseDigest() !== request.release_digest) fail("host_release_unbound");
  let state = safeEnv.readJournal();
  let activation = null;
  if (action === "recover") {
    try {
      activation = env.readRecoveryActivation();
      validateHostRecoveryActivation(request, activation, assertFence);
    } catch (error) {
      const terminalState = state !== null &&
        validJournal(state, request.binding_digest) ?
        state : { entries: [], terminal: null };
      return terminal(
        terminalState, safeEnv,
        String(error?.code ?? error?.message ??
          "host_revalidation_fence_invalid"),
        request.binding_digest,
      );
    }
  }
  if (state !== null && !validJournal(state, request.binding_digest)) {
    return terminal(
      { entries: [], terminal: null }, safeEnv, "host_journal_corrupt",
      request.binding_digest, activation,
    );
  }
  state ??= { entries: [], terminal: null };
  if (action === "apply") {
    if (state.terminal !== null) {
      reconcileTerminal(state, safeEnv);
      return {
        outcome: state.terminal.state, reason: state.terminal.reason,
        journal: state,
      };
    }
    if (state.entries.at(-1)?.phase === "verify") {
      return { outcome: "applied", journal: state };
    }
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
      env.assertFenceCurrent(clone(request.lease_fence), request.lease_fence_digest);
      const checkedAt = safeEnv.now();
      if (!iso(checkedAt) || Date.parse(checkedAt) < Date.parse(request.lease_fence.activated_at) || Date.parse(checkedAt) > Date.parse(request.lease_fence.expires_at)) fail("host_fence_expired");
      verifyAptEvidence(safeEnv, candidates, aptEvidence);
      ok(safeEnv, ["/usr/bin/apt-get", "--assume-yes", "--no-install-recommends", "--no-remove", "--only-upgrade", "install", ...candidates.map(item => `${item.name}=${item.candidate_version}`)], "host_apply_failed");
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
  if (state.terminal?.state === "terminally-blocked") {
    if (state.terminal.activation_digest !== digest(activation) ||
        state.terminal.revalidation_fence_digest !==
          activation.fence_digest) {
      activateHostRecoveryFence(env, activation);
      return terminal(
        state, safeEnv, state.terminal.reason, request.binding_digest,
        activation,
      );
    }
    reconcileTerminal(state, safeEnv);
    return { outcome: state.terminal.state, reason: state.terminal.reason,
      journal: state };
  }
  const recoveryPhase = state.entries.at(-1)?.phase;
  if (state.entries.length === 0 ||
      !["apply", "inventory_after", "unknown", "recover", "quarantine",
        "disarm"].includes(recoveryPhase)) {
    return terminal(
      state, safeEnv, "host_recovery_not_eligible", request.binding_digest,
    );
  }
  const startedAt = safeEnv.now();
  if (!iso(startedAt)) {
    return terminal(
      state, safeEnv, "host_clock_unverified", request.binding_digest,
      activation,
    );
  }
  const started = Date.parse(startedAt);
  let recoveryFenceActivated = false;
  try {
    activateHostRecoveryFence(env, activation);
    recoveryFenceActivated = true;
    if (!["recover", "quarantine", "disarm"].includes(recoveryPhase)) {
      append(state, "recover", safeEnv, {
        recovery_descriptor_digest: request.recovery_descriptor_digest,
      }, request.binding_digest);
    }
    const deadline = Math.min(started + descriptor.budget_seconds * 1000, Date.parse(activation.fence.expires_at));
    if (!["quarantine", "disarm"].includes(recoveryPhase)) {
      recoveryOk(safeEnv, deadline, ["/usr/bin/dpkg", "--configure", "-a"], "host_recovery_repair_failed");
      for (const unit of descriptor.restart_units) recoveryOk(safeEnv, deadline, ["/usr/bin/systemctl", "try-restart", unit], "host_recovery_restart_failed");
      for (const packageName of descriptor.packages) recoveryOk(safeEnv, deadline, ["/usr/bin/apt-mark", "hold", packageName], "host_recovery_hold_failed");
      withinRecoveryBudget(safeEnv, deadline);
    }
    const after = hostInventory(safeEnv, candidates);
    if (canonicalJson(after) !== canonicalJson(execution.expected_postconditions)) fail("host_postconditions_unverifiable");
    if (!["quarantine", "disarm"].includes(recoveryPhase)) {
      append(state, "quarantine", safeEnv, {
        descriptor_id: descriptor.descriptor_id,
      }, request.binding_digest);
    }
    if (recoveryPhase !== "disarm") {
      append(state, "disarm", safeEnv, {
        binding_digest: request.binding_digest,
      }, request.binding_digest);
    }
    if (state.terminal !== null &&
        state.terminal.activation_digest === digest(activation) &&
        state.terminal.revalidation_fence_digest === activation.fence_digest) {
      reconcileTerminal(state, safeEnv);
      return { outcome: "disarmed", journal: state };
    }
    return disarmedTerminal(safeEnv, state, request, activation);
  } catch (error) {
    return terminal(
      state, safeEnv,
      String(error?.code ?? error?.message ?? "host_recovery_failed"),
      request.binding_digest, recoveryFenceActivated ? activation : null,
    );
  }
}

function validRecoveryFence(fence, expected) {
  return exactKeys(fence, [
    "kind", "schema_version", "domain", "target_scope_digest", "attempt_id",
    "mutation_id", "binding_digest", "epoch", "holder_token", "activated_at",
    "expires_at",
  ]) && fence.kind === "brokkr-effect-lease-fence" &&
    fence.schema_version === "v1" &&
    fence.domain === "no-reboot-security-bugfix-maintenance" &&
    fence.target_scope_digest === expected.target_scope_digest &&
    fence.attempt_id === expected.attempt_id &&
    fence.mutation_id === expected.mutation_id &&
    fence.binding_digest === expected.binding_digest &&
    Number.isSafeInteger(fence.epoch) && fence.epoch >= 1 &&
    typeof fence.holder_token === "string" &&
    fence.holder_token.length >= 16 &&
    iso(fence.activated_at) && iso(fence.expires_at) &&
    Date.parse(fence.activated_at) <= Date.parse(fence.expires_at);
}
function validateRecoveryDispatch(request, activation) {
  if (!exactKeys(request, [
    "idempotency_key", "descriptor_digest", "target_scope_digest",
    "binding_digest", "lease_fence", "lease_fence_digest",
    "revalidation_fence", "revalidation_fence_digest",
  ]) || !ID.test(request.idempotency_key) ||
      !DIGEST.test(request.descriptor_digest) ||
      !DIGEST.test(request.target_scope_digest) ||
      !DIGEST.test(request.binding_digest) ||
      !DIGEST.test(request.lease_fence_digest) ||
      !DIGEST.test(request.revalidation_fence_digest) ||
      request.lease_fence_digest !== digest(request.lease_fence) ||
      request.revalidation_fence_digest !== digest(request.revalidation_fence)) {
    fail("bounded_recovery_dispatch_contract_invalid");
  }
  const attempt = request.revalidation_fence?.attempt_id;
  const expected = {
    attempt_id: attempt,
    mutation_id: request.revalidation_fence?.mutation_id,
    target_scope_digest: request.target_scope_digest,
    binding_digest: request.binding_digest,
  };
  if (!ID.test(attempt) || !ID.test(expected.mutation_id) ||
      !validRecoveryFence(request.lease_fence, expected) ||
      !validRecoveryFence(request.revalidation_fence, expected) ||
      request.revalidation_fence.epoch <= request.lease_fence.epoch ||
      request.revalidation_fence.holder_token ===
        request.lease_fence.holder_token ||
      Date.parse(request.revalidation_fence.activated_at) <
        Date.parse(request.lease_fence.activated_at) ||
      Date.parse(request.revalidation_fence.expires_at) <=
        Date.parse(request.revalidation_fence.activated_at)) {
    fail("bounded_recovery_dispatch_fence_invalid");
  }
  if (!exactKeys(activation, [
    "kind", "schema_version", "attempt_id", "binding_digest",
    "recovery_descriptor_digest", "fence", "fence_digest",
  ]) || activation.kind !== "brokkr-debian-recovery-activation" ||
      activation.schema_version !== "v1" ||
      activation.attempt_id !== attempt ||
      activation.binding_digest !== request.binding_digest ||
      activation.recovery_descriptor_digest !== request.descriptor_digest ||
      activation.fence_digest !== request.revalidation_fence_digest ||
      canonicalJson(activation.fence) !==
        canonicalJson(request.revalidation_fence)) {
    fail("bounded_recovery_activation_invalid");
  }
  return attempt;
}
function recoveryReceipt(attempt, activation, request) {
  const activationDigest = digest(activation);
  const terminal = readFixed("terminals", attempt);
  if (!exactKeys(terminal, [
    "kind", "schema_version", "state", "reason", "at", "binding_digest",
    "activation_digest", "revalidation_fence_digest",
  ]) || terminal.kind !== "brokkr-debian-host-adapter-terminal" ||
      terminal.schema_version !== "v1" ||
      !["disarmed", "terminally-blocked"].includes(terminal.state) ||
      typeof terminal.reason !== "string" || terminal.reason.length === 0 ||
      terminal.binding_digest !== request.binding_digest ||
      terminal.activation_digest !== activationDigest ||
      terminal.revalidation_fence_digest !==
        request.revalidation_fence_digest ||
      (terminal.state === "disarmed" &&
        terminal.reason !== "forward_recovery_verified") ||
      !iso(terminal.at)) {
    fail("bounded_recovery_terminal_unverified");
  }
  const recovered = terminal.state === "disarmed";
  return {
    activation_digest: activationDigest,
    idempotency_key: request.idempotency_key,
    effect_lease_fence_digest: request.lease_fence_digest,
    revalidated_lease_fence_digest: request.revalidation_fence_digest,
    revalidated_at: terminal.at,
    recovered,
    safe_state_verified: recovered,
    quarantine_active: true,
    reason_code: recovered ? null : terminal.reason,
  };
}
function validStoredActivation(activation, request, attempt) {
  const expected = {
    attempt_id: attempt,
    mutation_id: request.revalidation_fence.mutation_id,
    target_scope_digest: request.target_scope_digest,
    binding_digest: request.binding_digest,
  };
  return exactKeys(activation, [
    "kind", "schema_version", "attempt_id", "binding_digest",
    "recovery_descriptor_digest", "fence", "fence_digest",
  ]) && activation.kind === "brokkr-debian-recovery-activation" &&
    activation.schema_version === "v1" &&
    activation.attempt_id === attempt &&
    activation.binding_digest === request.binding_digest &&
    activation.recovery_descriptor_digest === request.descriptor_digest &&
    activation.fence_digest === digest(activation.fence) &&
    validRecoveryFence(activation.fence, expected);
}
function validPriorBoundTerminal(terminal, request) {
  return exactKeys(terminal, [
    "kind", "schema_version", "state", "reason", "at", "binding_digest",
    "activation_digest", "revalidation_fence_digest",
  ]) && terminal.kind === "brokkr-debian-host-adapter-terminal" &&
    terminal.schema_version === "v1" &&
    ["disarmed", "terminally-blocked"].includes(terminal.state) &&
    typeof terminal.reason === "string" && terminal.reason.length > 0 &&
    (terminal.state !== "disarmed" ||
      terminal.reason === "forward_recovery_verified") &&
    terminal.binding_digest === request.binding_digest &&
    DIGEST.test(terminal.activation_digest) &&
    DIGEST.test(terminal.revalidation_fence_digest) && iso(terminal.at);
}
function dispatchFixedRecovery(request, activation) {
  const attempt = validateRecoveryDispatch(request, activation);
  if (process.getuid() !== 0) fail("host_root_required");
  protectedDirectory(STATE_ROOT);
  assertRecoveryAuthorization(attempt, activation, request);
  protectedDirectory(path.join(STATE_ROOT, "recovery-activations"));
  const existingActivation = fixedReadOptional(
    "recovery-activations", attempt,
  );
  if (existingActivation === null) {
    atomicWriteFixed("recovery-activations", attempt, activation);
  } else if (canonicalJson(existingActivation) !== canonicalJson(activation)) {
    if (!validStoredActivation(existingActivation, request, attempt) ||
        activation.fence.epoch <= existingActivation.fence.epoch ||
        activation.fence.holder_token ===
          existingActivation.fence.holder_token ||
        Date.parse(activation.fence.activated_at) <
          Date.parse(existingActivation.fence.activated_at)) {
      fail("bounded_recovery_activation_conflict");
    }
    atomicWriteFixed("recovery-activations", attempt, activation);
  }
  const existingTerminal = fixedReadOptional("terminals", attempt);
  if (existingTerminal !== null) {
    try {
      return recoveryReceipt(attempt, activation, request);
    } catch (error) {
      if (!validPriorBoundTerminal(existingTerminal, request)) throw error;
      // A newly authorized successor may resume after the prior worker
      // terminalized but crashed before W2a durably accepted its receipt.
      // Start the fixed unit so it validates the successor and rebinds the
      // durable receipt without widening or replaying the original effect.
    }
  }
  const unit = `brokkr-debian-maintenance-recovery@${attempt}.service`;
  const result = fixedSpawnSync(
    "/usr/bin/systemctl", ["start", unit],
    { encoding: "utf8", timeout: 300_000 },
  );
  try {
    return recoveryReceipt(attempt, activation, request);
  } catch (error) {
    if (result.status !== 0) fail("bounded_recovery_fixed_adapter_failed");
    throw error;
  }
}

export function runFixedDebianMaintenanceHostOperation(input) {
  if (!exactKeys(input, ["action", "request", "registration"]) ||
      !["apply", "recover", "dispatch-recovery"].includes(input.action) ||
      !plain(input.request) || !plain(input.registration)) {
    fail("host_operation_contract_invalid");
  }
  const { action, request, registration } = input;
  if (action === "dispatch-recovery") {
    return dispatchFixedRecovery(request, registration);
  }

  // Complete structural validation and canonical attempt derivation happen
  // before the first caller-derived fixed-path lookup.
  validateRequest(request, registration, action);
  const attempt = request.attempt_id;
  assertAttempt(attempt);
  if (process.getuid() !== 0) fail("host_root_required");
  assertFixedInputBinding(attempt, request, registration);
  const activation = action === "recover" ?
    readFixed("recovery-activations", attempt) : null;
  if (action === "recover") {
    const authorization = assertRecoveryAuthorization(attempt, activation);
    validateRecoveryDispatch(
      authorization.recovery_request, authorization.activation,
    );
  }
  assertEffectLock(attempt);
  return runHostAdapterCore({
    action, request, registration,
    env: {
      uid: process.getuid(),
      now: fixedNow,
      run: fixedRun,
      rebootRequired: fixedRebootRequired,
      adapterReleaseDigest: fixedReleaseDigest,
      activateFence: fence => fixedActivateFence(attempt, fence),
      assertFenceCurrent: (fence, leaseFenceDigest) =>
        fixedAssertFenceCurrent(attempt, fence, leaseFenceDigest),
      readRecoveryActivation: () => clone(activation),
      readJournal: () => fixedReadOptional("journals", attempt),
      readTerminal: () => fixedReadOptional("terminals", attempt),
      writeJournal: value => atomicWriteFixed("journals", attempt, value),
      writeTerminal: value => atomicWriteFixed("terminals", attempt, value),
    },
  });
}
