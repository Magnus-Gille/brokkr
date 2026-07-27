// Fixed production dependencies for the root-only Debian host adapter.
// No path, executable, callback, or state-root choice is caller configurable.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const STATE_ROOT = "/var/lib/brokkr/debian-maintenance";
const ADAPTER_FILE = fileURLToPath(new URL("../debian-maintenance-host-adapter.mjs", import.meta.url));
const DEPENDENCY_FILE = fileURLToPath(import.meta.url);
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const canonicalJson = value => {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
};
const digest = value => `sha256:${crypto.createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
const fail = code => { const error = new Error(code); error.code = code; throw error; };
const exactKeys = (value, keys) => value !== null && typeof value === "object" && !Array.isArray(value) &&
  Object.keys(value).sort().join(",") === [...keys].sort().join(",");
const clone = value => structuredClone(value);
const assertAttempt = attempt => { if (!ID.test(attempt)) fail("host_attempt_invalid"); };

function regularRootOwned(file) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== 0 || (stat.mode & 0o077) !== 0) fail("host_input_file_unsafe");
}
function protectedDirectory(directory, create = false) {
  if (create && !fs.existsSync(directory)) fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== 0 || (stat.mode & 0o077) !== 0) fail("host_state_root_unsafe");
}
function readJson(file) {
  regularRootOwned(file);
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { fail("host_input_json_invalid"); }
}
function atomicWrite(file, value) {
  protectedDirectory(STATE_ROOT);
  protectedDirectory(path.dirname(file), true);
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}`;
  const fd = fs.openSync(temporary, "wx", 0o600);
  try { fs.writeFileSync(fd, `${canonicalJson(value)}\n`); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(temporary, file);
  const directory = fs.openSync(path.dirname(file), "r");
  try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
}

export function readFixedHostInputs(attempt) {
  assertAttempt(attempt);
  protectedDirectory(STATE_ROOT);
  protectedDirectory(path.join(STATE_ROOT, "requests"));
  protectedDirectory(path.join(STATE_ROOT, "registrations"));
  return {
    request: readJson(path.join(STATE_ROOT, "requests", `${attempt}.json`)),
    registration: readJson(path.join(STATE_ROOT, "registrations", `${attempt}.json`)),
  };
}

function hostFiles(attempt) {
  assertAttempt(attempt);
  protectedDirectory(STATE_ROOT);
  protectedDirectory(path.join(STATE_ROOT, "recovery-activations"));
  return {
    journal: path.join(STATE_ROOT, "journals", `${attempt}.json`),
    terminal: path.join(STATE_ROOT, "terminals", `${attempt}.json`),
    fence: path.join(STATE_ROOT, "fences", `${attempt}.json`),
    activation: path.join(STATE_ROOT, "recovery-activations", `${attempt}.json`),
  };
}

export const fixedUid = () => process.getuid();
export const fixedNow = () => new Date().toISOString().replace(".000Z", "Z");
export function fixedRun(argv, options = {}) {
  const result = spawnSync(argv[0], argv.slice(1), { encoding: "utf8", timeout: options.timeoutMs ?? 120_000 });
  return { status: result.status ?? 1, stdout: result.stdout ?? "" };
}
export const fixedRebootRequired = () => fs.existsSync("/var/run/reboot-required");
export const fixedAdapterReleaseDigest = () => `sha256:${crypto.createHash("sha256").update(fs.readFileSync(ADAPTER_FILE)).digest("hex")}`;
export function assertFixedDependencyDigest(expected) {
  const actual = `sha256:${crypto.createHash("sha256").update(fs.readFileSync(DEPENDENCY_FILE)).digest("hex")}`;
  if (actual !== expected) fail("host_fixed_dependency_unbound");
}
export function fixedAssertEffectLock(attempt) {
  protectedDirectory(path.join(STATE_ROOT, "fences"));
  const lockFile = hostFiles(attempt).fence.replace(/\.json$/, ".effect-lock");
  const lock = fs.lstatSync(lockFile);
  const matchingInheritedDescriptor = fs.readdirSync("/proc/self/fd").some(name => {
    if (!/^\d+$/.test(name) || Number(name) <= 2) return false;
    try {
      const descriptor = fs.fstatSync(Number(name));
      return descriptor.isFile() && descriptor.dev === lock.dev && descriptor.ino === lock.ino;
    } catch { return false; }
  });
  if (!matchingInheritedDescriptor || !lock.isFile() || lock.isSymbolicLink() ||
    lock.uid !== 0 || (lock.mode & 0o077) !== 0) fail("host_effect_lock_unverified");
  const contender = spawnSync("/usr/bin/flock", ["--nonblock", lockFile, "/usr/bin/true"], { encoding: "utf8" });
  if (contender.status !== 1) fail("host_effect_lock_unverified");
}
export function fixedActivateFence(attempt, fence) {
  const fenceFile = hostFiles(attempt).fence;
  protectedDirectory(path.dirname(fenceFile), true);
  const existing = fs.existsSync(fenceFile) ? readJson(fenceFile) : null;
  if (existing !== null) {
    if (!exactKeys(existing, ["fence", "lease_fence_digest"]) || existing.lease_fence_digest !== digest(existing.fence)) fail("host_fence_store_corrupt");
    if (existing.fence.epoch > fence.epoch || (existing.fence.epoch === fence.epoch && existing.lease_fence_digest !== digest(fence))) fail("host_fence_superseded");
  }
  atomicWrite(fenceFile, { fence: clone(fence), lease_fence_digest: digest(fence) });
  return { activated: true, lease_fence_digest: digest(fence) };
}
export function fixedAssertFenceCurrent(attempt, fence, leaseFenceDigest) {
  if (leaseFenceDigest !== digest(fence)) fail("host_fence_digest_invalid");
  const current = readJson(hostFiles(attempt).fence);
  if (canonicalJson(current) !== canonicalJson({ fence, lease_fence_digest: leaseFenceDigest })) fail("host_fence_superseded");
}
export const fixedReadRecoveryActivation = attempt => readJson(hostFiles(attempt).activation);
export function fixedReadJournal(attempt) {
  const journal = hostFiles(attempt).journal;
  return fs.existsSync(journal) ? readJson(journal) : null;
}
export const fixedWriteJournal = (attempt, value) => atomicWrite(hostFiles(attempt).journal, value);
export const fixedWriteTerminal = (attempt, value) => atomicWrite(hostFiles(attempt).terminal, value);
