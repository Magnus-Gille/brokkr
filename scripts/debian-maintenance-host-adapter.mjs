#!/usr/bin/env node
// Fixed CLI for the single production host operation. The CLI chooses no
// command, path, unit, or writer: it only validates a canonical attempt ID,
// acquires the fixed effect lock with flock --no-fork, reads the two fixed
// root-owned inputs, and passes their untrusted values across the closed
// operation boundary for independent revalidation.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { runFixedDebianMaintenanceHostOperation } from "./lib/fixed-debian-maintenance-host-operation.mjs";

const STATE_ROOT = "/var/lib/brokkr/debian-maintenance";
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const fail = code => { const error = new Error(code); error.code = code; throw error; };
const canonicalJson = value => value === null || typeof value !== "object" ?
  JSON.stringify(value) : Array.isArray(value) ?
    `[${value.map(canonicalJson).join(",")}]` :
    `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;

function protectedDirectory(directory) {
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== 0 ||
      (stat.mode & 0o077) !== 0) fail("host_state_root_unsafe");
}
function readFixedJson(directory, attempt) {
  protectedDirectory(directory);
  const file = path.join(directory, `${attempt}.json`);
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
function readInputs(attempt) {
  protectedDirectory(STATE_ROOT);
  return {
    request: readFixedJson(path.join(STATE_ROOT, "requests"), attempt),
    registration: readFixedJson(path.join(STATE_ROOT, "registrations"), attempt),
  };
}
function cli() {
  const [flag, action, attemptFlag, attempt] = process.argv.slice(2);
  if (flag !== "--action" || !["apply", "recover"].includes(action) ||
      attemptFlag !== "--attempt" || !ID.test(attempt) ||
      process.argv.length !== 6) fail("host_cli_arguments_invalid");
  if (process.getuid() !== 0) fail("host_root_required");
  protectedDirectory(STATE_ROOT);
  const fenceDirectory = path.join(STATE_ROOT, "fences");
  if (!fs.existsSync(fenceDirectory)) {
    fs.mkdirSync(fenceDirectory, { recursive: true, mode: 0o700 });
  }
  protectedDirectory(fenceDirectory);
  const lockFile = path.join(fenceDirectory, `${attempt}.effect-lock`);
  if (process.env.BROKKR_EFFECT_LOCKED !== "1") {
    const lockFd = fs.openSync(
      lockFile,
      fs.constants.O_RDWR | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW,
      0o600,
    );
    try {
      const lockStat = fs.fstatSync(lockFd);
      if (!lockStat.isFile() || lockStat.uid !== 0 ||
          (lockStat.mode & 0o077) !== 0) fail("host_effect_lock_unverified");
    } finally {
      fs.closeSync(lockFd);
    }
    const child = spawnSync("/usr/bin/flock", [
      "--nonblock", "--no-fork", lockFile,
      process.execPath, fileURLToPath(import.meta.url),
      "--action", action, "--attempt", attempt,
    ], {
      encoding: "utf8",
      env: { ...process.env, BROKKR_EFFECT_LOCKED: "1" },
    });
    process.stdout.write(child.stdout ?? "");
    process.stderr.write(child.stderr ?? "");
    process.exitCode = child.status ?? 1;
    return;
  }
  const { request, registration } = readInputs(attempt);
  const result = runFixedDebianMaintenanceHostOperation({
    action, request, registration,
  });
  process.stdout.write(`${canonicalJson({
    outcome: result.outcome, reason: result.reason ?? null,
  })}\n`);
  process.exitCode = ["applied", "disarmed"].includes(result.outcome) ? 0 : 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) cli();
