#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import net from "node:net";
import crypto from "node:crypto";

const TRACKED_FRAGMENT_SHA256 = "1d0f253f028ad9474835d9dbb35b19cb946ed6b56074343ae6ffbdbef65e39dd";

function fail(code) {
  process.stderr.write(`${JSON.stringify({ schema_version: "v1", outcome: "error", error: code })}\n`);
  process.exit(1);
}

function parseArgs() {
  const parsed = new Map();
  for (let i = 2; i < process.argv.length; i += 2) {
    if (!process.argv[i]?.startsWith("--") || i + 1 >= process.argv.length) fail("invalid_arguments");
    parsed.set(process.argv[i], process.argv[i + 1]);
  }
  return parsed;
}

function readJson(file, privateInput) {
  try {
    const resolved = path.resolve(file);
    const stat = fs.lstatSync(resolved);
    if (!stat.isFile() || stat.isSymbolicLink()) fail(privateInput ? "private_input_unsafe" : "template_invalid");
    if (privateInput && (stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o600)) fail("private_input_unsafe");
    return JSON.parse(fs.readFileSync(resolved, "utf8"));
  } catch {
    fail(privateInput ? "private_input_unsafe" : "template_invalid");
  }
}

const ROLE_TAG = new Map([
  ["m5-server", "tag:m5-server"],
  ["m5-inference", "tag:m5-inference"],
  ["m5-gateway-client", "tag:m5-gateway-client"],
  ["m5-whisper-client", "tag:m5-whisper-client"],
  ["m5-runtime-client", "tag:m5-runtime-client"],
]);
const USER_ROLE_HOST = new Map([
  ["m5-operator", ["m5-operator-device", "__BROKKR_OPERATOR_ADDRESS__"]],
  ["m5-ordinary-deny-probe", ["m5-ordinary-deny-probe", "__BROKKR_ORDINARY_DENY_PROBE_ADDRESS__"]],
  ["m5-guest-deny-probe", ["m5-guest-deny-probe", "__BROKKR_GUEST_DENY_PROBE_ADDRESS__"]],
]);

function ordered(value) {
  if (Array.isArray(value)) return value.map(ordered);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, ordered(value[key])]));
  }
  return value;
}

function canonical(value) {
  return JSON.stringify(ordered(value));
}

function sortedUnique(values) {
  if (!Array.isArray(values) || values.some((value) => typeof value !== "string")) return null;
  const sorted = [...values].sort();
  return new Set(sorted).size === sorted.length ? sorted : null;
}

function validBindings(manifest) {
  if (manifest?.schema_version !== "v1" || !Array.isArray(manifest.bindings)) return false;
  const ids = new Set();
  const addresses = new Set();
  const roleCounts = new Map();
  let serverId = null;
  let inferenceId = null;
  for (const binding of manifest.bindings) {
    if (!binding || typeof binding.stable_id !== "string" || !binding.stable_id || ids.has(binding.stable_id)) return false;
    ids.add(binding.stable_id);
    const roles = sortedUnique(binding.roles);
    const managedTags = sortedUnique(binding.managed_tags);
    if (!roles || !managedTags) return false;
    for (const role of roles) {
      if (!USER_ROLE_HOST.has(role) && !ROLE_TAG.has(role)) return false;
      roleCounts.set(role, (roleCounts.get(role) ?? 0) + 1);
    }
    const expectedTags = roles.filter((role) => ROLE_TAG.has(role)).map((role) => ROLE_TAG.get(role)).sort();
    if (JSON.stringify(managedTags) !== JSON.stringify(expectedTags)) return false;
    const userRoles = roles.filter((role) => USER_ROLE_HOST.has(role));
    if (userRoles.length > 0) {
      if (binding.identity_kind !== "user" || roles.length !== 1 || managedTags.length !== 0) return false;
      if (typeof binding.observed_user !== "string" || !binding.observed_user) return false;
      if (typeof binding.address !== "string" || net.isIP(binding.address) === 0 || addresses.has(binding.address)) return false;
      addresses.add(binding.address);
    } else if (binding.identity_kind !== "tagged" || binding.address !== undefined || binding.observed_user !== undefined) {
      return false;
    }
    if (roles.includes("m5-server")) serverId = binding.stable_id;
    if (roles.includes("m5-inference")) inferenceId = binding.stable_id;
  }
  for (const role of [...USER_ROLE_HOST.keys(), ...ROLE_TAG.keys()]) if (roleCounts.get(role) !== 1) return false;
  return serverId !== null && serverId === inferenceId;
}

const args = parseArgs();
const templatePath = args.get("--template");
const bindingsPath = args.get("--bindings");
const outputPath = args.get("--output");
if (!templatePath || !bindingsPath || !outputPath || args.size !== 3) fail("invalid_arguments");

const template = readJson(templatePath, false);
const bindings = readJson(bindingsPath, true);
if (!validBindings(bindings)) fail("bindings_invalid");
const fragmentDigest = crypto.createHash("sha256").update(canonical(template)).digest("hex");
if (fragmentDigest !== TRACKED_FRAGMENT_SHA256) {
  fail("template_invalid");
}
for (const [role, [host, marker]] of USER_ROLE_HOST) {
  if (template.hosts?.[host] !== marker) fail("template_invalid");
  template.hosts[host] = bindings.bindings.find((binding) => binding.roles.includes(role)).address;
}
if (JSON.stringify(template).includes("__BROKKR_")) fail("template_invalid");

const output = path.resolve(outputPath);
let descriptor;
try {
  descriptor = fs.openSync(output, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
  fs.writeFileSync(descriptor, `${JSON.stringify(template, null, 2)}\n`, "utf8");
  fs.fsyncSync(descriptor);
  fs.closeSync(descriptor);
} catch {
  if (descriptor !== undefined) {
    try { fs.closeSync(descriptor); } catch { /* already closed */ }
  }
  fail("output_unsafe");
}

process.stdout.write(`${JSON.stringify({ schema_version: "v1", outcome: "rendered" })}\n`);
