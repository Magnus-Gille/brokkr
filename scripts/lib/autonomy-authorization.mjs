// W0.1 Ed25519 owner authorization and signed runtime-narrowing verification.
// This is a library form of Grimnir's merged verifier contract at
// 298526972b46d4f8f0c40fbe92e830adb91087a8.
import crypto from "node:crypto";

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
  /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(value) &&
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

export function verifyOwnerAuthorizationBundle({
  authorization, constitution, coverage, ownerAttestations, recoveryRegistry,
  pinnedOwnerPublicKeyPem, authorizationCheckpoint,
}) {
  for (const value of [authorization, constitution, coverage, ownerAttestations, recoveryRegistry, authorizationCheckpoint]) boundedStructure(value);
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
  const row = coverage.domains?.find(entry => entry.domain === DOMAIN);
  const binding = row?.bindings?.find(entry => entry.target_scope_digest === targetScopeDigest);
  if (!binding || coverage.global_state !== "armed" || row.coverage !== binding.state ||
      !["armed-canary", "armed-fleet"].includes(row.coverage)) return "shadow";
  return narrowingEntries.some(entry => entry.domain === DOMAIN && entry.target_scope_digest === targetScopeDigest) ? "shadow" : binding.state;
}
