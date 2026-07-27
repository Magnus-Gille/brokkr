// Production-only recovery host. Its state location and systemd adapter are
// deliberately fixed: the public maintenance runner has no callback, factory,
// executable, or path injection surface for this consequential handoff.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const DIGEST = /^sha256:[a-f0-9]{64}$/;
const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const fail = code => { const error = new Error(code); error.code = code; throw error; };
const plain = value => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value, keys) => plain(value) && Object.keys(value).sort().join(",") === [...keys].sort().join(",");
const canonicalJson = value => value === null || typeof value !== "object" ? JSON.stringify(value) : Array.isArray(value) ? `[${value.map(canonicalJson).join(",")}]` : `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
const digest = value => `sha256:${crypto.createHash("sha256").update(canonicalJson(value)).digest("hex")}`;

const stateRoot = "/var/lib/brokkr/debian-maintenance";
const activationDirectory = path.join(stateRoot, "recovery-activations");
const terminalDirectory = path.join(stateRoot, "terminals");
const protectedDirectory = directory => {
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== 0 || (stat.mode & 0o077) !== 0) fail("bounded_recovery_state_unsafe");
};
const readJson = file => {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== 0 || (stat.mode & 0o077) !== 0) fail("bounded_recovery_state_unsafe");
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { fail("bounded_recovery_state_invalid"); }
};

export function runFixedBoundedRecoveryHost({ action, attempt_id: attemptId, activation, recovery_request: request }) {
  if (action !== "recover" || typeof attemptId !== "string" || !plain(activation) || !plain(request)) fail("bounded_recovery_fixed_host_contract_invalid");
  protectedDirectory(stateRoot); protectedDirectory(activationDirectory);
  const file = path.join(activationDirectory, `${attemptId}.json`);
  const activationDigest = digest(activation);
  if (fs.existsSync(file)) {
    if (canonicalJson(readJson(file)) !== canonicalJson(activation)) fail("bounded_recovery_activation_conflict");
  } else {
    const temporary = `${file}.${process.pid}.${crypto.randomUUID()}`;
    const fd = fs.openSync(temporary, "wx", 0o600);
    try { fs.writeFileSync(fd, `${canonicalJson(activation)}\n`); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    fs.renameSync(temporary, file);
    const directory = fs.openSync(activationDirectory, "r"); try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
  }
  const unit = `brokkr-debian-maintenance-recovery@${attemptId}.service`;
  const result = spawnSync("/usr/bin/systemctl", ["start", unit], { encoding: "utf8", timeout: 300_000 });
  if (result.status !== 0) fail("bounded_recovery_fixed_adapter_failed");
  protectedDirectory(stateRoot); protectedDirectory(terminalDirectory);
  const terminal = readJson(path.join(terminalDirectory, `${attemptId}.json`));
  if (!exactKeys(terminal, ["kind", "schema_version", "state", "reason", "at", "binding_digest", "activation_digest", "revalidation_fence_digest"]) || terminal.kind !== "brokkr-debian-host-adapter-terminal" || terminal.schema_version !== "v1" || terminal.state !== "disarmed" || terminal.reason !== "forward_recovery_verified" || terminal.binding_digest !== request.binding_digest || terminal.activation_digest !== activationDigest || terminal.revalidation_fence_digest !== request.revalidation_fence_digest || !ISO.test(terminal.at)) fail("bounded_recovery_terminal_unverified");
  return { activation_digest: activationDigest, idempotency_key: request.idempotency_key, effect_lease_fence_digest: request.lease_fence_digest, revalidated_lease_fence_digest: request.revalidation_fence_digest, revalidated_at: terminal.at, recovered: true, safe_state_verified: true, quarantine_active: true, reason_code: null };
}
