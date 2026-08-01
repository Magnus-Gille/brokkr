#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import net from "node:net";

const MANAGED_TAGS = new Set([
  "tag:m5-server",
  "tag:m5-inference",
  "tag:m5-gateway-client",
  "tag:m5-whisper-client",
  "tag:m5-runtime-client",
  "tag:ordinary-client",
  "tag:guest-client",
]);
const ROLE_TAG = new Map([
  ["m5-server", "tag:m5-server"],
  ["m5-inference", "tag:m5-inference"],
  ["m5-gateway-client", "tag:m5-gateway-client"],
  ["m5-whisper-client", "tag:m5-whisper-client"],
  ["m5-runtime-client", "tag:m5-runtime-client"],
]);

function fail(code) {
  process.stderr.write(`${JSON.stringify({ schema_version: "v1", outcome: "error", error: code })}\n`);
  process.exit(1);
}

function parseArgs() {
  const parsed = new Map();
  for (let i = 2; i < process.argv.length; i += 1) {
    const key = process.argv[i];
    if (key === "--live") {
      parsed.set(key, true);
      continue;
    }
    if (!key.startsWith("--") || i + 1 >= process.argv.length) fail("invalid_arguments");
    parsed.set(key, process.argv[i + 1]);
    i += 1;
  }
  return parsed;
}

function readPrivateJson(file) {
  try {
    const resolved = path.resolve(file);
    const stat = fs.lstatSync(resolved);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o600) {
      fail("private_input_unsafe");
    }
    return JSON.parse(fs.readFileSync(resolved, "utf8"));
  } catch {
    fail("private_input_unsafe");
  }
}

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

function validateBindings(manifest) {
  if (manifest?.schema_version !== "v1" || !Array.isArray(manifest.bindings)) fail("bindings_invalid");
  const ids = new Set();
  const roleCounts = new Map();
  let operatorId = null;
  for (const binding of manifest.bindings) {
    if (!binding || typeof binding.stable_id !== "string" || !binding.stable_id || ids.has(binding.stable_id)) fail("bindings_invalid");
    ids.add(binding.stable_id);
    const roles = sortedUnique(binding.roles);
    const managedTags = sortedUnique(binding.managed_tags);
    if (!roles || !managedTags) fail("bindings_invalid");
    for (const role of roles) {
      if (role !== "m5-operator" && !ROLE_TAG.has(role)) fail("bindings_invalid");
      roleCounts.set(role, (roleCounts.get(role) ?? 0) + 1);
    }
    const expectedTags = roles.filter((role) => ROLE_TAG.has(role)).map((role) => ROLE_TAG.get(role)).sort();
    if (canonical(managedTags) !== canonical(expectedTags)) fail("bindings_invalid");
    if (roles.includes("m5-operator")) {
      if (binding.identity_kind !== "user" || roles.length !== 1 || managedTags.length !== 0 || operatorId !== null) fail("bindings_invalid");
      if (typeof binding.observed_user !== "string" || !binding.observed_user) fail("bindings_invalid");
      if (typeof binding.operator_address !== "string" || net.isIP(binding.operator_address) === 0) fail("bindings_invalid");
      operatorId = binding.stable_id;
    } else if (binding.identity_kind !== "tagged" || binding.operator_address !== undefined) {
      fail("bindings_invalid");
    }
  }
  for (const role of ["m5-operator", ...ROLE_TAG.keys()]) if (roleCounts.get(role) !== 1) fail("bindings_invalid");
  const server = manifest.bindings.find((binding) => binding.roles.includes("m5-server"))?.stable_id;
  const inference = manifest.bindings.find((binding) => binding.roles.includes("m5-inference"))?.stable_id;
  if (!server || server !== inference || operatorId === null) fail("bindings_invalid");
  return manifest;
}

async function apiJson(endpoint, code) {
  const tailnet = process.env.TAILSCALE_TAILNET;
  const token = process.env.TAILSCALE_API_TOKEN;
  if (!tailnet || !token) fail("live_credentials_required");
  let response;
  try {
    response = await fetch(`https://api.tailscale.com/api/v2${endpoint.replace(":tailnet", encodeURIComponent(tailnet))}`, {
      method: "GET",
      headers: { Accept: "application/json", Authorization: `Bearer ${token}` },
      redirect: "error",
    });
  } catch {
    fail(code);
  }
  if (!response.ok) fail(code);
  try {
    const parsed = await response.json();
    return typeof parsed === "string" ? JSON.parse(parsed) : parsed;
  } catch {
    fail(code);
  }
}

function bindingsMatch(manifest, devices) {
  const byId = new Map(devices.map((device) => [String(device?.id ?? ""), device]));
  const expectedById = new Map(manifest.bindings.map((binding) => [binding.stable_id, binding]));
  for (const binding of manifest.bindings) {
    const device = byId.get(binding.stable_id);
    if (!device) return false;
    const actualManaged = sortedUnique((Array.isArray(device.tags) ? device.tags : []).filter((tag) => MANAGED_TAGS.has(tag)));
    if (!actualManaged || canonical(actualManaged) !== canonical([...binding.managed_tags].sort())) return false;
    if (binding.identity_kind === "user") {
      if (String(device.user ?? "") !== binding.observed_user) return false;
      if (!Array.isArray(device.addresses) || !device.addresses.includes(binding.operator_address)) return false;
    }
  }
  for (const device of devices) {
    const id = String(device?.id ?? "");
    const actualManaged = sortedUnique((Array.isArray(device?.tags) ? device.tags : []).filter((tag) => MANAGED_TAGS.has(tag)));
    if (!actualManaged) return false;
    const expected = expectedById.get(id)?.managed_tags ?? [];
    if (canonical(actualManaged) !== canonical([...expected].sort())) return false;
  }
  return true;
}

const args = parseArgs();
const expectedPath = args.get("--expected-policy");
const bindingsPath = args.get("--expected-bindings");
if (!expectedPath || !bindingsPath) fail("expected_inputs_required");
const expectedPolicy = readPrivateJson(expectedPath);
const bindings = validateBindings(readPrivateJson(bindingsPath));

let observedPolicy;
let settings;
let devicesResponse;
if (args.get("--live")) {
  if (["--observed-policy", "--observed-settings", "--observed-devices"].some((key) => args.has(key))) {
    fail("mixed_observation_modes");
  }
  observedPolicy = await apiJson("/tailnet/:tailnet/acl", "policy_read_failed");
  settings = await apiJson("/tailnet/:tailnet/settings", "settings_read_failed");
  devicesResponse = await apiJson("/tailnet/:tailnet/devices", "devices_read_failed");
} else {
  const required = ["--observed-policy", "--observed-settings", "--observed-devices"];
  if (required.some((key) => !args.get(key))) fail("observations_required");
  observedPolicy = readPrivateJson(args.get("--observed-policy"));
  settings = readPrivateJson(args.get("--observed-settings"));
  devicesResponse = readPrivateJson(args.get("--observed-devices"));
}

const devices = Array.isArray(devicesResponse) ? devicesResponse : devicesResponse?.devices;
if (!Array.isArray(devices) || typeof settings?.devicesApprovalOn !== "boolean") {
  fail("observation_schema_invalid");
}
const policyMatches = canonical(expectedPolicy) === canonical(observedPolicy);
const deviceApprovalEnabled = settings.devicesApprovalOn === true;
const roleBindingsMatch = bindingsMatch(bindings, devices);
const pendingDeviceApprovals = devices.filter((device) => device?.authorized !== true).length;

let outcome = "pass";
let exitCode = 0;
if (!policyMatches || !deviceApprovalEnabled || !roleBindingsMatch) {
  outcome = "drift";
  exitCode = 2;
} else if (pendingDeviceApprovals > 0) {
  outcome = "attention";
  exitCode = 3;
}

process.stdout.write(`${JSON.stringify({
  schema_version: "v1",
  outcome,
  policy_matches: policyMatches,
  device_approval_enabled: deviceApprovalEnabled,
  role_bindings_match: roleBindingsMatch,
  pending_device_approvals: pendingDeviceApprovals,
})}\n`);
process.exit(exitCode);
