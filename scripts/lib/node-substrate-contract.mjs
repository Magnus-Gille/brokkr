// Dependency-free helpers for the pinned Grimnir node/substrate v1 contract.
// The validation semantics deliberately mirror the normative consumer validator
// in grimnir tests/scripts/validate-node-substrate-contract.mjs at the pinned
// revision recorded in docs/node-substrate-contract-provenance.md.
import crypto from "node:crypto";
import fs from "node:fs";

const plain = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const typeMatches = (type, value) => ({
  object: plain(value),
  array: Array.isArray(value),
  string: typeof value === "string",
  integer: Number.isInteger(value),
  boolean: typeof value === "boolean",
  null: value === null,
})[type];

const UTC_SHAPE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;

// Exact second-resolution UTC instant on a real calendar date.
export const strictUtc = (value) => {
  if (typeof value !== "string") return false;
  const match = UTC_SHAPE.exec(value);
  if (!match) return false;
  const instant = new Date(value);
  if (Number.isNaN(instant.getTime())) return false;
  const [, year, month, day, hour, minute, second] = match;
  return (
    instant.getUTCFullYear() === Number(year) &&
    instant.getUTCMonth() + 1 === Number(month) &&
    instant.getUTCDate() === Number(day) &&
    instant.getUTCHours() === Number(hour) &&
    instant.getUTCMinutes() === Number(minute) &&
    instant.getUTCSeconds() === Number(second)
  );
};

// Canonical JSON: recursively key-sorted, no insignificant whitespace.
export const canonicalJson = (value) => {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (plain(value)) {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
};

// The evidence digest covers the canonical form of the whole record with only
// the evidence.digest field itself excluded.
export const evidenceDigest = (record) => {
  const copy = structuredClone(record);
  if (plain(copy.evidence)) delete copy.evidence.digest;
  return crypto.createHash("sha256").update(canonicalJson(copy)).digest("hex");
};

// These are the byte pins recorded in the public provenance note.  The
// producer validates them itself before parsing the schema so an accidental or
// hostile local edit cannot silently change the contract it enforces.
export const PINNED_CONTRACT_SHA256 = Object.freeze({
  schema: "9a69f1b23499cd6e70fdaa80ee57bf983e7e5b288882e0cf2b0f01f10824fbbe",
  manifest: "355481f2b3866840795ba18033077d6f36487d1a447b36c323384cf7837c5fcb",
  provenance: "ec8918cfc52e5ad95e1f339ab7aa6fd5af1411f2aaaa400228357c061bdf1bea",
});

const sha256File = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");

export function assertPinnedContractFiles({ schemaPath, manifestPath, provenancePath }) {
  const files = [
    ["schema", schemaPath],
    ["consumer fixture manifest", manifestPath],
    ["provenance", provenancePath],
  ];
  for (const [name, file] of files) {
    let actual;
    try {
      actual = sha256File(file);
    } catch {
      throw new Error(`pinned ${name} is unavailable`);
    }
    const expected = name === "schema" ? PINNED_CONTRACT_SHA256.schema
      : name === "consumer fixture manifest" ? PINNED_CONTRACT_SHA256.manifest
        : PINNED_CONTRACT_SHA256.provenance;
    if (actual !== expected) throw new Error(`pinned ${name} SHA-256 mismatch`);
  }
}

// An evidence id is an observation identity, not a stable node alias.  Its
// material deliberately excludes the two self-referential evidence fields;
// the final evidence digest below then covers the complete record.
export const observationEvidenceId = (record) => {
  const material = structuredClone(record);
  if (plain(material.evidence)) {
    delete material.evidence.evidence_id;
    delete material.evidence.digest;
  }
  return `obs-${crypto.createHash("sha256").update(canonicalJson(material)).digest("hex").slice(0, 56)}`;
};

const SUPPORTED_KEYWORDS = new Set([
  "$schema", "$id", "$defs", "$ref", "title", "description", "oneOf", "const", "enum",
  "type", "minLength", "pattern", "format", "minimum", "minItems", "uniqueItems",
  "items", "required", "properties", "additionalProperties",
]);

const resolveRef = (schema, ref) => {
  if (!ref.startsWith("#/")) throw new Error(`unsupported external schema ref ${ref}`);
  return ref
    .slice(2)
    .split("/")
    .reduce((value, raw) => value?.[raw.replaceAll("~1", "/").replaceAll("~0", "~")], schema);
};

// Refuse to validate against a schema using keywords this validator does not
// implement; an unsupported keyword must fail loudly rather than no-op.
export function checkSchema(schema, node = schema, at = "$") {
  if (typeof node === "boolean") return;
  if (!plain(node)) throw new Error(`schema node must be an object at ${at}`);
  for (const key of Object.keys(node)) {
    if (!SUPPORTED_KEYWORDS.has(key)) throw new Error(`unsupported JSON Schema keyword ${key} at ${at}`);
  }
  if (node.$ref !== undefined && !resolveRef(schema, node.$ref)) throw new Error(`unresolved ref ${node.$ref} at ${at}`);
  if (node.type !== undefined && !["object", "array", "string", "integer", "boolean", "null"].includes(node.type)) {
    throw new Error(`unsupported type at ${at}`);
  }
  if (node.format !== undefined && node.format !== "date-time") throw new Error(`unsupported format at ${at}`);
  for (const [key, child] of Object.entries(node.properties ?? {})) checkSchema(schema, child, `${at}.properties.${key}`);
  for (const [key, child] of Object.entries(node.$defs ?? {})) checkSchema(schema, child, `${at}.$defs.${key}`);
  if (node.items) checkSchema(schema, node.items, `${at}.items`);
  for (const [index, child] of (node.oneOf ?? []).entries()) checkSchema(schema, child, `${at}.oneOf[${index}]`);
}

export function schemaErrors(schema, value, node = schema, at = "$") {
  if (node === true) return [];
  if (node === false) return [`${at}: forbidden`];
  if (node.$ref) return schemaErrors(schema, value, resolveRef(schema, node.$ref), at);
  if (node.oneOf) {
    const attempts = node.oneOf.map((child) => schemaErrors(schema, value, child, at));
    return attempts.filter((errors) => errors.length === 0).length === 1
      ? []
      : [`${at}: expected exactly one branch (${attempts.flat().join("; ")})`];
  }
  const errors = [];
  if (Object.hasOwn(node, "const") && canonicalJson(value) !== canonicalJson(node.const)) errors.push(`${at}: const mismatch`);
  if (node.enum && !node.enum.some((candidate) => canonicalJson(candidate) === canonicalJson(value))) errors.push(`${at}: enum mismatch`);
  if (node.type && !typeMatches(node.type, value)) return [...errors, `${at}: expected ${node.type}`];
  if (typeof value === "string") {
    if (node.minLength !== undefined && value.length < node.minLength) errors.push(`${at}: minLength`);
    if (node.pattern && !new RegExp(node.pattern).test(value)) errors.push(`${at}: pattern`);
    if (node.format === "date-time" && !UTC_SHAPE.test(value)) errors.push(`${at}: date-time`);
  }
  if (typeof value === "number" && node.minimum !== undefined && value < node.minimum) errors.push(`${at}: minimum`);
  if (Array.isArray(value)) {
    if (node.minItems !== undefined && value.length < node.minItems) errors.push(`${at}: minItems`);
    if (node.uniqueItems && new Set(value.map(canonicalJson)).size !== value.length) errors.push(`${at}: duplicate items`);
    if (node.items) value.forEach((item, index) => errors.push(...schemaErrors(schema, item, node.items, `${at}[${index}]`)));
  }
  if (plain(value)) {
    for (const field of node.required ?? []) if (!Object.hasOwn(value, field)) errors.push(`${at}.${field}: required`);
    for (const [field, child] of Object.entries(node.properties ?? {})) {
      if (Object.hasOwn(value, field)) errors.push(...schemaErrors(schema, value[field], child, `${at}.${field}`));
    }
    if (node.additionalProperties === false) {
      for (const field of Object.keys(value)) {
        if (!Object.hasOwn(node.properties ?? {}, field)) errors.push(`${at}.${field}: additional property`);
      }
    }
  }
  return errors;
}
