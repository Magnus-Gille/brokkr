#!/usr/bin/env node
// Deterministic, read-only, Debian-first maintenance observation and plan
// (brokkr#33, parent epic brokkr#26). Consumes the pinned Grimnir
// maintenance-policy v1 contract (intent only -- never proves eligibility or
// authorizes mutation) plus a fresh Brokkr node-capability observation
// (brokkr#7, unchanged) and enumerates exact package/kernel/firmware
// candidates and Brokkr-owned safety-gate evidence WITHOUT applying anything.
//
// Non-mutation is structural, not a promise: every external command this
// process can ever run is gated by READ_ONLY_COMMANDS below, which is the
// single allowlist of (binary, exact-argv) pairs this program is permitted to
// execute, and the single `readOnly()` function below is the *only* place in
// this file that shells out. scripts/test/maintenance-plan.test.sh asserts
// both structural facts (single call site; every invocation across every
// fixture run matches the allowlist and never a mutating verb).
//
// This ticket does not duplicate brokkr#7 (node inventory), brokkr#2
// (node-agent contract), or a future execution/mutation journal (brokkr#10):
// it takes the node-capability record as an unchanged, already-produced
// input, and takes Brokkr's own missed-occurrence/deferral history as an
// explicit bound input (see --missed-occurrences/--deferral-elapsed below) --
// exactly the same way grimnir's contract itself declares occurrence-calendar
// enumeration and execution evidence out of scope for v1.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  assertPinnedContractFiles as assertPinnedMaintenanceContract,
  canonicalJson, checkSchema, decisionEffect, durationToMs, isValidDuration, isValidTimeZone,
  policyDigest, resolveWindowOccurrence, schemaErrors, strictUtc,
} from "./lib/maintenance-policy-contract.mjs";
import {
  assertPinnedContractFiles as assertPinnedNodeSubstrateContract,
  checkSchema as checkNodeSubstrateSchema, schemaErrors as nodeSubstrateSchemaErrors,
} from "./lib/node-substrate-contract.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const MAINTENANCE_SCHEMA_PATH = path.join(ROOT, "docs/maintenance-policy-v1.schema.json");
const MAINTENANCE_PROVENANCE_PATH = path.join(ROOT, "docs/maintenance-policy-provenance.md");
const NODE_SCHEMA_PATH = path.join(ROOT, "docs/node-substrate-contract-v1.schema.json");
const NODE_MANIFEST_PATH = path.join(ROOT, "tests/fixtures/node-substrate-contract/consumer-fixture-set.json");
const NODE_PROVENANCE_PATH = path.join(ROOT, "docs/node-substrate-contract-provenance.md");

const PKG_NAME = /^[a-z0-9][a-z0-9+.-]*$/i;
const PKG_VERSION = /^[A-Za-z0-9:+.~-]{1,128}$/;
const JSON_MODE = process.argv.includes("--json");
const context = {};

class PlanError extends Error {
  constructor(code, owner, message) { super(message); this.code = code; this.owner = owner; }
}
const fail = (code, owner, message) => { throw new PlanError(code, owner, message); };
const plain = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const hash = (value) => `sha256:${crypto.createHash("sha256").update(typeof value === "string" || Buffer.isBuffer(value) ? value : canonicalJson(value)).digest("hex")}`;
const idFrom = (prefix, material) => `${prefix}-${crypto.createHash("sha256").update(canonicalJson(material)).digest("hex").slice(0, 52)}`;
const sortBy = (items, key) => [...items].sort((a, b) => (a[key] < b[key] ? -1 : a[key] > b[key] ? 1 : 0));
const blocker = (code, owner, message) => ({ code, owner, message });

// ─── Structural non-mutation allowlist ───────────────────────────────────────
// Every probe this program can ever run is named here with the EXACT argv it
// is permitted to use. No entry here ever includes an install/remove/apply/
// configure/-y/--force/reboot/restart verb. Adding a new probe requires
// widening this table, not just calling execFileSync somewhere else -- there
// is exactly one call site (readOnly, below) and the test suite greps for
// that invariant.
export function buildAllowlist({ dpkgLockPath, rootMount }) {
  const exact = (expected) => (args) => args.length === expected.length && args.every((a, i) => a === expected[i]);
  return {
    "apt-get": exact(["-s", "dist-upgrade"]),
    "fuser": exact([dpkgLockPath]),
    "df": exact(["-Pm", rootMount]),
    "dpkg-query": exact(["-W", "-f=${Package}\\n", "linux-image-*"]),
    "timedatectl": exact(["show"]),
    "uname": exact(["-r"]),
    "rpi-eeprom-update": exact([]),
    "fwupdmgr": exact(["get-upgrades", "--json"]),
  };
}
export function readOnly(allowlist, command, args) {
  const gate = allowlist[command];
  if (!gate || !gate(args)) fail("read-only-allowlist-violation", "brokkr", `refusing to run a command outside the read-only allowlist: ${command}`);
  try {
    return { status: "ok", out: execFileSync(command, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 10_000, maxBuffer: 4 << 20 }) };
  } catch (error) {
    return { status: error.code === "ENOENT" ? "missing" : "failed", out: null };
  }
}

// ─── Args ─────────────────────────────────────────────────────────────────
const usage = () => "Usage: maintenance-plan.mjs --policy FILE --inventory FILE [--workload FILE] --now UTC --window-occurrence-date DATE --missed-occurrences N --deferral-elapsed DURATION [--json]";
function parseArgs() {
  const known = new Set(["policy", "inventory", "workload", "now", "window_occurrence_date", "missed_occurrences", "deferral_elapsed"]);
  const result = { json: false };
  const raw = process.argv.slice(2);
  for (let index = 0; index < raw.length; index += 1) {
    if (raw[index] === "--json") { result.json = true; continue; }
    if (!raw[index].startsWith("--") || index + 1 === raw.length) fail("arguments-invalid", "brokkr", usage());
    const key = raw[index].slice(2).replaceAll("-", "_");
    if (!known.has(key) || result[key] !== undefined) fail("arguments-invalid", "brokkr", usage());
    result[key] = raw[++index];
  }
  for (const key of ["policy", "inventory", "now", "window_occurrence_date", "missed_occurrences", "deferral_elapsed"]) {
    if (typeof result[key] !== "string") fail("arguments-invalid", "brokkr", usage());
  }
  if (!strictUtc(result.now)) fail("now-invalid", "brokkr", "--now must be an exact real UTC instant");
  context.now = result.now;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(result.window_occurrence_date)) fail("arguments-invalid", "brokkr", "--window-occurrence-date must be YYYY-MM-DD");
  if (!/^(0|[1-9][0-9]{0,6})$/.test(result.missed_occurrences)) fail("arguments-invalid", "brokkr", "--missed-occurrences must be a non-negative integer");
  if (!isValidDuration(result.deferral_elapsed)) fail("arguments-invalid", "brokkr", "--deferral-elapsed must be a bounded ISO 8601 duration");
  return result;
}

const readJson = (file, label, owner, prefix) => {
  let stat;
  try { stat = fs.lstatSync(file); } catch { fail(`${prefix}-unavailable`, owner, `${label} is unavailable`); }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1_000_000) fail(`${prefix}-unavailable`, owner, `${label} must be a regular bounded file`);
  try { return JSON.parse(fs.readFileSync(file)); } catch { fail(`${prefix}-invalid`, owner, `${label} is not valid JSON`); }
};

// ─── Environment-tunable operational thresholds (Brokkr-owned, not policy-owned) ───
function boundedEnvInt(name, fallback, min, max) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  if (!/^[0-9]{1,9}$/.test(raw)) fail("environment-invalid", "brokkr", `${name} must be a non-negative integer`);
  const value = Number.parseInt(raw, 10);
  if (value < min || value > max) fail("environment-invalid", "brokkr", `${name} must be between ${min} and ${max}`);
  return value;
}
function boundedEnvPath(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  if (!raw.startsWith("/") || raw.length > 1024 || /[\0\n]/.test(raw)) fail("environment-invalid", "brokkr", `${name} must be a bounded absolute path`);
  return raw;
}
const DPKG_LOCK_PATH = boundedEnvPath("BROKKR_MAINTENANCE_DPKG_LOCK", "/var/lib/dpkg/lock-frontend");
const ROOT_MOUNT = boundedEnvPath("BROKKR_MAINTENANCE_ROOT_MOUNT", "/");
const SYSFS_ROOT = boundedEnvPath("BROKKR_MAINTENANCE_SYSFS_ROOT", "/sys");
const MIN_FREE_MIB = boundedEnvInt("BROKKR_MAINTENANCE_MIN_FREE_MIB", 1024, 0, 1_000_000);

// ─── Candidate parsing (apt-get -s dist-upgrade output) ────────────────────
export function parseAptSimulate(output) {
  const unsignedDetected = /cannot be authenticated|could not be authenticated|is not signed/i.test(output);
  const candidates = [];
  for (const rawLine of output.split("\n")) {
    const line = rawLine.trim();
    const m = /^Inst\s+(\S+)\s+(?:\[([^\]]+)\]\s+)?\(([^)]+)\)/.exec(line);
    if (!m) continue;
    const [, name, oldVersion, parens] = m;
    const spaceIndex = parens.indexOf(" ");
    if (spaceIndex === -1) continue;
    const newVersion = parens.slice(0, spaceIndex);
    const remainder = parens.slice(spaceIndex + 1).trim().replace(/\s*\[[^\]]*\]\s*$/, "");
    const originTokens = remainder.split(",").map((t) => t.trim()).filter(Boolean);
    if (!PKG_NAME.test(name) || !PKG_VERSION.test(newVersion) || (oldVersion !== undefined && !PKG_VERSION.test(oldVersion)) || !originTokens.length) {
      fail("apt-output-unparseable", "brokkr", "apt-get simulation output could not be parsed safely");
    }
    candidates.push({ name, current_version: oldVersion ?? null, candidate_version: newVersion, originTokens });
  }
  return { candidates, unsignedDetected };
}
export const classifySource = (originTokens) => (originTokens.some((t) => /-backports/i.test(t)) ? "package_manager_lts_channel" : "distro_repository");
export const isSecurityOrigin = (originTokens) => originTokens.some((t) => /^Debian-Security:/i.test(t) || /-security(\/|$)/i.test(t));
export const classifyClass = (name, security) => (/^linux-(image|headers|modules)-/.test(name) ? "kernel" : security ? "security" : "bugfix");

// ─── Main ───────────────────────────────────────────────────────────────────
function main() {
  const args = parseArgs();

  try { assertPinnedMaintenanceContract({ schemaPath: MAINTENANCE_SCHEMA_PATH, provenancePath: MAINTENANCE_PROVENANCE_PATH }); }
  catch { fail("pinned-contract-invalid", "grimnir", "pinned Grimnir maintenance-policy contract artifacts do not verify"); }
  const maintenanceSchema = readJson(MAINTENANCE_SCHEMA_PATH, "pinned maintenance-policy contract", "grimnir", "pinned-contract");
  checkSchema(maintenanceSchema);

  try { assertPinnedNodeSubstrateContract({ schemaPath: NODE_SCHEMA_PATH, manifestPath: NODE_MANIFEST_PATH, provenancePath: NODE_PROVENANCE_PATH }); }
  catch { fail("pinned-contract-invalid", "grimnir", "pinned Grimnir node-substrate contract artifacts do not verify"); }
  const nodeSchema = readJson(NODE_SCHEMA_PATH, "pinned node-substrate contract", "grimnir", "pinned-contract");
  checkNodeSubstrateSchema(nodeSchema);

  const policy = readJson(args.policy, "maintenance policy", "grimnir", "policy");
  context.policy = policy;
  if (policy.kind !== "maintenance-policy") fail("policy-invalid", "grimnir", "policy input is not a maintenance-policy record");
  if (schemaErrors(maintenanceSchema, policy).length) fail("policy-invalid", "grimnir", "maintenance policy violates the pinned Grimnir v1 schema");
  if (!isValidTimeZone(policy.timezone)) fail("policy-invalid", "grimnir", "maintenance policy timezone is not a known IANA identifier");
  if (policy.policy_digest !== policyDigest(policy)) fail("policy-digest-invalid", "grimnir", "maintenance policy digest does not recompute");

  const inventory = readJson(args.inventory, "node inventory", "brokkr", "inventory");
  context.inventory = inventory;
  if (inventory.kind !== "node-capability") fail("inventory-invalid", "brokkr", "inventory input is not a node-capability record");
  if (nodeSubstrateSchemaErrors(nodeSchema, inventory).length) fail("inventory-invalid", "brokkr", "node inventory violates the pinned Grimnir v1 schema");

  let workload = null;
  if (typeof args.workload === "string") {
    workload = readJson(args.workload, "workload requirement", "grimnir", "workload");
    if (workload.kind !== "workload-requirement") fail("workload-invalid", "grimnir", "workload input is not a workload-requirement record");
    if (nodeSubstrateSchemaErrors(nodeSchema, workload).length) fail("workload-invalid", "grimnir", "workload requirement violates the pinned Grimnir v1 schema");
  }

  const now = args.now;
  const blockers = [];
  const add = (condition, code, owner, message) => { if (condition) blockers.push(blocker(code, owner, message)); };

  // Fail closed: missing or stale inventory.
  add(!strictUtc(inventory.observed_at) || !strictUtc(inventory.valid_until), "inventory-invalid", "brokkr", "Inventory timestamps are not exact UTC instants.");
  add(inventory.observed_at > now || inventory.valid_until <= now, "stale-inventory-evidence", "brokkr", "Node inventory evidence is stale relative to the evaluation instant.");
  add(inventory.capability_status !== "known", "inventory-not-decision-ready", "brokkr", "Node inventory capability status is not known (a probe failed).");

  // The policy must actually cover this node (or the named workload).
  const selectsNode = policy.selector.node_ids.includes(inventory.node_id);
  const selectsWorkload = workload !== null && policy.selector.workload_ids.includes(workload.workload_id);
  add(!selectsNode && !selectsWorkload, "policy-does-not-select-target", "grimnir", "Maintenance policy selector does not reference this node or workload.");

  // Grimnir decision-effect precedence, bound to the caller-supplied,
  // Brokkr-evidence-derived missed-occurrence/deferral history (never invented
  // here -- see the file banner).
  const missedOccurrences = Number.parseInt(args.missed_occurrences, 10);
  const deferralElapsedMs = durationToMs(args.deferral_elapsed);
  add(missedOccurrences === 0 && deferralElapsedMs !== 0, "decision-input-invalid", "brokkr", "deferral_elapsed must be PT0S when nothing was missed.");

  let windowOccurrence = null;
  let decision = null;
  try {
    windowOccurrence = resolveWindowOccurrence(policy, args.window_occurrence_date);
  } catch (error) {
    blockers.push(blocker("dst-fail-closed", "grimnir", error.message));
  }

  if (!blockers.length) {
    const effect = decisionEffect(policy, { missedOccurrences, deferralElapsedMs });
    const evidenceId = idFrom("dec-obs", { evidence_id: inventory.evidence.evidence_id, digest: inventory.evidence.digest });
    decision = {
      kind: "maintenance-decision", schema_version: "v1",
      decision_id: idFrom("decision", { policy_id: policy.policy_id, policy_digest: policy.policy_digest, window_occurrence: windowOccurrence, now }),
      policy_id: policy.policy_id, policy_digest: policy.policy_digest,
      evidence: { evidence_id: evidenceId, producer: "brokkr", observed_at: inventory.evidence.observed_at, digest: inventory.evidence.digest },
      as_of: now, window_occurrence: windowOccurrence,
      missed_occurrences: missedOccurrences, deferral_elapsed: args.deferral_elapsed,
      effect: effect.effect, reason: effect.reason, extensions: [],
    };
    if (schemaErrors(maintenanceSchema, decision).length) fail("decision-output-invalid", "brokkr", "planner produced an invalid pinned maintenance-decision");
  }

  // ─── Brokkr-owned safety gates (never expressed by the policy schema itself) ───
  const allowlist = buildAllowlist({ dpkgLockPath: DPKG_LOCK_PATH, rootMount: ROOT_MOUNT });
  const gate = (name) => readOnly(allowlist, ...name);

  // Package-manager lock: `fuser <lockfile>` is inherently read-only (no -k);
  // exit 0 with output means another process holds the lock. Missing `fuser`
  // itself is also fail-closed -- an unlocked claim we cannot prove is unsafe.
  const lockProbe = gate(["fuser", [DPKG_LOCK_PATH]]);
  const lockStatus = lockProbe.status === "ok" ? "locked" : lockProbe.status === "failed" ? "unlocked" : "unknown";
  add(lockStatus !== "unlocked", "package-manager-lock", "brokkr", `Package-manager lock state is ${lockStatus}, not provably unlocked.`);

  // Disk: df -Pm <root>, read-only.
  const dfProbe = gate(["df", ["-Pm", ROOT_MOUNT]]);
  let availableMib = null;
  if (dfProbe.status === "ok") {
    const dataLine = dfProbe.out.trim().split("\n").slice(1).find(Boolean);
    const fields = dataLine ? dataLine.trim().split(/\s+/) : [];
    availableMib = fields.length >= 4 && /^\d+$/.test(fields[3]) ? Number.parseInt(fields[3], 10) : null;
  }
  add(availableMib === null, "disk-evidence-unavailable", "brokkr", "Disk headroom could not be measured read-only.");
  add(availableMib !== null && availableMib < MIN_FREE_MIB, "low-disk", "brokkr", "Available disk headroom is below the configured minimum.");

  // Power: filesystem-only probe of /sys/class/power_supply/*, configurable
  // root (mirrors Heimdall's collector taking a configurable sysfs root) --
  // no command execution needed at all for this gate.
  let powerStatus = "not_applicable";
  try {
    const powerDir = path.join(SYSFS_ROOT, "class", "power_supply");
    const entries = fs.readdirSync(powerDir, { withFileTypes: true }).filter((e) => e.isDirectory() || e.isSymbolicLink());
    const batteries = [];
    for (const entry of entries) {
      const typeFile = path.join(powerDir, entry.name, "type");
      let type = "";
      try { type = fs.readFileSync(typeFile, "utf8").trim(); } catch { /* unreadable entry counts as unknown below */ }
      if (type !== "Battery") continue;
      let onlineRaw = null;
      try { onlineRaw = fs.readFileSync(path.join(powerDir, entry.name, "online"), "utf8").trim(); } catch { /* try status */ }
      let statusRaw = null;
      try { statusRaw = fs.readFileSync(path.join(powerDir, entry.name, "status"), "utf8").trim(); } catch { /* neither available */ }
      if (onlineRaw === "1" || statusRaw === "Charging" || statusRaw === "Full") batteries.push("mains");
      else if (onlineRaw === "0" || statusRaw === "Discharging") batteries.push("battery");
      else batteries.push("unknown");
    }
    if (batteries.length === 0) powerStatus = "not_applicable";
    else if (batteries.every((b) => b === "mains")) powerStatus = "mains";
    else if (batteries.some((b) => b === "battery")) powerStatus = "battery";
    else powerStatus = "unknown";
  } catch {
    powerStatus = "not_applicable"; // no power_supply class at all (e.g. non-Linux) -- assume mains-only host
  }
  add(powerStatus === "battery" || powerStatus === "unknown", "unsafe-power", "brokkr", `Power source is ${powerStatus}, not provably mains-backed.`);

  // Clock: timedatectl show, read-only. Non-systemd hosts fail closed with an
  // honest "unsupported" reason rather than silently assuming synchronized.
  const clockProbe = gate(["timedatectl", ["show"]]);
  let clockStatus = "unsupported";
  if (clockProbe.status === "ok") {
    const line = clockProbe.out.split("\n").find((l) => l.startsWith("NTPSynchronized="));
    clockStatus = line === "NTPSynchronized=yes" ? "synchronized" : "unsynchronized";
  }
  add(clockStatus !== "synchronized", "bad-clock", "brokkr", `Clock synchronization status is ${clockStatus}.`);

  // Workload-hook readiness: structural only (declared hooks exist); this
  // never invokes a hook. Absent workload input is "not_applicable", not a
  // failure -- hook ownership belongs to the component repo (#26 boundary).
  let workloadHooks = "not_applicable";
  const hookGaps = [];
  if (workload) {
    for (const name of ["preflight", "drain", "verify"]) {
      if (!workload.hooks.some((h) => h.name === name)) hookGaps.push(`hook-${name}-missing`);
    }
    workloadHooks = hookGaps.length ? "incomplete" : "ready";
  }

  // Recovery eligibility: kernel rollback is observable read-only (previous
  // kernel image packages still installed); firmware rollback is honestly
  // reported unsupported -- Brokkr has no automatic firmware recovery adapter
  // yet (epic non-goal: never claim rollback capability that does not exist).
  const kernelProbe = gate(["dpkg-query", ["-W", "-f=${Package}\\n", "linux-image-*"]]);
  const installedKernels = kernelProbe.status === "ok" ? kernelProbe.out.split("\n").map((l) => l.trim()).filter(Boolean) : [];
  const kernelRollback = kernelProbe.status === "ok" ? (installedKernels.length >= 2 ? "eligible" : "not_eligible") : "unknown";

  // ─── Candidates ───────────────────────────────────────────────────────────
  const aptProbe = gate(["apt-get", ["-s", "dist-upgrade"]]);
  add(aptProbe.status !== "ok", "apt-simulation-unavailable", "brokkr", "apt-get read-only simulation did not run successfully.");
  const { candidates: rawCandidates, unsignedDetected } = aptProbe.status === "ok" ? parseAptSimulate(aptProbe.out) : { candidates: [], unsignedDetected: false };
  add(unsignedDetected, "unsigned-source-detected", "brokkr", "apt reported an unauthenticated/unsigned package source.");

  const unsupportedClasses = [];
  const candidates = [];
  for (const raw of rawCandidates) {
    const security = isSecurityOrigin(raw.originTokens);
    const source = classifySource(raw.originTokens);
    const klass = classifyClass(raw.name, security);
    const reasons = [];
    if (!policy.updates.allowed_classes.includes(klass)) reasons.push("class-not-allowed-by-policy");
    if (!policy.updates.allowed_sources.includes(source)) reasons.push("source-not-allowed-by-policy");
    if (klass === "kernel" && kernelRollback !== "eligible") reasons.push(`kernel-recovery-${kernelRollback}`);
    candidates.push({
      id: `${raw.name}@${raw.candidate_version}`, name: raw.name, class: klass, source,
      current_version: raw.current_version, candidate_version: raw.candidate_version,
      eligible: reasons.length === 0, reasons,
    });
  }

  // Firmware: detect via rpi-eeprom-update (Pi) or fwupdmgr (UEFI/LVFS),
  // whichever is present. Detection only -- Brokkr has no automatic apply
  // adapter for either yet, so a firmware candidate is NEVER eligible; it is
  // always reported, never silently dropped (acceptance criterion 5).
  const eepromProbe = gate(["rpi-eeprom-update", []]);
  const fwupdProbe = gate(["fwupdmgr", ["get-upgrades", "--json"]]);
  let firmwareAdapter = "none";
  if (eepromProbe.status === "ok" || eepromProbe.status === "failed") firmwareAdapter = "rpi-eeprom";
  else if (fwupdProbe.status === "ok" || fwupdProbe.status === "failed") firmwareAdapter = "fwupd";

  const firmwareReasons = () => {
    const reasons = ["firmware-recovery-unsupported"];
    if (!policy.updates.allowed_classes.includes("firmware")) reasons.push("class-not-allowed-by-policy");
    if (!policy.updates.allowed_sources.includes("vendor_signed_firmware_channel")) reasons.push("source-not-allowed-by-policy");
    return reasons;
  };
  if (firmwareAdapter === "rpi-eeprom" && eepromProbe.status === "ok" && /update available/i.test(eepromProbe.out)) {
    candidates.push({ id: "rpi-eeprom-update@pending", name: "rpi-eeprom-update", class: "firmware", source: "vendor_signed_firmware_channel", current_version: null, candidate_version: null, eligible: false, reasons: firmwareReasons() });
  } else if (firmwareAdapter === "fwupd" && fwupdProbe.status === "ok") {
    let parsed = null;
    try { parsed = JSON.parse(fwupdProbe.out); } catch { /* malformed JSON handled as unsupported below */ }
    const devices = plain(parsed) && Array.isArray(parsed.Devices) ? parsed.Devices : null;
    if (devices === null) add(true, "firmware-evidence-unparseable", "brokkr", "fwupdmgr get-upgrades output could not be parsed safely.");
    else for (const device of devices) candidates.push({ id: `fwupd-device@${idFrom("fw", device).slice(0, 12)}`, name: "fwupd-managed-device", class: "firmware", source: "vendor_signed_firmware_channel", current_version: null, candidate_version: null, eligible: false, reasons: firmwareReasons() });
  }
  if (policy.updates.allowed_classes.includes("firmware") && firmwareAdapter === "none") {
    unsupportedClasses.push({ class: "firmware", reason: "no-adapter-detected" });
  }

  const sortedCandidates = sortBy(candidates, "id");
  const sortedBlockers = sortBy(blockers, "code");
  const outcome = sortedBlockers.length ? "blocked" : "planned";

  const runningKernelProbe = gate(["uname", ["-r"]]);
  const runningKernel = runningKernelProbe.status === "ok" ? runningKernelProbe.out.trim() : "unknown";
  if (runningKernelProbe.status === "ok" && !PKG_VERSION.test(runningKernel)) add(true, "kernel-evidence-unparseable", "brokkr", "Running kernel release could not be parsed safely.");

  const planMaterial = {
    policy_digest: policy.policy_digest, inventory_evidence_id: inventory.evidence.evidence_id,
    window_occurrence: windowOccurrence, missed_occurrences: missedOccurrences, deferral_elapsed: args.deferral_elapsed,
    now, outcome, blockers: sortedBlockers, candidates: sortedCandidates,
  };
  const planId = idFrom("maint-plan", planMaterial);

  const result = {
    kind: "brokkr-maintenance-plan", schema_version: "v1", plan_id: planId,
    outcome, node_id: inventory.node_id,
    policy_id: policy.policy_id, policy_digest: policy.policy_digest,
    inventory_evidence_id: inventory.evidence.evidence_id,
    decision, running_kernel: runningKernel,
    gates: {
      package_manager_lock: lockStatus, disk: availableMib === null ? "unknown" : availableMib < MIN_FREE_MIB ? "insufficient" : "sufficient",
      power: powerStatus, clock: clockStatus, workload_hooks: workloadHooks, kernel_recovery: kernelRollback,
    },
    hook_gaps: sortBy(hookGaps.map((code) => ({ code })), "code"),
    candidates: sortedCandidates,
    unsupported_classes: sortBy(unsupportedClasses, "class"),
    blockers: sortedBlockers,
    created_at: now,
  };
  result.plan_digest = hash(result);
  if (JSON_MODE) process.stdout.write(`${canonicalJson(result)}\n`);
  else {
    process.stdout.write(`${outcome === "planned" ? "PLANNED" : "BLOCKED"}: maintenance plan ${planId} for ${inventory.node_id}\n`);
    for (const item of sortedBlockers) process.stdout.write(`- [${item.owner}] ${item.code}: ${item.message}\n`);
    for (const item of sortedCandidates) process.stdout.write(`  candidate ${item.id} [${item.class}/${item.source}] eligible=${item.eligible}${item.reasons.length ? ` (${item.reasons.join(",")})` : ""}\n`);
  }
  process.exit(outcome === "planned" ? 0 : 3);
}

function failurePlan(error) {
  const item = blocker(error.code ?? "planner-failure", error.owner ?? "brokkr", error.message ?? "planner failed closed");
  const now = strictUtc(context.now) ? context.now : "1970-01-01T00:00:00Z";
  const material = { error: item, now };
  const result = {
    kind: "brokkr-maintenance-plan", schema_version: "v1", plan_id: idFrom("maint-plan", material),
    outcome: "blocked", node_id: context.inventory?.node_id ?? "unknown",
    policy_id: context.policy?.policy_id ?? "unknown", policy_digest: context.policy?.policy_digest ?? `sha256:${"0".repeat(64)}`,
    inventory_evidence_id: context.inventory?.evidence?.evidence_id ?? "obs-unavailable",
    decision: null, running_kernel: "unknown",
    gates: { package_manager_lock: "unknown", disk: "unknown", power: "unknown", clock: "unknown", workload_hooks: "not_applicable", kernel_recovery: "unknown" },
    hook_gaps: [], candidates: [], unsupported_classes: [], blockers: [item], created_at: now,
  };
  result.plan_digest = hash(result);
  return result;
}

// Guarded like Python's `if __name__ == "__main__"`: running this file
// directly (`node scripts/maintenance-plan.mjs ...`) still auto-executes, but
// importing it as a module (scripts/test/maintenance-plan.test.sh does this
// to unit-test buildAllowlist/parseAptSimulate directly and precisely) never
// triggers main()/process.exit as an import side effect.
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    main();
  } catch (error) {
    const grounded = error instanceof PlanError ? error : new PlanError("planner-failure", "brokkr", "planner failed closed");
    if (JSON_MODE) process.stdout.write(`${canonicalJson(failurePlan(grounded))}\n`);
    else process.stderr.write(`FAIL [${grounded.owner}] ${grounded.code}: ${grounded.message}\n`);
    process.exit(3);
  }
}
