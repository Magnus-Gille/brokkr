// W0.2 Ed25519 owner authorization and signed runtime-narrowing verification.
// This is a library form of Grimnir's merged verifier contract at
// 16edee0a5a0111f0142569f5b0cf2f90e807060c. The owner authorization,
// recovery, attestation, and narrowing envelopes remain v1.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DIGEST = /^sha256:[a-f0-9]{64}$/;
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const DOMAIN = "no-reboot-security-bugfix-maintenance";
const DOMAINS = new Set(["micro-routing", "macro-routing", "prompt", "harness", "tool-policy", "served-model-roster", DOMAIN]);
const plain = value => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value, keys) => (
  plain(value) && Object.keys(value).sort().join(",") === [...keys].sort().join(",")
);
const fail = code => {
  const error = new Error(code);
  error.code = code;
  throw error;
};
export const canonicalJson = value => (
  plain(value)
    ? `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`
    : Array.isArray(value) ? `[${value.map(canonicalJson).join(",")}]` : JSON.stringify(value)
);
export const autonomyDigest = (value, omit = null) => {
  const copy = structuredClone(value);
  if (omit !== null) delete copy[omit];
  return `sha256:${crypto.createHash("sha256").update(canonicalJson(copy)).digest("hex")}`;
};
export const strictUtc = value => (
  typeof value === "string" &&
  /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{3})?Z$/.test(value) &&
  !Number.isNaN(Date.parse(value)) &&
  new Date(value).toISOString().replace(".000Z", "Z") === value
);
const keyFingerprint = key => `sha256:${crypto.createHash("sha256").update(key.export({ type: "spki", format: "der" })).digest("hex")}`;
const boundedStructure = value => {
  let nodes = 0;
  const visit = (item, depth = 0) => {
    if (++nodes > 10_000 || depth > 64) fail("authorization_input_structure_exceeded");
    if (item && typeof item === "object") for (const child of Object.values(item)) visit(child, depth + 1);
  };
  visit(value);
  if (Buffer.byteLength(JSON.stringify(value)) > 1_000_000) fail("authorization_input_size_exceeded");
};
const schemaFiles = Object.freeze({
  constitution: ["autonomy-constitution-v2.schema.json", "0c0d2bbbe9129b9a692220afc6e7ce53f7415e2eb96cfb06aedcda1f77de170b"],
  coverage: ["autonomy-coverage-registry-v2.schema.json", "fd2eec3b99fcaccceefe7ea4f432b0ce07d36bf1b66763c719cb1c9752fffdc9"],
  ownerAttestations: ["autonomy-owner-attestation-registry-v1.schema.json", "80099e3d2f871ff89d98facff49ce9f4e8ca7c791ba7e40357ca812d556ecb59"],
  authorization: ["autonomy-owner-authorization-v1.schema.json", "94d685bf863ab6c1f6782374a4f292896aa861ff631545ab765fc9018b1f5225"],
  recoveryRegistry: ["autonomy-recovery-worker-registry-v1.schema.json", "24c51aefbf5511be5ae4d478dc8801f2387b3e8d83274d90c4a3be7b5ee52e48"],
  runtimeNarrowing: ["autonomy-runtime-narrowing-v1.schema.json", "d4ec31f156b31efd70584ebc2cb9c22033602fa1275c168cc31686c7631b80e9"],
});
const schemaRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..", "docs");
const schemaCache = new Map();
function closedSchema(name) {
  if (schemaCache.has(name)) return schemaCache.get(name);
  const [file, expected] = schemaFiles[name];
  const raw = fs.readFileSync(path.join(schemaRoot, file));
  if (crypto.createHash("sha256").update(raw).digest("hex") !== expected) fail("w01_schema_pin_mismatch");
  const root = JSON.parse(raw);
  const supported = new Set([
    "$schema", "$id", "title", "description", "$defs", "$ref", "oneOf", "allOf",
    "const", "enum", "type", "pattern", "format", "minimum", "maximum", "minItems",
    "maxItems", "uniqueItems", "items", "required", "properties", "additionalProperties",
  ]);
  const resolve = ref => {
    if (!ref.startsWith("#/")) fail("w01_external_schema_ref");
    return ref.slice(2).split("/").reduce((value, key) => (
      value?.[key.replaceAll("~1", "/").replaceAll("~0", "~")]
    ), root);
  };
  const inspect = node => {
    if (!plain(node)) fail("w01_schema_node_invalid");
    for (const key of Object.keys(node)) if (!supported.has(key)) fail("w01_schema_keyword_unsupported");
    if (node.$ref && !resolve(node.$ref)) fail("w01_schema_ref_invalid");
    for (const child of Object.values(node.$defs ?? {})) inspect(child);
    for (const child of Object.values(node.properties ?? {})) inspect(child);
    if (node.items) inspect(node.items);
    for (const child of node.oneOf ?? []) inspect(child);
    for (const child of node.allOf ?? []) inspect(child);
  };
  const typeMatches = (type, value) => ({
    object: plain(value), array: Array.isArray(value), string: typeof value === "string",
    integer: Number.isInteger(value), boolean: typeof value === "boolean", null: value === null,
  })[type];
  const errors = (node, value, at = "$") => {
    if (node.$ref) return errors(resolve(node.$ref), value, at);
    if (node.oneOf) return node.oneOf.filter(child => errors(child, value, at).length === 0).length === 1 ?
      [] : [`${at}:oneOf`];
    if (node.allOf) return node.allOf.flatMap(child => errors(child, value, at));
    const result = [];
    if (Object.hasOwn(node, "const") && canonicalJson(value) !== canonicalJson(node.const)) result.push(`${at}:const`);
    if (node.enum && !node.enum.some(candidate => canonicalJson(value) === canonicalJson(candidate))) result.push(`${at}:enum`);
    if (node.type && !typeMatches(node.type, value)) return [...result, `${at}:type`];
    if (typeof value === "string") {
      if (node.pattern && !new RegExp(node.pattern).test(value)) result.push(`${at}:pattern`);
      if (node.format === "date-time" && !strictUtc(value)) result.push(`${at}:date-time`);
    }
    if (Number.isInteger(value)) {
      if (node.minimum !== undefined && value < node.minimum) result.push(`${at}:minimum`);
      if (node.maximum !== undefined && value > node.maximum) result.push(`${at}:maximum`);
    }
    if (Array.isArray(value)) {
      if (node.minItems !== undefined && value.length < node.minItems) result.push(`${at}:minItems`);
      if (node.maxItems !== undefined && value.length > node.maxItems) result.push(`${at}:maxItems`);
      if (node.uniqueItems && new Set(value.map(canonicalJson)).size !== value.length) result.push(`${at}:uniqueItems`);
      value.forEach((item, index) => { if (node.items) result.push(...errors(node.items, item, `${at}[${index}]`)); });
    }
    if (plain(value)) {
      for (const field of node.required ?? []) if (!Object.hasOwn(value, field)) result.push(`${at}.${field}:required`);
      if (node.additionalProperties === false) {
        for (const field of Object.keys(value)) if (!Object.hasOwn(node.properties ?? {}, field)) result.push(`${at}.${field}:additional`);
      }
      for (const [field, child] of Object.entries(node.properties ?? {})) {
        if (Object.hasOwn(value, field)) result.push(...errors(child, value[field], `${at}.${field}`));
      }
    }
    return result;
  };
  inspect(root);
  const check = value => {
    const found = errors(root, value);
    if (found.length) fail(`w01_schema_invalid:${name}:${found[0]}`);
  };
  schemaCache.set(name, check);
  return check;
}

export function verifyOwnerAuthorizationBundle({
  authorization, constitution, coverage, ownerAttestations, recoveryRegistry,
  pinnedOwnerPublicKeyPem, authorizationCheckpoint,
}) {
  for (const value of [authorization, constitution, coverage, ownerAttestations, recoveryRegistry, authorizationCheckpoint]) boundedStructure(value);
  for (const [name, value] of Object.entries({
    authorization, constitution, coverage, ownerAttestations, recoveryRegistry,
  })) closedSchema(name)(value);
  if (!exactKeys(authorization, ["kind", "schema_version", "authorization_id", "authorization_sequence", "previous_authorization_digest", "issued_at", "authority", "bindings", "signature"]) ||
      !exactKeys(authorization.authority, ["key_id", "algorithm", "public_key_pem", "public_key_fingerprint"]) ||
      !exactKeys(authorization.bindings, ["constitution_digest", "coverage_intent_digest", "owner_attestation_registry_digest", "recovery_worker_registry_digest"]) ||
      !exactKeys(authorization.signature, ["algorithm", "value_base64"])) fail("owner_authorization_shape_invalid");
  if (!exactKeys(authorizationCheckpoint, ["kind", "schema_version", "authorization_digest", "minimum_sequence"]) ||
      authorizationCheckpoint.kind !== "autonomy-owner-authorization-checkpoint" ||
      authorizationCheckpoint.schema_version !== "v1" || !DIGEST.test(authorizationCheckpoint.authorization_digest) ||
      !Number.isSafeInteger(authorizationCheckpoint.minimum_sequence)) fail("owner_authorization_checkpoint_invalid");
  if (authorization.kind !== "autonomy-owner-authorization" || authorization.schema_version !== "v1" ||
      authorization.authority.algorithm !== "Ed25519" || authorization.signature.algorithm !== "Ed25519" ||
      !ID.test(authorization.authorization_id) || !ID.test(authorization.authority.key_id) ||
      !strictUtc(authorization.issued_at) || !Number.isSafeInteger(authorization.authorization_sequence) ||
      authorization.authorization_sequence < authorizationCheckpoint.minimum_sequence ||
      !BASE64.test(authorization.signature.value_base64)) fail("owner_authorization_invalid");
  if ((authorization.authorization_sequence === 1) !== (authorization.previous_authorization_digest === null)) fail("owner_authorization_chain_invalid");
  if (authorization.previous_authorization_digest !== null && !DIGEST.test(authorization.previous_authorization_digest)) fail("owner_authorization_chain_invalid");

  const manifestKey = crypto.createPublicKey(authorization.authority.public_key_pem);
  const pinnedKey = crypto.createPublicKey(pinnedOwnerPublicKeyPem);
  if (manifestKey.asymmetricKeyType !== "ed25519" || pinnedKey.asymmetricKeyType !== "ed25519" ||
      !manifestKey.export({ type: "spki", format: "der" }).equals(pinnedKey.export({ type: "spki", format: "der" }))) fail("owner_public_key_not_pinned");
  if (authorization.authority.public_key_fingerprint !== keyFingerprint(manifestKey)) fail("owner_public_key_fingerprint_invalid");
  const unsigned = structuredClone(authorization);
  delete unsigned.signature;
  if (!crypto.verify(null, Buffer.from(canonicalJson(unsigned)), manifestKey, Buffer.from(authorization.signature.value_base64, "base64"))) fail("owner_signature_invalid");

  for (const [record, field] of [
    [constitution, "constitution_digest"],
    [coverage, "registry_digest"],
    [ownerAttestations, "registry_digest"],
    [recoveryRegistry, "registry_digest"],
  ]) if (record[field] !== autonomyDigest(record, field)) fail("owner_bound_artifact_digest_invalid");
  const expected = {
    constitution_digest: autonomyDigest(constitution, "constitution_digest"),
    coverage_intent_digest: autonomyDigest(coverage, "registry_digest"),
    owner_attestation_registry_digest: autonomyDigest(ownerAttestations, "registry_digest"),
    recovery_worker_registry_digest: autonomyDigest(recoveryRegistry, "registry_digest"),
  };
  if (canonicalJson(authorization.bindings) !== canonicalJson(expected)) fail("owner_authorization_binding_mismatch");
  const authorizationDigest = autonomyDigest(authorization);
  if (authorizationCheckpoint.authorization_digest !== authorizationDigest) fail("owner_authorization_not_current");

  if (!exactKeys(recoveryRegistry, ["kind", "schema_version", "registry_id", "entries", "registry_digest", "extensions"]) ||
      recoveryRegistry.kind !== "autonomy-recovery-worker-registry" || recoveryRegistry.schema_version !== "v1" ||
      !ID.test(recoveryRegistry.registry_id) || !Array.isArray(recoveryRegistry.entries) ||
      recoveryRegistry.entries.length > 256 || !Array.isArray(recoveryRegistry.extensions) || recoveryRegistry.extensions.length) fail("recovery_registry_invalid");
  const recoveryIdentities = new Set();
  const fingerprints = new Set();
  for (const entry of recoveryRegistry.entries) {
    if (!exactKeys(entry, ["domain", "target_scope_digest", "recovery_worker_identity", "public_key_pem", "public_key_fingerprint"]) ||
        !DOMAINS.has(entry.domain) || !DIGEST.test(entry.target_scope_digest) || !ID.test(entry.recovery_worker_identity)) fail("recovery_binding_invalid");
    const key = crypto.createPublicKey(entry.public_key_pem);
    const fingerprint = keyFingerprint(key);
    if (key.asymmetricKeyType !== "ed25519" || fingerprint !== entry.public_key_fingerprint) fail("recovery_key_invalid");
    const identity = `${entry.domain}:${entry.target_scope_digest}:${entry.recovery_worker_identity}`;
    if (recoveryIdentities.has(identity) || fingerprints.has(fingerprint)) fail("recovery_binding_ambiguous");
    recoveryIdentities.add(identity);
    fingerprints.add(fingerprint);
  }
  return { authorizationDigest, constitution, coverage, ownerAttestations, recoveryRegistry };
}

export function verifyRuntimeNarrowingLedger({ ledger, recoveryRegistry, authorizationDigest, tailCheckpoint }) {
  for (const value of [ledger, recoveryRegistry, tailCheckpoint]) boundedStructure(value);
  closedSchema("runtimeNarrowing")(ledger);
  closedSchema("recoveryRegistry")(recoveryRegistry);
  if (!exactKeys(ledger, ["kind", "schema_version", "ledger_id", "owner_authorization_digest", "entries", "extensions"]) ||
      ledger.kind !== "autonomy-runtime-narrowing" || ledger.schema_version !== "v1" || !ID.test(ledger.ledger_id) ||
      !DIGEST.test(ledger.owner_authorization_digest) || !Array.isArray(ledger.entries) || ledger.entries.length > 4096 ||
      !Array.isArray(ledger.extensions) || ledger.extensions.length) fail("runtime_narrowing_shape_invalid");
  if (ledger.owner_authorization_digest !== authorizationDigest) fail("runtime_narrowing_authorization_mismatch");
  let previous = null;
  const bindings = new Set();
  for (let index = 0; index < ledger.entries.length; index += 1) {
    const entry = ledger.entries[index];
    if (!exactKeys(entry, ["sequence", "recorded_at", "domain", "target_scope_digest", "from_state", "to_state", "recovery_worker_identity", "journal_receipt_digest", "previous_entry_digest", "entry_digest", "signature"]) ||
        !exactKeys(entry.signature, ["algorithm", "value_base64"]) || entry.signature.algorithm !== "Ed25519" ||
        entry.sequence !== index + 1 || !strictUtc(entry.recorded_at) || !DOMAINS.has(entry.domain) ||
        !DIGEST.test(entry.target_scope_digest) || !ID.test(entry.recovery_worker_identity) ||
        !DIGEST.test(entry.journal_receipt_digest) || (entry.previous_entry_digest !== null && !DIGEST.test(entry.previous_entry_digest)) ||
        !DIGEST.test(entry.entry_digest) || !BASE64.test(entry.signature.value_base64)) fail("runtime_narrowing_entry_invalid");
    if (entry.previous_entry_digest !== previous || entry.to_state !== "shadow" ||
        !["armed-canary", "armed-fleet"].includes(entry.from_state)) fail("runtime_narrowing_transition_invalid");
    const bound = recoveryRegistry.entries.find(candidate => (
      candidate.domain === entry.domain && candidate.target_scope_digest === entry.target_scope_digest &&
      candidate.recovery_worker_identity === entry.recovery_worker_identity
    ));
    if (!bound) fail("runtime_narrowing_worker_unbound");
    const identity = `${entry.domain}:${entry.target_scope_digest}:${entry.recovery_worker_identity}`;
    if (bindings.has(identity)) fail("runtime_narrowing_duplicate");
    bindings.add(identity);
    const unsigned = structuredClone(entry);
    delete unsigned.signature;
    if (!crypto.verify(null, Buffer.from(canonicalJson(unsigned)), crypto.createPublicKey(bound.public_key_pem), Buffer.from(entry.signature.value_base64, "base64"))) fail("runtime_narrowing_signature_invalid");
    const digestInput = structuredClone(entry);
    delete digestInput.entry_digest;
    delete digestInput.signature;
    if (entry.entry_digest !== autonomyDigest(digestInput)) fail("runtime_narrowing_digest_invalid");
    previous = entry.entry_digest;
  }
  if (!exactKeys(tailCheckpoint, ["kind", "schema_version", "owner_authorization_digest", "ledger_tail_digest", "minimum_entries"]) ||
      tailCheckpoint.kind !== "autonomy-runtime-narrowing-checkpoint" || tailCheckpoint.schema_version !== "v1" ||
      tailCheckpoint.owner_authorization_digest !== authorizationDigest ||
      !Number.isInteger(tailCheckpoint.minimum_entries) || tailCheckpoint.minimum_entries < 0 ||
      ledger.entries.length < tailCheckpoint.minimum_entries || tailCheckpoint.ledger_tail_digest !== previous) fail("runtime_narrowing_checkpoint_invalid");
  return { entries: ledger.entries, tailDigest: previous };
}

export function effectiveTargetState({ coverage, narrowingEntries, targetScopeDigest }) {
  const rows = coverage.domains?.filter(entry => entry.domain === DOMAIN) ?? [];
  const bindings = rows[0]?.bindings?.filter(entry => entry.target_scope_digest === targetScopeDigest) ?? [];
  const row = rows[0], binding = bindings[0];
  if (rows.length !== 1 || bindings.length !== 1 || coverage.global_state !== "armed" ||
      row.coverage !== row.target_state || row.coverage !== binding.state ||
      !["armed-canary", "armed-fleet"].includes(row.coverage)) return "shadow";
  return narrowingEntries.some(entry => entry.domain === DOMAIN && entry.target_scope_digest === targetScopeDigest) ? "shadow" : binding.state;
}
