#!/usr/bin/env node
// Read-only Brokkr node-capability producer (brokkr#7).  The record shape is
// owned by Grimnir's pinned v1 contract; this program only observes it.
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";

const now = process.env.BROKKR_INVENTORY_NOW || new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
const ttl = Number.parseInt(process.env.BROKKR_INVENTORY_TTL_SECONDS || "3600", 10);
const nodeId = process.env.BROKKR_NODE_ID || "unknown-node";
const errors = [];
const probe = (command, args) => {
  try { return execFileSync(command, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); }
  catch { errors.push(command); return null; }
};
const positive = (value) => Number.isInteger(value) && value > 0;
const cpuRaw = probe("getconf", ["_NPROCESSORS_ONLN"]);
const memRaw = probe("awk", ["/MemTotal/ { print int($2 / 1024) }", "/proc/meminfo"]);
const architectureRaw = probe("uname", ["-m"]);
const mountsRaw = probe("df", ["-Pm"]);
const systemctl = probe("systemctl", ["--version"]);
const launchctl = systemctl === null ? probe("launchctl", ["version"]) : null;
const unitsRaw = systemctl === null ? null : probe("systemctl", ["list-units", "--all", "--type=service", "--type=timer", "--no-legend"]);
const ipsRaw = probe("ip", ["-o", "link", "show"]);
const tailscaleRaw = probe("tailscale", ["status", "--json"]);
const cpu = Number.parseInt(cpuRaw || "", 10);
const memory = Number.parseInt(memRaw || "", 10);
const architecture = architectureRaw === "aarch64" || architectureRaw === "arm64" ? "arm64" : architectureRaw === "x86_64" ? "x86_64" : "unknown";
const network = [];
if (ipsRaw !== null) { if (/\beth\w*\b/.test(ipsRaw)) network.push("wired"); if (/\bwlan\w*\b/.test(ipsRaw)) network.push("wifi"); }
if (tailscaleRaw !== null) network.push("tailnet");
if (!network.length) network.push("unknown");
const storage = [];
if (mountsRaw !== null) {
  for (const line of mountsRaw.split("\n").slice(1)) {
    const fields = line.trim().split(/\s+/);
    const available = Number.parseInt(fields[3] || "", 10);
    if (positive(available)) storage.push({ class: "local_ssd", available_mib: available, status: "known" });
  }
}
if (!storage.length) storage.push({ class: "unknown", available_mib: 0, status: "unknown" });
const complete = positive(cpu) && positive(memory) && ["arm64", "x86_64"].includes(architecture) && !errors.length;
const observed = {
  kind: "node-capability", schema_version: "v1", node_id: nodeId, observed_at: now,
  valid_until: new Date(Date.parse(now) + Math.max(1, ttl) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z"),
  evidence: {}, capability_status: complete ? "known" : "unknown", architecture,
  resources: { cpu_cores: positive(cpu) ? cpu : 1, memory_mib: positive(memory) ? memory : 1 },
  uptime_class: "unknown", network_capabilities: network, logical_storage: storage,
  service_manager: systemctl !== null ? "systemd" : launchctl !== null ? "launchd" : "unknown",
  deployment_mechanisms: ["unknown"], health_reporting: "unknown", extensions: []
};
const digest = crypto.createHash("sha256").update(JSON.stringify(observed)).digest("hex");
observed.evidence = { evidence_id: `obs-${nodeId}`, producer: "brokkr", observed_at: now, digest: `sha256:${digest}` };
process.stdout.write(`${JSON.stringify(observed)}\n`);
const units = unitsRaw === null ? "units=unknown" : `units=${unitsRaw.split("\n").filter(Boolean).map((line) => line.split(/\s+/)[0]).filter((name) => /^[a-z0-9@._-]+$/i.test(name)).join(",") || "none"}`;
process.stderr.write(`Brokkr node inventory: ${nodeId}; ${observed.capability_status}; ${units}; ${errors.length ? `partial probes=${errors.join(",")}` : "all probes collected"}\n`);
