#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DIGEST = /^sha256:[a-f0-9]{64}$/;
const REVISION = /^[a-f0-9]{40}$/;
const MAX_FRAGMENT_BYTES = 64 * 1024;
const EXPECTED = new Map([
  ["clean-run", { outcome: "committed", quarantine: false }],
  ["controller-kill-9", { outcome: "disarmed", quarantine: true }],
  ["progress-loop-wedge", { outcome: "disarmed", quarantine: true }],
  ["interrupted-package-state", { outcome: "disarmed", quarantine: true }],
  ["lock-contention", { outcome: "terminally-blocked", quarantine: true }],
  ["network-loss", { outcome: "terminally-blocked", quarantine: true }],
  ["disk-headroom-failure", {
    outcome: "terminally-blocked", quarantine: true,
  }],
  ["postcondition-failure", {
    outcome: "terminally-blocked", quarantine: true,
  }],
  ["recovery-crash-loop", { outcome: "disarmed", quarantine: true }],
  ["unknown-reachability", {
    outcome: "terminally-blocked", quarantine: true,
  }],
  ["terminal-exhaustion", {
    outcome: "terminally-blocked", quarantine: true,
  }],
]);

const fail = code => {
  const error = new Error(code);
  error.code = code;
  throw error;
};
const plain = value =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value, keys) =>
  plain(value) &&
  Object.keys(value).sort().join(",") === [...keys].sort().join(",");
const digestFile = relative =>
  `sha256:${crypto.createHash("sha256")
    .update(fs.readFileSync(path.join(ROOT, relative))).digest("hex")}`;
const strictUtc = value =>
  typeof value === "string" &&
  /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(value) &&
  new Date(value).toISOString().replace(".000Z", "Z") === value;

function parseArguments(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!["--revision", "--controller", "--host", "--output"].includes(flag) ||
        typeof value !== "string") {
      fail("supervised_fi_arguments_invalid");
    }
    result[flag.slice(2)] = value;
  }
  if (!exactKeys(result, ["revision", "controller", "host", "output"]) ||
      !REVISION.test(result.revision) ||
      !path.isAbsolute(result.controller) ||
      !path.isAbsolute(result.host) ||
      !path.isAbsolute(result.output)) {
    fail("supervised_fi_arguments_invalid");
  }
  return result;
}

function readFragment(file) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() ||
      stat.size < 2 || stat.size > MAX_FRAGMENT_BYTES) {
    fail("supervised_fi_fragment_unsafe");
  }
  let fragment;
  try {
    fragment = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    fail("supervised_fi_fragment_invalid");
  }
  if (!exactKeys(fragment, [
    "kind", "schema_version", "path_id", "production_path", "scenarios",
  ]) ||
      fragment.kind !== "brokkr-supervised-debian-fi-fragment" ||
      fragment.schema_version !== "v1" ||
      fragment.path_id !== "w2a-w2b-production-v1" ||
      !plain(fragment.production_path) ||
      !Array.isArray(fragment.scenarios)) {
    fail("supervised_fi_fragment_invalid");
  }
  return fragment;
}

function validateScenario(value) {
  if (!exactKeys(value, [
    "id", "outcome", "path_id", "passed", "quarantine_active",
    "new_plan_mutations", "budget_seconds", "observed_elapsed_seconds",
    "terminal_at",
  ]) ||
      !EXPECTED.has(value.id) ||
      value.path_id !== "w2a-w2b-production-v1" ||
      value.passed !== true ||
      value.outcome !== EXPECTED.get(value.id).outcome ||
      value.quarantine_active !== EXPECTED.get(value.id).quarantine ||
      value.new_plan_mutations !== 0 ||
      !Number.isSafeInteger(value.budget_seconds) ||
      value.budget_seconds < 1 ||
      !Number.isSafeInteger(value.observed_elapsed_seconds) ||
      value.observed_elapsed_seconds < 0 ||
      value.observed_elapsed_seconds > value.budget_seconds ||
      !strictUtc(value.terminal_at)) {
    fail("supervised_fi_scenario_invalid");
  }
  return structuredClone(value);
}

function atomicWrite(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const serialized = Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, "wx", 0o600);
    fs.writeFileSync(descriptor, serialized);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporary, file);
    const directory = fs.openSync(path.dirname(file), "r");
    try {
      fs.fsyncSync(directory);
    } finally {
      fs.closeSync(directory);
    }
  } catch (error) {
    try {
      fs.unlinkSync(temporary);
    } catch {
      // Only this unique failed temporary is eligible for cleanup.
    }
    throw error;
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

const args = parseArguments(process.argv.slice(2));
const controller = readFragment(args.controller);
const host = readFragment(args.host);
const productionPath = {
  controller: digestFile("scripts/debian-maintenance-autonomy.mjs"),
  bounded_recovery_dispatcher: digestFile(
    "scripts/lib/bounded-recovery-dispatch.mjs",
  ),
  host_operation: digestFile(
    "scripts/lib/fixed-debian-maintenance-host-operation.mjs",
  ),
  recovery_unit: digestFile(
    "systemd/brokkr-debian-maintenance-recovery.service.in",
  ),
};
if (!exactKeys(controller.production_path, [
  "controller", "bounded_recovery_dispatcher",
]) ||
    !exactKeys(host.production_path, ["host_operation", "recovery_unit"]) ||
    Object.entries({
      ...controller.production_path,
      ...host.production_path,
    }).some(([key, value]) =>
      !DIGEST.test(value) || value !== productionPath[key])) {
  fail("supervised_fi_production_path_drift");
}

const scenarios = [...controller.scenarios, ...host.scenarios]
  .map(validateScenario)
  .sort((left, right) => left.id.localeCompare(right.id));
if (scenarios.length !== EXPECTED.size ||
    new Set(scenarios.map(value => value.id)).size !== EXPECTED.size ||
    [...EXPECTED.keys()].some(id => !scenarios.some(value => value.id === id))) {
  fail("supervised_fi_scenario_set_invalid");
}

const generatedAt = new Date(
  Math.floor(Date.now() / 1000) * 1000,
).toISOString().replace(".000Z", "Z");
if (!strictUtc(generatedAt)) fail("supervised_fi_clock_invalid");
const dossier = {
  kind: "brokkr-supervised-debian-fault-injection-dossier",
  schema_version: "v1",
  release_sha: args.revision,
  generated_at: generatedAt,
  clean_runs: scenarios.filter(value => value.id === "clean-run").length,
  induced_failures:
    scenarios.filter(value => value.id !== "clean-run").length,
  production_path: productionPath,
  scenarios,
  redaction: {
    private_locators: "excluded",
    package_logs: "excluded",
  },
};
atomicWrite(args.output, dossier);
process.stdout.write(
  `supervised FI dossier: ${dossier.clean_runs} clean, ` +
  `${dossier.induced_failures} induced; no live action\n`,
);
