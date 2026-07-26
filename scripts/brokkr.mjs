#!/usr/bin/env node
// Read-only controller entry point.  Its only transport is the fixed SSH
// invocation below; node addressing, the remote checkout and trust roots stay
// in a private owner overlay and never appear in diagnostics or JSON output.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { assertPinnedContractFiles, canonicalJson, checkSchema, evidenceDigest, observationEvidenceId, schemaErrors, strictUtc } from "./lib/node-substrate-contract.mjs";

const fail = (message) => { process.stderr.write(`brokkr: ${message}\n`); process.exit(1); };
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const schemaPath = path.join(root, "docs/node-substrate-contract-v1.schema.json");
const manifestPath = path.join(root, "tests/fixtures/node-substrate-contract/consumer-fixture-set.json");
const provenancePath = path.join(root, "docs/node-substrate-contract-provenance.md");
const NODE_ID = /^[a-z][a-z0-9-]{2,57}$/;
const overlayPath = process.env.BROKKR_INSPECT_OVERLAY;
const now = process.env.BROKKR_INSPECT_NOW ?? new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
if (!strictUtc(now)) fail("BROKKR_INSPECT_NOW must be an exact UTC instant");
if (process.argv.length !== 4 || process.argv[2] !== "inspect" || !NODE_ID.test(process.argv[3])) fail("usage: brokkr.mjs inspect <stable-node-id>");
const nodeId = process.argv[3];

function secureRead(file, label) {
  if (!file) fail(`${label} is required`);
  let fd;
  try { fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW); } catch { fail(`${label} is unavailable`); }
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || (typeof process.getuid === "function" && stat.uid !== process.getuid()) || (stat.mode & 0o077) !== 0) fail(`${label} must be owner-only regular file`);
    return fs.readFileSync(fd, "utf8");
  } finally { fs.closeSync(fd); }
}

let overlay;
try { overlay = JSON.parse(secureRead(overlayPath, "inspection overlay")); } catch { fail("inspection overlay is invalid"); }
const closed = (value, keys) => value && typeof value === "object" && !Array.isArray(value) &&
  JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
if (!closed(overlay, ["schema_version", "nodes"]) || overlay.schema_version !== 1 || !overlay.nodes || typeof overlay.nodes !== "object" || Array.isArray(overlay.nodes)) fail("inspection overlay has unsupported fields");
const node = overlay.nodes[nodeId];
if (!closed(node, ["location", "remote_dir", "ssh_target", "signing_public_key"]) ||
  !closed(node.location, ["location_secret", "observed_at", "provenance", "valid_until"]) ||
  typeof node.ssh_target !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$/.test(node.ssh_target) ||
  typeof node.remote_dir !== "string" || !/^\/[A-Za-z0-9._/-]*$/.test(node.remote_dir) ||
  typeof node.signing_public_key !== "string" || !strictUtc(node.location.observed_at) || !strictUtc(node.location.valid_until) ||
  !["known", "partial", "unknown"].includes(node.location.provenance) || typeof node.location.location_secret !== "string" || !node.location.location_secret.length) fail("inspection overlay has invalid node configuration");

const locationEvidence = {
  kind: "brokkr-location-evidence", schema_version: "v1", observed_at: node.location.observed_at,
  valid_until: node.location.valid_until, provenance: node.location.provenance,
  // The private location name is never output.  The opaque digest lets a
  // controller detect a move without turning this command into topology output.
  location_digest: `sha256:${crypto.createHash("sha256").update(node.location.location_secret).digest("hex")}`,
};

function output(status, extra = {}) {
  process.stdout.write(`${JSON.stringify({ kind: "brokkr-controller-inspection", schema_version: "v1", node_id: nodeId, checked_at: now, inspection_status: status, location_evidence: locationEvidence, ...extra })}\n`);
}
const stale = Date.parse(node.location.valid_until) < Date.parse(now);
try { assertPinnedContractFiles({ schemaPath, manifestPath, provenancePath }); } catch { fail("pinned shared contract is unavailable or changed"); }
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8")); checkSchema(schema);

// The command is purposefully not configurable.  An owner can select only a
// host alias and checkout path, while the controller fixes batch mode, connect
// timeout, output cap and the precise read-only agent command.
const remote = `cd -- ${node.remote_dir} && BROKKR_NODE_ID=${nodeId} node scripts/node-inventory.mjs --detail`;
const child = spawnSync("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", node.ssh_target, remote], {
  encoding: "utf8", timeout: 15000, maxBuffer: 1024 * 1024, env: { PATH: process.env.PATH ?? "/usr/bin:/bin" },
});
if (child.error || child.status !== 0) { output("unreachable", { freshness: stale ? "stale" : "current" }); process.exit(2); }
let capability;
try { capability = JSON.parse(child.stdout); } catch { output("partial", { freshness: stale ? "stale" : "current", reason: "invalid-agent-record" }); process.exit(2); }
if (capability.node_id !== nodeId) { output("identity-mismatch", { freshness: stale ? "stale" : "current" }); process.exit(2); }
if (schemaErrors(schema, capability).length || capability.evidence.digest !== `sha256:${evidenceDigest(capability)}` || capability.evidence.evidence_id !== observationEvidenceId(capability)) { output("partial", { freshness: stale ? "stale" : "current", reason: "invalid-shared-contract" }); process.exit(2); }
const detailLine = child.stderr.split("\n").find((line) => line.startsWith("Brokkr node inventory detail JSON: "));
let detail;
try { detail = JSON.parse(detailLine.slice("Brokkr node inventory detail JSON: ".length)); } catch { output("partial", { freshness: stale ? "stale" : "current", reason: "missing-signed-detail" }); process.exit(2); }
const signature = detail.signature;
if (!closed(detail, ["backup_roles", "detail_digest", "kind", "observation_digest", "observation_evidence_id", "observed_at", "schema_version", "signature", "signing_key_id", "unit_state", "valid_until", "workloads"]) ||
  detail.kind !== "brokkr-node-inventory-detail" || detail.schema_version !== "v1" || !strictUtc(detail.observed_at) || !strictUtc(detail.valid_until) ||
  detail.observation_evidence_id !== capability.evidence.evidence_id || detail.observation_digest !== capability.evidence.digest ||
  detail.observed_at !== capability.observed_at || detail.valid_until !== capability.valid_until) { output("partial", { freshness: stale ? "stale" : "current", reason: "unbound-signed-detail" }); process.exit(2); }
const unsigned = structuredClone(detail); delete unsigned.signature;
const expectedDigest = `sha256:${crypto.createHash("sha256").update(canonicalJson(Object.fromEntries(Object.entries(unsigned).filter(([key]) => key !== "detail_digest")))).digest("hex")}`;
if (detail.detail_digest !== expectedDigest) { output("partial", { freshness: stale ? "stale" : "current", reason: "invalid-detail-digest" }); process.exit(2); }
try {
  const publicKey = crypto.createPublicKey(node.signing_public_key);
  const keyId = `sha256:${crypto.createHash("sha256").update(publicKey.export({ type: "spki", format: "der" })).digest("hex")}`;
  if (detail.signing_key_id !== keyId || !crypto.verify(null, Buffer.from(canonicalJson(unsigned)), publicKey, Buffer.from(signature, "base64"))) throw new Error();
} catch { output("partial", { freshness: stale ? "stale" : "current", reason: "untrusted-signed-detail" }); process.exit(2); }
output(stale || capability.capability_status !== "known" || node.location.provenance !== "known" ? "partial" : "ok", {
  freshness: stale || Date.parse(capability.valid_until) < Date.parse(now) ? "stale" : "current",
  node_capability: capability, detail,
});
