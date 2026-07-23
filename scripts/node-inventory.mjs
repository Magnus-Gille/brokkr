#!/usr/bin/env node
// Read-only Brokkr node-capability producer (brokkr#7).  The record shape is
// owned by Grimnir's pinned v1 contract; this program only observes it.  Facts
// that cannot be probed read-only come from an owner-only overlay file or are
// reported as explicit unknowns; nothing is invented.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  assertPinnedContractFiles, checkSchema, evidenceDigest, observationEvidenceId, schemaErrors, strictUtc,
} from "./lib/node-substrate-contract.mjs";

const fail = (message) => {
  process.stderr.write(`node-inventory: ${message}\n`);
  process.exit(1);
};

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const schemaPath = path.join(root, "docs/node-substrate-contract-v1.schema.json");
const manifestPath = path.join(root, "tests/fixtures/node-substrate-contract/consumer-fixture-set.json");
const provenancePath = path.join(root, "docs/node-substrate-contract-provenance.md");
try {
  // This must precede schema parsing and collection: the v1 meaning comes from
  // Grimnir, not from whatever files happen to be present at runtime.
  assertPinnedContractFiles({ schemaPath, manifestPath, provenancePath });
} catch (error) {
  fail(`refusing to use unverified vendored contract: ${error.message}`);
}

const detailRequested = process.argv.slice(2).every((arg) => arg === "--detail") && process.argv.length === 3;
if (!detailRequested && process.argv.length !== 2) fail("usage: node-inventory.mjs [--detail]");

// --- Strict input validation, before any collection.
// The contract id pattern allows 63 chars.  Evidence ids use a hash of the
// complete observation material, so node ids need not be truncated into them.
const NODE_ID = /^[a-z][a-z0-9-]{2,57}$/;
const nodeId = process.env.BROKKR_NODE_ID ?? os.hostname().split(".")[0].toLowerCase();
if (!NODE_ID.test(nodeId)) fail(`invalid node id '${nodeId}': need ^[a-z][a-z0-9-]{2,57}$ (set BROKKR_NODE_ID)`);

const nowRaw = process.env.BROKKR_INVENTORY_NOW;
if (nowRaw !== undefined && !strictUtc(nowRaw)) {
  fail(`invalid BROKKR_INVENTORY_NOW '${nowRaw}': need an exact real UTC instant YYYY-MM-DDTHH:MM:SSZ`);
}
const now = nowRaw ?? new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

const ttlRaw = process.env.BROKKR_INVENTORY_TTL_SECONDS ?? "3600";
const ttl = /^[0-9]{1,5}$/.test(ttlRaw) ? Number.parseInt(ttlRaw, 10) : NaN;
if (!(ttl >= 60 && ttl <= 86400)) fail(`invalid TTL '${ttlRaw}': need an integer between 60 and 86400 seconds`);
const validUntil = new Date(Date.parse(now) + ttl * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

// --- Owner-only overlay: operator-declared facts that are not probeable
// read-only.  Treated like sourced configuration: regular non-symlink file,
// current-user-owned, no group/other permissions, closed key set.
const OVERLAY_KEYS = ["uptime_class", "deployment_mechanisms", "health_reporting", "logical_storage", "workloads", "backup_roles"];
const STORAGE_CLASSES = ["local_ssd", "external_ssd", "network_share"];
const DEPLOYMENT_MECHANISMS = ["guarded_deploy", "systemd", "manual_operator"];
const OVERLAY_ID = /^[a-z][a-z0-9-]{2,52}$/;
const uniqueSubset = (value, allowed) =>
  Array.isArray(value) && value.length > 0 && new Set(value).size === value.length && value.every((item) => allowed.includes(item));

function loadOverlay(overlayPath) {
  const noFollow = fs.constants.O_NOFOLLOW;
  if (typeof noFollow !== "number") fail("secure owner overlay reads are unsupported on this platform");
  let fd;
  try {
    fd = fs.openSync(overlayPath, fs.constants.O_RDONLY | noFollow);
  } catch {
    fail("overlay is unreadable or not a regular non-symlink file");
  }
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) fail("overlay must be a regular non-symlink file");
    if (typeof process.getuid === "function" && stat.uid !== process.getuid()) fail("overlay must be owned by the current user");
    if ((stat.mode & 0o077) !== 0) fail("overlay must not be group/other accessible");
    let parsed;
    try {
      parsed = JSON.parse(fs.readFileSync(fd, "utf8"));
    } catch {
      fail("overlay is not valid JSON");
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) fail("overlay must be a JSON object");
    for (const key of Object.keys(parsed)) {
      if (!OVERLAY_KEYS.includes(key)) fail("overlay contains an unsupported key");
    }
    if (parsed.uptime_class !== undefined && !["always_on", "best_effort"].includes(parsed.uptime_class)) {
      fail("overlay uptime_class must be always_on or best_effort");
    }
    if (parsed.deployment_mechanisms !== undefined && !uniqueSubset(parsed.deployment_mechanisms, DEPLOYMENT_MECHANISMS)) {
      fail(`overlay deployment_mechanisms must be a unique non-empty subset of ${DEPLOYMENT_MECHANISMS.join("/")}`);
    }
    if (parsed.health_reporting !== undefined && !["supported", "unsupported"].includes(parsed.health_reporting)) {
      fail("overlay health_reporting must be supported or unsupported");
    }
    if (parsed.logical_storage !== undefined) {
      const valid = Array.isArray(parsed.logical_storage) && parsed.logical_storage.length > 0 &&
        parsed.logical_storage.every((entry) =>
          entry !== null && typeof entry === "object" && !Array.isArray(entry) &&
          JSON.stringify(Object.keys(entry).sort()) === '["class","mount"]' &&
          STORAGE_CLASSES.includes(entry.class) && typeof entry.mount === "string" && entry.mount.startsWith("/"));
      if (!valid) fail(`overlay logical_storage entries must be {class: ${STORAGE_CLASSES.join("/")}, mount: /absolute/path}`);
    }
    if (parsed.workloads !== undefined) {
      const valid = Array.isArray(parsed.workloads) && new Set(parsed.workloads).size === parsed.workloads.length &&
        parsed.workloads.every((id) => typeof id === "string" && OVERLAY_ID.test(id));
      if (!valid) fail("overlay workloads must be unique ids matching ^[a-z][a-z0-9-]{2,52}$");
    }
    if (parsed.backup_roles !== undefined && !uniqueSubset(parsed.backup_roles, ["producer", "consumer"])) {
      fail("overlay backup_roles must be a unique non-empty subset of producer/consumer");
    }
    return parsed;
  } finally {
    fs.closeSync(fd);
  }
}

const overlay = process.env.BROKKR_INVENTORY_OVERLAY ? loadOverlay(process.env.BROKKR_INVENTORY_OVERLAY) : null;

// --- Bounded read-only probes.  "missing" (command not installed) and
// "failed" (installed but broken, timed out, or oversized) are distinct.
const failures = [];
const positive = (value) => Number.isInteger(value) && value > 0;
const probe = (command, args) => {
  try {
    return {
      status: "ok",
      out: execFileSync(command, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 5000, maxBuffer: 1 << 20 }).trim(),
    };
  } catch (error) {
    return { status: error.code === "ENOENT" ? "missing" : "failed", out: null };
  }
};

const cpuRes = probe("getconf", ["_NPROCESSORS_ONLN"]);
const cpu = cpuRes.status === "ok" ? Number.parseInt(cpuRes.out, 10) : NaN;
if (!positive(cpu)) failures.push("cpu");

let memory = NaN;
const memProc = probe("awk", ["/MemTotal/ { print int($2 / 1024) }", "/proc/meminfo"]);
if (memProc.status === "ok") memory = Number.parseInt(memProc.out, 10);
if (!positive(memory)) {
  const memSysctl = probe("sysctl", ["-n", "hw.memsize"]);
  if (memSysctl.status === "ok") {
    const bytes = Number.parseInt(memSysctl.out, 10);
    if (positive(bytes)) memory = Math.floor(bytes / 1048576);
  }
}
if (!positive(memory)) failures.push("memory");

const archRes = probe("uname", ["-m"]);
const architecture = archRes.out === "aarch64" || archRes.out === "arm64" ? "arm64" : archRes.out === "x86_64" ? "x86_64" : "unknown";
if (architecture === "unknown") failures.push("architecture");

let serviceManager = "unknown";
let systemd = false;
let launchd = false;
const systemctlRes = probe("systemctl", ["--version"]);
if (systemctlRes.status === "ok") {
  serviceManager = "systemd";
  systemd = true;
} else if (systemctlRes.status === "failed") {
  failures.push("service-manager");
} else {
  const launchctlRes = probe("launchctl", ["version"]);
  if (launchctlRes.status === "ok") {
    serviceManager = "launchd";
    launchd = true;
  }
  else failures.push("service-manager");
}

let unitObservation = { status: "unavailable", units: [] };
if (systemd) {
  const unitsRes = probe("systemctl", ["list-units", "--all", "--type=service", "--type=timer", "--no-legend", "--plain"]);
  const filesRes = probe("systemctl", ["list-unit-files", "--type=service", "--type=timer", "--no-legend", "--plain"]);
  if (unitsRes.status === "ok" && filesRes.status === "ok") {
    const observed = new Map(filesRes.out.split("\n").flatMap((line) => {
      const [name, installed] = line.trim().split(/\s+/);
      return /^[a-z0-9@._-]+$/i.test(name) && /^[a-z0-9_-]+$/i.test(installed)
        ? [[name, { name, installed_state: installed, active_state: "unknown", sub_state: "unknown" }]]
        : [];
    }));
    for (const line of unitsRes.out.split("\n")) {
      const [name, load, active, sub] = line.trim().split(/\s+/);
      if (!/^[a-z0-9@._-]+$/i.test(name) || !/^[a-z0-9_-]+$/i.test(load) || !/^[a-z0-9_-]+$/i.test(active) || !/^[a-z0-9_-]+$/i.test(sub)) continue;
      observed.set(name, { name, installed_state: observed.get(name)?.installed_state ?? load, active_state: active, sub_state: sub });
    }
    unitObservation = {
      status: "known",
      units: [...observed.values()],
    };
  } else {
    failures.push("units");
    unitObservation = { status: "unknown", units: [] };
  }
} else if (launchd) {
  const jobsRes = probe("launchctl", ["list"]);
  if (jobsRes.status === "ok") {
    unitObservation = {
      status: "known",
      units: jobsRes.out.split("\n").flatMap((line) => {
        const [pid, status, name] = line.trim().split(/\s+/);
        return /^[a-z0-9._-]+$/i.test(name) && /^(?:-|[0-9]+)$/.test(pid) && /^(?:-|[0-9]+)$/.test(status)
          ? [{ name, installed_state: "loaded", active_state: pid === "-" ? "not-running" : "running", sub_state: status === "-" ? "unknown" : "exited" }]
          : [];
      }),
    };
  } else {
    failures.push("units");
    unitObservation = { status: "unknown", units: [] };
  }
}

// Linux gets carrier state from ip.  Darwin has no ip by default, so it uses
// ifconfig -u plus networksetup's hardware-port map; en* alone never implies
// Ethernet because a Wi-Fi adapter is commonly en0.
const network = [];
const osType = probe("uname", ["-s"]);
if (osType.status === "ok" && osType.out === "Darwin") {
  const interfacesRes = probe("ifconfig", ["-u"]);
  const portsRes = probe("networksetup", ["-listallhardwareports"]);
  if (interfacesRes.status === "ok" && portsRes.status === "ok") {
    const active = new Set(interfacesRes.out.split("\n").flatMap((line) => {
      const match = /^([a-z0-9._-]+):\s+flags=/i.exec(line.trim());
      return match ? [match[1]] : [];
    }));
    const classes = new Map();
    let port = null;
    for (const line of portsRes.out.split("\n")) {
      const hardware = /^Hardware Port:\s*(.+)$/i.exec(line.trim());
      if (hardware) {
        port = hardware[1];
        continue;
      }
      const device = /^Device:\s*([a-z0-9._-]+)$/i.exec(line.trim());
      if (!device || !port) continue;
      if (/^(?:wi-fi|airport)$/i.test(port)) classes.set(device[1], "wifi");
      else if (/ethernet|\blan\b/i.test(port)) classes.set(device[1], "wired");
    }
    for (const kind of ["wired", "wifi"]) {
      if ([...active].some((name) => classes.get(name) === kind)) network.push(kind);
    }
  } else {
    failures.push("network");
  }
} else {
  const linkRes = probe("ip", ["-o", "link", "show"]);
  if (linkRes.status === "ok") {
    for (const line of linkRes.out.split("\n")) {
      const match = /^\d+:\s+([a-z0-9._-]+?)(?:@\S+)?:\s+<([^>]*)>/i.exec(line.trim());
      if (!match) continue;
      const [, name, rawFlags] = match;
      const flags = rawFlags.split(",");
      if (!flags.includes("UP") || !flags.includes("LOWER_UP")) continue;
      if (/^(eth|en|lan)/.test(name) && !network.includes("wired")) network.push("wired");
      if (/^wl/.test(name) && !network.includes("wifi")) network.push("wifi");
    }
  } else {
    failures.push("network");
  }
}

// Tailnet requires a valid, running, online JSON status.  A missing client is
// no capability; stopped, offline, malformed, and failed probes are distinct
// fail-closed observations.
const tailscaleRes = probe("tailscale", ["status", "--json"]);
if (tailscaleRes.status === "ok") {
  let status = null;
  try {
    status = JSON.parse(tailscaleRes.out);
  } catch {
    failures.push("tailnet-malformed");
  }
  if (status !== null) {
    if (typeof status !== "object" || Array.isArray(status) || typeof status.BackendState !== "string") {
      failures.push("tailnet-malformed");
    } else if (status.BackendState !== "Running") {
      failures.push("tailnet-stopped");
    } else if (status.Self === null || typeof status.Self !== "object" || Array.isArray(status.Self) || typeof status.Self.Online !== "boolean") {
      failures.push("tailnet-malformed");
    } else if (status.Self.Online !== true) {
      failures.push("tailnet-offline");
    } else {
      network.push("tailnet");
    }
  }
} else if (tailscaleRes.status === "failed") {
  failures.push("tailnet-unavailable");
}
if (!network.length) network.push("unknown");

// Logical storage classes come only from the owner overlay; df merely
// confirms the declared mount and measures headroom.  Nothing declared means
// an explicit unknown, never a guessed class.
let storage = [];
if (overlay?.logical_storage) {
  const mounts = new Map();
  const dfRes = probe("df", ["-Pm"]);
  if (dfRes.status === "ok") {
    for (const line of dfRes.out.split("\n").slice(1)) {
      const fields = line.trim().split(/\s+/);
      if (fields.length >= 6) mounts.set(fields.slice(5).join(" "), Number.parseInt(fields[3], 10));
    }
  } else {
    failures.push("storage");
  }
  storage = overlay.logical_storage.map(({ class: storageClass, mount }) => {
    const available = mounts.get(mount);
    return Number.isInteger(available) && available >= 0
      ? { class: storageClass, available_mib: available, status: "known" }
      : { class: storageClass, available_mib: 0, status: "unknown" };
  });
}
if (!storage.length) storage = [{ class: "unknown", available_mib: 0, status: "unknown" }];

// Probe failures are represented in the machine record itself as closed,
// versioned, informational extensions; capability_status stays the only
// decision-driving signal and any failure forces it to unknown.
const extension = (id) => ({ id, version: "v1", decision_effect: "informational" });
const extensions = [
  ...(overlay?.workloads ?? []).map((id) => extension(`workload-${id}`)),
  ...(overlay?.backup_roles ?? []).map((role) => extension(`backup-role-${role}`)),
  ...failures.map((name) => extension(`probe-failed-${name}`)),
].sort((a, b) => (a.id < b.id ? -1 : 1));

const record = {
  kind: "node-capability",
  schema_version: "v1",
  node_id: nodeId,
  observed_at: now,
  valid_until: validUntil,
  evidence: { evidence_id: "", producer: "brokkr", observed_at: now, digest: "" },
  capability_status: failures.length ? "unknown" : "known",
  architecture,
  // Schema floors (1) stand in when a probe failed; the matching
  // probe-failed-* extension plus capability_status unknown mark them.
  resources: { cpu_cores: positive(cpu) ? cpu : 1, memory_mib: positive(memory) ? memory : 1 },
  uptime_class: overlay?.uptime_class ?? "unknown",
  network_capabilities: network,
  logical_storage: storage,
  service_manager: serviceManager,
  deployment_mechanisms: overlay?.deployment_mechanisms ?? ["unknown"],
  health_reporting: overlay?.health_reporting ?? "unknown",
  extensions,
};
record.evidence.evidence_id = observationEvidenceId(record);
record.evidence.digest = `sha256:${evidenceDigest(record)}`;

// Every emitted record is validated against the pinned normative schema; a
// record this producer cannot prove valid is never emitted.
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
checkSchema(schema);
const violations = schemaErrors(schema, record);
if (violations.length) fail(`refusing to emit record violating pinned v1 schema: ${violations.join("; ")}`);

process.stdout.write(`${JSON.stringify(record)}\n`);
if (detailRequested) {
  // This is deliberately separate from the normative v1 record: v1 is a
  // closed consumer contract and cannot carry arbitrary operational payload.
  // The optional stderr record has a closed, versioned, public-safe shape: no
  // addresses, paths, interface names, descriptions, or credentials.
  const detail = {
    kind: "brokkr-node-inventory-detail",
    schema_version: "v1",
    observation_evidence_id: record.evidence.evidence_id,
    unit_state: unitObservation,
    workloads: overlay?.workloads ?? [],
    backup_roles: overlay?.backup_roles ?? [],
  };
  process.stderr.write(`Brokkr node inventory detail JSON: ${JSON.stringify(detail)}\n`);
}
const unitsSummary = unitObservation.status === "unavailable" ? "units=unavailable"
  : unitObservation.status === "unknown" ? "units=unknown"
    : `units=${unitObservation.units.map((unit) => `${unit.name}[${unit.active_state}/${unit.sub_state}]`).join(",") || "none"}`;
const overlaySummary = overlay
  ? ` workloads=${(overlay.workloads ?? []).join(",") || "none"}; backup-roles=${(overlay.backup_roles ?? []).join(",") || "none"};`
  : "";
process.stderr.write(
  `Brokkr node inventory: ${nodeId}; ${record.capability_status}; ${unitsSummary};${overlaySummary} ` +
    `${failures.length ? `partial probes=${failures.join(",")}` : "all probes collected"}\n`,
);
