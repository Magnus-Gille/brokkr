#!/usr/bin/env node
// Deterministic pre-install negotiation: a deployment never assumes that an
// agent understands the record version it is about to receive or emit.
import fs from "node:fs";
const die = (m) => { process.stderr.write(`node-agent-compatibility: ${m}\n`); process.exit(1); };
const a = process.argv.slice(2); if (a.length !== 4 || a[0] !== "--agent" || a[2] !== "--deployment") die("usage: node-agent-compatibility.mjs --agent agent.json --deployment deployment.json");
const read = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { die(`cannot read ${p}`); } };
const agent = read(a[1]), deployment = read(a[3]);
if (agent.kind !== "brokkr-node-agent-handshake" || agent.schema_version !== "v1" || deployment.kind !== "brokkr-node-agent-deployment" || deployment.schema_version !== "v1") die("unsupported handshake or deployment");
const p = deployment.required_versions?.platform_fault, n = deployment.required_versions?.node_substrate;
const compatible = typeof p === "string" && typeof n === "string" && agent.supported_platform_fault_versions?.includes(p) && agent.supported_node_substrate_versions?.includes(n);
if (!compatible) die("incompatible node-agent contract versions");
process.stdout.write(JSON.stringify({ kind: "brokkr-node-agent-compatibility", schema_version: "v1", outcome: "compatible", agent_version: agent.agent_version, negotiated: { platform_fault: p, node_substrate: n } }, null, 2) + "\n");
