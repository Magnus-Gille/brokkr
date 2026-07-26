#!/usr/bin/env node
// Deterministic pre-install negotiation: a deployment never assumes that an
// agent understands the record version it is about to receive or emit.
import fs from "node:fs";
const die = (m) => { process.stderr.write(`node-agent-compatibility: ${m}\n`); process.exit(1); };
const a = process.argv.slice(2); if (a.length !== 4 || a[0] !== "--agent" || a[2] !== "--deployment") die("usage: node-agent-compatibility.mjs --agent agent.json --deployment deployment.json");
const read = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { die(`cannot read ${p}`); } };
const agent = read(a[1]), deployment = read(a[3]);
const exactKeys = (value, keys) => value !== null && typeof value === "object" && !Array.isArray(value) &&
  JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
const versionList = (value) => Array.isArray(value) && value.every((version) => typeof version === "string");
if (!exactKeys(agent, ["kind", "schema_version", "agent_version", "supported_platform_fault_versions", "supported_node_substrate_versions"]) ||
  agent.kind !== "brokkr-node-agent-handshake" || agent.schema_version !== "v1" || typeof agent.agent_version !== "string" ||
  !versionList(agent.supported_platform_fault_versions) || !versionList(agent.supported_node_substrate_versions) ||
  !exactKeys(deployment, ["kind", "schema_version", "required_versions"]) || deployment.kind !== "brokkr-node-agent-deployment" ||
  deployment.schema_version !== "v1" || !exactKeys(deployment.required_versions, ["platform_fault", "node_substrate"])) die("unsupported handshake or deployment");
const p = deployment.required_versions?.platform_fault, n = deployment.required_versions?.node_substrate;
const compatible = typeof p === "string" && typeof n === "string" && agent.supported_platform_fault_versions?.includes(p) && agent.supported_node_substrate_versions?.includes(n);
if (!compatible) die("incompatible node-agent contract versions");
process.stdout.write(JSON.stringify({ kind: "brokkr-node-agent-compatibility", schema_version: "v1", outcome: "compatible", agent_version: agent.agent_version, negotiated: { platform_fault: p, node_substrate: n } }, null, 2) + "\n");
